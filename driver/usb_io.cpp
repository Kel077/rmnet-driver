#include "usb_io.h"

#include <os/log.h>
#include <string.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/OSAction.h>
#include <USBDriverKit/USBDriverKit.h>  // umbrella: also declares IOUSBHostFreeDescriptor

#include "rmnet/qmi.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "RMNet: " fmt, ##__VA_ARGS__)

namespace {

constexpr uint8_t kHostToInterfaceClass = 0x21;     // host-to-device, class, interface
constexpr uint8_t kInterfaceToHostClass = 0xA1;     // device-to-host, class, interface
constexpr uint8_t kSendEncapsulatedCommand = 0x00;  // CDC SEND_ENCAPSULATED_COMMAND
constexpr uint8_t kGetEncapsulatedResponse = 0x01;  // CDC GET_ENCAPSULATED_RESPONSE
constexpr uint8_t kSetControlLineState = 0x22;      // CDC SET_CONTROL_LINE_STATE
constexpr uint16_t kDtr = 1;
constexpr uint8_t kNotifyResponseAvailable = 0x01;  // CDC notification RESPONSE_AVAILABLE
constexpr uint32_t kControlTimeoutMs = 5000;
constexpr uint32_t kMaxInterruptFailures = 5;  // in a row, each followed by a stall clear
constexpr uint16_t kDefaultInterruptSize = 64;
constexpr uint16_t kDefaultBulkPacketSize = 512;  // USB 2.0 high speed, if the descriptor gives none
constexpr uint8_t kMaxReadFailures = 5;  // aborts in a row of one bulk read outside a recovery
constexpr uint8_t kMaxRecoveries = 5;    // stall recoveries in a row of one bulk pipe, no success between
constexpr uint32_t kRecoveryTicks = 10;  // a recovery not finished after this many ticks (~1 s) is fatal
constexpr uint32_t kUplinkTimeoutMs = 5000;  // a write the modem does not take frees its buffer
// The modem answers an empty GET_ENCAPSULATED_RESPONSE with a STALL. Accept the legacy code too.
constexpr IOReturn kLegacyPipeStalled = (IOReturn)0xe000404f;

kern_return_t MakeBuffer(IOUSBHostInterface* intf, IOOptionBits dir, uint32_t size,
                         IOBufferMemoryDescriptor** buf, uint8_t** addr) {
  kern_return_t ret = intf->CreateIOBuffer(dir, size, buf);
  if (ret != kIOReturnSuccess) return ret;
  ret = (*buf)->SetLength(size);
  if (ret != kIOReturnSuccess) return ret;
  IOAddressSegment seg{};
  ret = (*buf)->GetAddressRange(&seg);
  *addr = reinterpret_cast<uint8_t*>(seg.address);
  return ret;
}

// Errors are logged when their count is a power of two (1, 2, 4, 8, ...): the first ones in
// full, then ever more rarely. The counters carry the rest.
bool Worth(uint64_t n) { return n != 0 && (n & (n - 1)) == 0; }

// The SDK (IOUSBHostPipe.iig, ClearStall): any IO error other than a timeout halts a bulk
// endpoint. Aborts are ours (a recovery, or stop); a device that is gone cannot be recovered.
bool Halts(IOReturn status) {
  return status != kIOReturnSuccess && status != kIOReturnAborted && status != kIOReturnTimeout &&
         status != kIOReturnNotAttached && status != kIOReturnNoDevice;
}

bool Gone(IOReturn status) { return status == kIOReturnNotAttached || status == kIOReturnNoDevice; }

uint16_t PacketSize(IOUSBHostPipe* pipe, const IOUSBEndpointDescriptor* ep, uint16_t fallback) {
  uint8_t speed = 0;
  if (pipe->GetSpeed(&speed) != kIOReturnSuccess) return fallback;
  uint16_t mps = IOUSBGetEndpointMaxPacketSize(speed, ep);
  return mps > 0 ? mps : fallback;
}

}  // namespace

UsbIo::UsbIo(UsbIoListener& listener)
    : listener_(listener),
      owner_(nullptr),
      intf_(nullptr),
      iface_number_(0),
      opened_(false),
      bulk_in_(nullptr),
      bulk_out_(nullptr),
      intr_in_(nullptr),
      intr_size_(kDefaultInterruptSize),
      bulk_in_mps_(kDefaultBulkPacketSize),
      bulk_out_mps_(kDefaultBulkPacketSize),
      intr_action_(nullptr),
      out_action_(nullptr),
      in_action_(nullptr),
      intr_buf_(nullptr),
      intr_addr_(nullptr),
      in_buf_(nullptr),
      in_addr_(nullptr),
      out_buf_(),
      out_addr_(),
      slots_(),
      read_action_(),
      read_buf_(),
      read_addr_(),
      read_busy_(),
      read_failures_(),
      reads_busy_(0),
      read_len_(0),
      uplink_action_(),
      uplink_buf_(),
      uplink_addr_(),
      uplink_(),
      uplinks_busy_(0),
      stats_(),
      logged_first_read_(false),
      logged_first_uplink_(false),
      in_recovering_(false),
      out_recovering_(false),
      in_recoveries_(0),
      out_recoveries_(0),
      in_recovery_ticks_(0),
      out_recovery_ticks_(0),
      head_(0),
      count_(0),
      out_busy_(false),
      intr_busy_(false),
      in_busy_(false),
      drain_reads_(0),
      drain_again_(false),
      intr_failures_(0),
      phase_(Phase::Running),
      failed_(false),
      send_failed_(false),
      sent_at_stop_(0),
      dropped_at_stop_(0) {}

UsbIo::~UsbIo() {
  if (opened_) {
    intf_->Close(owner_, 0);
    opened_ = false;
  }
  if (phase_ != Phase::Released && outstanding() > 0) LOG("usb freed with %u requests outstanding", outstanding());
  release();
}

kern_return_t UsbIo::open(IOService* owner, IOUSBHostInterface* intf, const UsbIoActions& actions) {
  owner_ = owner;
  intf_ = intf;
  intf_->retain();
  intr_action_ = actions.interrupt;
  out_action_ = actions.control_out;
  in_action_ = actions.control_in;
  intr_action_->retain();
  out_action_->retain();
  in_action_->retain();
  for (uint32_t i = 0; i < kBulkReads; i++) {
    read_action_[i] = actions.bulk_in[i];
    read_action_[i]->retain();
  }
  for (uint32_t i = 0; i < kUplinkSlots; i++) {
    uplink_action_[i] = actions.bulk_out[i];
    uplink_action_[i]->retain();
  }

  kern_return_t ret = intf_->Open(owner_, 0, nullptr);
  if (ret != kIOReturnSuccess) return ret;
  opened_ = true;

  // The interface's endpoints: one bulk in, one bulk out, one interrupt in.
  const IOUSBConfigurationDescriptor* cfg = intf_->CopyConfigurationDescriptor();
  if (!cfg) return kIOReturnNotFound;
  const IOUSBInterfaceDescriptor* id = intf_->GetInterfaceDescriptor(cfg);
  if (!id) {
    IOUSBHostFreeDescriptor(cfg);
    return kIOReturnNotFound;
  }
  iface_number_ = id->bInterfaceNumber;
  const IOUSBEndpointDescriptor* ep = nullptr;
  while (ret == kIOReturnSuccess &&
         (ep = IOUSBGetNextEndpointDescriptor(cfg, id, reinterpret_cast<const IOUSBDescriptorHeader*>(ep)))) {
    uint8_t type = IOUSBGetEndpointType(ep);
    bool in = IOUSBGetEndpointDirection(ep) == kIOUSBEndpointDirectionIn;
    uint8_t addr = IOUSBGetEndpointAddress(ep);
    if (type == kIOUSBEndpointTypeBulk && in && !bulk_in_) {
      ret = intf_->CopyPipe(addr, &bulk_in_);
      if (ret == kIOReturnSuccess) bulk_in_mps_ = PacketSize(bulk_in_, ep, kDefaultBulkPacketSize);
    } else if (type == kIOUSBEndpointTypeBulk && !in && !bulk_out_) {
      ret = intf_->CopyPipe(addr, &bulk_out_);
      if (ret == kIOReturnSuccess) bulk_out_mps_ = PacketSize(bulk_out_, ep, kDefaultBulkPacketSize);
    } else if (type == kIOUSBEndpointTypeInterrupt && in && !intr_in_) {
      ret = intf_->CopyPipe(addr, &intr_in_);
      if (ret == kIOReturnSuccess) intr_size_ = PacketSize(intr_in_, ep, kDefaultInterruptSize);
    }
  }
  IOUSBHostFreeDescriptor(cfg);
  if (ret != kIOReturnSuccess) return ret;
  if (!bulk_in_ || !bulk_out_ || !intr_in_) {
    LOG("interface lacks a bulk in, bulk out or interrupt in endpoint");
    return kIOReturnNotFound;
  }

  ret = MakeBuffer(intf_, kIOMemoryDirectionInOut, intr_size_, &intr_buf_, &intr_addr_);
  if (ret != kIOReturnSuccess) return ret;
  ret = MakeBuffer(intf_, kIOMemoryDirectionInOut, kResponseSize, &in_buf_, &in_addr_);
  if (ret != kIOReturnSuccess) return ret;
  for (uint32_t i = 0; i < kRingSlots; i++) {
    ret = MakeBuffer(intf_, kIOMemoryDirectionInOut, kSlotSize, &out_buf_[i], &out_addr_[i]);
    if (ret != kIOReturnSuccess) return ret;
  }
  // Bulk buffers at the largest sizes Core accepts, so a later session granting other sizes
  // needs no new buffers; reads and transfers use the granted sizes. InOut: the dext writes the
  // uplink buffers, and an Out buffer is read-only to the dext (Runtime findings, Task 5).
  for (uint32_t i = 0; i < kBulkReads; i++) {
    ret = MakeBuffer(intf_, kIOMemoryDirectionInOut, kMaxDownlink, &read_buf_[i], &read_addr_[i]);
    if (ret != kIOReturnSuccess) return ret;
    *static_cast<uint32_t*>(read_action_[i]->GetReference()) = i;
  }
  for (uint32_t i = 0; i < kUplinkSlots; i++) {
    ret = MakeBuffer(intf_, kIOMemoryDirectionInOut, kMaxUplink, &uplink_buf_[i], &uplink_addr_[i]);
    if (ret != kIOReturnSuccess) return ret;
    *static_cast<uint32_t*>(uplink_action_[i]->GetReference()) = i;
  }
  LOG("usb: bulk in packet %u, bulk out packet %u, interrupt %u bytes", bulk_in_mps_, bulk_out_mps_, intr_size_);
  return kIOReturnSuccess;
}

void UsbIo::read_serial(char* out, size_t cap) {
  if (cap == 0) return;
  out[0] = '\0';
  IOUSBHostDevice* dev = nullptr;
  if (intf_->CopyDevice(&dev) != kIOReturnSuccess || !dev) return;
  uint8_t index = 0;
  const IOUSBDeviceDescriptor* dd = dev->CopyDeviceDescriptor();
  if (dd) {
    index = dd->iSerialNumber;
    IOUSBHostFreeDescriptor(dd);
  }
  OSSafeReleaseNULL(dev);
  if (index == 0) return;
  const IOUSBStringDescriptor* sd = intf_->CopyStringDescriptor(index);
  if (!sd) return;
  // UTF-16LE after the two header bytes; anything outside printable ASCII becomes '?'.
  size_t chars = sd->bLength >= 2 ? (sd->bLength - 2u) / 2u : 0;
  size_t n = 0;
  for (size_t i = 0; i < chars && n + 1 < cap; i++) {
    uint8_t lo = sd->bString[2 * i];
    uint8_t hi = sd->bString[2 * i + 1];
    out[n++] = (hi == 0 && lo > 0x20 && lo < 0x7f) ? static_cast<char>(lo) : '?';
  }
  out[n] = '\0';
  IOUSBHostFreeDescriptor(sd);
}

kern_return_t UsbIo::start() {
  if (!queue(kSetControlLineState, kDtr, nullptr, 0)) return kIOReturnNoResources;
  kern_return_t ret = post_interrupt();
  if (ret != kIOReturnSuccess) return ret;
  // Responses left from an earlier session may sit without a fresh notification; read them now.
  // Core ignores any that do not answer its outstanding request.
  begin_drain();
  return kIOReturnSuccess;
}

bool UsbIo::send(const uint8_t* data, size_t len) {
  if (len == 0) return false;
  return queue(kSendEncapsulatedCommand, 0, data, len);
}

bool UsbIo::queue(uint8_t request, uint16_t value, const uint8_t* data, size_t len) {
  if (phase_ != Phase::Running || !opened_) return false;
  if (len > kSlotSize) {
    LOG("control message of %zu bytes dropped: longer than %u", len, (unsigned)kSlotSize);
    return false;
  }
  if (count_ == kRingSlots) {
    LOG("control message dropped: all %u buffers in use", (unsigned)kRingSlots);
    return false;
  }
  uint32_t i = (head_ + count_) % kRingSlots;
  if (len) memcpy(out_addr_[i], data, len);
  slots_[i] = Slot{request, value, static_cast<uint16_t>(len)};
  count_++;
  submit_next();
  return true;
}

// Sends the oldest queued message unless one is already in flight. A message that cannot be
// submitted is dropped (the session's timeout recovers), and the next one is tried; while
// draining at stop, a failure ends the drain instead (abort drops the rest).
void UsbIo::submit_next() {
  while (!out_busy_ && count_ > 0 && (phase_ == Phase::Running || phase_ == Phase::Draining)) {
    uint32_t i = head_;
    const Slot& s = slots_[i];
    kern_return_t ret = kIOReturnSuccess;
    if (s.len) ret = out_buf_[i]->SetLength(s.len);
    if (ret == kIOReturnSuccess) {
      ret = intf_->AsyncDeviceRequest(kHostToInterfaceClass, s.request, s.value, iface_number_, s.len,
                                      s.len ? out_buf_[i] : nullptr, out_action_, kControlTimeoutMs);
    }
    if (ret == kIOReturnSuccess) {
      out_busy_ = true;
      return;
    }
    LOG("control request 0x%02x not submitted: 0x%x", s.request, ret);
    head_ = (head_ + 1) % kRingSlots;
    count_--;
    if (phase_ == Phase::Draining) {
      dropped_at_stop_++;
      send_failed_ = true;
      return;
    }
  }
}

void UsbIo::control_out_complete(IOReturn status, uint32_t) {
  out_busy_ = false;
  if (count_ > 0) {
    uint8_t request = slots_[head_].request;
    head_ = (head_ + 1) % kRingSlots;
    count_--;
    if (status != kIOReturnSuccess && phase_ != Phase::Aborted) LOG("control request 0x%02x failed: 0x%x", request, status);
    if (phase_ == Phase::Draining) {
      if (status == kIOReturnSuccess) {
        sent_at_stop_++;
      } else {
        dropped_at_stop_++;
        send_failed_ = true;
      }
    } else if (phase_ == Phase::Aborted) {
      if (status == kIOReturnSuccess) sent_at_stop_++;
      else dropped_at_stop_++;
    }
  }
  if (phase_ == Phase::Draining && send_failed_) return;
  submit_next();
}

kern_return_t UsbIo::post_interrupt() {
  kern_return_t ret = intr_in_->AsyncIO(intr_buf_, intr_size_, intr_action_, 0);  // 0: interrupt endpoint
  if (ret == kIOReturnSuccess) intr_busy_ = true;
  return ret;
}

void UsbIo::interrupt_complete(IOReturn status, uint32_t bytes) {
  intr_busy_ = false;
  if (phase_ != Phase::Running) return;  // not re-posted while stopping
  if (status != kIOReturnSuccess) {
    intr_failures_++;
    LOG("interrupt read failed: 0x%x (%u in a row)", status, intr_failures_);
    if (intr_failures_ >= kMaxInterruptFailures) {
      fail("interrupt read keeps failing");
      return;
    }
    if (status != kIOReturnAborted) intr_in_->ClearStall(true);
  } else {
    intr_failures_ = 0;
    if (bytes >= 2 && intr_addr_[0] == kInterfaceToHostClass && intr_addr_[1] == kNotifyResponseAvailable) {
      begin_drain();
    }
  }
  kern_return_t ret = post_interrupt();
  if (ret != kIOReturnSuccess) {
    LOG("interrupt read not posted: 0x%x", ret);
    fail("interrupt read could not be posted");
  }
}

// Reads responses until the modem has none left (or kMaxDrain reads), one request at a time.
void UsbIo::begin_drain() {
  if (in_busy_) {
    drain_again_ = true;
    return;
  }
  drain_again_ = false;
  drain_reads_ = 0;
  post_response_read();
}

void UsbIo::post_response_read() {
  if (phase_ != Phase::Running) return;
  kern_return_t ret = intf_->AsyncDeviceRequest(kInterfaceToHostClass, kGetEncapsulatedResponse, 0, iface_number_,
                                                kResponseSize, in_buf_, in_action_, kControlTimeoutMs);
  if (ret != kIOReturnSuccess) {
    // The drain ends here. A notification noted during it is dropped with it: with no read in
    // flight, the next notification starts a fresh drain.
    LOG("response read not submitted: 0x%x", ret);
    drain_again_ = false;
    return;
  }
  in_busy_ = true;
  drain_reads_++;
}

void UsbIo::control_in_complete(IOReturn status, uint32_t bytes) {
  in_busy_ = false;
  if (phase_ != Phase::Running) return;  // Core is not called once stopping
  if (status == kIOReturnSuccess && bytes > 0) {
    deliver(bytes);
    if (phase_ != Phase::Running) return;
    if (drain_reads_ < kMaxDrain) {
      post_response_read();
      return;
    }
    LOG("response drain stopped after %u reads", (unsigned)kMaxDrain);
  } else if (status != kIOReturnSuccess && status != kUSBHostReturnPipeStalled && status != kLegacyPipeStalled) {
    LOG("response read failed: 0x%x", status);
  }
  // A STALL or an empty answer: nothing more waiting.
  end_drain();
}

void UsbIo::end_drain() {
  if (drain_again_) begin_drain();
}

// Hands each complete QMUX frame of a response to the listener. Bytes that do not start with a
// complete frame end the split and are discarded; nothing is carried over to the next read.
void UsbIo::deliver(uint32_t bytes) {
  size_t off = 0;
  while (off < bytes) {
    size_t n = rmnet::qmi_frame_length(rmnet::Span{in_addr_ + off, bytes - off});
    if (n == 0) break;
    listener_.on_control(in_addr_ + off, n);
    if (phase_ != Phase::Running) return;
    off += n;
  }
  if (off < bytes) LOG("discarded %zu bytes of a %u-byte response", bytes - off, bytes);
}

// --- Bulk IN ---------------------------------------------------------------------------------------

void UsbIo::start_bulk(uint32_t read_len) {
  if (phase_ != Phase::Running || !opened_) return;
  uint32_t mps = bulk_in_mps_ ? bulk_in_mps_ : kDefaultBulkPacketSize;
  uint32_t len = (read_len + mps - 1) / mps * mps;
  if (len == 0 || len > kMaxDownlink) len = kMaxDownlink;
  read_len_ = len;
  if (in_recovering_) return;  // the recovery re-posts every read when it ends
  for (uint32_t i = 0; i < kBulkReads && phase_ == Phase::Running && !failed_; i++) {
    if (!read_busy_[i]) post_read(i);
  }
}

void UsbIo::post_read(uint32_t i) {
  kern_return_t ret = bulk_in_->AsyncIO(read_buf_[i], read_len_, read_action_[i], 0);  // 0: no timeout
  if (ret == kIOReturnSuccess) {
    read_busy_[i] = true;
    reads_busy_++;
    return;
  }
  LOG("bulk read %u not posted: 0x%x", i, ret);
  fail("bulk read could not be posted");
}

// A failure that halts the endpoint starts a recovery of the pipe (begin_in_recovery): nothing
// is re-posted, the pipe is aborted asynchronously, and once no read is pending the stall is
// cleared and every read posted again (end_in_recovery). ClearStall is synchronous on the Default
// queue and aborts whatever is pending on the endpoint, so it is only called with nothing pending.
// kMaxRecoveries recoveries in a row with no successful read between them is fatal. Aborted
// completions during a recovery are expected and not counted; outside one (no cause known) the
// read is re-posted, and kMaxReadFailures of those in a row for one read is fatal. A device that
// is gone is fatal at once.
void UsbIo::bulk_in_complete(uint32_t i, IOReturn status, uint32_t bytes) {
  if (i >= kBulkReads || !read_busy_[i]) return;
  read_busy_[i] = false;
  reads_busy_--;
  // Not delivered or re-posted while stopping, nor after a fatal failure (the session is over).
  if (phase_ != Phase::Running || failed_) return;
  if (status == kIOReturnSuccess) {
    read_failures_[i] = 0;
    in_recoveries_ = 0;
    if (!logged_first_read_) {
      logged_first_read_ = true;
      LOG("first bulk read: %u bytes", bytes);
    }
    if (bytes >= read_len_) stats_.full_reads++;
    listener_.on_bulk_in(read_addr_[i], bytes);
    if (phase_ != Phase::Running || failed_) return;
    if (!in_recovering_) post_read(i);
  } else if (status == kIOReturnAborted && in_recovering_) {
    // Expected: the recovery aborted it.
  } else {
    stats_.bulk_in_errors++;
    if (Worth(stats_.bulk_in_errors)) {
      LOG("bulk read %u failed: 0x%x (%llu bulk read errors)", i, status, stats_.bulk_in_errors);
    }
    if (Gone(status)) {
      fail("bulk in: device not attached");
      return;
    }
    if (Halts(status)) {
      if (!in_recovering_) begin_in_recovery();
    } else if (!in_recovering_) {
      if (++read_failures_[i] >= kMaxReadFailures) {
        fail("bulk read keeps failing");
        return;
      }
      post_read(i);
    }
  }
  if (in_recovering_ && reads_busy_ == 0 && phase_ == Phase::Running && !failed_) end_in_recovery();
}

void UsbIo::begin_in_recovery() {
  in_recoveries_++;
  stats_.recoveries++;
  LOG("bulk in halted: recovery %u in a row, %u reads pending", in_recoveries_, reads_busy_);
  if (in_recoveries_ >= kMaxRecoveries) {
    fail("bulk in keeps stalling");
    return;
  }
  in_recovering_ = true;
  in_recovery_ticks_ = 0;
  if (reads_busy_ > 0) {
    // forClient must be NULL on a non-control pipe (IOUSBHostPipe.iig, Abort).
    kern_return_t ret = bulk_in_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, nullptr);
    if (ret != kIOReturnSuccess) {
      LOG("bulk in abort for recovery: 0x%x", ret);
      fail("bulk in could not be aborted for a stall recovery");
    }
  }
}

void UsbIo::end_in_recovery() {
  in_recovering_ = false;
  stats_.stall_clears++;
  kern_return_t ret = bulk_in_->ClearStall(true);
  LOG("bulk in recovered: ClearStall 0x%x, reads posted again", ret);
  for (uint32_t i = 0; i < kBulkReads && phase_ == Phase::Running && !failed_; i++) {
    if (!read_busy_[i]) post_read(i);
  }
}

// --- Bulk OUT --------------------------------------------------------------------------------------

int UsbIo::acquire_uplink() {
  if (phase_ != Phase::Running || !opened_ || out_recovering_) return -1;
  for (uint32_t i = 0; i < kUplinkSlots; i++) {
    if (uplink_[i] == Uplink::Free) {
      uplink_[i] = Uplink::Reserved;
      return static_cast<int>(i);
    }
  }
  return -1;
}

uint8_t* UsbIo::uplink_buffer(int slot) const {
  if (slot < 0 || slot >= static_cast<int>(kUplinkSlots)) return nullptr;
  return uplink_addr_[slot];
}

void UsbIo::release_uplink(int slot) {
  if (slot < 0 || slot >= static_cast<int>(kUplinkSlots)) return;
  if (uplink_[slot] == Uplink::Reserved) uplink_[slot] = Uplink::Free;
}

bool UsbIo::send_uplink(int slot, uint32_t len) {
  if (slot < 0 || slot >= static_cast<int>(kUplinkSlots) || uplink_[slot] != Uplink::Reserved) return false;
  if (phase_ != Phase::Running || out_recovering_ || len == 0 || len > kMaxUplink) {
    uplink_[slot] = Uplink::Free;
    return false;
  }
  kern_return_t ret = bulk_out_->AsyncIO(uplink_buf_[slot], len, uplink_action_[slot], kUplinkTimeoutMs);
  if (ret != kIOReturnSuccess) {
    uplink_[slot] = Uplink::Free;
    stats_.bulk_out_errors++;
    if (Worth(stats_.bulk_out_errors)) {
      LOG("uplink transfer not submitted: 0x%x (%llu bulk out errors)", ret, stats_.bulk_out_errors);
    }
    return false;
  }
  if (!logged_first_uplink_) {
    logged_first_uplink_ = true;
    LOG("first uplink transfer: %u bytes", len);
  }
  uplink_[slot] = Uplink::InFlight;
  uplinks_busy_++;
  return true;
}

// A failure that halts the endpoint starts a recovery of the pipe, as for bulk IN: no uplink
// transfer is started (acquire_uplink gives none), the pipe is aborted asynchronously, and once
// no transfer is in flight the stall is cleared. kMaxRecoveries in a row with no successful
// transfer between them is fatal. Aborts and timeouts leave the endpoint usable.
void UsbIo::bulk_out_complete(uint32_t i, IOReturn status, uint32_t) {
  if (i >= kUplinkSlots || uplink_[i] != Uplink::InFlight) return;
  uplink_[i] = Uplink::Free;
  uplinks_busy_--;
  bool ok = status == kIOReturnSuccess;
  bool expected_abort = status == kIOReturnAborted && out_recovering_;
  if (!ok && !expected_abort) {
    stats_.bulk_out_errors++;
    if (phase_ == Phase::Running && Worth(stats_.bulk_out_errors)) {
      LOG("uplink transfer failed: 0x%x (%llu bulk out errors)", status, stats_.bulk_out_errors);
    }
  }
  if (phase_ != Phase::Running || failed_) return;  // the owner is not called while stopping
  if (ok) out_recoveries_ = 0;
  listener_.on_bulk_out_done(static_cast<int>(i), ok);
  if (phase_ != Phase::Running || failed_) return;
  if (Gone(status)) {
    fail("bulk out: device not attached");
    return;
  }
  if (Halts(status) && !out_recovering_) begin_out_recovery();
  if (out_recovering_ && uplinks_busy_ == 0 && phase_ == Phase::Running && !failed_) end_out_recovery();
}

void UsbIo::begin_out_recovery() {
  out_recoveries_++;
  stats_.recoveries++;
  LOG("bulk out halted: recovery %u in a row, %u transfers in flight", out_recoveries_, uplinks_busy_);
  if (out_recoveries_ >= kMaxRecoveries) {
    fail("bulk out keeps stalling");
    return;
  }
  out_recovering_ = true;
  out_recovery_ticks_ = 0;
  if (uplinks_busy_ > 0) {
    // forClient must be NULL on a non-control pipe (IOUSBHostPipe.iig, Abort).
    kern_return_t ret = bulk_out_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, nullptr);
    if (ret != kIOReturnSuccess) {
      LOG("bulk out abort for recovery: 0x%x", ret);
      fail("bulk out could not be aborted for a stall recovery");
    }
  }
}

// The owner's 100 ms tick while running. A recovery whose aborted requests have not all returned
// within kRecoveryTicks is fatal, so a pipe cannot stay idle with the link reported up. Nothing
// happens once stopping has begun or after a fatal failure.
void UsbIo::tick() {
  if (phase_ != Phase::Running || failed_) return;
  if (in_recovering_ && ++in_recovery_ticks_ >= kRecoveryTicks) {
    LOG("bulk in recovery: %u reads still pending after %u ticks", reads_busy_, in_recovery_ticks_);
    fail("bulk in recovery did not finish within 1 s");
    return;
  }
  if (out_recovering_ && ++out_recovery_ticks_ >= kRecoveryTicks) {
    LOG("bulk out recovery: %u transfers still in flight after %u ticks", uplinks_busy_, out_recovery_ticks_);
    fail("bulk out recovery did not finish within 1 s");
  }
}

void UsbIo::end_out_recovery() {
  out_recovering_ = false;
  stats_.stall_clears++;
  kern_return_t ret = bulk_out_->ClearStall(true);
  LOG("bulk out recovered: ClearStall 0x%x, uplink open again", ret);
}

// --- Stopping ----------------------------------------------------------------------------------------

void UsbIo::fail(const char* what) {
  if (failed_) return;
  failed_ = true;
  listener_.on_fatal(what);
}

void UsbIo::finish_sending() {
  if (phase_ == Phase::Running) phase_ = Phase::Draining;
}

bool UsbIo::sending_done() const { return count_ == 0 || send_failed_ || !opened_; }

void UsbIo::abort() {
  if (phase_ == Phase::Aborted || phase_ == Phase::Released) return;
  phase_ = Phase::Aborted;
  // Messages queued behind the one in flight are dropped; the in-flight one is counted when its
  // completion pops it.
  uint32_t waiting = out_busy_ ? count_ - 1 : count_;
  dropped_at_stop_ += waiting;
  count_ -= waiting;
  for (uint32_t i = 0; i < kUplinkSlots; i++) {
    if (uplink_[i] == Uplink::Reserved) uplink_[i] = Uplink::Free;
  }
  if (opened_) {
    // forClient NULL: only control endpoints may name a client (IOUSBHostPipe.iig, Abort).
    if (intr_in_) intr_in_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, nullptr);
    if (bulk_in_) bulk_in_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, nullptr);
    if (bulk_out_) bulk_out_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, nullptr);
    intf_->AbortDeviceRequests(kIOUSBAbortAsynchronous, kIOReturnAborted);
  }
}

void UsbIo::close() {
  if (opened_) {
    intf_->Close(owner_, 0);
    opened_ = false;
  }
}

void UsbIo::close_and_release() {
  close();
  release();
}

void UsbIo::release() {
  phase_ = Phase::Released;
  OSSafeReleaseNULL(bulk_in_);
  OSSafeReleaseNULL(bulk_out_);
  OSSafeReleaseNULL(intr_in_);
  OSSafeReleaseNULL(intr_buf_);
  OSSafeReleaseNULL(in_buf_);
  for (uint32_t i = 0; i < kRingSlots; i++) OSSafeReleaseNULL(out_buf_[i]);
  for (uint32_t i = 0; i < kBulkReads; i++) {
    OSSafeReleaseNULL(read_buf_[i]);
    OSSafeReleaseNULL(read_action_[i]);
  }
  for (uint32_t i = 0; i < kUplinkSlots; i++) {
    OSSafeReleaseNULL(uplink_buf_[i]);
    OSSafeReleaseNULL(uplink_action_[i]);
  }
  OSSafeReleaseNULL(intr_action_);
  OSSafeReleaseNULL(out_action_);
  OSSafeReleaseNULL(in_action_);
  OSSafeReleaseNULL(intf_);
}
