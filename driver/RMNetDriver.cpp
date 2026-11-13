// The driver: opens the modem's QMI interface, runs Core's QMI session over its control channel,
// and presents an Ethernet port whose link follows the session. Frames from the stack go through
// CoreHost to the bulk OUT pipe; bulk IN transfers come back through CoreHost as received frames.
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
constexpr uint32_t kTxHold = 256;  // sent packets the completion queue has not taken yet
constexpr uint32_t kRxHold = 256;  // filled packets the completion queue has not taken yet
constexpr uint32_t kRxBatch = 64;  // filled packets handed up in one EnqueuePackets at most
constexpr uint8_t kLinkHeaderLen = 14;  // Ethernet
constexpr uint32_t kCounterTicks = 10;  // counters are published once a second
constexpr uint64_t kTickNs = 100 * 1000000ull;
constexpr uint64_t kTickLeewayNs = 10 * 1000000ull;
constexpr uint64_t kStopDrainMs = 1000;  // the control ring may take this long to send at Stop
constexpr uint64_t kStopAbortMs = 1000;  // and the aborted requests this long to come back

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
  kLogBulkIn = 1u << 24,
  kLogBulkOut = 1u << 25,
  kLogTxPacket = 1u << 26,
  kLogRxPacket = 1u << 27,
  kLogRxCompleteFull = 1u << 28,
  kLogPoolCount = 1u << 29,
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
  void on_bulk_in(const uint8_t* data, size_t len) override { driver->OnBulkIn(data, len); }
  void on_bulk_out_done(int slot, bool ok) override { driver->OnBulkOutDone(slot, ok); }
  RMNetDriver* driver;
};

// Gives CoreHost the driver's receive packets.
struct RxBridge final : RxSink {
  explicit RxBridge(RMNetDriver* d) : driver(d) {}
  uint8_t* rx_buffer(size_t* cap) override { return driver->RxBuffer(cap); }
  void rx_commit(size_t len) override { driver->RxCommit(len); }
  RMNetDriver* driver;
};

// What PublishCounters last published, in its order.
enum : uint32_t { kCounterCount = 33 };

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
  RxBridge* rxBridge;
  UsbIo* usb;       // released objects only once its aborted completions have arrived
  CoreHost* core;
  bool stopping;
  // The stop sequence (TearDown, AdvanceStop): Draining sends what the session queued, Aborting
  // waits for the aborted requests, Done has passed Stop to the superclass.
  enum StopPhase : uint8_t { kStopNone, kStopDraining, kStopAborting, kStopDone } stopPhase;
  IOService* stopProvider;  // retained from TearDown until Stop is passed to the superclass
  uint64_t stopStartMs;
  uint64_t abortStartMs;
  bool usbFailed;
  bool coreStopped;  // session.stop() was called; the Session is not called again
  bool linkActive;  // the link status last reported to the stack
  uint32_t mtu;     // what getMaxTransferUnit answers
  char published[256];  // the status last published, "state|ipv4|ipv6"; empty before the first
  uint32_t logged;  // kLog* bits already logged
  // The data path's packets. A packet taken from the RX submission queue waits in rxSpare until it
  // is filled; filled ones wait in rxOut, and sent ones in txDone, until their completion queue
  // takes them (leftovers go first next time, so the pool does not shrink).
  IOUserNetworkPacket* rxSpare;
  IOUserNetworkPacket* rxOut[kRxHold];
  uint32_t rxOutCount;
  IOUserNetworkPacket* txDone[kTxHold];
  uint32_t txDoneCount;
  bool txHeld;  // frames may wait in the TX submission queue (paused, or no room in txDone)
  uint32_t ticks;
  bool countersPublished;
  uint64_t counters[kCounterCount];
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
    delete ivars->rxBridge;
    ivars->rxBridge = nullptr;
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
    ivars->rxBridge = new RxBridge(this);
    if (ivars->rxBridge) ivars->core = new CoreHost(*ivars->usb, *ivars->rxBridge, macs);
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
    TearDown(provider);  // passes Stop to the superclass, at once or once USB has quiesced
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
  for (uint32_t i = 0; i < kBulkReads && ret == kIOReturnSuccess; i++) {
    ret = CreateActionBulkInComplete(sizeof(uint32_t), &actions.bulk_in[i]);
  }
  for (uint32_t i = 0; i < kUplinkSlots && ret == kIOReturnSuccess; i++) {
    ret = CreateActionBulkOutComplete(sizeof(uint32_t), &actions.bulk_out[i]);
  }
  if (ret == kIOReturnSuccess) ret = ivars->usb->open(this, intf, actions);
  OSSafeReleaseNULL(actions.interrupt);
  OSSafeReleaseNULL(actions.control_out);
  OSSafeReleaseNULL(actions.control_in);
  for (uint32_t i = 0; i < kBulkReads; i++) OSSafeReleaseNULL(actions.bulk_in[i]);
  for (uint32_t i = 0; i < kUplinkSlots; i++) OSSafeReleaseNULL(actions.bulk_out[i]);
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

// The stop sequence, shared by Stop and a failed Start (docs/driverkit-notes.md 3.9):
// 1. stopping; the session stops and queues its releases; the link is reported inactive and the
//    queues are disabled. Core is not called again.
// 2. Draining: the control ring keeps sending, until it is empty, a request fails, or
//    kStopDrainMs after the start.
// 3. Aborting: the pipes and control requests are aborted; wait until none is outstanding, or
//    kStopAbortMs.
// 4. Close the interface, release the USB objects, pass Stop to the superclass.
// Nothing blocks: AdvanceStop runs after every USB completion and on every timer tick (the timer
// is kept running until step 4 and is the clock for both deadlines). Stop always finishes: past
// the second deadline it is passed on with requests still outstanding, and that is logged.
void RMNetDriver::TearDown(IOService* provider) {
  if (ivars->stopping) return;
  ivars->stopping = true;
  ivars->stopProvider = provider;
  provider->retain();
  ivars->stopStartMs = NowMs();
  // Not again if OnUsbFatal already stopped the session: Core is not called after stop().
  if (ivars->core && !ivars->coreStopped) {
    ivars->coreStopped = true;
    ivars->core->stop();
    ivars->core->take_link_change();
  }
  if (ivars->usb) LOG("stop: %u control messages queued", ivars->usb->queued());
  ivars->linkActive = false;
  if (ivars->txSubmit) ReportLink();
  if (ivars->txSubmit) ivars->txSubmit->setEnable(false);
  if (ivars->txComplete) ivars->txComplete->setEnable(false);
  if (ivars->rxSubmit) ivars->rxSubmit->setEnable(false);
  if (ivars->rxComplete) ivars->rxComplete->setEnable(false);
  ivars->stopPhase = RMNetDriver_IVars::kStopDraining;
  if (ivars->usb) ivars->usb->finish_sending();
  AdvanceStop();
}

void RMNetDriver::AdvanceStop() {
  uint64_t now = NowMs();
  UsbIo* usb = ivars->usb;
  if (ivars->stopPhase == RMNetDriver_IVars::kStopDraining) {
    bool late = now - ivars->stopStartMs >= kStopDrainMs;
    // Without the timer there is no clock for the deadline; nothing was ever posted then.
    if (usb && !usb->sending_done() && !late && ivars->timer) return;
    if (usb) {
      usb->abort();
      LOG("stop: control messages sent %u, dropped %u%{public}s; aborted with %u requests outstanding",
          usb->sent_at_stop(), usb->dropped_at_stop(), late ? " (drain deadline)" : "", usb->outstanding());
    }
    ivars->stopPhase = RMNetDriver_IVars::kStopAborting;
    ivars->abortStartMs = now;
  }
  if (ivars->stopPhase == RMNetDriver_IVars::kStopAborting) {
    if (usb && usb->outstanding() > 0) {
      if (now - ivars->abortStartMs < kStopAbortMs && ivars->timer) return;
      // Close also aborts; the objects are left to free(), which may run before they return.
      LOG("stop: %u aborted requests still outstanding after %llu ms; passing Stop on anyway",
          usb->outstanding(), now - ivars->abortStartMs);
      usb->close();
    } else if (usb) {
      usb->close_and_release();
      LOG("stop: usb objects released");
    }
    FinishStop();
  }
}

void RMNetDriver::FinishStop() {
  ivars->stopPhase = RMNetDriver_IVars::kStopDone;
  if (ivars->timer) ivars->timer->Cancel(^{});
  IOService* provider = ivars->stopProvider;
  ivars->stopProvider = nullptr;
  LOG("stop: passing Stop to the superclass");
  kern_return_t ret = Stop(provider, SUPERDISPATCH);
  if (ret != kIOReturnSuccess) LOG("super Stop 0x%x", ret);
  OSSafeReleaseNULL(provider);
}

// Starts the stop sequence and returns; the superclass gets Stop when USB has quiesced.
kern_return_t RMNetDriver::Stop_Impl(IOService* provider) {
  LOG_FIRST(kLogStop, "Stop");
  TearDown(provider);
  return kIOReturnSuccess;
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
  if (ivars->stopping || !ivars->core || ivars->coreStopped) return;
  ivars->core->on_control(data, len, NowMs());
  ApplyCore();
}

// The control channel stopped for good (the interrupt read keeps failing). The session cannot
// continue: stop it and report the link down. It is not restarted; a re-enumeration starts afresh.
void RMNetDriver::OnUsbFatal(const char* what) {
  LOG("usb failed: %{public}s", what);
  ivars->usbFailed = true;
  if (ivars->stopping || !ivars->core || ivars->coreStopped) return;
  ivars->coreStopped = true;
  ivars->core->stop();
  ApplyCore();
}

// Applies what the last Core call decided, now that it has returned: link down, then link up
// (both, in that order, for a bounce). A second link up while the link is up means a family was
// added: the emulator, the MTU and the properties are updated, a router advertisement goes out if
// IPv6 is new, and the link stays active. The data path is updated last, after the link is
// reported, because starting the bulk reads can fail and stop the session (OnUsbFatal, which
// applies its own link down).
void RMNetDriver::ApplyCore() {
  CoreHost::LinkChange c = ivars->core->take_link_change();
  if (c.down) {
    ivars->core->data_link_down();
    ivars->mtu = kMtu;
    if (ivars->linkActive) {
      ivars->linkActive = false;
      ReportLink();
    }
    LOG("link down");
  }
  if (c.up) {
    const rmnet::RuntimeSettings& s = ivars->core->link_config().settings;
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
    ivars->core->data_link_up(NowMs());
  }
  PublishStatus();
  FlushRx();  // a router advertisement
  if (ivars->core->take_uplink_resumed()) DrainTx();
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

void RMNetDriver::TxPacketsAvailable_Impl(OSAction*) {
  LOG_FIRST(kLogTxAvailable, "TxPacketsAvailable");
  DrainTx();
}

// Empty receive packets arrived; also a chance to hand up filled ones the queue refused before.
void RMNetDriver::RxPacketsAvailable_Impl(OSAction*) {
  LOG_FIRST(kLogRxAvailable, "RxPacketsAvailable");
  if (ivars->stopping) return;
  FlushRx();
}

// Takes frames from the TX submission queue until it is empty, passes each to CoreHost and
// completes it whatever happened to it (CoreHost copies what it keeps), then sends the open
// uplink buffer: the queue is empty. Not while the modem has paused the uplink: frames stay
// queued until it resumes. If the completion queue refuses packets, they are kept and returned
// first next time; with no room to keep a whole batch, the rest waits for the next timer tick.
void RMNetDriver::DrainTx() {
  FlushTxDone();
  if (ivars->stopping || !ivars->core || !ivars->txSubmit) return;
  if (ivars->core->uplink_paused()) {
    ivars->txHeld = true;
    return;
  }
  ivars->txHeld = false;
  IOUserNetworkPacket* pkts[kTxBatch];
  for (;;) {
    if (kTxHold - ivars->txDoneCount < kTxBatch) {
      ivars->txHeld = true;
      break;
    }
    uint32_t n = ivars->txSubmit->DequeuePackets(pkts, kTxBatch);
    if (n == 0) break;
    for (uint32_t i = 0; i < n; i++) {
      IOUserNetworkPacket* p = pkts[i];
      size_t off = p->getDataOff();
      uint32_t len = p->getDataLength();
      LOG_FIRST(kLogTxPacket, "first tx packet: data offset %zu, length %u", off, len);
      const uint8_t* data = reinterpret_cast<const uint8_t*>(p->getDataVirtualAddress()) + off;
      ivars->core->transmit(data, len);
      ivars->txDone[ivars->txDoneCount++] = p;
    }
    FlushTxDone();
  }
  ivars->core->flush_uplink();
  FlushRx();  // emulator replies
}

void RMNetDriver::FlushTxDone() {
  uint32_t n = ivars->txDoneCount;
  if (n == 0 || !ivars->txComplete) return;
  uint32_t done = ivars->txComplete->EnqueuePackets(ivars->txDone, n);
  if (done > n) done = n;
  if (done < n) {
    LOG_FIRST(kLogTxCompleteFull, "tx completion queue took %u of %u packets; the rest are kept", done, n);
    memmove(&ivars->txDone[0], &ivars->txDone[done], (n - done) * sizeof(ivars->txDone[0]));
  }
  ivars->txDoneCount = n - done;
}

// CoreHost's receive buffers: one packet from the RX submission queue at a time, kept until it
// is filled. None when kRxHold filled packets are still waiting for the completion queue.
uint8_t* RMNetDriver::RxBuffer(size_t* cap) {
  if (!ivars->rxSpare) {
    if (ivars->rxOutCount >= kRxHold || !ivars->rxSubmit) return nullptr;
    IOUserNetworkPacket* p = nullptr;
    if (ivars->rxSubmit->DequeuePacket(&p) != kIOReturnSuccess || !p) return nullptr;
    ivars->rxSpare = p;
  }
  *cap = kPacketBufSize;
  return reinterpret_cast<uint8_t*>(ivars->rxSpare->getDataVirtualAddress());
}

void RMNetDriver::RxCommit(size_t len) {
  IOUserNetworkPacket* p = ivars->rxSpare;
  if (!p) return;
  ivars->rxSpare = nullptr;
  IOReturn ret = p->setDataOffAndLen(0, len);
  LOG_FIRST(kLogRxPacket, "first rx packet: length %zu, setDataOffAndLen 0x%x", len, ret);
  p->setLinkHeaderLength(kLinkHeaderLen);
  ivars->rxOut[ivars->rxOutCount++] = p;
  if (ivars->rxOutCount >= kRxBatch) FlushRx();
}

// Hands filled packets up in one call; what the completion queue refuses is kept, in order.
void RMNetDriver::FlushRx() {
  uint32_t n = ivars->rxOutCount;
  if (n == 0 || !ivars->rxComplete) return;
  uint32_t done = ivars->rxComplete->EnqueuePackets(ivars->rxOut, n);
  if (done > n) done = n;
  if (done < n) {
    LOG_FIRST(kLogRxCompleteFull, "rx completion queue took %u of %u packets; the rest are kept", done, n);
    memmove(&ivars->rxOut[0], &ivars->rxOut[done], (n - done) * sizeof(ivars->rxOut[0]));
  }
  ivars->rxOutCount = n - done;
}

// One completed bulk read: frames go up in one batch, and a resumed uplink is drained.
void RMNetDriver::OnBulkIn(const uint8_t* data, size_t len) {
  if (ivars->stopping || !ivars->core) return;
  ivars->core->on_bulk_in(data, len);
  FlushRx();
  if (ivars->core->take_uplink_resumed()) DrainTx();
}

void RMNetDriver::OnBulkOutDone(int slot, bool ok) {
  if (ivars->stopping || !ivars->core) return;
  ivars->core->on_bulk_out_done(slot, ok);
}

// The data path counters, as properties next to RMNetState, once a second when they changed.
// RMNetPacketsHeld is what the driver holds of the pool (spare, unhanded receive packets and
// uncompleted transmit packets); idle, it is 0 or 1 (a spare).
void RMNetDriver::PublishCounters() {
  const DataCounters& c = ivars->core->counters();
  const UsbIoStats& u = ivars->usb->stats();
  uint32_t poolCount = 0;
  kern_return_t pret = ivars->pool ? ivars->pool->GetPacketCount(&poolCount) : kIOReturnNotReady;
  LOG_FIRST(kLogPoolCount, "pool GetPacketCount: %u (0x%x)", poolCount, pret);
  struct Entry {
    const char* key;
    uint64_t value;
  };
  const Entry entries[kCounterCount] = {
      {"RMNetRxPackets", c.rx_packets},
      {"RMNetRxBytes", c.rx_bytes},
      {"RMNetTxPackets", c.tx_packets},
      {"RMNetTxBytes", c.tx_bytes},
      {"RMNetRxTransfers", c.rx_transfers},
      {"RMNetRxEmptyTransfers", c.rx_empty_transfers},
      {"RMNetTxTransfers", c.tx_transfers},
      {"RMNetReplies", c.replies},
      {"RMNetRxDropLinkDown", c.rx_drop_link_down},
      {"RMNetRxDropNoPacket", c.rx_drop_no_packet},
      {"RMNetRxDropFiltered", c.rx_drop_filtered},
      {"RMNetRxDropTooBig", c.rx_drop_too_big},
      {"RMNetRxDropOtherMux", c.rx_drop_other_mux},
      {"RMNetRxDropBadQmap", c.rx_drop_bad_qmap},
      {"RMNetTxDropLinkDown", c.tx_drop_link_down},
      {"RMNetTxDropFiltered", c.tx_drop_filtered},
      {"RMNetTxDropBusy", c.tx_drop_busy},
      {"RMNetTxDropRecovering", c.tx_drop_recovering},
      {"RMNetTxDropTooBig", c.tx_drop_too_big},
      {"RMNetTxDropUsb", c.tx_drop_usb},
      {"RMNetReplyDropNoPacket", c.reply_drop_no_packet},
      {"RMNetQmapCommands", c.commands},
      {"RMNetQmapFlowDisable", c.flow_disable},
      {"RMNetQmapFlowEnable", c.flow_enable},
      {"RMNetQmapCommandReplies", c.command_replies},
      {"RMNetQmapCommandReplyDrops", c.command_reply_drops},
      {"RMNetUsbBulkInErrors", u.bulk_in_errors},
      {"RMNetUsbBulkOutErrors", u.bulk_out_errors},
      {"RMNetUsbRecoveries", u.recoveries},
      {"RMNetUsbStallClears", u.stall_clears},
      {"RMNetPacketsHeld", uint64_t{ivars->rxOutCount} + ivars->txDoneCount + (ivars->rxSpare ? 1u : 0u)},
      {"RMNetPoolPacketCount", poolCount},
      {"RMNetUplinkPaused", ivars->core->uplink_paused() ? 1u : 0u},
  };
  bool changed = !ivars->countersPublished;
  for (uint32_t i = 0; i < kCounterCount; i++) {
    if (entries[i].value != ivars->counters[i]) changed = true;
  }
  if (!changed) return;

  OSDictionary* props = OSDictionary::withCapacity(kCounterCount);
  if (!props) return;
  bool ok = true;
  for (uint32_t i = 0; i < kCounterCount && ok; i++) {
    OSNumber* n = OSNumber::withNumber(entries[i].value, 64);
    ok = n && props->setObject(entries[i].key, n);
    OSSafeReleaseNULL(n);
  }
  if (ok) {
    kern_return_t ret = SetProperties(props);
    if (ret == kIOReturnSuccess) {
      for (uint32_t i = 0; i < kCounterCount; i++) ivars->counters[i] = entries[i].value;
      ivars->countersPublished = true;
    } else {
      LOG("SetProperties (counters) 0x%x", ret);
    }
  }
  OSSafeReleaseNULL(props);
}

// --- USB and timer -------------------------------------------------------------------------------

// Completions go to UsbIo even while stopping: it counts the aborted ones before releasing.
void RMNetDriver::BulkInComplete_Impl(OSAction* action, IOReturn status, uint32_t actualByteCount, uint64_t) {
  LOG_FIRST(kLogBulkIn, "BulkInComplete 0x%x, %u bytes", status, actualByteCount);
  if (!ivars || !ivars->usb) return;
  uint32_t slot = *static_cast<uint32_t*>(action->GetReference());
  ivars->usb->bulk_in_complete(slot, status, actualByteCount);
  if (ivars->stopping) AdvanceStop();
}

void RMNetDriver::BulkOutComplete_Impl(OSAction* action, IOReturn status, uint32_t actualByteCount, uint64_t) {
  LOG_FIRST(kLogBulkOut, "BulkOutComplete 0x%x, %u bytes", status, actualByteCount);
  if (!ivars || !ivars->usb) return;
  uint32_t slot = *static_cast<uint32_t*>(action->GetReference());
  ivars->usb->bulk_out_complete(slot, status, actualByteCount);
  if (ivars->stopping) AdvanceStop();
}

void RMNetDriver::InterruptComplete_Impl(OSAction*, IOReturn status, uint32_t actualByteCount, uint64_t) {
  LOG_FIRST(kLogInterruptComplete, "InterruptComplete 0x%x, %u bytes", status, actualByteCount);
  if (ivars && ivars->usb) ivars->usb->interrupt_complete(status, actualByteCount);
  if (ivars && ivars->stopping) AdvanceStop();
}

void RMNetDriver::ControlOutComplete_Impl(OSAction*, IOReturn status, uint32_t bytesTransferred) {
  LOG_FIRST(kLogControlOutComplete, "ControlOutComplete 0x%x, %u bytes", status, bytesTransferred);
  if (ivars && ivars->usb) ivars->usb->control_out_complete(status, bytesTransferred);
  if (ivars && ivars->stopping) AdvanceStop();
}

void RMNetDriver::ControlInComplete_Impl(OSAction*, IOReturn status, uint32_t bytesTransferred) {
  LOG_FIRST(kLogControlInComplete, "ControlInComplete 0x%x, %u bytes", status, bytesTransferred);
  if (ivars && ivars->usb) ivars->usb->control_in_complete(status, bytesTransferred);
  if (ivars && ivars->stopping) AdvanceStop();
}

void RMNetDriver::TimerFired_Impl(OSAction*, uint64_t) {
  LOG_FIRST(kLogTimerFired, "TimerFired");
  if (!ivars) return;
  if (ivars->stopping) {
    // The timer is the clock of the stop sequence until it passes Stop on.
    AdvanceStop();
    if (ivars->stopPhase != RMNetDriver_IVars::kStopDone) ArmTimer();
    return;
  }
  if (!ivars->core) return;
  uint64_t now = NowMs();
  if (ivars->usb) ivars->usb->tick();  // bounds a bulk pipe recovery; may report on_fatal
  if (!ivars->coreStopped) {
    ivars->core->tick(now);
    ApplyCore();
  }
  ivars->core->data_tick(now);
  FlushRx();
  if (ivars->txHeld || ivars->txDoneCount > 0) DrainTx();
  if (++ivars->ticks % kCounterTicks == 0) PublishCounters();
  ArmTimer();
}
