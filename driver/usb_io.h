// The modem's QMI interface over USB: plain C++ owned by the driver, run on the driver's Default
// queue. It knows nothing about QMI beyond finding frame boundaries, and nothing about QMAP.
//
// QMI control messages travel as USB CDC encapsulated commands and responses on the default
// control pipe, addressed to the interface. The interrupt endpoint announces waiting responses
// (A1 01, RESPONSE_AVAILABLE); the modem answers GET_ENCAPSULATED_RESPONSE with a STALL when it
// has none waiting.
//
// Data travels on the bulk pipes: kBulkReads reads stay posted on bulk IN once start_bulk is
// called, each re-posted after its completion; uplink transfers go out on bulk OUT from
// kUplinkSlots buffers, several in flight at once.
//
// Nothing here blocks: every request is asynchronous, and its completion arrives through an
// OSAction the driver created and forwards to the matching *_complete method.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <DriverKit/IOReturn.h>

#include "rmnet/stall.h"

class IOService;
class IOUSBHostInterface;
class IOUSBHostPipe;
class IOBufferMemoryDescriptor;
class OSAction;

// What UsbIo reports to its owner. None is called from inside UsbIo::send or send_uplink, and
// none once the owner has called finish_sending.
class UsbIoListener {
 public:
  virtual void on_control(const uint8_t* data, size_t len) = 0;  // one QMUX frame
  virtual void on_fatal(const char* what) = 0;  // USB has stopped for good (control or bulk)
  // One completed bulk read; the bytes are valid only during the call (the read is re-posted
  // after it returns). A zero-length or all-zero transfer is reported like any other.
  virtual void on_bulk_in(const uint8_t* data, size_t len) = 0;
  // The uplink transfer from `slot` completed; the slot is free again.
  virtual void on_bulk_out_done(int slot, bool ok) = 0;
  // The uplink is stuck (rmnet::kUplinkStallsStuck stalls, no successful transfer between them) for
  // the first time since a successful transfer: the owner should restart the session, after the
  // current call returns. A second time with no success between is on_fatal instead.
  virtual void on_uplink_stuck() = 0;
 protected:
  ~UsbIoListener() = default;
};

enum : uint32_t {
  kBulkReads = 32,       // bulk IN reads kept posted
  kUplinkSlots = 8,      // bulk OUT buffers
  kMaxDownlink = 31744,  // the largest downlink transfer Core accepts (data_format_usable)
  kMaxUplink = 16384,    // the largest uplink transfer Core accepts
};

// Bulk OUT stalls are counted by rmnet::UplinkStallCounter (core/include/rmnet/stall.h):
// rmnet::kUplinkStallsStuck stalls in a row, with no successful transfer between them, make the
// uplink stuck: the first time the owner restarts the session (on_uplink_stuck), the second time
// with no success since then the uplink is given up (on_fatal). A stall is a transfer that timed out
// (kUplinkTimeoutMs, 5 s) or was aborted by no one in this driver; the transfers queued together
// during one stall count once (UsbIo::bulk_out_complete decides which failures it reports).

// Completion actions made by the driver (its CreateAction* methods). UsbIo takes a reference
// to each and releases it with the other USB objects. Each bulk action carries its slot index
// as a uint32_t in its reference area.
struct UsbIoActions {
  OSAction* interrupt;    // TYPE(IOUSBHostPipe::CompleteAsyncIO)
  OSAction* control_out;  // TYPE(IOUSBHostDevice::CompleteAsyncDeviceRequest)
  OSAction* control_in;   // TYPE(IOUSBHostDevice::CompleteAsyncDeviceRequest)
  OSAction* bulk_in[kBulkReads];      // TYPE(IOUSBHostPipe::CompleteAsyncIO)
  OSAction* bulk_out[kUplinkSlots];   // TYPE(IOUSBHostPipe::CompleteAsyncIO)
};

// Bulk errors since open.
struct UsbIoStats {
  uint64_t bulk_in_errors;   // reads that completed with an error; aborts a recovery caused are not counted
  uint64_t bulk_out_errors;  // uplink transfers that failed or could not be submitted; not recovery aborts
  uint64_t recoveries;       // stall recoveries started on either bulk pipe
  uint64_t stall_clears;     // ClearStall calls on either bulk pipe (one per finished recovery)
  // Reads that came back filled to their length: the read size, not the modem's aggregation,
  // ended the transfer.
  uint64_t full_reads;
  // Uplink transfers that ended in their timeout, or were aborted while running and not by a
  // recovery (also in bulk_out_errors), whether or not they counted as a new stall.
  uint64_t bulk_out_timeouts;
  uint64_t uplink_stuck_restarts;  // times the uplink was stuck and a session restart was asked for
  // Completions of any kind that arrived while held (hold), and the last status other than success
  // among them. They are counted only here, never in the error counts above.
  uint64_t sleep_completions;
  uint32_t sleep_last_status;
};

class UsbIo {
 public:
  explicit UsbIo(UsbIoListener& listener);
  ~UsbIo();  // releases whatever is still held
  UsbIo(const UsbIo&) = delete;
  UsbIo& operator=(const UsbIo&) = delete;

  // Opens the interface for `owner`, copies its bulk in, bulk out and interrupt in pipes and
  // creates the control and bulk buffers. Nothing is sent.
  kern_return_t open(IOService* owner, IOUSBHostInterface* intf, const UsbIoActions& actions);
  // The device's USB serial number as ASCII, or an empty string. Reads the device and string
  // descriptors (once, at start).
  void read_serial(char* out, size_t cap);
  // Raises DTR, keeps one interrupt read posted, and reads any responses already waiting.
  kern_return_t start();
  // Queues one SEND_ENCAPSULATED_COMMAND; messages go out one at a time, in order. False if the
  // message is too long, the ring is full, or UsbIo is stopping.
  bool send(const uint8_t* data, size_t len);

  // A bulk pipe whose endpoint halts is recovered without blocking: nothing new is posted on it,
  // it is aborted asynchronously, and ClearStall runs only once nothing is pending on it. While
  // bulk OUT recovers, acquire_uplink gives no buffer (uplink_recovering() says why). A failed
  // abort, or a recovery not finished within about 1 s (tick), is fatal. A timed-out uplink
  // transfer does not halt the pipe; rmnet::kUplinkStallsStuck stalls in a row, with no successful
  // transfer between, ask for a session restart, and again after it are fatal ("uplink is not
  // accepting data").
  //
  // Bulk IN: posts every idle read, each `read_len` bytes (rounded up to the endpoint's packet
  // size, at most kMaxDownlink). Later re-posts use the newest length. Reads keep being re-posted
  // until finish_sending. A read that cannot be posted is fatal.
  void start_bulk(uint32_t read_len);
  // Bulk OUT. acquire_uplink reserves a free buffer and returns its slot, or -1 when all are in
  // use; uplink_buffer gives its kMaxUplink bytes. send_uplink sends `len` bytes from a reserved
  // slot (false if it could not be submitted; the slot is then free again); release_uplink frees
  // a reserved slot unsent. Nothing is sent once finish_sending has been called.
  int acquire_uplink();
  uint8_t* uplink_buffer(int slot) const;
  bool send_uplink(int slot, uint32_t len);
  void release_uplink(int slot);
  bool uplink_recovering() const { return out_recovering_; }
  // True once any request or submission has returned not-attached or no-device: the device has
  // gone (a re-enumeration or an unplug), as opposed to a failure of a device still present.
  bool device_gone() const { return gone_; }
  // Called by the owner every 100 ms while running: bounds a pipe recovery to about 1 s, after
  // which it is fatal. Does nothing once finish_sending or abort has been called, or while held.
  void tick();
  // Sleep. hold (the system is going to sleep): nothing is posted, re-posted, submitted or sent
  // and nothing is delivered to the listener: no interrupt or bulk read, no uplink transfer
  // (acquire_uplink gives no buffer), no control message (send refuses it), no response read and
  // no pipe recovery or ClearStall. Completions that arrive while held free their request and are
  // counted in sleep_completions only: never toward a failure limit, never a recovery, never
  // on_fatal; a not-attached or no-device status still sets device_gone. Only while running.
  // resume (after the wake), one attempt; the owner may make several for one wake. Failed, and
  // the hold stays, if USB has failed or the device has gone. The first attempt after a hold clears
  // the failure memory (the uplink stall count and its restart memory, transfers submitted before
  // it no longer counting as new stalls, the per-read and interrupt failure counts, the recovery
  // counts in a row). Each attempt finishes a bulk IN recovery whose reads have all returned (one
  // ClearStall per recovery, whatever the attempts) and posts the interrupt read and every bulk read
  // not posted; requests an earlier attempt posted stay posted and are not posted again.
  // - A post refused with a status other than not-attached or no-device, when last_try is false:
  //   NotYet. The hold stays (held_), nothing is reported to the listener, and what this attempt
  //   posted stays posted (its completions are handled as every completion while held is). Logged
  //   at the first refusal of a wake and at power-of-two counts after it.
  // - A post refused with not-attached or no-device, or any refusal when last_try is true: Failed.
  //   As a refused post at the wake always was: the hold ends and the failure is reported through
  //   on_fatal.
  // - Every post made, in this attempt or earlier ones: Done. Only then does the hold end; the
  //   bulk OUT recovery whose transfers have returned is finished, the queued control messages are
  //   sent and any waiting response is read.
  // hold resets the attempts: the next resume is the first of a new wake. finish_sending on a held
  // UsbIo ends the hold and drops the messages waiting behind it; stopping then goes on as it does
  // when not held.
  enum class Resume : uint8_t { Done, NotYet, Failed };
  void hold();
  Resume resume(bool last_try);
  bool held() const { return held_; }
  uint16_t bulk_out_packet_size() const { return bulk_out_mps_; }  // from the endpoint descriptor
  const UsbIoStats& stats() const { return stats_; }
  // Stopping, in three calls made by the owner (docs/driverkit-notes.md 3.9):
  // finish_sending: no new messages or uplink transfers are accepted, reads (control and bulk)
  // are no longer re-posted or delivered, and the messages already queued keep going out in order. sending_done() says when the ring is
  // empty or a request failed (the device is gone).
  void finish_sending();
  bool sending_done() const;
  // abort: drops what is still queued, aborts the pipes (bulk reads and uplink transfers
  // included) and the control requests. The owner then
  // waits until outstanding() is 0 (its completions keep arriving through the *_complete methods).
  void abort();
  // close_and_release: closes the interface and releases every USB object and action.
  void close_and_release();
  // close: closes the interface only, when the owner gives up waiting for aborted requests; the
  // objects are then released by the destructor.
  void close();
  uint32_t queued() const { return count_; }  // messages in the ring, the one in flight included
  uint32_t sent_at_stop() const { return sent_at_stop_; }
  uint32_t dropped_at_stop() const { return dropped_at_stop_; }

  // Completions, forwarded by the driver.
  void interrupt_complete(IOReturn status, uint32_t bytes);
  void control_out_complete(IOReturn status, uint32_t bytes);
  void control_in_complete(IOReturn status, uint32_t bytes);
  void bulk_in_complete(uint32_t slot, IOReturn status, uint32_t bytes);
  void bulk_out_complete(uint32_t slot, IOReturn status, uint32_t bytes);

  // Requests posted whose completion has not arrived yet: control, interrupt, bulk reads and
  // uplink transfers.
  uint32_t outstanding() const {
    return uint32_t{intr_busy_} + in_busy_ + out_busy_ + reads_busy_ + uplinks_busy_;
  }

 private:
  enum : uint32_t { kRingSlots = 8, kSlotSize = 128, kResponseSize = 4096, kMaxDrain = 64 };
  enum class Uplink : uint8_t { Free, Reserved, InFlight };

  struct Slot {
    uint8_t request;  // SEND_ENCAPSULATED_COMMAND or SET_CONTROL_LINE_STATE
    uint16_t value;
    uint16_t len;
  };

  bool queue(uint8_t request, uint16_t value, const uint8_t* data, size_t len);
  void submit_next();
  kern_return_t post_interrupt();
  void begin_drain();
  void post_response_read();
  void end_drain();
  void deliver(uint32_t bytes);
  void post_read(uint32_t slot);
  kern_return_t submit_read(uint32_t slot);
  kern_return_t clear_in_stall();
  Resume resume_refused(const char* what, const char* fatal, IOReturn status, bool last_try);
  void begin_in_recovery();
  void end_in_recovery();
  void begin_out_recovery();
  void end_out_recovery();
  void fail(const char* what);
  void note(IOReturn status);
  void note_held(const char* what, IOReturn status);
  void release();

  UsbIoListener& listener_;
  IOService* owner_;  // not retained: the owner holds this object
  IOUSBHostInterface* intf_;
  uint8_t iface_number_;  // wIndex of every class request
  bool opened_;
  IOUSBHostPipe* bulk_in_;
  IOUSBHostPipe* bulk_out_;
  IOUSBHostPipe* intr_in_;
  uint16_t intr_size_;
  uint16_t bulk_in_mps_;
  uint16_t bulk_out_mps_;
  OSAction* intr_action_;
  OSAction* out_action_;
  OSAction* in_action_;
  IOBufferMemoryDescriptor* intr_buf_;
  uint8_t* intr_addr_;
  IOBufferMemoryDescriptor* in_buf_;
  uint8_t* in_addr_;
  IOBufferMemoryDescriptor* out_buf_[kRingSlots];
  uint8_t* out_addr_[kRingSlots];
  Slot slots_[kRingSlots];
  // Bulk IN reads.
  OSAction* read_action_[kBulkReads];
  IOBufferMemoryDescriptor* read_buf_[kBulkReads];
  uint8_t* read_addr_[kBulkReads];
  bool read_busy_[kBulkReads];
  uint8_t read_failures_[kBulkReads];  // consecutive failures of each read
  uint32_t reads_busy_;
  uint32_t read_len_;  // 0 until start_bulk
  // Bulk OUT buffers.
  OSAction* uplink_action_[kUplinkSlots];
  IOBufferMemoryDescriptor* uplink_buf_[kUplinkSlots];
  uint8_t* uplink_addr_[kUplinkSlots];
  Uplink uplink_[kUplinkSlots];
  uint32_t uplinks_busy_;  // in flight
  UsbIoStats stats_;
  bool logged_first_read_;
  bool logged_first_uplink_;
  bool in_recovering_;   // bulk IN: aborted for a stall, waiting for its reads to return
  bool out_recovering_;  // bulk OUT: the same for the uplink transfers
  uint32_t in_recoveries_;   // recoveries in a row with no successful read between
  uint32_t out_recoveries_;  // recoveries in a row with no successful transfer between
  uint32_t in_recovery_ticks_;   // ticks since the current bulk IN recovery began
  uint32_t out_recovery_ticks_;  // ticks since the current bulk OUT recovery began
  // Bulk OUT stalls. Each submitted transfer's sequence number (UplinkStallCounter::submitted) is
  // kept in out_submit_seq_ for its slot and given back to the counter if the transfer stalls.
  rmnet::UplinkStallCounter out_stalls_;
  uint64_t out_submit_seq_[kUplinkSlots];
  uint32_t head_;   // oldest queued slot
  uint32_t count_;  // queued slots, the head one in flight when out_busy_
  bool out_busy_;
  bool intr_busy_;
  bool in_busy_;
  uint32_t drain_reads_;  // response reads in the current drain
  bool drain_again_;      // a notification arrived during the drain
  uint32_t intr_failures_;
  enum class Phase : uint8_t { Running, Draining, Aborted, Released };
  Phase phase_;
  bool failed_;
  bool held_;  // hold: the system sleeps; only while phase_ is Running
  // The resume attempts of the current wake, reset by hold.
  struct ResumeState {
    uint32_t attempts;       // resume calls made while held
    uint32_t refusals;       // posts refused (NotYet)
    uint32_t reads_pending;  // bulk reads still pending at the first attempt
    uint32_t reads_posted;   // bulk reads posted by the attempts
    bool intr_posted;        // the interrupt read was posted by an attempt
    bool in_was_recovering;  // bulk IN was recovering at the first attempt
  };
  ResumeState resume_;
  bool gone_;  // a status said the device is not attached (device_gone)
  bool send_failed_;         // a control request failed while draining
  uint32_t sent_at_stop_;    // messages sent after finish_sending
  uint32_t dropped_at_stop_; // messages not sent after finish_sending
};
