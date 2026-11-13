// The control side of the modem's QMI interface: plain C++ owned by the driver, run on the
// driver's Default queue. It knows nothing about QMI beyond finding frame boundaries.
//
// QMI control messages travel as USB CDC encapsulated commands and responses on the default
// control pipe, addressed to the interface. The interrupt endpoint announces waiting responses
// (A1 01, RESPONSE_AVAILABLE); the modem answers GET_ENCAPSULATED_RESPONSE with a STALL when it
// has none waiting. Bulk pipes are copied here but carry nothing yet.
//
// Nothing here blocks: every request is asynchronous, and its completion arrives through an
// OSAction the driver created and forwards to the matching *_complete method.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <DriverKit/IOReturn.h>

class IOService;
class IOUSBHostInterface;
class IOUSBHostPipe;
class IOBufferMemoryDescriptor;
class OSAction;

// What UsbIo reports to its owner. Neither is called from inside UsbIo::send.
class UsbIoListener {
 public:
  virtual void on_control(const uint8_t* data, size_t len) = 0;  // one QMUX frame
  virtual void on_fatal(const char* what) = 0;  // the control channel has stopped for good
 protected:
  ~UsbIoListener() = default;
};

// Completion actions made by the driver (its CreateAction* methods). UsbIo takes a reference
// to each and releases it with the other USB objects.
struct UsbIoActions {
  OSAction* interrupt;    // TYPE(IOUSBHostPipe::CompleteAsyncIO)
  OSAction* control_out;  // TYPE(IOUSBHostDevice::CompleteAsyncDeviceRequest)
  OSAction* control_in;   // TYPE(IOUSBHostDevice::CompleteAsyncDeviceRequest)
};

class UsbIo {
 public:
  explicit UsbIo(UsbIoListener& listener);
  ~UsbIo();  // releases whatever is still held
  UsbIo(const UsbIo&) = delete;
  UsbIo& operator=(const UsbIo&) = delete;

  // Opens the interface for `owner`, copies its bulk in, bulk out and interrupt in pipes and
  // creates the control buffers. Nothing is sent.
  kern_return_t open(IOService* owner, IOUSBHostInterface* intf, const UsbIoActions& actions);
  // The device's USB serial number as ASCII, or an empty string. Reads the device and string
  // descriptors (once, at start).
  void read_serial(char* out, size_t cap);
  // Raises DTR, keeps one interrupt read posted, and reads any responses already waiting.
  kern_return_t start();
  // Queues one SEND_ENCAPSULATED_COMMAND; messages go out one at a time, in order. False if the
  // message is too long, the ring is full, or UsbIo is stopping.
  bool send(const uint8_t* data, size_t len);
  // Stopping, in three calls made by the owner (docs/driverkit-notes.md 3.9):
  // finish_sending: no new messages are accepted, reads are no longer re-posted or delivered, and
  // the messages already queued keep going out in order. sending_done() says when the ring is
  // empty or a request failed (the device is gone).
  void finish_sending();
  bool sending_done() const;
  // abort: drops what is still queued, aborts the pipes and the control requests. The owner then
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

  // Requests posted whose completion has not arrived yet.
  uint32_t outstanding() const { return uint32_t{intr_busy_} + in_busy_ + out_busy_; }

 private:
  enum : uint32_t { kRingSlots = 8, kSlotSize = 128, kResponseSize = 4096, kMaxDrain = 64 };

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
  void fail(const char* what);
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
  bool send_failed_;         // a control request failed while draining
  uint32_t sent_at_stop_;    // messages sent after finish_sending
  uint32_t dropped_at_stop_; // messages not sent after finish_sending
};
