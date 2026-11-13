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
      head_(0),
      count_(0),
      out_busy_(false),
      intr_busy_(false),
      in_busy_(false),
      drain_reads_(0),
      drain_again_(false),
      intr_failures_(0),
      stopping_(false),
      failed_(false),
      released_(false) {}

UsbIo::~UsbIo() {
  if (opened_) {
    intf_->Close(owner_, 0);
    opened_ = false;
  }
  if (!released_ && outstanding() > 0) LOG("usb freed with %u requests outstanding", outstanding());
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
    } else if (type == kIOUSBEndpointTypeBulk && !in && !bulk_out_) {
      ret = intf_->CopyPipe(addr, &bulk_out_);
    } else if (type == kIOUSBEndpointTypeInterrupt && in && !intr_in_) {
      ret = intf_->CopyPipe(addr, &intr_in_);
      uint8_t speed = 0;
      if (ret == kIOReturnSuccess && intr_in_->GetSpeed(&speed) == kIOReturnSuccess) {
        uint16_t mps = IOUSBGetEndpointMaxPacketSize(speed, ep);
        if (mps > 0) intr_size_ = mps;
      }
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
  if (stopping_ || !opened_) return false;
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
// submitted is dropped (the session's timeout recovers), and the next one is tried.
void UsbIo::submit_next() {
  while (!out_busy_ && count_ > 0 && !stopping_) {
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
  }
}

void UsbIo::control_out_complete(IOReturn status, uint32_t) {
  out_busy_ = false;
  if (count_ > 0) {
    uint8_t request = slots_[head_].request;
    head_ = (head_ + 1) % kRingSlots;
    count_--;
    if (status != kIOReturnSuccess && !stopping_) LOG("control request 0x%02x failed: 0x%x", request, status);
  }
  if (stopping_) {
    release_if_idle();
    return;
  }
  submit_next();
}

kern_return_t UsbIo::post_interrupt() {
  kern_return_t ret = intr_in_->AsyncIO(intr_buf_, intr_size_, intr_action_, 0);  // 0: interrupt endpoint
  if (ret == kIOReturnSuccess) intr_busy_ = true;
  return ret;
}

void UsbIo::interrupt_complete(IOReturn status, uint32_t bytes) {
  intr_busy_ = false;
  if (stopping_) {
    release_if_idle();
    return;
  }
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
  if (stopping_) return;
  kern_return_t ret = intf_->AsyncDeviceRequest(kInterfaceToHostClass, kGetEncapsulatedResponse, 0, iface_number_,
                                                kResponseSize, in_buf_, in_action_, kControlTimeoutMs);
  if (ret != kIOReturnSuccess) {
    LOG("response read not submitted: 0x%x", ret);
    return;
  }
  in_busy_ = true;
  drain_reads_++;
}

void UsbIo::control_in_complete(IOReturn status, uint32_t bytes) {
  in_busy_ = false;
  if (stopping_) {
    release_if_idle();
    return;
  }
  if (status == kIOReturnSuccess && bytes > 0) {
    deliver(bytes);
    if (stopping_) return;
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
    if (stopping_) return;
    off += n;
  }
  if (off < bytes) LOG("discarded %zu bytes of a %u-byte response", bytes - off, bytes);
}

void UsbIo::fail(const char* what) {
  if (failed_) return;
  failed_ = true;
  listener_.on_fatal(what);
}

void UsbIo::abort() {
  if (stopping_) return;
  stopping_ = true;
  // Messages queued behind the one in flight are dropped; its completion pops it.
  count_ = out_busy_ ? 1 : 0;
  if (opened_) {
    if (intr_in_) intr_in_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, owner_);
    if (bulk_in_) bulk_in_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, owner_);
    if (bulk_out_) bulk_out_->Abort(kIOUSBAbortAsynchronous, kIOReturnAborted, owner_);
    intf_->AbortDeviceRequests(kIOUSBAbortAsynchronous, kIOReturnAborted);
    intf_->Close(owner_, 0);
    opened_ = false;
  }
  LOG("usb aborted, %u requests outstanding", outstanding());
  release_if_idle();
}

void UsbIo::release_if_idle() {
  if (stopping_ && outstanding() == 0 && !released_) {
    release();
    LOG("usb objects released");
  }
}

void UsbIo::release() {
  released_ = true;
  OSSafeReleaseNULL(bulk_in_);
  OSSafeReleaseNULL(bulk_out_);
  OSSafeReleaseNULL(intr_in_);
  OSSafeReleaseNULL(intr_buf_);
  OSSafeReleaseNULL(in_buf_);
  for (uint32_t i = 0; i < kRingSlots; i++) OSSafeReleaseNULL(out_buf_[i]);
  OSSafeReleaseNULL(intr_action_);
  OSSafeReleaseNULL(out_action_);
  OSSafeReleaseNULL(in_action_);
  OSSafeReleaseNULL(intf_);
}
