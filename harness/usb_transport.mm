#include "usb_transport.h"

#include "rmnet/qmi.h"

#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBHostFamilyDefinitions.h>
#import <IOKit/usb/USBSpec.h>
#import <IOUSBHost/IOUSBHost.h>
#include <libkern/OSByteOrder.h>
#include <stdio.h>

#include <vector>

namespace {

constexpr uint16_t kVendor = 0x2c7c;
constexpr uint16_t kProduct = 0x0801;
constexpr uint8_t kVendorSpecific = 0xff;  // interface class, subclass and protocol of QMI
constexpr int64_t kQmiInterfaceNumber = 4;  // the only interface the harness may open

// USB CDC class requests, addressed to the interface.
constexpr uint8_t kHostToInterfaceClass = 0x21;     // host-to-device, class, interface
constexpr uint8_t kInterfaceToHostClass = 0xA1;     // device-to-host, class, interface
constexpr uint8_t kSendEncapsulatedCommand = 0x00;  // CDC SEND_ENCAPSULATED_COMMAND
constexpr uint8_t kGetEncapsulatedResponse = 0x01;  // CDC GET_ENCAPSULATED_RESPONSE
constexpr uint8_t kSetControlLineState = 0x22;      // CDC SET_CONTROL_LINE_STATE
constexpr uint8_t kNotifyResponseAvailable = 0x01;  // CDC notification RESPONSE_AVAILABLE
constexpr uint16_t kResponseLength = 16384;
constexpr int kMaxDrain = 64;
constexpr int kBulkReadsPosted = 8;
// Consecutive failures of one posted read (each followed by a stall clear and a re-post) before
// the path is given up and the error handler is told.
constexpr int kMaxReadRetries = 5;
constexpr NSTimeInterval kBulkWriteTimeout = 5.0;

std::string describe(const char* what, NSError* e) {
  char buf[64];
  if (e == nil) return std::string(what) + " failed";
  snprintf(buf, sizeof buf, " (0x%08x)", (unsigned)e.code);
  return std::string(what) + " failed: " + e.localizedDescription.UTF8String + buf;
}

// Runs one IOUSBHost call. A NO result or a thrown Objective-C exception becomes false and an
// error string.
template <typename F>
bool guarded(const char* what, std::string* err, F&& f) {
  @try {
    NSError* e = nil;
    if (f(&e)) return true;
    if (err) *err = describe(what, e);
    return false;
  } @catch (NSException* ex) {
    if (err) {
      *err = std::string(what) + " raised " + (ex.name ? ex.name.UTF8String : "?") + ": " +
             (ex.reason ? ex.reason.UTF8String : "");
    }
    return false;
  }
}

void log_error(const std::string& s) { fprintf(stderr, "usb: %s\n", s.c_str()); }

bool read_int_property(io_service_t svc, const char* key, int64_t* out) {
  CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
  CFTypeRef v = IORegistryEntryCreateCFProperty(svc, k, kCFAllocatorDefault, 0);
  CFRelease(k);
  bool ok = v && CFGetTypeID(v) == CFNumberGetTypeID() &&
            CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, out);
  if (v) CFRelease(v);
  return ok;
}

std::string read_string_property(io_service_t svc, const char* key) {
  CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
  CFTypeRef v = IORegistryEntrySearchCFProperty(svc, kIOServicePlane, k, kCFAllocatorDefault,
                                                kIORegistryIterateRecursively |
                                                    kIORegistryIterateParents);
  CFRelease(k);
  std::string s;
  if (v && CFGetTypeID(v) == CFStringGetTypeID()) {
    char buf[256];
    if (CFStringGetCString((CFStringRef)v, buf, sizeof buf, kCFStringEncodingUTF8)) s = buf;
  }
  if (v) CFRelease(v);
  return s;
}

// Finds the IOUSBHostInterface of 2c7c:0801 whose class, subclass and protocol are 0xff, from
// registry properties alone. Returns a retained service, or 0.
io_service_t find_qmi_interface() {
  CFMutableDictionaryRef match = IOServiceMatching("IOUSBHostInterface");
  if (!match) return 0;
  io_iterator_t it = 0;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) return 0;
  io_service_t found = 0;
  while (io_service_t svc = IOIteratorNext(it)) {
    int64_t vid = -1, pid = -1, cls = -1, sub = -1, proto = -1;
    if (!found && read_int_property(svc, kUSBHostMatchingPropertyVendorID, &vid) &&
        read_int_property(svc, kUSBHostMatchingPropertyProductID, &pid) && vid == kVendor &&
        pid == kProduct && read_int_property(svc, kUSBHostMatchingPropertyInterfaceClass, &cls) &&
        read_int_property(svc, kUSBHostMatchingPropertyInterfaceSubClass, &sub) &&
        read_int_property(svc, kUSBHostMatchingPropertyInterfaceProtocol, &proto) &&
        cls == kVendorSpecific && sub == kVendorSpecific && proto == kVendorSpecific) {
      found = svc;
      continue;
    }
    IOObjectRelease(svc);
  }
  IOObjectRelease(it);
  return found;
}

}  // namespace

struct UsbTransport::Impl {
  IOUSBHostInterface* iface = nil;
  IOUSBHostPipe* bulk_in_pipe = nil;
  IOUSBHostPipe* bulk_out_pipe = nil;
  IOUSBHostPipe* interrupt_pipe = nil;
  dispatch_queue_t io_queue = nil;  // IOUSBHost completions; handlers are re-posted to main
  uint8_t interface_number = 0;
  uint8_t bulk_in = 0, bulk_out = 0, interrupt_in = 0;
  size_t bulk_packet_size = 0;
  size_t interrupt_packet_size = 0;
  std::string serial;
  bool closed = true;

  Handler on_message;
  NSMutableData* interrupt_buf = nil;
  Handler on_transfer;
  std::vector<NSMutableData*> bulk_bufs;
  std::vector<int> bulk_failures;  // consecutive failures of each posted bulk read
  int interrupt_failures = 0;
  ErrorHandler on_error;
  bool failed = false;  // on_error has been called

  // Reports a read path that cannot continue; once only. Runs on the main queue.
  void fail(const std::string& what) {
    log_error(what);
    if (failed || closed) return;
    failed = true;
    if (on_error) on_error(what);
  }

  // After a failed read: clears a halt on the pipe and counts the failure. Returns false once
  // `*failures` passes the retry limit. An abort is counted but needs no stall clear: clearing
  // a stall aborts the other reads posted on the same pipe.
  bool recover(IOUSBHostPipe* pipe, const char* what, IOReturn status, int* failures) {
    char buf[96];
    snprintf(buf, sizeof buf, "%s failed (0x%08x), attempt %d of %d", what, (unsigned)status,
             *failures + 1, kMaxReadRetries);
    log_error(buf);
    if (++*failures >= kMaxReadRetries) return false;
    if (status != kIOReturnAborted) {
      std::string err;
      if (!guarded("clear stall", &err, [&](NSError* __autoreleasing* e) {
            return [pipe clearStallWithError:e];
          })) {
        log_error(err);
      }
    }
    return true;
  }

  bool control_out(uint8_t request, uint16_t value, const uint8_t* data, size_t len,
                   std::string* err) {
    IOUSBDeviceRequest req = {};
    req.bmRequestType = kHostToInterfaceClass;
    req.bRequest = request;
    req.wValue = value;
    req.wIndex = interface_number;
    req.wLength = (uint16_t)len;
    NSMutableData* d = len ? [NSMutableData dataWithBytes:data length:len] : nil;
    IOUSBHostInterface* i = iface;
    return guarded("control request", err, [&](NSError* __autoreleasing* e) {
      return [i sendDeviceRequest:req data:d bytesTransferred:nil error:e];
    });
  }

  // Reads one encapsulated response. `out` is empty when the modem has none waiting.
  bool read_response(std::vector<uint8_t>* out, std::string* err) {
    IOUSBDeviceRequest req = {};
    req.bmRequestType = kInterfaceToHostClass;
    req.bRequest = kGetEncapsulatedResponse;
    req.wValue = 0;
    req.wIndex = interface_number;
    req.wLength = kResponseLength;
    NSMutableData* d = [NSMutableData dataWithLength:kResponseLength];
    NSUInteger n = 0;
    IOUSBHostInterface* i = iface;
    bool stalled = false;
    if (!guarded("GET_ENCAPSULATED_RESPONSE", err, [&](NSError* __autoreleasing* e) {
          if ([i sendDeviceRequest:req data:d bytesTransferred:&n error:e]) return true;
          // This modem answers STALL, not a zero-length response, when it has none waiting.
          stalled = *e && (*e).code == kUSBHostReturnPipeStalled;
          return stalled;
        })) {
      return false;
    }
    if (stalled) n = 0;
    const uint8_t* p = (const uint8_t*)d.bytes;
    out->assign(p, p + n);
    return true;
  }

  // Delivers each QMUX frame of a response separately. Bytes that do not start with a complete
  // frame go out as one message.
  void deliver_messages(const std::vector<uint8_t>& r) {
    size_t off = 0;
    while (off < r.size() && on_message && !closed) {
      size_t rest = r.size() - off;
      size_t n = rmnet::qmi_frame_length({r.data() + off, rest});
      if (n == 0) n = rest;
      on_message(r.data() + off, n);
      off += n;
    }
  }

  // Posts the interrupt read; tells the error handler if it cannot be posted.
  void arm_interrupt(const std::shared_ptr<Impl>& self) {
    std::string err;
    IOUSBHostPipe* pipe = interrupt_pipe;
    NSMutableData* buf = interrupt_buf;
    // Built outside the lambda: a block made inside it would capture the lambda's references.
    std::weak_ptr<Impl> weak = self;
    IOUSBHostCompletionHandler done = ^(IOReturn status, NSUInteger n) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (auto s = weak.lock()) s->interrupt_done(s, status, n);
      });
    };
    bool ok = guarded("interrupt read", &err, [&](NSError* __autoreleasing* e) {
      return [pipe enqueueIORequestWithData:buf completionTimeout:0 error:e completionHandler:done];
    });
    if (!ok) fail(err + "; control reads stopped");
  }

  void interrupt_done(const std::shared_ptr<Impl>& self, IOReturn status, NSUInteger n) {
    if (closed) return;
    if (status != kIOReturnSuccess) {
      if (!recover(interrupt_pipe, "interrupt read", status, &interrupt_failures)) {
        fail("interrupt read keeps failing; control reads stopped");
        return;
      }
      arm_interrupt(self);
      return;
    }
    interrupt_failures = 0;
    const uint8_t* p = (const uint8_t*)interrupt_buf.bytes;
    if (n >= 2 && p[0] == kInterfaceToHostClass && p[1] == kNotifyResponseAvailable) {
      // Same limit as the drain in open: a modem that never runs dry cannot starve the queue.
      for (int i = 0; i < kMaxDrain; i++) {
        std::vector<uint8_t> r;
        std::string err;
        if (!read_response(&r, &err)) {
          log_error(err);
          break;
        }
        if (r.empty()) break;
        deliver_messages(r);
        if (closed) return;  // a handler closed the transport
      }
    }
    arm_interrupt(self);
  }

  void post_bulk_read(const std::shared_ptr<Impl>& self, size_t index) {
    std::string err;
    IOUSBHostPipe* pipe = bulk_in_pipe;
    NSMutableData* buf = bulk_bufs[index];
    std::weak_ptr<Impl> weak = self;
    IOUSBHostCompletionHandler done = ^(IOReturn status, NSUInteger n) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (auto s = weak.lock()) s->bulk_done(s, index, status, n);
      });
    };
    bool ok = guarded("bulk read", &err, [&](NSError* __autoreleasing* e) {
      return [pipe enqueueIORequestWithData:buf completionTimeout:0 error:e completionHandler:done];
    });
    if (!ok) fail(err + "; bulk reads stopped");
  }

  void bulk_done(const std::shared_ptr<Impl>& self, size_t index, IOReturn status, NSUInteger n) {
    if (closed) return;
    if (status != kIOReturnSuccess) {
      if (!recover(bulk_in_pipe, "bulk read", status, &bulk_failures[index])) {
        fail("bulk read keeps failing; bulk reads stopped");
        return;
      }
      post_bulk_read(self, index);
      return;
    }
    bulk_failures[index] = 0;
    NSMutableData* buf = bulk_bufs[index];  // stays alive if the handler closes the transport
    if (on_transfer) on_transfer((const uint8_t*)buf.bytes, n);
    if (closed) return;
    post_bulk_read(self, index);
  }
};

UsbTransport::UsbTransport() : impl_(std::make_shared<Impl>()) {}

UsbTransport::~UsbTransport() { close(); }

bool UsbTransport::open(std::string* error) {
  Impl& d = *impl_;
  if (!d.closed) close();
  d.bulk_in = d.bulk_out = d.interrupt_in = 0;
  d.bulk_packet_size = d.interrupt_packet_size = 0;
  d.on_message = nullptr;
  d.on_transfer = nullptr;
  d.bulk_failures.clear();
  d.interrupt_failures = 0;
  d.failed = false;
  std::string err;

  io_service_t svc = find_qmi_interface();
  if (!svc) {
    if (error) *error = "no interface of 2c7c:0801 with class, subclass and protocol 0xff";
    return false;
  }
  int64_t num = -1;
  if (!read_int_property(svc, kUSBHostMatchingPropertyInterfaceNumber, &num) || num < 0 ||
      num > 0xff) {
    IOObjectRelease(svc);
    if (error) *error = "the QMI interface has no valid bInterfaceNumber";
    return false;
  }
  if (num != kQmiInterfaceNumber) {
    IOObjectRelease(svc);
    if (error) {
      *error = "the interface with class, subclass and protocol 0xff is number " +
               std::to_string(num) + ", not 4; refusing to open it";
    }
    return false;
  }
  d.interface_number = (uint8_t)num;
  d.serial = read_string_property(svc, kUSBSerialNumberString);

  d.io_queue = dispatch_queue_create("rmnet-harness.usb", DISPATCH_QUEUE_SERIAL);
  IOUSBHostInterface* iface = nil;
  dispatch_queue_t q = d.io_queue;
  bool ok = guarded("open interface", &err, [&](NSError* __autoreleasing* e) {
    iface = [[IOUSBHostInterface alloc] initWithIOService:svc
                                                    queue:q
                                                    error:e
                                          interestHandler:nil];
    return iface != nil;
  });
  IOObjectRelease(svc);
  if (!ok) {
    if (error) *error = err;
    return false;
  }
  d.iface = iface;
  d.closed = false;

  // Endpoints, from the interface's own descriptors.
  const IOUSBConfigurationDescriptor* config = nullptr;
  const IOUSBInterfaceDescriptor* ifdesc = nullptr;
  ok = guarded("read descriptors", &err, [&](NSError* __autoreleasing*) {
    config = iface.configurationDescriptor;
    ifdesc = iface.interfaceDescriptor;
    return config != nullptr && ifdesc != nullptr;
  });
  if (ok) {
    const IOUSBDescriptorHeader* cur = (const IOUSBDescriptorHeader*)ifdesc;
    while (const IOUSBEndpointDescriptor* ep = IOUSBGetNextEndpointDescriptor(config, ifdesc, cur)) {
      cur = (const IOUSBDescriptorHeader*)ep;
      uint8_t addr = ep->bEndpointAddress;
      uint8_t type = ep->bmAttributes & 0x03;
      size_t mps = OSSwapLittleToHostInt16(ep->wMaxPacketSize) & 0x7ff;
      bool in = (addr & 0x80) != 0;
      if (type == 2 && in && !d.bulk_in) {
        d.bulk_in = addr;
        d.bulk_packet_size = mps;
      } else if (type == 2 && !in && !d.bulk_out) {
        d.bulk_out = addr;
      } else if (type == 3 && in && !d.interrupt_in) {
        d.interrupt_in = addr;
        d.interrupt_packet_size = mps;
      }
    }
    if (!d.bulk_in || !d.bulk_out || !d.interrupt_in) {
      ok = false;
      err = "interface lacks a bulk in, bulk out or interrupt in endpoint";
    }
  }
  if (ok) {
    ok = guarded("open pipes", &err, [&](NSError* __autoreleasing* e) {
      d.bulk_in_pipe = [iface copyPipeWithAddress:d.bulk_in error:e];
      if (!d.bulk_in_pipe) return false;
      d.bulk_out_pipe = [iface copyPipeWithAddress:d.bulk_out error:e];
      if (!d.bulk_out_pipe) return false;
      d.interrupt_pipe = [iface copyPipeWithAddress:d.interrupt_in error:e];
      return d.interrupt_pipe != nil;
    });
  }
  if (ok) {
    ok = guarded("allocate interrupt buffer", &err, [&](NSError* __autoreleasing* e) {
      d.interrupt_buf = [iface ioDataWithCapacity:d.interrupt_packet_size error:e];
      return d.interrupt_buf != nil;
    });
  }
  // SET_CONTROL_LINE_STATE, value 1 (DTR): tells the modem a host is present.
  if (ok) ok = d.control_out(kSetControlLineState, 1, nullptr, 0, &err);
  if (ok) {
    // Discard responses left from an earlier session.
    for (int i = 0; i < kMaxDrain; i++) {
      std::vector<uint8_t> r;
      std::string drain_err;
      if (!d.read_response(&r, &drain_err) || r.empty()) break;
    }
  }
  if (!ok) {
    close();
    if (error) *error = err;
    return false;
  }
  return true;
}

uint8_t UsbTransport::interface_number() const { return impl_->interface_number; }
uint8_t UsbTransport::bulk_in() const { return impl_->bulk_in; }
uint8_t UsbTransport::bulk_out() const { return impl_->bulk_out; }
uint8_t UsbTransport::interrupt_in() const { return impl_->interrupt_in; }
size_t UsbTransport::bulk_packet_size() const { return impl_->bulk_packet_size; }
std::string UsbTransport::serial() const { return impl_->serial; }

bool UsbTransport::send_control(const uint8_t* data, size_t len) {
  if (impl_->closed || len > 0xffff) return false;
  std::string err;
  if (impl_->control_out(kSendEncapsulatedCommand, 0, data, len, &err)) return true;
  log_error(err);
  return false;
}

void UsbTransport::start_control(Handler on_message) {
  if (impl_->closed) return;
  impl_->on_message = std::move(on_message);
  impl_->arm_interrupt(impl_);
}

void UsbTransport::start_bulk(size_t read_size, Handler on_transfer) {
  Impl& d = *impl_;
  if (d.closed || !d.bulk_bufs.empty()) return;
  d.on_transfer = std::move(on_transfer);
  IOUSBHostInterface* iface = d.iface;
  for (int i = 0; i < kBulkReadsPosted; i++) {
    NSMutableData* buf = nil;
    std::string err;
    if (!guarded("allocate bulk buffer", &err, [&](NSError* __autoreleasing* e) {
          buf = [iface ioDataWithCapacity:read_size error:e];
          return buf != nil;
        })) {
      log_error(err);
      break;
    }
    d.bulk_bufs.push_back(buf);
  }
  if (d.bulk_bufs.size() < (size_t)kBulkReadsPosted) {
    d.fail("could not allocate every bulk read buffer");
    return;
  }
  d.bulk_failures.assign(d.bulk_bufs.size(), 0);
  for (size_t i = 0; i < d.bulk_bufs.size() && !d.closed && !d.failed; i++) {
    d.post_bulk_read(impl_, i);
  }
}

void UsbTransport::set_error_handler(ErrorHandler on_error) {
  impl_->on_error = std::move(on_error);
}

bool UsbTransport::write_bulk(const uint8_t* data, size_t len) {
  Impl& d = *impl_;
  if (d.closed || len == 0) return false;
  IOUSBHostPipe* pipe = d.bulk_out_pipe;
  NSMutableData* buf = [NSMutableData dataWithBytes:data length:len];
  std::string err;
  bool ok = guarded("bulk write", &err, [&](NSError* __autoreleasing* e) {
    return [pipe sendIORequestWithData:buf
                      bytesTransferred:nil
                     completionTimeout:kBulkWriteTimeout
                                 error:e];
  });
  // A transfer that fills its last packet exactly is ended by a zero-length packet.
  if (ok && d.bulk_packet_size && len % d.bulk_packet_size == 0) {
    ok = guarded("bulk write (zero-length packet)", &err, [&](NSError* __autoreleasing* e) {
      return [pipe sendIORequestWithData:nil
                        bytesTransferred:nil
                       completionTimeout:kBulkWriteTimeout
                                   error:e];
    });
  }
  if (!ok) log_error(err);
  return ok;
}

void UsbTransport::close() {
  Impl& d = *impl_;
  if (d.closed) return;
  d.closed = true;
  std::string ignored;
  for (IOUSBHostPipe* p : {d.interrupt_pipe, d.bulk_in_pipe, d.bulk_out_pipe}) {
    if (!p) continue;
    guarded("abort pipe", &ignored, [&](NSError* __autoreleasing* e) {
      return [p abortWithOption:IOUSBHostAbortOptionSynchronous error:e];
    });
  }
  IOUSBHostInterface* iface = d.iface;
  guarded("destroy interface", &ignored, [&](NSError* __autoreleasing*) {
    [iface destroy];
    return true;
  });
  d.interrupt_pipe = d.bulk_in_pipe = d.bulk_out_pipe = nil;
  d.iface = nil;
  d.interrupt_buf = nil;
  d.bulk_bufs.clear();
  // The handlers stay set: close may be called from inside one of them.
}
