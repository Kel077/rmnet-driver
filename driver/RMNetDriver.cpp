// The driver: opens the modem's QMI interface, runs Core's QMI session over its control channel,
// and presents an Ethernet port whose link follows the session. Packets are not carried yet:
// transmitted frames are completed and dropped.
#include <os/log.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOTimerDispatchSource.h>
#include <DriverKit/OSCollections.h>
#include <USBDriverKit/USBDriverKit.h>  // umbrella: also declares IOUSBHostFreeDescriptor
#include <NetworkingDriverKit/NetworkingDriverKit.h>

#include "rmnet/ethernet.h"

#include "RMNetDriver.h"
#include "core_host.h"
#include "usb_io.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "RMNet: " fmt, ##__VA_ARGS__)
// Logs only the first time this point is reached, so the log shows which callbacks macOS uses.
#define LOG_FIRST(flag, fmt, ...)                        \
  do {                                                   \
    if (FirstCall(flag)) LOG(fmt, ##__VA_ARGS__);        \
  } while (0)

namespace {

constexpr uint8_t kQmiInterfaceNumber = 4;
constexpr uint8_t kVendorSpecific = 0xff;
constexpr uint32_t kPacketCount = 512;
constexpr uint32_t kPacketBufSize = 2048;  // one Ethernet frame per packet
constexpr uint32_t kQueueCapacity = 256;
constexpr uint32_t kMtu = 1500;
constexpr uint32_t kMinMtu = 576;
constexpr uint32_t kTxBatch = 32;
constexpr uint64_t kTickNs = 100 * 1000000ull;
constexpr uint64_t kTickLeewayNs = 10 * 1000000ull;

// One bit per override and handler, set the first time it runs.
enum : uint32_t {
  kLogInit = 1u << 0,
  kLogFree = 1u << 1,
  kLogStart = 1u << 2,
  kLogStop = 1u << 3,
  kLogSetPowerState = 1u << 4,
  kLogSetInterfaceEnable = 1u << 5,
  kLogSetPromiscuous = 1u << 6,
  kLogSetAllMulticast = 1u << 7,
  kLogSelectMediaType = 1u << 8,
  kLogGetSupportedMedia = 1u << 9,
  kLogSetMulticastAddresses = 1u << 10,
  kLogSetInterfaceEnableLower = 1u << 11,
  kLogSetPromiscuousLower = 1u << 12,
  kLogSetAllMulticastLower = 1u << 13,
  kLogHandleChosenMedia = 1u << 14,
  kLogGetMaxTransferUnit = 1u << 15,
  kLogSetPowerStateLower = 1u << 16,
  kLogTxAvailable = 1u << 17,
  kLogRxAvailable = 1u << 18,
  kLogTxCompleteFull = 1u << 19,
  kLogInterruptComplete = 1u << 20,
  kLogControlOutComplete = 1u << 21,
  kLogControlInComplete = 1u << 22,
  kLogTimerFired = 1u << 23,
};

// True if the provider is the modem's QMI interface: number 4, class, subclass and protocol 0xff.
bool IsQmiInterface(IOService* provider) {
  IOUSBHostInterface* intf = OSDynamicCast(IOUSBHostInterface, provider);
  if (!intf) return false;
  const IOUSBConfigurationDescriptor* cfg = intf->CopyConfigurationDescriptor();
  if (!cfg) return false;
  const IOUSBInterfaceDescriptor* id = intf->GetInterfaceDescriptor(cfg);
  bool ok = id && id->bInterfaceNumber == kQmiInterfaceNumber && id->bInterfaceClass == kVendorSpecific &&
            id->bInterfaceSubClass == kVendorSpecific && id->bInterfaceProtocol == kVendorSpecific;
  IOUSBHostFreeDescriptor(cfg);
  return ok;
}

uint64_t NowNs() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
uint64_t NowMs() { return NowNs() / 1000000ull; }

uint8_t PrefixLength(const uint8_t mask[4]) {
  uint8_t n = 0;
  for (int i = 0; i < 4; i++) {
    for (int b = 7; b >= 0; b--) {
      if (mask[i] & (1u << b)) n++;
    }
  }
  return n;
}

// "a.b.c.d/n gw e.f.g.h"
void FormatIPv4(const rmnet::RuntimeSettings& s, char* out, size_t cap) {
  snprintf(out, cap, "%u.%u.%u.%u/%u gw %u.%u.%u.%u", s.v4_addr[0], s.v4_addr[1], s.v4_addr[2], s.v4_addr[3],
           PrefixLength(s.v4_mask), s.v4_gateway[0], s.v4_gateway[1], s.v4_gateway[2], s.v4_gateway[3]);
}

// RFC 5952 text form (longest run of two or more zero groups shortened to ::), then "/n".
void FormatIPv6(const rmnet::RuntimeSettings& s, char* out, size_t cap) {
  uint16_t g[8];
  for (int i = 0; i < 8; i++) g[i] = static_cast<uint16_t>(s.v6_addr[2 * i] << 8 | s.v6_addr[2 * i + 1]);
  int best = -1, best_len = 0;
  for (int i = 0; i < 8;) {
    if (g[i] != 0) {
      i++;
      continue;
    }
    int j = i;
    while (j < 8 && g[j] == 0) j++;
    if (j - i > best_len && j - i >= 2) {
      best = i;
      best_len = j - i;
    }
    i = j;
  }
  size_t n = 0;
  for (int i = 0; i < 8 && n < cap; i++) {
    if (i == best) {
      n += snprintf(out + n, cap - n, "::");
      i += best_len - 1;
      continue;
    }
    bool sep = i > 0 && !(best >= 0 && i == best + best_len);
    n += snprintf(out + n, cap - n, sep ? ":%x" : "%x", g[i]);
  }
  if (n < cap) snprintf(out + n, cap - n, "/%u", s.v6_prefix_len);
}

}  // namespace

// Forwards UsbIo's reports to the driver.
struct UsbBridge final : UsbIoListener {
  explicit UsbBridge(RMNetDriver* d) : driver(d) {}
  void on_control(const uint8_t* data, size_t len) override { driver->OnControl(data, len); }
  void on_fatal(const char* what) override { driver->OnUsbFatal(what); }
  RMNetDriver* driver;
};

struct RMNetDriver_IVars {
  IODispatchQueue* queue;  // the service's Default queue; everything runs on it
  IOUserNetworkPacketBufferPool* pool;
  IOUserNetworkTxSubmissionQueue* txSubmit;
  IOUserNetworkTxCompletionQueue* txComplete;
  IOUserNetworkRxSubmissionQueue* rxSubmit;
  IOUserNetworkRxCompletionQueue* rxComplete;
  OSAction* txAvailAction;
  OSAction* rxAvailAction;
  IOTimerDispatchSource* timer;
  OSAction* timerAction;
  UsbBridge* bridge;
  UsbIo* usb;       // released objects only once its aborted completions have arrived
  CoreHost* core;
  bool stopping;
  bool usbFailed;
  bool linkActive;  // the link status last reported to the stack
  uint32_t mtu;     // what getMaxTransferUnit answers
  char published[256];  // the status last published, "state|ipv4|ipv6"; empty before the first
  uint32_t logged;  // kLog* bits already logged
};

bool RMNetDriver::FirstCall(uint32_t flag) {
  if (!ivars || (ivars->logged & flag)) return false;
  ivars->logged |= flag;
  return true;
}

bool RMNetDriver::init() {
  if (!super::init()) return false;
  ivars = IONewZero(RMNetDriver_IVars, 1);
  if (!ivars) return false;
  ivars->mtu = kMtu;
  LOG_FIRST(kLogInit, "init");
  return true;
}

// Objects are released here rather than in Stop, so nothing still queued on the Default queue can
// reach a released object. UsbIo has normally released its USB objects already (after the last
// aborted completion); deleting it releases whatever is left.
void RMNetDriver::free() {
  LOG_FIRST(kLogFree, "free");
  if (ivars) {
    delete ivars->core;
    ivars->core = nullptr;
    delete ivars->usb;
    ivars->usb = nullptr;
    delete ivars->bridge;
    ivars->bridge = nullptr;
    OSSafeReleaseNULL(ivars->timer);
    OSSafeReleaseNULL(ivars->timerAction);
    OSSafeReleaseNULL(ivars->txAvailAction);
    OSSafeReleaseNULL(ivars->rxAvailAction);
    OSSafeReleaseNULL(ivars->txSubmit);
    OSSafeReleaseNULL(ivars->txComplete);
    OSSafeReleaseNULL(ivars->rxSubmit);
    OSSafeReleaseNULL(ivars->rxComplete);
    OSSafeReleaseNULL(ivars->pool);
    OSSafeReleaseNULL(ivars->queue);
  }
  IOSafeDeleteNULL(ivars, RMNetDriver_IVars, 1);
  super::free();
}

// Order (docs/driverkit-notes.md 3.9): open USB and read the serial number, create Core, the
// interface with the MAC derived from the serial, the timer, then DTR and the interrupt read, then
// the session. A failure tears down what was made and fails Start. Failures to report the link
// status or publish properties do not fail Start (see ReportLink and PublishStatus).
kern_return_t RMNetDriver::Start_Impl(IOService* provider) {
  LOG_FIRST(kLogStart, "Start");
  kern_return_t ret = Start(provider, SUPERDISPATCH);
  if (ret != kIOReturnSuccess) {
    LOG("super Start failed 0x%x", ret);
    return ret;
  }
  if (!IsQmiInterface(provider)) {
    LOG("not the QMI interface");
    ret = kIOReturnUnsupported;
  }
  if (ret == kIOReturnSuccess) ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
  if (ret == kIOReturnSuccess) ret = OpenUsb(provider);

  rmnet::MacPair macs{};
  if (ret == kIOReturnSuccess) {
    char serial[64];
    ivars->usb->read_serial(serial, sizeof serial);
    if (serial[0] == '\0') {
      LOG("no USB serial number; MACs derived from \"unknown\"");
      macs = rmnet::derive_macs("unknown");
    } else {
      macs = rmnet::derive_macs(serial);
    }
    LOG("serial number of %zu characters, host MAC %02x:%02x:%02x:%02x:%02x:%02x", strlen(serial), macs.host[0],
        macs.host[1], macs.host[2], macs.host[3], macs.host[4], macs.host[5]);
    ivars->core = new CoreHost(*ivars->usb, macs);
    if (!ivars->core) ret = kIOReturnNoMemory;
  }
  if (ret == kIOReturnSuccess) ret = CreateInterface(macs.host);
  if (ret == kIOReturnSuccess) ret = StartTimer();
  if (ret == kIOReturnSuccess) ret = ivars->usb->start();
  if (ret == kIOReturnSuccess) {
    ivars->core->start(NowMs());
    ApplyCore();
    PublishStatus();
    ret = RegisterService();
  }
  if (ret != kIOReturnSuccess) {
    LOG("Start failed 0x%x", ret);
    TearDown();
    Stop(provider, SUPERDISPATCH);
    return ret;
  }
  LOG("started");
  return kIOReturnSuccess;
}

// UsbIo opens the interface with completion actions made here; it holds its own references.
kern_return_t RMNetDriver::OpenUsb(IOService* provider) {
  IOUSBHostInterface* intf = OSDynamicCast(IOUSBHostInterface, provider);
  if (!intf) return kIOReturnUnsupported;
  ivars->bridge = new UsbBridge(this);
  if (!ivars->bridge) return kIOReturnNoMemory;
  ivars->usb = new UsbIo(*ivars->bridge);
  if (!ivars->usb) return kIOReturnNoMemory;

  UsbIoActions actions{};
  kern_return_t ret = CreateActionInterruptComplete(0, &actions.interrupt);
  if (ret == kIOReturnSuccess) ret = CreateActionControlOutComplete(0, &actions.control_out);
  if (ret == kIOReturnSuccess) ret = CreateActionControlInComplete(0, &actions.control_in);
  if (ret == kIOReturnSuccess) ret = ivars->usb->open(this, intf, actions);
  OSSafeReleaseNULL(actions.interrupt);
  OSSafeReleaseNULL(actions.control_out);
  OSSafeReleaseNULL(actions.control_in);
  if (ret != kIOReturnSuccess) LOG("USB open failed 0x%x", ret);
  return ret;
}

// The pool, the four packet queues and their handlers, then the Ethernet interface itself, with
// the link reported inactive.
kern_return_t RMNetDriver::CreateInterface(const uint8_t* hostMac) {
  IOUserNetworkPacketBufferPoolOptions opts{};
  opts.packetCount = kPacketCount;
  opts.bufferCount = kPacketCount;
  opts.bufferSize = kPacketBufSize;
  opts.maxBuffersPerPacket = 1;
  opts.poolFlags = PoolFlagMapToDext;
  kern_return_t ret = IOUserNetworkPacketBufferPool::CreateWithOptions(this, "RMNetPool", &opts, &ivars->pool);
  if (ret != kIOReturnSuccess) return ret;

  ret = IOUserNetworkTxSubmissionQueue::Create(ivars->pool, this, kQueueCapacity, 0, ivars->queue, &ivars->txSubmit);
  if (ret != kIOReturnSuccess) return ret;
  ret = IOUserNetworkTxCompletionQueue::Create(ivars->pool, this, kQueueCapacity, 0, ivars->queue, &ivars->txComplete);
  if (ret != kIOReturnSuccess) return ret;
  ret = IOUserNetworkRxSubmissionQueue::Create(ivars->pool, this, kQueueCapacity, 0, ivars->queue, &ivars->rxSubmit);
  if (ret != kIOReturnSuccess) return ret;
  ret = IOUserNetworkRxCompletionQueue::Create(ivars->pool, this, kQueueCapacity, 0, ivars->queue, &ivars->rxComplete);
  if (ret != kIOReturnSuccess) return ret;

  IODataQueueDispatchSource* dq = nullptr;
  ret = CreateActionTxPacketsAvailable(0, &ivars->txAvailAction);
  if (ret != kIOReturnSuccess) return ret;
  ret = ivars->txSubmit->CopyDataQueue(&dq);
  if (ret != kIOReturnSuccess) return ret;
  ret = dq->SetDataAvailableHandler(ivars->txAvailAction);
  OSSafeReleaseNULL(dq);
  if (ret != kIOReturnSuccess) return ret;

  ret = CreateActionRxPacketsAvailable(0, &ivars->rxAvailAction);
  if (ret != kIOReturnSuccess) return ret;
  ret = ivars->rxSubmit->CopyDataQueue(&dq);
  if (ret != kIOReturnSuccess) return ret;
  ret = dq->SetDataAvailableHandler(ivars->rxAvailAction);
  OSSafeReleaseNULL(dq);
  if (ret != kIOReturnSuccess) return ret;

  ether_addr_t mac;
  memcpy(mac.octet, hostMac, sizeof(mac.octet));
  IOUserNetworkPacketQueue* queues[] = {ivars->txSubmit, ivars->txComplete, ivars->rxSubmit, ivars->rxComplete};
  ret = RegisterEthernetInterface(mac, ivars->pool, queues, 4);
  if (ret != kIOReturnSuccess) return ret;

  // setMaxTransferUnit here fails with kIOReturnUnsupported (first load); getMaxTransferUnit
  // gives the stack the MTU instead. A link status reported here is lost (configd ran DHCP on the
  // port), so it is reported again once the stack enables the interface. Neither fails Start.
  ReportLink();
  return kIOReturnSuccess;
}

kern_return_t RMNetDriver::StartTimer() {
  kern_return_t ret = IOTimerDispatchSource::Create(ivars->queue, &ivars->timer);
  if (ret == kIOReturnSuccess) ret = CreateActionTimerFired(0, &ivars->timerAction);
  if (ret == kIOReturnSuccess) ret = ivars->timer->SetHandler(ivars->timerAction);
  if (ret == kIOReturnSuccess) ArmTimer();
  return ret;
}

// The timer is one-shot: re-armed after every tick.
void RMNetDriver::ArmTimer() {
  kern_return_t ret = ivars->timer->WakeAtTime(kIOTimerClockUptimeRaw, NowNs() + kTickNs, kTickLeewayNs);
  if (ret != kIOReturnSuccess) LOG("timer not armed: 0x%x", ret);
}

// Quiesces everything, in the order of docs/driverkit-notes.md 3.9: the session first, while USB
// is still open (it sends releases), then the timer, the link, the queues, and USB. UsbIo releases
// its objects once the aborted completions have arrived; the rest is released in free().
void RMNetDriver::TearDown() {
  if (ivars->stopping) return;
  ivars->stopping = true;
  if (ivars->core) {
    ivars->core->stop();
    ivars->core->take_link_change();
  }
  if (ivars->timer) ivars->timer->Cancel(^{});
  ivars->linkActive = false;
  if (ivars->txSubmit) ReportLink();
  if (ivars->txSubmit) ivars->txSubmit->setEnable(false);
  if (ivars->txComplete) ivars->txComplete->setEnable(false);
  if (ivars->rxSubmit) ivars->rxSubmit->setEnable(false);
  if (ivars->rxComplete) ivars->rxComplete->setEnable(false);
  if (ivars->usb) ivars->usb->abort();
}

kern_return_t RMNetDriver::Stop_Impl(IOService* provider) {
  LOG_FIRST(kLogStop, "Stop");
  TearDown();
  return Stop(provider, SUPERDISPATCH);
}

kern_return_t RMNetDriver::SetPowerState_Impl(uint32_t powerFlags) {
  LOG_FIRST(kLogSetPowerState, "SetPowerState 0x%x", powerFlags);
  return SetPowerState(powerFlags, SUPERDISPATCH);  // must reach the superclass to acknowledge
}

// Reports the link status last decided (ivars->linkActive). A failure is logged and does not
// fail the caller: the status is reported again whenever the stack enables the interface.
IOReturn RMNetDriver::ReportLink() {
  LinkStatus status = ivars->linkActive ? kIOUserNetworkLinkStatusActive : kIOUserNetworkLinkStatusInactive;
  IOReturn ret = reportLinkStatus(status, kIOUserNetworkMediaEthernetAuto);
  if (ret != kIOReturnSuccess) LOG("reportLinkStatus %d: 0x%x", ivars->linkActive, ret);
  return ret;
}

// --- Session ------------------------------------------------------------------------------------

// One QMUX frame from the modem (UsbIo, from a response read's completion).
void RMNetDriver::OnControl(const uint8_t* data, size_t len) {
  if (ivars->stopping || !ivars->core) return;
  ivars->core->on_control(data, len, NowMs());
  ApplyCore();
}

// The control channel stopped for good (the interrupt read keeps failing). The session cannot
// continue: stop it and report the link down. It is not restarted; a re-enumeration starts afresh.
void RMNetDriver::OnUsbFatal(const char* what) {
  LOG("usb failed: %{public}s", what);
  ivars->usbFailed = true;
  if (ivars->stopping || !ivars->core) return;
  ivars->core->stop();
  ApplyCore();
}

// Applies what the last Core call decided, now that it has returned: link down, then link up
// (both, in that order, for a bounce). A second link up while the link is up means a family was
// added: the emulator, the MTU and the properties are updated, and the link stays active.
void RMNetDriver::ApplyCore() {
  CoreHost::LinkChange c = ivars->core->take_link_change();
  if (c.down) {
    ivars->core->ethernet().set_link(nullptr);
    ivars->mtu = kMtu;
    if (ivars->linkActive) {
      ivars->linkActive = false;
      ReportLink();
    }
    LOG("link down");
  }
  if (c.up) {
    const rmnet::RuntimeSettings& s = ivars->core->link_config().settings;
    ivars->core->ethernet().set_link(&s);
    uint32_t mtu = s.mtu;
    if (mtu == 0 || mtu > kMtu) mtu = kMtu;
    if (mtu < kMinMtu) mtu = kMinMtu;
    ivars->mtu = mtu;
    IOReturn mret = setMaxTransferUnit(mtu);
    bool again = ivars->linkActive;
    if (!again) {
      ivars->linkActive = true;
      ReportLink();
    }
    LOG("link up%{public}s: ipv4 %d ipv6 %d, carrier mtu %u, interface mtu %u (setMaxTransferUnit 0x%x)",
        again ? " (family added)" : "", s.has_v4, s.has_v6, s.mtu, mtu, mret);
  }
  PublishStatus();
}

// Status for the host app: properties on this service in the I/O registry. Republished only when
// something changed. A failure is logged and does not fail the caller: the status is for the
// app, and the driver works without it.
void RMNetDriver::PublishStatus() {
  char state[24];
  char v4[64] = "none";
  char v6[80] = "none";
  snprintf(state, sizeof state, "%s", ivars->usbFailed ? "usb failed" : SessionStateName(ivars->core->state()));
  if (ivars->linkActive) {
    const rmnet::RuntimeSettings& s = ivars->core->link_config().settings;
    if (s.has_v4) FormatIPv4(s, v4, sizeof v4);
    if (s.has_v6) FormatIPv6(s, v6, sizeof v6);
  }
  char key[sizeof ivars->published];
  snprintf(key, sizeof key, "%s|%s|%s", state, v4, v6);
  if (strcmp(key, ivars->published) == 0) return;

  OSDictionary* props = OSDictionary::withCapacity(3);
  OSString* st = OSString::withCString(state);
  OSString* a4 = OSString::withCString(v4);
  OSString* a6 = OSString::withCString(v6);
  if (props && st && a4 && a6) {
    props->setObject("RMNetState", st);
    props->setObject("RMNetIPv4", a4);
    props->setObject("RMNetIPv6", a6);
    kern_return_t ret = SetProperties(props);
    if (ret != kIOReturnSuccess) {
      LOG("SetProperties 0x%x", ret);
    } else {
      strlcpy(ivars->published, key, sizeof ivars->published);
    }
  }
  OSSafeReleaseNULL(st);
  OSSafeReleaseNULL(a4);
  OSSafeReleaseNULL(a6);
  OSSafeReleaseNULL(props);
}

// --- Network stack callbacks ---------------------------------------------------------------------

// Reached through the base class's setInterfaceEnable, which the stack calls first.
kern_return_t RMNetDriver::SetInterfaceEnable_Impl(bool isEnable) {
  LOG_FIRST(kLogSetInterfaceEnable, "SetInterfaceEnable %d", isEnable);
  ivars->txSubmit->setEnable(isEnable);
  ivars->txComplete->setEnable(isEnable);
  ivars->rxSubmit->setEnable(isEnable);
  ivars->rxComplete->setEnable(isEnable);
  if (isEnable) ReportLink();
  return kIOReturnSuccess;
}

kern_return_t RMNetDriver::SetPromiscuousModeEnable_Impl(bool enable) {
  LOG_FIRST(kLogSetPromiscuous, "SetPromiscuousModeEnable %d", enable);
  return kIOReturnSuccess;
}

kern_return_t RMNetDriver::SetAllMulticastModeEnable_Impl(bool enable) {
  LOG_FIRST(kLogSetAllMulticast, "SetAllMulticastModeEnable %d", enable);
  return kIOReturnSuccess;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
kern_return_t RMNetDriver::SelectMediaType_Impl(IOUserNetworkMediaType mediaType) {
  LOG_FIRST(kLogSelectMediaType, "SelectMediaType 0x%x", mediaType);
  return kIOReturnSuccess;
}
#pragma clang diagnostic pop

// Replaces the deprecated ReportAvailableMediaTypes: the framework asks for the media list. A call
// without an array, or with no room, is answered with the count alone.
IOReturn RMNetDriver::getSupportedMediaArray(MediaWord* mediaArray, uint32_t* mediaCount) {
  LOG_FIRST(kLogGetSupportedMedia, "getSupportedMediaArray array %d count %u", mediaArray != nullptr,
            mediaCount ? *mediaCount : 0);
  if (!mediaCount) return kIOReturnBadArgument;
  if (mediaArray && *mediaCount >= 1) mediaArray[0] = kIOUserNetworkMediaEthernetAuto;
  *mediaCount = 1;
  return kIOReturnSuccess;
}

IOReturn RMNetDriver::setMulticastAddresses(const ether_addr_t*, uint32_t count) {
  LOG_FIRST(kLogSetMulticastAddresses, "setMulticastAddresses %u", count);
  return kIOReturnSuccess;
}

IOReturn RMNetDriver::setInterfaceEnable(bool enable) {
  LOG_FIRST(kLogSetInterfaceEnableLower, "setInterfaceEnable %d", enable);
  return super::setInterfaceEnable(enable);
}

IOReturn RMNetDriver::setPromiscuousModeEnable(bool enable) {
  LOG_FIRST(kLogSetPromiscuousLower, "setPromiscuousModeEnable %d", enable);
  return super::setPromiscuousModeEnable(enable);
}

IOReturn RMNetDriver::setAllMulticastModeEnable(bool enable) {
  LOG_FIRST(kLogSetAllMulticastLower, "setAllMulticastModeEnable %d", enable);
  return super::setAllMulticastModeEnable(enable);
}

IOReturn RMNetDriver::handleChosenMedia(MediaWord chosenMedia) {
  LOG_FIRST(kLogHandleChosenMedia, "handleChosenMedia 0x%x", chosenMedia);
  return super::handleChosenMedia(chosenMedia);
}

uint32_t RMNetDriver::getMaxTransferUnit() {
  LOG_FIRST(kLogGetMaxTransferUnit, "getMaxTransferUnit, superclass says %u", super::getMaxTransferUnit());
  return ivars->mtu;
}

IOReturn RMNetDriver::setPowerState(unsigned long powerState, IOService* whatDevice) {
  LOG_FIRST(kLogSetPowerStateLower, "setPowerState %lu", powerState);
  return super::setPowerState(powerState, whatDevice);
}

// --- Packet queues -------------------------------------------------------------------------------

// No data path yet: every queued frame is handed straight back as completed, so the pool does
// not drain.
void RMNetDriver::TxPacketsAvailable_Impl(OSAction*) {
  LOG_FIRST(kLogTxAvailable, "TxPacketsAvailable");
  IOUserNetworkPacket* pkts[kTxBatch];
  uint32_t n;
  while ((n = ivars->txSubmit->DequeuePackets(pkts, kTxBatch)) > 0) {
    uint32_t done = ivars->txComplete->EnqueuePackets(pkts, n);
    if (done < n) {
      LOG_FIRST(kLogTxCompleteFull, "tx completion queue full, %u packets not returned", n - done);
      break;
    }
  }
}

void RMNetDriver::RxPacketsAvailable_Impl(OSAction*) {
  LOG_FIRST(kLogRxAvailable, "RxPacketsAvailable");
}

// --- USB and timer -------------------------------------------------------------------------------

// Completions go to UsbIo even while stopping: it counts the aborted ones before releasing.
void RMNetDriver::InterruptComplete_Impl(OSAction*, IOReturn status, uint32_t actualByteCount, uint64_t) {
  LOG_FIRST(kLogInterruptComplete, "InterruptComplete 0x%x, %u bytes", status, actualByteCount);
  if (ivars && ivars->usb) ivars->usb->interrupt_complete(status, actualByteCount);
}

void RMNetDriver::ControlOutComplete_Impl(OSAction*, IOReturn status, uint32_t bytesTransferred) {
  LOG_FIRST(kLogControlOutComplete, "ControlOutComplete 0x%x, %u bytes", status, bytesTransferred);
  if (ivars && ivars->usb) ivars->usb->control_out_complete(status, bytesTransferred);
}

void RMNetDriver::ControlInComplete_Impl(OSAction*, IOReturn status, uint32_t bytesTransferred) {
  LOG_FIRST(kLogControlInComplete, "ControlInComplete 0x%x, %u bytes", status, bytesTransferred);
  if (ivars && ivars->usb) ivars->usb->control_in_complete(status, bytesTransferred);
}

void RMNetDriver::TimerFired_Impl(OSAction*, uint64_t) {
  LOG_FIRST(kLogTimerFired, "TimerFired");
  if (!ivars || ivars->stopping || !ivars->core) return;
  ivars->core->tick(NowMs());
  ApplyCore();
  ArmTimer();
}
