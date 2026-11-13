// Skeleton: registers an inactive Ethernet interface on the modem's QMI interface without opening
// it. Transmitted frames are completed and dropped. USB and the QMI session come later.
#include <os/log.h>
#include <string.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/OSCollections.h>
#include <USBDriverKit/USBDriverKit.h>  // umbrella: also declares IOUSBHostFreeDescriptor
#include <NetworkingDriverKit/NetworkingDriverKit.h>

#include "rmnet/ethernet.h"

#include "RMNetDriver.h"

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
constexpr uint32_t kTxBatch = 32;

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

}  // namespace

struct RMNetDriver_IVars {
  IODispatchQueue* queue;  // the service's Default queue; everything runs on it
  IOUserNetworkPacketBufferPool* pool;
  IOUserNetworkTxSubmissionQueue* txSubmit;
  IOUserNetworkTxCompletionQueue* txComplete;
  IOUserNetworkRxSubmissionQueue* rxSubmit;
  IOUserNetworkRxCompletionQueue* rxComplete;
  OSAction* txAvailAction;
  OSAction* rxAvailAction;
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
  LOG_FIRST(kLogInit, "init");
  return true;
}

// Objects are released here rather than in Stop, so nothing still queued on the Default queue can
// reach a released object.
void RMNetDriver::free() {
  LOG_FIRST(kLogFree, "free");
  if (ivars) {
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
  if (ret == kIOReturnSuccess) ret = CreateInterface();
  if (ret == kIOReturnSuccess) {
    PublishState("skeleton");
    ret = RegisterService();
  }
  if (ret != kIOReturnSuccess) {
    LOG("Start failed 0x%x", ret);
    Stop(provider, SUPERDISPATCH);
    return ret;
  }
  LOG("started");
  return kIOReturnSuccess;
}

// The pool, the four packet queues and their handlers, then the Ethernet interface itself, with
// the link reported inactive.
kern_return_t RMNetDriver::CreateInterface() {
  kern_return_t ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
  if (ret != kIOReturnSuccess) return ret;

  IOUserNetworkPacketBufferPoolOptions opts{};
  opts.packetCount = kPacketCount;
  opts.bufferCount = kPacketCount;
  opts.bufferSize = kPacketBufSize;
  opts.maxBuffersPerPacket = 1;
  opts.poolFlags = PoolFlagMapToDext;
  ret = IOUserNetworkPacketBufferPool::CreateWithOptions(this, "RMNetPool", &opts, &ivars->pool);
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

  // The USB serial number is not read yet (the interface is not opened), so the MAC is a fixed one.
  rmnet::MacPair macs = rmnet::derive_macs("unknown");
  ether_addr_t mac;
  memcpy(mac.octet, macs.host, sizeof(mac.octet));
  IOUserNetworkPacketQueue* queues[] = {ivars->txSubmit, ivars->txComplete, ivars->rxSubmit, ivars->rxComplete};
  ret = RegisterEthernetInterface(mac, ivars->pool, queues, 4);
  if (ret != kIOReturnSuccess) return ret;

  ret = setMaxTransferUnit(kMtu);
  if (ret != kIOReturnSuccess) LOG("setMaxTransferUnit 0x%x", ret);
  ret = reportLinkStatus(kIOUserNetworkLinkStatusInactive, kIOUserNetworkMediaEthernetAuto);
  if (ret != kIOReturnSuccess) LOG("reportLinkStatus 0x%x", ret);
  return kIOReturnSuccess;
}

kern_return_t RMNetDriver::Stop_Impl(IOService* provider) {
  LOG_FIRST(kLogStop, "Stop");
  if (ivars->txSubmit) {
    reportLinkStatus(kIOUserNetworkLinkStatusInactive, kIOUserNetworkMediaEthernetAuto);
    ivars->txSubmit->setEnable(false);
    ivars->txComplete->setEnable(false);
    ivars->rxSubmit->setEnable(false);
    ivars->rxComplete->setEnable(false);
  }
  return Stop(provider, SUPERDISPATCH);
}

kern_return_t RMNetDriver::SetPowerState_Impl(uint32_t powerFlags) {
  LOG_FIRST(kLogSetPowerState, "SetPowerState 0x%x", powerFlags);
  return SetPowerState(powerFlags, SUPERDISPATCH);  // must reach the superclass to acknowledge
}

// Status for the host app: properties on this service in the I/O registry.
void RMNetDriver::PublishState(const char* state) {
  OSDictionary* props = OSDictionary::withCapacity(1);
  OSString* s = OSString::withCString(state);
  if (props && s) {
    props->setObject("RMNetState", s);
    kern_return_t ret = SetProperties(props);
    if (ret != kIOReturnSuccess) LOG("SetProperties 0x%x", ret);
  }
  OSSafeReleaseNULL(s);
  OSSafeReleaseNULL(props);
}

// --- Network stack callbacks ---------------------------------------------------------------------

kern_return_t RMNetDriver::SetInterfaceEnable_Impl(bool isEnable) {
  LOG_FIRST(kLogSetInterfaceEnable, "SetInterfaceEnable %d", isEnable);
  ivars->txSubmit->setEnable(isEnable);
  ivars->txComplete->setEnable(isEnable);
  ivars->rxSubmit->setEnable(isEnable);
  ivars->rxComplete->setEnable(isEnable);
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

// Replaces the deprecated ReportAvailableMediaTypes: the framework asks for the media list.
IOReturn RMNetDriver::getSupportedMediaArray(MediaWord* mediaArray, uint32_t* mediaCount) {
  LOG_FIRST(kLogGetSupportedMedia, "getSupportedMediaArray");
  if (!mediaArray || !mediaCount || *mediaCount < 1) return kIOReturnBadArgument;
  mediaArray[0] = kIOUserNetworkMediaEthernetAuto;
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
  LOG_FIRST(kLogGetMaxTransferUnit, "getMaxTransferUnit");
  return super::getMaxTransferUnit();
}

IOReturn RMNetDriver::setPowerState(unsigned long powerState, IOService* whatDevice) {
  LOG_FIRST(kLogSetPowerStateLower, "setPowerState %lu", powerState);
  return super::setPowerState(powerState, whatDevice);
}

// --- Packet queues -------------------------------------------------------------------------------

// The skeleton sends nothing: every queued frame is handed straight back as completed.
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
