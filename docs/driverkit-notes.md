# DriverKit notes for the RM520N-GL driver

Date: 2026-11-13. macOS 27.0, Xcode 27.1, DriverKit SDK 27.0, Apple silicon.

This is reference material for writing the dext. Every API below was compiled and linked against DriverKit SDK 27.0 in a throwaway spike, unless it is marked **[not compiled]**. Anything marked **[runtime]** can only be settled by loading a real driver; compiling proves nothing about it.

- Spike: `/private/tmp/claude-501/-Users-you--claude-spares-spare-GDJ2gj/3d0de6da-24d1-49cc-a5d9-0a21dc065501/scratchpad/dext-spike/` (`gen.rb`, `Driver/NetSpike.iig`, `Driver/NetSpike.cpp`, `Driver/Info.plist`, `Driver/Driver.entitlements`, `Host/`). It is a scratch directory and may not survive, so the examples below are copied out of it.
- `$FW` below means `/Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform/Developer/SDKs/DriverKit27.0.sdk/System/DriverKit/System/Library/Frameworks`. Declarations are quoted from the `.iig` files. The generated `.h` next to each one has the same declarations plus the RPC plumbing.
- The other source of truth was macOS's own network dexts in `/System/Library/DriverExtensions/`: `com.apple.DriverKit.AppleUserECM.dext` (USB), `AppleEthernetE1000` and `AppleEthernetIXL` (PCI). I read only their `Info.plist`, entitlements, imported and exported symbol names (`nm`), and strings. **All three use the same older API shape**: uppercase `Start`/`Stop`, queues made with `Create(..., IODispatchQueue*, ...)`, and data-available handlers. The spike follows that shape because it is what ships on this OS.

---

## 1. Network interface (NetworkingDriverKit)

### 1.1 Declaring the subclass

Header: `$FW/NetworkingDriverKit.framework/Headers/IOUserNetworkEthernet.iig`

```
class KERNEL IOUserNetworkEthernet : public IOService
```

Spike `.iig`. This is the set AppleUserECM implements, plus our USB and timer handlers:

```cpp
#include <NetworkingDriverKit/IOUserNetworkEthernet.iig>
#include <USBDriverKit/IOUSBHostPipe.iig>
#include <USBDriverKit/IOUSBHostDevice.iig>   // for the CompleteAsyncDeviceRequest TYPE
#include <DriverKit/IOTimerDispatchSource.iig>
#include <DriverKit/IODataQueueDispatchSource.iig>

class NetSpike : public IOUserNetworkEthernet
{
public:
    virtual bool init() override;
    virtual void free() override;
    virtual kern_return_t Start(IOService * provider) override;
    virtual kern_return_t Stop(IOService * provider) override;
    virtual kern_return_t SetPowerState(uint32_t powerFlags) override;

    virtual kern_return_t SetInterfaceEnable(bool isEnable) override;
    virtual kern_return_t SetPromiscuousModeEnable(bool enable) override;
    virtual kern_return_t SetAllMulticastModeEnable(bool enable) override;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    virtual kern_return_t SelectMediaType(IOUserNetworkMediaType mediaType) override;
#pragma clang diagnostic pop
    virtual IOReturn getSupportedMediaArray(MediaWord * mediaArray, uint32_t * mediaCount) override LOCALONLY;
    virtual IOReturn setMulticastAddresses(const ether_addr_t * addresses, uint32_t count) override LOCALONLY;

    virtual void TxPacketsAvailable(OSAction * action) TYPE(IODataQueueDispatchSource::DataAvailable);
    virtual void RxPacketsAvailable(OSAction * action) TYPE(IODataQueueDispatchSource::DataAvailable);
    // ... USB completions and timer, see sections 2 and 3
};
```

What it must override. In the header these are declared `= 0`: `SetInterfaceEnable`, `SetPromiscuousModeEnable`, `SetMulticastAddresses`, `SetAllMulticastModeEnable`, `SelectMediaType`, `SetWakeOnMagicPacketEnable`, `SetMTU`, `GetMaxTransferUnit`, `SetHardwareAssists`, `GetHardwareAssists`. **The compiler does not enforce any of these.** A build with none of them overridden still succeeded. The framework itself exports `_SetInterfaceEnable_Impl`, `_SelectMediaType_Impl`, `_SetMaxTransferUnit_Impl` and the others, and they presumably forward to the lowercase virtuals. AppleUserECM overrides `SetInterfaceEnable`, `SetPromiscuousModeEnable`, `SetAllMulticastModeEnable`, `SelectMediaType` (all uppercase, as `_Impl`) and the lowercase `setMulticastAddresses`. Do the same. **[runtime]** Which of the uppercase and lowercase variants the stack actually calls: log in every one on first load.

`SetInterfaceEnable` is where the stack turns the interface on or off. The spike enables the four queues there, as AppleUserECM does:

```cpp
kern_return_t NetSpike::SetInterfaceEnable_Impl(bool isEnable) {
  ivars->txSubmit->SetEnable(isEnable);
  ivars->txComplete->SetEnable(isEnable);
  ivars->rxSubmit->SetEnable(isEnable);
  ivars->rxComplete->SetEnable(isEnable);
  return kIOReturnSuccess;
}
```

### 1.2 Buffer pool

Header: `$FW/NetworkingDriverKit.framework/Headers/IOUserNetworkPacketBufferPool.iig`

```
static kern_return_t
CreateWithOptions(
    IOService * device,
    const char name[1024],
    const IOUserNetworkPacketBufferPoolOptions * options,
    IOUserNetworkPacketBufferPool ** pool) LOCALONLY;

struct IOUserNetworkPacketBufferPoolOptions {
    uint32_t packetCount; uint32_t bufferCount; uint32_t bufferSize;
    uint32_t maxBuffersPerPacket; uint32_t memorySegmentSize; uint32_t poolFlags;
    IODMACommandSpecification dmaSpecification; uint32_t _resv[16];
};
// poolFlags: PoolFlagSingleMemorySegment, PoolFlagIODirectionIn/Out, PoolFlagVirtualDevice,
//            PoolFlagMapToDext, PoolFlagMapToDevice   (PoolFlagPersistentMemory is deprecated)
```

`Create(...)` (no options) is deprecated. Spike:

```cpp
IOUserNetworkPacketBufferPoolOptions opts{};
opts.packetCount = 512; opts.bufferCount = 512; opts.bufferSize = 2048;
opts.maxBuffersPerPacket = 1;
opts.poolFlags = PoolFlagMapToDext;
ret = IOUserNetworkPacketBufferPool::CreateWithOptions(this, "NetSpikePool", &opts, &ivars->pool);
```

**[runtime]** Whether `PoolFlagMapToDext` is needed for `getDataVirtualAddress()` to be usable, and what `memorySegmentSize` and `dmaSpecification` should be (left zero). There is no DMA here: every byte is copied by the CPU between USB buffers and packets.

### 1.3 The four queues

Headers: `IOUserNetworkTxSubmissionQueue.iig`, `IOUserNetworkTxCompletionQueue.iig`, `IOUserNetworkRxSubmissionQueue.iig`, `IOUserNetworkRxCompletionQueue.iig` in `$FW/NetworkingDriverKit.framework/Headers/`. All four have the same shape:

```
static kern_return_t
Create( IOUserNetworkPacketBufferPool *   pool,
        OSObject *                        owner,
        uint32_t                          capacity,
        uint32_t                          queueId,
        IODispatchQueue *                 dispatchQueue,
        IOUserNetworkTxSubmissionQueue ** queue ) LOCALONLY;
```

The TX submission queue also has an NDK_24 overload with `IOUserNetworkServiceClass serviceClass` after `owner`. The roles, from Apple's class documentation:

- **TX submission**: frames from the stack for the driver to send.
- **TX completion**: the driver hands sent packets back here.
- **RX submission**: empty packets for the driver to fill.
- **RX completion**: the driver hands filled packets up here.

Spike, all on the service's Default queue (E1000 does the same):

```cpp
ret = CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
ret = IOUserNetworkTxSubmissionQueue::Create(ivars->pool, this, 256, 0, ivars->queue, &ivars->txSubmit);
ret = IOUserNetworkTxCompletionQueue::Create(ivars->pool, this, 256, 0, ivars->queue, &ivars->txComplete);
ret = IOUserNetworkRxSubmissionQueue::Create(ivars->pool, this, 256, 0, ivars->queue, &ivars->rxSubmit);
ret = IOUserNetworkRxCompletionQueue::Create(ivars->pool, this, 256, 0, ivars->queue, &ivars->rxComplete);
```

### 1.4 Registering the interface with a MAC address

```
virtual kern_return_t
RegisterEthernetInterface(
    ether_addr_t macAddress,
    IOUserNetworkPacketBufferPool *pool,
    IOUserNetworkPacketQueue **queues,
    uint32_t queueCount) LOCALONLY NDK_21;

virtual IOReturn                                    // NDK_24, separate TX and RX pools
registerEthernetInterface(
    ether_addr_t macAddress,
    IOUserNetworkPacketQueue **queues,
    uint32_t numQueues,
    IOUserNetworkPacketBufferPool *txPool,
    IOUserNetworkPacketBufferPool *rxPool) LOCALONLY NDK_24;
```

The overload that takes `IOUserNetworkMACAddress` is deprecated. AppleUserECM imports both live variants. Spike:

```cpp
rmnet::MacPair macs = rmnet::derive_macs("spike-serial");
ether_addr_t mac;
memcpy(mac.octet, macs.host, 6);
IOUserNetworkPacketQueue* queues[] = {ivars->txSubmit, ivars->txComplete, ivars->rxSubmit, ivars->rxComplete};
ret = RegisterEthernetInterface(mac, ivars->pool, queues, 4);
// also compiled: registerEthernetInterface(mac, queues, 4, ivars->pool, ivars->pool);
```

### 1.5 Transmit: learning that frames are waiting, reading them, completing them

Header: `IOUserNetworkPacketQueue.iig`

```
virtual kern_return_t CopyDataQueue(IODataQueueDispatchSource ** dataQueue) LOCALONLY;
virtual uint32_t DequeuePackets(IOUserNetworkPacket ** packets, uint32_t maxDequeueCount) LOCALONLY;
virtual kern_return_t DequeuePacket(IOUserNetworkPacket ** packet) LOCALONLY;
virtual uint32_t EnqueuePackets(IOUserNetworkPacket ** packets, uint32_t packetCount) LOCALONLY;
virtual kern_return_t EnqueuePacket(IOUserNetworkPacket * packet) LOCALONLY;
```

Header: `$FW/DriverKit.framework/Headers/IODataQueueDispatchSource.iig`

```
virtual kern_return_t SetDataAvailableHandler(OSAction * action TYPE(DataAvailable));
```

The driver gets the TX submission queue's data queue and installs its own `DataAvailable` handler. AppleUserECM does exactly this; it exports `TxPacketsAvailable_Impl` and imports `SetDataAvailableHandler`:

```cpp
IODataQueueDispatchSource* dq = nullptr;
ret = CreateActionTxPacketsAvailable(0, &ivars->txAvailAction);
ret = ivars->txSubmit->CopyDataQueue(&dq);
ret = dq->SetDataAvailableHandler(ivars->txAvailAction);
OSSafeReleaseNULL(dq);
// the same for rxSubmit -> RxPacketsAvailable: empty buffers became available
```

Reading the bytes. Header: `IOUserNetworkPacket.iig`

```
virtual uint64_t getDataVirtualAddress() const LOCALONLY;
virtual uint32_t getDataLength() const LOCALONLY final;
virtual size_t   getDataOff() const final LOCALONLY NDK_23;
virtual IOReturn setDataOffAndLen(size_t offset, size_t length) final LOCALONLY NDK_23;
```

The handler as compiled:

```cpp
void NetSpike::TxPacketsAvailable_Impl(OSAction*) {
  IOUserNetworkPacket* pkts[32];
  uint32_t n = ivars->txSubmit->DequeuePackets(pkts, 32);
  for (uint32_t i = 0; i < n; i++) {
    const uint8_t* data = reinterpret_cast<const uint8_t*>(pkts[i]->getDataVirtualAddress()) + pkts[i]->getDataOff();
    uint32_t len = pkts[i]->getDataLength();
    rmnet::TxResult r = c->eth.handle_tx(data, len, c->frame, sizeof(c->frame));
    if (r.action == rmnet::TxAction::Forward) c->agg.add(0x81, r.ip.data, r.ip.len);
    else if (r.action == rmnet::TxAction::Reply) DeliverRx(c->frame, r.reply_len);
  }
  if (n) ivars->txComplete->EnqueuePackets(pkts, n);          // completing = handing back
  size_t xfer = c->agg.finish();
  if (xfer) ivars->bulkOut->AsyncIO(ivars->outBuf, (uint32_t)xfer, ivars->outAction, 0);
}
```

**[runtime]**:
- Whether `getDataVirtualAddress()` points at the buffer start, so that adding `getDataOff()` is right, or already at the data.
- Whether the handler fires once per batch, or the driver must drain the queue until it is empty. Drain in a loop.
- Whether completing a packet before its USB transfer finishes is acceptable. The spike copies the bytes into the aggregate first, so it is safe either way.

### 1.6 Receive: getting a packet, filling it, handing it up

```cpp
void NetSpike::DeliverRx(const uint8_t* frame, size_t len) {
  IOUserNetworkPacket* pkt = nullptr;
  if (ivars->rxSubmit->DequeuePacket(&pkt) != kIOReturnSuccess || !pkt) return;
  memcpy(reinterpret_cast<uint8_t*>(pkt->getDataVirtualAddress()), frame, len);
  pkt->setDataOffAndLen(0, len);
  ivars->rxComplete->EnqueuePacket(pkt);
}
```

**[runtime]**: whether the RX submission queue already holds empty packets when the interface comes up, or only after `SetInterfaceEnable(true)`. What happens when it is empty: the spike drops the frame, and the real driver should count the drop. Whether `EnqueuePackets` in batches is required to be fast enough. Batch anyway: one `EnqueuePackets` per USB transfer.

### 1.7 Link status, speed and MTU

```
virtual IOReturn reportLinkStatus(LinkStatus linkStatus, MediaWord activeMediaType) LOCALONLY NDK_21;
virtual IOReturn reportLinkQuality(LinkQuality linkQuality) LOCALONLY NDK_21;
virtual IOReturn reportDataBandwidths(uint64_t maxInputBandwidth, uint64_t maxOutputBandwidth,
        uint64_t effectiveInputBandwidth, uint64_t effectiveOutputBandwidth) LOCALONLY NDK_21;
virtual IOReturn getSupportedMediaArray(MediaWord *mediaArray, uint32_t *mediaCount) LOCALONLY NDK_21;
virtual IOReturn setMaxTransferUnit( uint32_t mtu ) LOCALONLY NDK_21;
virtual uint32_t getMaxTransferUnit() LOCALONLY NDK_21;
virtual IOReturn addHardwareCountsWithInterfaceStatistics(const IOUserNetworkHardwareCounts *stats) LOCALONLY NDK_22;
```

Constants are in `IOUserNetworkTypes.h`: `kIOUserNetworkLinkStatusInactive` (1), `kIOUserNetworkLinkStatusActive` (3), `kIOUserNetworkMediaEthernetAuto` (`IFM_ETHER | IFM_AUTO`), and `kIOUserNetworkMediaEthernet10GBaseT` and the rest.

```cpp
reportLinkStatus(kIOUserNetworkLinkStatusActive, kIOUserNetworkMediaEthernetAuto);   // link_up
reportLinkStatus(kIOUserNetworkLinkStatusInactive, kIOUserNetworkMediaEthernetAuto); // link_down
reportDataBandwidths(5000000000ull, 5000000000ull, 0, 0);

IOReturn NetSpike::getSupportedMediaArray(MediaWord* mediaArray, uint32_t* mediaCount) {
  if (!mediaArray || !mediaCount || *mediaCount < 1) return kIOReturnBadArgument;
  mediaArray[0] = kIOUserNetworkMediaEthernetAuto;
  *mediaCount = 1;
  return kIOReturnSuccess;
}
```

AppleUserECM uses the lowercase `reportLinkStatus`: it never imports the RPC stub of the uppercase `ReportLinkStatus`.

**[runtime]** MTU. It is not clear whether `setMaxTransferUnit` is the driver announcing its MTU or the stack's request handler, the counterpart of `getMaxTransferUnit`. The spike calls `setMaxTransferUnit(1500)` after registering. If the interface does not show MTU 1500, override `getMaxTransferUnit()` instead. 1500 is the Ethernet default anyway. A carrier MTU below 1500 (QMI reports one) is delivered to macOS by Core's DHCP option 26 and the RA MTU option. It does not need the interface MTU.

### 1.8 Deprecated in this SDK, and what replaces them

All are marked `__deprecated` in the headers above.

| Deprecated | Use |
|---|---|
| `RegisterEthernetInterface(IOUserNetworkMACAddress, ...)` | `RegisterEthernetInterface(ether_addr_t, ...)` or `registerEthernetInterface(...)` |
| `ReportLinkStatus`, `ReportLinkQuality`, `ReportDataBandwidths` | `reportLinkStatus`, `reportLinkQuality`, `reportDataBandwidths` |
| `ReportAvailableMediaTypes` | override `getSupportedMediaArray` |
| `SelectMediaType` | `handleChosenMedia`. Still overridden by AppleUserECM; keep it. |
| `SetInterfaceEnable`, `SetPromiscuousModeEnable`, `SetAllMulticastModeEnable`, `SetMulticastAddresses` | lowercase versions. Apple's dexts still implement the uppercase ones. |
| `SetMTU`, `GetMaxTransferUnit`, `SetHardwareAssists`, `GetHardwareAssists`, `SetWakeOnMagicPacketEnable` | `setMaxTransferUnit`, `getMaxTransferUnit`, `setHardwareAssists(uint32_t, uint32_t)`, `getHardwareAssists` |
| `SetTxPacketHeadroom` | override `getTxDataOffset` |
| `IOUserNetworkMediaType`, `IOUserNetworkMACAddress` (types) | `MediaWord`, `ether_addr_t` |
| `IOUserNetworkPacketBufferPool::Create` | `CreateWithOptions` |
| `IOUserNetworkPacket::SetDataLength`, `GetDataLength`, `SetDataOffset`, `getDataOffset`, `setDataOffsetAndLength` | `setDataLength`, `getDataLength`, `setDataOff`, `getDataOff`, `setDataOffAndLen` |
| `IOUserNetworkPacketQueue::SetEnable` | `setEnable` |

There is also a newer, kernel-style queue API (NDK 22 and later), which no Apple dext on this Mac uses. It compiles (spike `AlternativeApis()`, never called):

```cpp
static IOUserNetworkTxSubmissionQueue *
withPool( IOUserNetworkPacketBufferPool *pool, uint32_t capacity, IOUserNetworkPacketQueueId queueId,
          OSObject *target, QueryFreeSpaceAction freeSpaceAction, DequeueAction dequeueAction,
          void *refCon = 0, IOOptionBits options = 0 ) LOCALONLY;
typedef uint32_t (*DequeueAction)(OSObject *target, IOUserNetworkPacketQueue *queue,
                                  IOUserNetworkPacket **packetArray, uint32_t packetCount, void *refCon);
virtual IOReturn requestEnqueue(void *refCon = 0, IOOptionBits options = 0) LOCALONLY;
virtual IOReturn requestDequeue(void *refCon = 0, IOOptionBits options = 0) LOCALONLY;
virtual IOReturn enqueuePackets(IOUserNetworkPacket **inPackets, uint32_t count, IOOptionBits options = 0) LOCALONLY;
virtual IOReturn allocatePacket(IOUserNetworkPacket ** packet, IOOptionBits options = kIOUserNetworkNonBlocking) LOCALONLY;  // on the pool
```

There is also `IOUserNetworkPacketPoller` (`IOUserNetworkPacketPoller.iig`), for hybrid polling. **[not compiled]**. Neither is recommended for the first version: there is no shipping example to copy and no documentation of who calls the actions on which queue.

### 1.9 Threading model

- Every dext service has a serial **Default** queue (`kIOServiceDefaultQueueName`). `Start`, `Stop` and every RPC or action method without `QUEUENAME` run on it, one at a time. All queues are serial (`IODispatchQueue.iig`: "All queues are currently serial").
- A method declared with `QUEUENAME(Name)` in the `.iig` runs on the queue the driver registered with `SetDispatchQueue("Name", queue)`. That compiles (tested with `QUEUENAME(DataQueue)`); the runtime pairing is **[runtime]**. The framework's own TX and RX submission handlers are declared `QUEUENAME(TxDispatchQueue)` and `QUEUENAME(RxDispatchQueue)` (macros `_txDispatchQueue` and `_rxDispatchQueue`). AppleUserECM has the strings `TxDispatchQueue`, `RxDispatchQueue` and its own `rxDispatchQueue`. E1000 puts its packet queues on Default.
- **Recommendation**: run everything on the Default queue: queues, USB completions, the timer and Core. Then Core needs no locks, and the "no re-entry from a delegate callback" rule is easy to keep. Add a second queue only if the throughput gate fails, and then put all Core calls behind one queue.

---

## 2. USB (USBDriverKit)

Include `<USBDriverKit/USBDriverKit.h>` in the `.cpp`. The individual headers do not pull in `USBDriverKitDefs.h` (see build error 1).

### 2.1 Opening the interface and copying pipes

Header: `$FW/USBDriverKit.framework/Headers/IOUSBHostInterface.iig`

```
virtual kern_return_t Open (IOService *forClient, IOOptionBits options, uint8_t * arg );
virtual kern_return_t Close (IOService *forClient, IOOptionBits options);
virtual kern_return_t CopyPipe(uint8_t address, IOUSBHostPipe ** pipe);
virtual const IOUSBConfigurationDescriptor * CopyConfigurationDescriptor() LOCALONLY;
virtual const IOUSBInterfaceDescriptor * GetInterfaceDescriptor(const IOUSBConfigurationDescriptor * configurationDescriptor) LOCALONLY;
virtual kern_return_t CopyDevice(IOUSBHostDevice ** device);
```

`IOUSBHostFreeDescriptor` overloads are declared in `USBDriverKitDefs.h`. `Close` "will acquire the service's workloop lock, abort any IO for the interface and its endpoints".

```cpp
ivars->interface = OSDynamicCast(IOUSBHostInterface, provider);
ivars->interface->retain();
const IOUSBConfigurationDescriptor* cfg = ivars->interface->CopyConfigurationDescriptor();
const IOUSBInterfaceDescriptor* id = cfg ? ivars->interface->GetInterfaceDescriptor(cfg) : nullptr;
bool ok = id && id->bInterfaceClass == 0xff && id->bInterfaceSubClass == 0xff &&
          id->bInterfaceProtocol == 0xff && id->bNumEndpoints == 3;
if (cfg) IOUSBHostFreeDescriptor(cfg);
ret = ivars->interface->Open(this, 0, nullptr);
ret = ivars->interface->CopyPipe(0x8e, &ivars->bulkIn);
ret = ivars->interface->CopyPipe(0x0f, &ivars->bulkOut);
ret = ivars->interface->CopyPipe(0x88, &ivars->intrIn);
```

Pipe information, compiled: `GetSpeed(uint8_t *speed) const`, `GetDescriptors(IOUSBStandardEndpointDescriptors *, IOUSBGetEndpointDescriptorOptions)`, and `uint16_t IOUSBGetEndpointMaxPacketSize(uint32_t usbDeviceSpeed, const IOUSBEndpointDescriptor*)` (`AppleUSBDescriptorParsing.h`). Use these to read the 1024-byte packet size rather than hard-coding it.

The USB serial number for `derive_macs` comes from `CopyDevice` and then `IOUSBHostDevice::CopyStringDescriptor(uint8_t index)` with the device descriptor's `iSerialNumber`. **[not compiled]**: the declarations exist in `IOUSBHostDevice.iig`, but the spike passes a constant. The descriptor is UTF-16LE and must be converted to ASCII.

### 2.2 Buffers

```
// IOUSBHostInterface.iig
virtual kern_return_t CreateIOBuffer (IOOptionBits options, uint64_t capacity,
                                      IOBufferMemoryDescriptor ** buffer) LOCALONLY;
// DriverKit IOBufferMemoryDescriptor.iig
static kern_return_t Create(uint64_t options, uint64_t capacity, uint64_t alignment, IOBufferMemoryDescriptor ** memory);
kern_return_t GetAddressRange(IOAddressSegment * range) LOCALONLY;
virtual kern_return_t SetLength(uint64_t length);
```

`CreateIOBuffer` gives a buffer "optimized for use by the underlying controller hardware ... will not be bounced". Options are `kIOMemoryDirectionIn` for reads and `kIOMemoryDirectionOut` for writes (**wrong for a buffer the dext writes: see Runtime findings, Task 5**). `GetAddressRange` gives the dext's own mapping, so there is no separate `CreateMapping` call. AppleUserECM imports `IOMemoryDescriptor::Map` instead.

```cpp
static kern_return_t MakeBuffer(IOUSBHostInterface* intf, IOOptionBits dir, uint32_t size,
                                IOBufferMemoryDescriptor** buf, uint8_t** addr) {
  kern_return_t ret = intf->CreateIOBuffer(dir, size, buf);
  if (ret != kIOReturnSuccess) return ret;
  IOAddressSegment seg{};
  ret = (*buf)->GetAddressRange(&seg);
  *addr = reinterpret_cast<uint8_t*>(seg.address);
  return ret;
}
```

### 2.3 Control requests

```
// IOUSBHostInterface.iig
virtual kern_return_t DeviceRequest (uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue,
        uint16_t wIndex, uint16_t wLength, IOMemoryDescriptor *dataBuffer,
        uint16_t *bytesTransferred, uint32_t completionTimeoutMs) LOCALONLY;
virtual kern_return_t AsyncDeviceRequest (uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue,
        uint16_t wIndex, uint16_t wLength, IOMemoryDescriptor *dataBuffer,
        OSAction *completion/*TYPE(CompleteAsyncDeviceRequest)*/, uint32_t completionTimeoutMs) LOCALONLY;
virtual kern_return_t AbortDeviceRequests (IOOptionBits options, IOReturn withError) LOCALONLY;
// IOUSBHostDevice.iig: the completion type lives here, not on the interface
virtual void CompleteAsyncDeviceRequest (OSAction *action TARGET, IOReturn status, uint32_t bytesTransferred) = 0;
```

Declaring the completion in your `.iig`:

```cpp
virtual void ControlComplete(OSAction * action, IOReturn status,
                             uint32_t bytesTransferred) TYPE(IOUSBHostDevice::CompleteAsyncDeviceRequest);
```

Compiled uses:

```cpp
// DTR, synchronous: SET_CONTROL_LINE_STATE
ret = ivars->interface->DeviceRequest(0x21, 0x22, 1, 4, 0, nullptr, &done, 1000);
// GET_ENCAPSULATED_RESPONSE, asynchronous, after the interrupt fires
ret = ivars->interface->AsyncDeviceRequest(0xa1, 0x01, 0, 4, 4096, ivars->ctrlBuf, ivars->ctrlAction, 5000);
// SEND_ENCAPSULATED_COMMAND
ret = ivars->interface->AsyncDeviceRequest(0x21, 0x00, 0, 4, len, outBuf, outAction, 5000);

void NetSpike::ControlComplete_Impl(OSAction*, IOReturn status, uint32_t bytes) {
  if (status != kIOReturnSuccess || bytes == 0) return;   // STALL = nothing waiting
  ivars->core->session.on_qmi(ivars->ctrlAddr, bytes, NowMs());
}
```

The real driver must send QMI with `AsyncDeviceRequest` from a small ring of OUT buffers. The spike's synchronous `SendQmi` blocks the Default queue for up to the timeout. `Session::stop()` sends several releases back to back, so one buffer is not enough.

### 2.4 Bulk and interrupt transfers

Header: `$FW/USBDriverKit.framework/Headers/IOUSBHostPipe.iig`

```
virtual kern_return_t AsyncIO (IOMemoryDescriptor *dataBuffer, uint32_t dataBufferLength,
        OSAction *completion TYPE(CompleteAsyncIO), uint32_t completionTimeoutMs);
virtual void CompleteAsyncIO (OSAction *action TARGET, IOReturn status,
        uint32_t actualByteCount, uint64_t completionTimestamp ) = 0;
virtual kern_return_t IO (IOMemoryDescriptor *dataBuffer, uint32_t dataBufferLength,
        uint32_t *bytesTransferred, uint32_t completionTimeoutMs);
```

"completionTimeoutMs Must be 0 for interrupt endpoints."

**Several reads posted at once.** Give each slot its own buffer and its own `OSAction`, and put the slot index in the action's reference area:

```cpp
// .iig
virtual void BulkInComplete(OSAction * action, IOReturn status, uint32_t actualByteCount,
                            uint64_t completionTimestamp) TYPE(IOUSBHostPipe::CompleteAsyncIO);
// Start
for (uint32_t i = 0; i < kReads; i++) {
  MakeBuffer(ivars->interface, kIOMemoryDirectionIn, 32768, &ivars->inBuf[i], &ivars->inAddr[i]);
  CreateActionBulkInComplete(sizeof(uint32_t), &ivars->inAction[i]);
  *static_cast<uint32_t*>(ivars->inAction[i]->GetReference()) = i;
}
for (uint32_t i = 0; i < kReads; i++) ivars->bulkIn->AsyncIO(ivars->inBuf[i], 32768, ivars->inAction[i], 0);
// completion
void NetSpike::BulkInComplete_Impl(OSAction* action, IOReturn status, uint32_t actual, uint64_t) {
  uint32_t i = *static_cast<uint32_t*>(action->GetReference());
  if (ivars->stopping || status == kIOReturnAborted) return;
  if (status == kUSBHostReturnPipeStalled) { ivars->bulkIn->ClearStall(true); /* re-post all */ return; }
  rmnet::Span buf{ivars->inAddr[i], actual};
  size_t off = 0; rmnet::QmapFrame f;
  while (rmnet::qmap_next(buf, &off, &f) == rmnet::QmapStatus::Ok) { /* wrap_rx -> DeliverRx */ }
  PostBulkIn(i);
}
// interrupt: same TYPE, completionTimeoutMs 0
ivars->intrIn->AsyncIO(ivars->intrBuf, 64, ivars->intrAction, 0);
```

**Bundled transfers**, which are what AppleUserECM uses for its data pipes. They put up to 16 transfers in one call from a ring of descriptors. This compiled:

```
virtual kern_return_t CreateMemoryDescriptorRing(uint32_t size);
virtual kern_return_t SetMemoryDescriptor( IOMemoryDescriptor *memoryDescriptor, uint32_t index );
virtual kern_return_t AsyncIOBundled ( uint32_t ioTransferIndex, uint32_t ioTransferCount,
        uint32_t *ioTransferAcceptedCount, const uint32_t dataBufferLengthArray[kIOUSBHostPipeBundlingMax],
        int dataBufferLengthArrayCount, OSAction *completion TYPE(CompleteAsyncIOBundled),
        uint32_t completionTimeoutMs);
virtual void CompleteAsyncIOBundled (OSAction *action TARGET, uint32_t ioCompletionIndex,
        uint32_t ioCompletionCount, const uint32_t actualByteCountArray[kIOUSBHostPipeBundlingMax],
        int actualByteCountArrayCount, const kern_return_t statusArray[kIOUSBHostPipeBundlingMax],
        int statusArrayCount) = 0;
enum{ kIOUSBHostPipeBundlingMax = 16 };
```

"The ring must only be created once, and will be freed by the kernel driver when the pipe is destroyed." "This method should only be used with bulk pipes." The modem sends one packet per transfer, followed by a 4-byte zero transfer. That means many small completions, so the bundled path is the main lever for downlink throughput. Start with `AsyncIO` slots (simpler) and switch if the gate fails.

**Clearing a stall:**

```
virtual kern_return_t ClearStall (bool withRequest);
```

The header says: "All pending IO on the endpoint will be aborted, and the data toggle for the endpoint will also be reset ... it is recommended that the withRequest parameter is always set to true". After `ClearStall(true)`, every read on that pipe has to be posted again.

**Aborting at stop:**

```
virtual kern_return_t Abort (IOOptionBits options, kern_return_t withError, IOService *forClient);
// USBDriverKitDefs.h: kIOUSBAbortAsynchronous = 0x0, kIOUSBAbortSynchronous = 0x1
```

Pending transfers complete with `kIOReturnAborted` (the documented default `withError`). The spike uses `kIOUSBAbortAsynchronous` and then `Close`. **[runtime]** `kIOUSBAbortSynchronous` blocks until the aborted I/O has completed. Those completions are dispatched to the Default queue, and `Stop` is itself running on the Default queue, so a synchronous abort there may deadlock. AppleUserECM does not import `Abort` at all; it relies on `Close`.

**Zero-length packets.** Nothing in USBDriverKit mentions them: there is no option, flag or comment, and the DriverKit headers say "See IOUSBHostIOSource::io for documentation" without including it. **[runtime]** Assume no ZLP is sent. Core's `QmapAggregator::finish()` never produces an exact multiple of the packet size, so it does not matter. Keep it that way.

---

## 3. DriverKit basics

### 3.1 `.iig` rules learned by compiling

- The `.iig` is processed by `iig` into `DerivedSources/<bundle id>/<Name>.h` and `<Name>.iig.cpp`. Include `"<Name>.h"` from the `.cpp`. Only class declarations, `#include`s of other `.iig` files, and plain types belong in it.
- Every method must be `virtual`, `static` or `LOCALONLY`. Otherwise: `error: method NetSpike::SendQmi not virtual, static, or localonly`.
- A `virtual` method without `LOCALONLY` is an **RPC method**. You implement `Name_Impl(...)`, and callers call `Name(args)`. A plain `NetSpike::SendQmi(...)` definition then fails with `out-of-line definition of 'SendQmi' does not match any declaration`. Mark plain C++ helpers `LOCALONLY` (as the spike does), or keep them out of the class.
- Overriding a framework method: write the signature with **the same spelled types** as the base. `SelectMediaType(uint32_t)` fails `iig` with `NetSpike::SelectMediaType does not override`, even though `IOUserNetworkMediaType` is a typedef of `uint32_t`. Wrap deprecated types in `#pragma clang diagnostic ignored "-Wdeprecated-declarations"`.
- `TYPE(Class::Method)` declares a method as the target of an `OSAction`. `iig` then generates `CreateAction<Method>(size_t referenceSize, OSAction ** action)`. Compiled: `TYPE(IOUSBHostPipe::CompleteAsyncIO)`, `TYPE(IOUSBHostPipe::CompleteAsyncIOBundled)`, `TYPE(IOUSBHostDevice::CompleteAsyncDeviceRequest)`, `TYPE(IOTimerDispatchSource::TimerOccurred)` and `TYPE(IODataQueueDispatchSource::DataAvailable)`.
- `QUEUENAME(Name)` routes that method to a named queue. It compiles; see 1.9.
- `LOCALONLY` methods are ordinary C++ and are called directly; the `override LOCALONLY` form works too.
- `IMPL(Class, Method)` still compiles (the signing stub used it), but `OSObject.h` says: "Use of the IMPL macro is discouraged and should be replaced by a normal c++ method implementation (with the all method arguments) and the name of the method given a suffix '_Impl'". Write `kern_return_t NetSpike::Start_Impl(IOService* provider)`.
- **ivars**: `iig` adds `struct <Name>_IVars; <Name>_IVars * ivars;` to the class. Define the struct in the `.cpp` and allocate it in `init()`:

```cpp
struct NetSpike_IVars { IOUSBHostInterface* interface; /* ... */ CoreState* core; bool stopping; };
bool NetSpike::init() { if (!super::init()) return false; ivars = IONewZero(NetSpike_IVars, 1); return ivars != nullptr; }
void NetSpike::free() { if (ivars) delete ivars->core; IOSafeDeleteNULL(ivars, NetSpike_IVars, 1); super::free(); }
```

`IONewZero` only zero-fills, so it runs no constructors. Objects with constructors (Core's `Session`, `EthernetEmulator`, `QmapAggregator`) go in a separate object made with `new`:

```cpp
struct CoreState {
  CoreState(NetSpike* owner, uint8_t* uplink, size_t cap)
      : bridge(owner), session(rmnet::SessionConfig{}, bridge),
        eth(rmnet::derive_macs("spike-serial")), agg(uplink, cap, 32, 1024) {}
  SessionBridge bridge; rmnet::Session session; rmnet::EthernetEmulator eth; rmnet::QmapAggregator agg;
  uint8_t frame[2048];
};
ivars->core = new CoreState(this, ivars->outAddr, kBulkOutSize);
```

- Calling the superclass: `Start(provider, SUPERDISPATCH)`, `Stop(provider, SUPERDISPATCH)`, `SetPowerState(powerFlags, SUPERDISPATCH)`. Ordinary virtuals use `super::init()`.

### 3.2 OSAction

Header: `$FW/DriverKit.framework/Headers/OSAction.iig`

```
void * GetReference() LOCALONLY;
kern_return_t Cancel(OSActionCancelHandler handler) LOCALONLY;
```

Create actions with the generated `CreateAction<Method>(referenceSize, &action)`. `referenceSize` bytes of per-action storage are returned by `GetReference()`. Release actions with `OSSafeReleaseNULL` once no transfer can still complete on them.

### 3.3 Dispatch queues

Header: `IODispatchQueue.iig` and `IOService.iig`

```
static kern_return_t Create(const IODispatchQueueName name, uint64_t options, uint64_t priority, IODispatchQueue ** queue) LOCAL;
void DispatchAsync(IODispatchBlock block) LOCALONLY;
void DispatchSync(IODispatchBlock block) LOCALONLY;
bool OnQueue() LOCALONLY;
// IOService
virtual kern_return_t CopyDispatchQueue(const IODispatchQueueName name, IODispatchQueue ** queue) override;
virtual kern_return_t SetDispatchQueue(const IODispatchQueueName name, IODispatchQueue * queue) override LOCAL;
```

The spike uses `CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue)`. Blocks (`^{ }`) are supported: `Cancel(^{})` compiled.

### 3.4 Repeating timer for `Session::tick`

Header: `$FW/DriverKit.framework/Headers/IOTimerDispatchSource.iig`

```
static kern_return_t Create(IODispatchQueue * queue, IOTimerDispatchSource ** source);
virtual kern_return_t SetHandler(OSAction * action TYPE(TimerOccurred));
virtual kern_return_t WakeAtTime(uint64_t options, uint64_t deadline, uint64_t leeway);
virtual kern_return_t Cancel(IODispatchSourceCancelHandler handler) override;
virtual void TimerOccurred(OSAction * action TARGET, uint64_t time) REPLY LOCAL;
// options: kIOTimerClockUptimeRaw (clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ns), kIOTimerClockMonotonicRaw, ...
```

The timer is one-shot: re-arm it in the handler.

```cpp
ret = IOTimerDispatchSource::Create(ivars->queue, &ivars->timer);
ret = CreateActionTimerFired(0, &ivars->timerAction);
ret = ivars->timer->SetHandler(ivars->timerAction);
ret = ivars->timer->WakeAtTime(kIOTimerClockUptimeRaw, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 100 * 1000000ull, 10 * 1000000ull);

void NetSpike::TimerFired_Impl(OSAction*, uint64_t) {
  if (ivars->stopping) return;
  ivars->core->session.tick(NowMs());       // NowMs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000
  ivars->timer->WakeAtTime(kIOTimerClockUptimeRaw, clock_gettime_nsec_np(CLOCK_UPTIME_RAW) + 100 * 1000000ull, 10 * 1000000ull);
}
```

`CLOCK_UPTIME_RAW` stops during sleep. That suits Core's timeouts, because the driver restarts the session on wake anyway. The same timer can drive the 600-second router advertisement.

### 3.5 Logging

`os_log(OS_LOG_DEFAULT, "NetSpike: ...")` from `<os/log.h>` works. Read it with `log stream --predicate 'sender == "<bundle id>"'`. `IOLog` (`IOLib.h`) also exists. AppleUserECM imports both.

### 3.6 Memory

`IOLib.h`: `IOMalloc`, `IOMallocZero(size_t)`, `IOFree(void*, size_t)` (the size is required), `IONew(type, count)`, `IONewZero`, `IOSafeDeleteNULL(ptr, type, count)`, `OSSafeReleaseNULL(obj)`. C++ `new` and `delete` link from `/System/DriverKit/usr/lib/libc++.dylib`. The spike uses both.

### 3.7 Publishing status for the app

```
// IOService.iig
virtual kern_return_t SetProperties(OSDictionary * properties);
virtual kern_return_t RegisterService();
// OSDictionary.h / OSString.h / OSNumber.h
static OSDictionaryPtr withCapacity(uint32_t capacity);  bool setObject(const char * key, const OSMetaClassBase * anObject);
static OSStringPtr withCString(const char * cString);    static OSNumberPtr withNumber(uint64_t value, size_t numberOfBits);
```

```cpp
OSDictionary* props = OSDictionary::withCapacity(2);
OSString* s = OSString::withCString(state);
OSNumber* n = OSNumber::withNumber((uint64_t)ivars->core->session.state(), 32);
props->setObject("RMNetState", s);
props->setObject("RMNetSessionState", n);
SetProperties(props);
OSSafeReleaseNULL(s); OSSafeReleaseNULL(n); OSSafeReleaseNULL(props);
```

**[runtime]** Whether `SetProperties` on this kernel class actually lands in the I/O registry. Kernel `IOService::setProperties` refuses by default for many classes. Check with `ioreg -l -c IOUserNetworkEthernet` on first load. Fallback 1: put static values in the personality, which is copied into the registry at match time. Fallback 2: an `IOUserClient`. The profile number can live in the personality (`RMNetProfile` in the spike plist). Read it with `CopyProperties` **[not compiled]**.

### 3.8 Power

```
// IOService.iig
virtual kern_return_t SetPowerState(uint32_t powerFlags) LOCAL;
// kIOServicePowerCapabilityOff = 0 (system sleeping), kIOServicePowerCapabilityOn = 2, kIOServicePowerCapabilityLow = 0x10000
// IOUserNetworkEthernet.iig also has: virtual IOReturn setPowerState(unsigned long powerState, IOService *whatDevice) LOCALONLY NDK_21;
```

```cpp
kern_return_t NetSpike::SetPowerState_Impl(uint32_t powerFlags) {
  if (powerFlags == kIOServicePowerCapabilityOff) { /* stop session, link down, abort I/O */ }
  else if (powerFlags & kIOServicePowerCapabilityOn) { /* re-post reads, restart session from Sync */ }
  return SetPowerState(powerFlags, SUPERDISPATCH);   // must reach the superclass to acknowledge
}
```

`IOUserNetworkEthernet` exports its own `SetPowerState_Impl`, so `SUPERDISPATCH` reaches it. AppleEthernetIXL overrides `SetPowerState`; AppleUserECM does not. **[runtime]** What the USB interface looks like after wake. The design already says to treat wake as a full restart.

### 3.9 Order of work

`Start_Impl` (spike order):

1. `Start(provider, SUPERDISPATCH)`.
2. `CopyDispatchQueue(Default)`.
3. Cast the provider to `IOUSBHostInterface`, check its class, subclass, protocol and endpoint count, then `Open`.
4. `CopyPipe` ×3; create buffers and actions.
5. Create Core (`new CoreState`).
6. Pool, then the four queues, then the data-available handlers.
7. `RegisterEthernetInterface`, then `setMaxTransferUnit`, then `reportLinkStatus(Inactive)`.
8. Timer.
9. DTR (`SET_CONTROL_LINE_STATE`), then post the interrupt read and the bulk reads.
10. `session.start(now)`; publish status.
11. `RegisterService()`.

On any failure: `Stop(provider, SUPERDISPATCH)` and return the error. **[runtime]** Whether `RegisterService` must come before or after `RegisterEthernetInterface`. AppleUserECM calls both.

`Stop_Impl`:

1. Set `stopping`, so completions ignore what follows.
2. `session.stop()`, while USB is still open, because it sends releases.
3. Cancel the timer.
4. `reportLinkStatus(Inactive)`.
5. Disable the queues.
6. Abort the pipes asynchronously and call `AbortDeviceRequests`.
7. `interface->Close(this, 0)`.
8. Release objects.
9. `Stop(provider, SUPERDISPATCH)`.

**[runtime]** Completions arriving after step 8 would touch released actions and buffers. The safer pattern is to release USB objects in `free()`, or after the last aborted completion has been counted.

**As built (Task 5, fix round 1): `Stop` is asynchronous.** `IOService.iig` says "Stop should quiesce all activity and when complete, pass the call to super. After calling super ... this object will likely be freed." So `Stop_Impl` starts the sequence and returns without calling the superclass; `Stop(provider, SUPERDISPATCH)` is called later, on the Default queue, with the provider retained until then. A failed `Start` uses the same path.
1. `stopping`; `session.stop()` queues its releases; report inactive; disable the queues. Core is not called again; reads are no longer re-posted or delivered.
2. Drain: the control ring keeps sending, one request at a time, until it is empty, a request fails (the device is gone), or **1 s after `Stop` began**.
3. Abort the three pipes and the control requests (`kIOUSBAbortAsynchronous`); wait until no request is outstanding, **at most 1 s**.
4. `Close`, release the USB objects and actions, cancel the timer, then `Stop(provider, SUPERDISPATCH)`. If requests are still outstanding after the second second, the driver logs the count, closes the interface, and passes `Stop` on anyway (the objects are then released in `free()`): a termination that never completes is worse.
Both deadlines are timed by the driver's 100 ms timer, which keeps running until step 4; each USB completion also advances the sequence at once.

---

## 4. Packaging

### 4.1 Dext `Info.plist` personality

Apple's documentation for `IOUserNetworkEthernet` says to always include `IOClass` = `IOUserNetworkEthernet`, `IOProviderClass` = `IOUSBHostInterface` (for USB), `IOUserClass` = your subclass, `CFBundleIdentifier`, and `CFBundleIdentifierKernel` = `com.apple.iokit.IOSkywalkFamily`. AppleUserECM also has `IOUserServerName` and a top-level `OSBundleLibraries` = { `com.apple.iokit.IOSkywalkFamily` = `1.0` }. The spike plist, which builds:

```xml
<key>OSBundleLibraries</key>
<dict><key>com.apple.iokit.IOSkywalkFamily</key><string>1.0</string></dict>
<key>IOKitPersonalities</key>
<dict>
  <key>NetSpike</key>
  <dict>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleIdentifierKernel</key><string>com.apple.iokit.IOSkywalkFamily</string>
    <key>IOClass</key><string>IOUserNetworkEthernet</string>
    <key>IOProviderClass</key><string>IOUSBHostInterface</string>
    <key>IOUserClass</key><string>NetSpike</string>
    <key>IOUserServerName</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>idVendor</key><integer>11388</integer>        <!-- 0x2C7C -->
    <key>idProduct</key><integer>2049</integer>        <!-- 0x0801 -->
    <key>bConfigurationValue</key><integer>1</integer>
    <key>bInterfaceNumber</key><integer>4</integer>
    <key>RMNetProfile</key><integer>1</integer>
  </dict>
</dict>
```

Matching keys:
- The registry on this Mac (read with `ioreg`, with the modem in QMI mode) shows `RmNet@4` carrying `idVendor` 11388, `idProduct` 2049, `bConfigurationValue` 1, `bInterfaceNumber` 4, and class, subclass and protocol 255. Nothing is attached to it.
- The signing stub matched interface 3 with exactly `idVendor` + `idProduct` + `bConfigurationValue` + `bInterfaceNumber`, so that combination is proven on this system.
- Adding `bInterfaceClass`, `bInterfaceSubClass` and `bInterfaceProtocol` = 255 may also be accepted, but that is **[runtime]**: the USB family accepts only certain key combinations. The spike leaves them out of the plist and checks class, subclass and protocol in `Start` instead.

### 4.2 Entitlements

Dext (`Driver/Driver.entitlements`, the same as the signing stub):

```xml
<key>com.apple.developer.driverkit</key><true/>
<key>com.apple.developer.driverkit.transport.usb</key>
<array><dict><key>idVendor</key><string>*</string></dict></array>
<key>com.apple.developer.driverkit.family.networking</key><true/>
<key>com.apple.security.app-sandbox</key><true/>
```

AppleUserECM has `driverkit`, `family.networking` and `transport.usb` (by interface class). It also has `com.apple.private.driverkit.use-system-thread-group`, which is private: do not copy it. The `transport.usb` value may be narrowed to `idVendor` 11388 (integer). **[runtime]** Whether the wildcard profile accepts a narrowed value.

Host app (`Host/Host.entitlements`): `com.apple.developer.system-extension.install` = true. The host is a normal macOS app, with Hardened Runtime on and `GENERATE_INFOPLIST_FILE`. It embeds the dext through a Copy Files phase with `dstSubfolderSpec` 16 and `dstPath` `$(SYSTEM_EXTENSIONS_FOLDER_PATH)`. The unsigned build places it at `NetSpike.app/Contents/Library/SystemExtensions/io.rmnetspike.netspike.host.driver.dext`. It activates with `OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)` (`spike-dext/Host/main.swift`).

### 4.3 Identifiers and naming

- The dext's bundle identifier must begin with the host app's (design document; the stub was `io.rmnetspike.x7k2.host` and `.host.driver`).
- `PRODUCT_NAME = $(PRODUCT_BUNDLE_IDENTIFIER)` makes the bundle `<id>.dext` and the executable `<id>`, as Apple's own dexts are named.
- `IOUserServerName` = the bundle id. `IOUserClass` = the `.iig` class name, exactly.
- The host app must be in `/Applications` to activate (proven by the stub).
- The current stub (`io.rmnetspike.x7k2.host.driver`) is attached to interface 3 right now. Remove it before installing the real driver, as the design says.

---

## 5. Linking Core

Result: **all nine `core/src/*.cpp` files compile and link into the dext unchanged.** The binary has 146 `rmnet::` symbols, including `Session::Session`, `Session::tick` and `EthernetEmulator::EthernetEmulator`, and Core produced no warnings under Xcode's default warning set, which includes `-Wshorten-64-to-32`.

| Question | Finding |
|---|---|
| Pure virtuals (`SessionDelegate`) | Link. `___cxa_pure_virtual` resolves from `/System/DriverKit/usr/lib/libc++.dylib`, which is linked automatically (`-stdlib=libc++`). |
| `memcpy`, `memset`, `memcmp`, `bzero` | Link from DriverKit's libSystem (imported `_memcpy`, `_memset`, `_memcmp`, `_bzero`). |
| Static initialisation | Core has none that runs code: the binary has no `__mod_init_func` section. The only static is `static const uint8_t kZeroIp[4]` (constant data). `__cxa_atexit` and `__cxa_guard_*` exist in libc++ if ever needed. |
| `new` / `delete` | Available: `operator new(unsigned long)` and `operator delete(void*)` imported from libc++. Core does not use them; the driver does (`new CoreState`). |
| Exceptions and RTTI | Xcode passes `-fno-exceptions -fno-rtti` for DriverKit. The spike also sets `GCC_ENABLE_CPP_EXCEPTIONS=NO` and `GCC_ENABLE_CPP_RTTI=NO` explicitly. |
| C++ standard | `CLANG_CXX_LANGUAGE_STANDARD = c++17` → `-std=c++17`, the same as the Makefile. (The signing stub used `gnu++20`; either works for the driver's own code.) |
| Target | `-target arm64-apple-driverkit27.0`. `ARCHS = arm64` for both Debug and Release. Apple's dexts are arm64e, but third-party ones are arm64, and the signing stub loaded. |

Target settings needed beyond the stub's (from `gen.rb`):

```ruby
'SDKROOT' => 'driverkit', 'DRIVERKIT_DEPLOYMENT_TARGET' => '27.0',
'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
'GCC_ENABLE_CPP_EXCEPTIONS' => 'NO', 'GCC_ENABLE_CPP_RTTI' => 'NO',
'HEADER_SEARCH_PATHS' => ['$(SRCROOT)/core/include'],      # spike used an absolute path
'OTHER_LDFLAGS' => '-framework DriverKit -framework USBDriverKit -framework NetworkingDriverKit',
```

Then add every `core/src/*.cpp` to the dext's Sources phase. `core/src/ethernet_internal.h` is found relative to its source file. The design's "no heap" rule for Core is unaffected: only the driver allocates.

---

## Build record

Spike settings: those of `spike-dext/gen.rb`, plus the Core settings above. There is no `DEVELOPMENT_TEAM` or `CODE_SIGN_STYLE`; signing is turned off on the command line.

```
cd .../scratchpad/dext-spike
/usr/bin/ruby gen.rb ~/personal/RM520N-GL/rmnet-driver
xcodebuild -project NetSpike.xcodeproj -target NetSpikeDriver -configuration Debug \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
```

Final build, from a clean `build/`: `** BUILD SUCCEEDED **`. The only warning left comes from `IOUserNetworkMediaType` in the generated header. Release and the host app (`-target NetSpike`, which embeds the dext) also print `** BUILD SUCCEEDED **`. Product: `build/Debug-driverkit/io.rmnetspike.netspike.host.driver.dext`.

Every `xcodebuild` run prints `DVTProvisioningProfileManager: Failed to load profile ".../Provisioning Profiles/untitled folder"`. That is harmless noise from a stray folder in `~/Library/MobileDevice/Provisioning Profiles`.

### Build errors and what they taught

1. `error: use of undeclared identifier 'IOUSBHostFreeDescriptor'` and `... 'kIOUSBAbortSynchronous'`. Cause: `IOUSBHostInterface.h` and `IOUSBHostPipe.h` do not include `USBDriverKitDefs.h`. Fix: include the umbrella `<USBDriverKit/USBDriverKit.h>`.
2. `warning: implicit conversion loses integer precision: 'uint64_t' to 'IOOptionBits'` on `CreateIOBuffer`. Its options are 32-bit `IOOptionBits`, while `IOBufferMemoryDescriptor::Create` takes `uint64_t`.
3. `warning: 'IOUserNetworkMediaType' is deprecated` from `ReportAvailableMediaTypes`. Fix: override `getSupportedMediaArray`.
4. `iig: NetSpike::SelectMediaType does not override` after the deprecated `IOUserNetworkMediaType` was spelled as `uint32_t`. `iig` compares spelled types, not resolved ones. Fix: keep the header's spelling and silence the deprecation with a pragma.
5. Experiment: `error: method NetSpike::SendQmi not virtual, static, or localonly`. Every `.iig` method needs one of the three.
6. Experiment: making the helper `virtual` without `LOCALONLY` gave `out-of-line definition of 'SendQmi' does not match any declaration`. It had become an RPC method whose body must be `SendQmi_Impl`.
7. Experiment, not an error: removing the `= 0` overrides (`SetInterfaceEnable`, `SelectMediaType` and the rest) still built. The SDK does not force you to implement them, so the absence of an error proves nothing about runtime.

Also compiled without complaint on the first try:
- `QUEUENAME(...)`
- `AsyncIOBundled` with `TYPE(IOUSBHostPipe::CompleteAsyncIOBundled)`
- the NDK 22 `withPool` queues
- `registerEthernetInterface` with two pools
- `TYPE(IOUSBHostDevice::CompleteAsyncDeviceRequest)` for the interface's `AsyncDeviceRequest`, whose own header leaves the `TYPE` commented out

---

## Open risks, most serious first

1. **Downlink throughput through NetworkingDriverKit.** macOS's ECM dext uses the same framework and the same queue model, and measured 38 to 62 Mbit/s here. The modem delivers one IP packet per USB transfer plus a 4-byte zero transfer, which means many completions, each an IPC round trip, plus a copy into a packet. *Settles it:* the design's throughput gate, run as soon as RX works. Levers, in order: 32 or more posted reads; batching `EnqueuePackets` per completion; `AsyncIOBundled`; a separate RX queue via `QUEUENAME`; asking the modem for larger downlink aggregation.
2. **Which callbacks the framework actually invokes**: `SetInterfaceEnable` or `setInterfaceEnable`, the data-available handlers on the default queue, `SetPowerState` or `setPowerState`, and the MTU calls. All compile either way, and `= 0` is not enforced. The spike copies AppleUserECM's shipping pattern, which lowers but does not remove this risk. *Settles it:* the first load, with an `os_log` line in every override and handler.
3. **Teardown races on unplug and stop**: completions after `Stop`, synchronous `Abort` from the Default queue, and releasing actions and buffers while transfers are still in flight. *Settles it:* unplug and replug in a loop, and deactivate while traffic flows, watching for crashes in `log stream` and crash reports.
4. **Personality matching on interface 4.** The 4-key form is proven on interface 3. Adding class keys is unproven. *Settles it:* the first install; `ioreg -r -n RmNet@4` shows the driver attached.
5. **RX and TX packet semantics**: the meaning of the data address and offset, whether `PoolFlagMapToDext` is needed, whether the RX submission queue is stocked before enable, and pool sizing at 32 posted reads. *Settles it:* the first ping, both directions, and `netstat -I` counters.
6. **Status publishing.** `SetProperties` may be refused for this kernel class. *Settles it:* `ioreg -l` on first load. Fallback: personality values or a user client.
7. **QMI over asynchronous control requests.** `Session::stop()` emits several frames back to back, so the driver needs a small ring of OUT buffers and in-order submission. There is also the interaction between the interrupt read and the STALL that answers an empty response. *Settles it:* bring-up on hardware, plus a forced `stop()` while connecting.
8. **Sleep and wake.** Whether `SetPowerState` arrives at all for a USB network dext, and in what state the pipes are on wake. *Settles it:* the sleep/wake test from the design's "Done means".
9. **Signing a networking-family dext.** The stub that was signed and loaded was an `IOUserService`, not an `IOUserNetworkEthernet`, though its profile already carries `family.networking`. *Settles it:* the first signed build and install.
10. **Zero-length packets.** These cannot be checked from the headers. Core's padding avoids the case, and the follow-ups list already asks whether the modem accepts the extra padding.

---

## Runtime findings (first load, 2026-11-13)

From installing the skeleton (`scripts/install-driver.sh`) several times and re-enumerating the modem, with the modem attached in QMI mode.

**Reading the driver's log**
- A dext's `os_log` lines are kernel messages: process `kernel`, pid 0, `senderImagePath` the dext's executable (`.../io.rmnetdriver.RMNet.driver.dext/io.rmnetdriver.RMNet.driver`), type Default, no subsystem.
- `log show` cannot return them afterwards. On this Mac, `log show` (as the user) returns no kernel lines older than a few seconds, at any level. The only record is a live `log stream`, so `scripts/driver-log.sh` streams and also saves to `build/logs/driver-<time>.log`. Start it before the load.
- Stream at the **default level**, with a narrow predicate (`senderImagePath ENDSWITH "/io.rmnetdriver.RMNet.driver" OR eventMessage BEGINSWITH "RMNet:"`). Streams with `--level info` or `--level debug` lost lines around a load: `init`, `Start`, `Stop` and `free` were missing, even though `started` (logged by `Start` a millisecond later) arrived. The default-level stream showed every line of a full reload (`Stop`, `free`, `init`, `Start`, ...) on each re-enumeration it was used for.

**Packaging and signing**
- `CFBundleVersion` must be a valid kext version (major up to 4 digits, minor and revision up to 2). With a ten-digit timestamp, the app printed `activate failed: extension category returned error (code 9)` and `kernelmanagerd` logged, in category `DextValidation`, `Extension io.rmnetdriver.RMNet.driver is not valid, error: ... invalid properties: ["Property 'CFBundleVersion' must be a valid kext version"]` (from the controller's reading of the log). The install script now uses `<days since 2026-01-01>.<hour>.<minute>` in UTC.
- The networking-family dext, signed with team `ABCDE12345` and automatic signing, validated and loaded (risk 9 closed). `sysextd` logs "Error checking with notarization daemon: 3" and `kernelmanagerd` "openat_authenticated_np() failed ... (errno 80)"; both are harmless.
- Matching needed no change: the 4-key personality (`idVendor`, `idProduct`, `bConfigurationValue`, `bInterfaceNumber`) attached `RMNetDriver` to `RmNet@4` (`IOProbeScore` 90000), and the class check in `Start` passed. Interfaces 0 to 3 are untouched.
- The interface was `en33` on each load, MAC `02:c7:bd:1f:39:58` (configd logged "Assigned unit 33 (from database)" on the load at 23:59). configd creates a network service named `RM520N-GL`. It is not listed in `scutil --nwi`.

**Calls and their order** (first call of each, from the first load; the log shows only the first call of each, because every handler logs through `LOG_FIRST`):
`init`, `Start`, (`setMaxTransferUnit` fails with `kIOReturnUnsupported`), `started`, `SetPowerState 0x2` then `setPowerState 2`, `getMaxTransferUnit`, `setInterfaceEnable 1` then `SetInterfaceEnable 1`, `RxPacketsAvailable`, `setAllMulticastModeEnable 0` then `SetAllMulticastModeEnable 0`, `TxPacketsAvailable`, `setMulticastAddresses 3`, `getSupportedMediaArray array 1 count 0`. On re-enumeration: `Stop`, then `free`, and the new instance starts about 10 s later.
- The order is not fixed, and neither is the multicast count: the first load logged `TxPacketsAvailable` then `setMulticastAddresses 3`, while the load at 00:15 logged `setMulticastAddresses 5` then `TxPacketsAvailable`.
- The stack calls the **lowercase** `setInterfaceEnable` and `setAllMulticastModeEnable`; their base implementations call the deprecated uppercase ones within the same millisecond. Power is the other way round: the kernel calls uppercase `SetPowerState`, and the superclass then calls lowercase `setPowerState`. Implementing either form works; keep the superclass call in each lowercase override.
- Never called on this load: `SetPromiscuousModeEnable`/`setPromiscuousModeEnable`, `SelectMediaType`, `handleChosenMedia`.
- On the first load, `init` and `Start` logged from one thread ID and every later callback, both data-available handlers included, from a different one. On the loads at 00:13 and 00:15, every line came from a single thread ID. Which dispatch queue each callback ran on was not checked.
- Each data-available handler fired at least once, the first time right after the interface was enabled. Whether it fired again is not visible: only the first call is logged.
- `RegisterService` after `RegisterEthernetInterface` works.
- `setMaxTransferUnit(1500)` in `Start` returns `kIOReturnUnsupported`; the MTU is 1500 anyway. The driver now returns its MTU from `getMaxTransferUnit`.

**Link status and media**
- `reportLinkStatus(Inactive)` called in `Start` did not take effect: configd started DHCP on `en33` and gave it a 169.254 address. Reporting it again when the stack enables the interface (`SetInterfaceEnable(true)`) fixed that: configd logs "Process interface link status inactive: en33", and `en33` gets no address.
- `getSupportedMediaArray` is first called with a non-null array and `*mediaCount == 0`: a query for the count. The first skeleton answered that with `kIOReturnBadArgument`, so the port had no media list: `ifconfig` failed with `SIOCGIFXMEDIA: Input/output error` and showed no `status:` line. Answering with `*mediaCount = 1` and success fixed it: `ifconfig en33` shows `media: autoselect` and `status: inactive`, and `IOSkywalkLegacyEthernet` has `IOLinkStatus = 1`. (AppleUserECM does not override `getSupportedMediaArray`; it calls the deprecated `ReportAvailableMediaTypes`.)

**Status publishing**: `SetProperties` works. `RMNetState = "skeleton"` appears on the `RMNetDriver` entry in `ioreg` and in `RMNet status`, next to `RMNetProfile = 1` from the personality. No fallback is needed.

**Lifetime and reloads**
- `free` runs: after the modem re-enumerated (`AT+CFUN=1,1`), the log showed `Stop` then `free` and the process exited 0. The `OSAction`s held in the ivars do not keep the driver alive.
- **A running RMNetDriver is not stopped when the extension is disabled or replaced.** `kernelmanagerd`: "services failed to terminate - 0xe00002c7", and the extension stays "terminating for disable but still running". A replacement build is staged and enabled, but the old process keeps the interface until the modem re-enumerates (unplug, or `AT+CFUN=1,1`); then the new build matches. `scripts/install-driver.sh` now compares the running driver's `IOUserServerCDHash` with the installed one and says so.
- A replacement build needs no new approval: sysextd logs "replacing extension ... with inherited user approval". (Here the old build had been switched off in System Settings, so the replacement waited in `activated_waiting_to_upgrade` until the owner switched it on.)
- `rm -rf /Applications/RMNet.app` followed by `ditto` and `activate`, with the extension active, made sysextd do nothing (no uninstall, no state change). The script still removes the old app only after checking the new build.
- An entry left `activated disabled` (the old build, switched off while it could not stop) blocks every later activation: sysextd faults with "activateDecision found two entries ... activated_disabled ... activated_enabled" and `activate` fails with `OSSystemExtensionErrorDomain` error 4. This came from the driver being switched off in System Settings right after it was approved. The app in the next plan must guard against it (refuse to activate while such an entry exists, and say what to do), and tell the owner not to switch the driver off while the modem is attached.
- **Deactivation is matched against the exact driver version embedded in the app that asks.** With `/Applications/RMNet.app` carrying 316.16.1 and entries 316.15.49 and 316.15.56 installed, `RMNet deactivate` failed with `OSSystemExtensionErrorDomain` error 4 (sysextd: "deactivation request could not find extension ... buildNumber: 316.16.1"). Rebuilding the app with `CURRENT_PROJECT_VERSION` set to an installed entry's version, and deactivating from that app, worked: once per entry, each time with the owner's password. So an installed driver can be removed only by an app with the same driver version. `scripts/install-driver.sh` keeps that app in `build/installed/RMNet-<version>.app` before replacing `/Applications/RMNet.app` (README, "Removing the driver").

## Runtime findings (QMI session, Task 5, 2026-11-14)

From installing 316.16.36, 316.16.40 and 316.16.41 and rebooting the modem with `AT+CFUN=1,1`. Logs: `build/logs/driver-20261114-003624.log` (the crash), `driver-20261114-004041.log` (first link up), `driver-20261114-004151.log` (modem reboot).

**Buffers**
- `kIOMemoryDirectionOut` means the memory is *readable* (by the device), and the dext's own mapping of such a buffer is read-only. 316.16.36 wrote a QMI message into an `CreateIOBuffer(kIOMemoryDirectionOut, ...)` buffer and crashed in `Start` with `EXC_BAD_ACCESS (SIGBUS) KERN_PROTECTION_FAILURE` in `memmove` (`/Library/Logs/DiagnosticReports/io.rmnetdriver.RMNet.driver-2026-11-14-003648.ips`). The header says it: "kIOMemoryDirectionIn memory described will be writable, kIOMemoryDirectionOut memory described will be readable". Every control buffer is now `kIOMemoryDirectionInOut`. Use `InOut` (or at least `In`) for any buffer the dext fills, including bulk OUT buffers.
- None of that instance's `os_log` lines reached the stream (not even `init` or `Start`), although it ran for about 2 s before crashing: a crashing dext's last lines can be lost.

**Control channel** (all asynchronous, on the Default queue)
- `AsyncDeviceRequest` works for SET_CONTROL_LINE_STATE (no data buffer, `wLength` 0), SEND_ENCAPSULATED_COMMAND and GET_ENCAPSULATED_RESPONSE. `IOBufferMemoryDescriptor::SetLength` is called before each send; whether it is needed was not tested.
- The interrupt endpoint's notification is 8 bytes (`InterruptComplete 0x0, 8 bytes`); its max packet size is read with `GetSpeed` and `IOUSBGetEndpointMaxPacketSize`.
- The first response read after open returned eight stale CTL Sync responses (txid 0) queued by the modem from earlier hosts before the answer to the driver's own sync; Core ignored them. Reading what is waiting at start is worth keeping.
- The modem also sends CTL Sync *indications* (kind 2) when it comes back from a reboot, before it answers a sync request.
- `CopyDevice`, `CopyDeviceDescriptor` and `CopyStringDescriptor(iSerialNumber)` give the serial number (8 characters). The MAC is now `02:68:7a:43:12:f6`.

**Session**
- From a running modem: sync answered on the first try; link up about 0.5 s after the first sync (both calls connect; Start Network for IPv4 takes about 0.45 s). Data format: raw IP, QMAP both ways, 32 datagrams, UL 16384 and DL 31744 bytes.
- After `AT+CFUN=1,1`: the old instance received a WDS Packet Service Status indication (disconnected) at once, went to `backoff` and sent its releases, then 4 s later its interrupt read failed with `0xe00002eb` (`kIOReturnAborted`), re-posting failed with `0xe00002d8` (`kIOReturnNotAttached`), so `usb failed` was reported, and `Stop` came 4 ms later. The new instance started about 11 s later and sent a sync every 2 s for about 18 s (10 in all) until the modem answered, then reached `link up` within 0.5 s.
- `setMaxTransferUnit` still returns `kIOReturnUnsupported` (0xe00002c7) after link up; the carrier MTU was 1500 in every run, so the interface MTU stays 1500 from `getMaxTransferUnit`.

**Stopping**
- `Stop` is asynchronous (section 3.9, "As built"): drain the control ring for up to 1 s, abort, wait up to 1 s for the aborted requests, then release and pass `Stop` to the superclass. The fix-round evidence is in the next bullets and the Task 5 report.
- On a modem reboot `Stop` arrived with no USB request outstanding (the failures had already completed): "usb aborted, 0 requests outstanding", "usb objects released", `free`. No crash report. Releasing after aborted completions that are still in flight has therefore not been seen yet.
- `Start` decisions: a failed `reportLinkStatus` or `SetProperties` is logged and does not fail `Start`. The link status is reported again whenever the stack enables the interface (and a status reported in `Start` is lost anyway); the properties are only for the app. Every other failure in `Start` tears down and fails it.

**macOS and the port**
- With the new MAC, the port kept the name `en33` and the hardware port `RM520N-GL` (`networksetup -listallhardwareports`: `Device: en33`, `Ethernet Address: 02:68:7a:43:12:f6`). No new service or interface appeared.
- Link active: `ifconfig en33` shows `status: active`, only a link-local IPv6 address (DHCP and RAs are unanswered without a data path). `scutil --nwi` lists only `utun5` and `en0`; `en33` is not a primary or listed service. The stack counted 32 frames sent on `en33` (`netstat -I en33 -b`); the driver completed and dropped them.
- Kernel `os_log` lines redact `%s` arguments as `<private>`; use `%{public}s`. Numbers are not redacted.

---

## Recommended source layout for the real driver

- `driver/RMNetDriver.iig` + `.cpp`: the only DriverKit class, an `IOUserNetworkEthernet` subclass. It owns its lifecycle (`Start`, `Stop`, `SetPowerState`), the pool and the four queues, link reporting, the timer, and every `TYPE(...)` completion stub. Each stub is a few lines that forward to the classes below. Everything runs on the Default queue.
- `driver/usb_io.{h,cpp}`: plain C++ held in the ivars. It holds the interface and three pipes, the posted-read slots and their buffers, the ring of QMI OUT buffers, the uplink buffer, stall recovery and abort. It knows nothing about QMI.
- `driver/core_host.{h,cpp}`: plain C++ that implements `rmnet::SessionDelegate` and owns `Session`, `EthernetEmulator` and `QmapAggregator`. It turns USB completions into `on_qmi`, `qmap_next` and `wrap_rx` calls, turns TX packets into `handle_tx` and the aggregator, and calls `tick` and the periodic router advertisement. This is where Core is driven from, always on the Default queue, never re-entered from a delegate callback.
- `driver/Info.plist`, `driver/Driver.entitlements`, `app/` (SwiftUI host, activation, and a status read through `IORegistryEntryCreateCFProperty`), and `gen.rb` at the root, producing the project with `$(SRCROOT)`-relative paths and `core/src/*.cpp` in the dext target.
