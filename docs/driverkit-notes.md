# DriverKit notes for the RM520N-GL driver

Date: 2026-11-13. macOS 27.0, Xcode 27.1, DriverKit SDK 27.0, Apple silicon.

This is reference material for writing the dext. Every API below was compiled and linked against DriverKit SDK 27.0 in a throwaway spike, unless it is marked **[not compiled]**. Anything marked **[runtime]** can only be settled by loading a real driver; compiling proves nothing about it.

- Spike: `.../scratchpad/dext-spike/`, in the session's scratch directory (`gen.rb`, `Driver/NetSpike.iig`, `Driver/NetSpike.cpp`, `Driver/Info.plist`, `Driver/Driver.entitlements`, `Host/`). It is a scratch directory and may not survive, so the examples below are copied out of it.
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

As built (2026-11-14): the driver takes empty packets in batches, one `DequeuePackets` call of up to 32 (`kRxStock`) whenever its stock is empty, into `rxStock`. The last packet of the stock is the buffer offered to CoreHost and stays the one offered until it is committed, so a frame rejected after its buffer was offered costs no packet. An empty RX submission queue gives no buffer, and neither do 256 (`kRxHold`) filled packets still waiting for the completion queue; the frame is then dropped and counted, a data frame in `RMNetRxDropNoPacket` and an emulator reply in `RMNetReplyDropNoPacket`. Filled packets go up with `EnqueuePackets` once 64 (`kRxBatch`) have gathered, and at the end of each transfer; a hand-up after the completion queue refused packets passes everything kept, up to 256, in one call. (Not yet run on hardware.) `RMNetRxStock` shows the stock; `RMNetPacketsHeld` does not count it.

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

`ClearStall` is the only form USBDriverKit 27.0 offers: there is no asynchronous variant, so with `withRequest` true it sends CLEAR_FEATURE synchronously on the Default queue, and it aborts whatever is pending on the endpoint. Calling it while other requests are posted on the pipe could block the queue on their aborted completions, which are delivered to that same queue. **As built (Task 6, fix round 1), a bulk pipe is recovered without blocking:** on a completion that halts the endpoint (any error other than an abort, a timeout or a device that is gone, as the header says), nothing more is posted on that pipe (bulk IN: no read is re-posted; bulk OUT: `acquire_uplink` gives no buffer, and frames are dropped and counted as `RMNetTxDropRecovering`); the pipe is aborted with `kIOUSBAbortAsynchronous`; when its busy count reaches 0, `ClearStall(true)` runs with nothing pending, and bulk IN posts all 32 reads again. Aborted completions during a recovery are expected and not counted as errors. "5 failures in a row" now counts **recoveries per pipe**: the fifth recovery started on a pipe with no successful transfer on it since the first is fatal (`on_fatal`). A completion saying the device is gone (`kIOReturnNotAttached`, `kIOReturnNoDevice`) is fatal at once; an abort outside a recovery re-posts that read, and five of those in a row for one read are fatal. **A recovery is bounded (fix round 2):** if the asynchronous `Abort` returns an error, that is fatal at once ("bulk in could not be aborted for a stall recovery"); and the driver's 100 ms timer calls `UsbIo::tick()`, which makes a recovery still waiting for its aborted requests after 10 ticks (about 1 s) fatal ("bulk in recovery did not finish within 1 s", logged with the number still pending). Without the bound, an abort that aborted nothing would leave bulk IN idle for good with the link up, since reads have no timeout. `tick()` is not called once the stop sequence has begun and does nothing after a fatal failure, so the deadline cannot report into Core after `session.stop()`. Once stopping begins nothing is re-posted and no recovery finishes, so no `ClearStall` is issued; the stop sequence aborts the pipes as before. The log shows `bulk in halted: recovery N in a row, M reads pending` and then `bulk in recovered: ClearStall 0x0, reads posted again` (bulk OUT: `bulk out halted ...`, `bulk out recovered ... uplink open again`); `RMNetUsbRecoveries` and `RMNetUsbStallClears` count them. **The recovery path has never run on hardware**: no bulk endpoint has stalled so far (both counters 0).

**Aborting at stop:**

```
virtual kern_return_t Abort (IOOptionBits options, kern_return_t withError, IOService *forClient);
// USBDriverKitDefs.h: kIOUSBAbortAsynchronous = 0x0, kIOUSBAbortSynchronous = 0x1
```

`forClient` must be NULL on any pipe but the control pipe. The header, parameter `forClient`: "Service for which to abort requests. If NULL, all requests will be aborted. Only control endpoints can specify a non-NULL value." Task 5 and fix round 1 of Task 6 passed the driver itself on the interrupt and bulk pipes; since Task 6 fix round 2 every `Abort` on those pipes, at stop and in a recovery, passes `nullptr`. (`AbortDeviceRequests` on the interface is a different call and is unchanged.)

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

**As built (final review fix wave, 316.18.48):** `Start` reads `RMNetProfile` with `CopyProperties(&dict)`, `dict->getObject("RMNetProfile")` and `OSDynamicCast(OSNumber, ...)->unsigned64BitValue()`; anything but an integer from 1 to 255 (or no key) gives 1 with a log line. The value used goes to Core as `SessionConfig.profile` and is published back as `RMNetProfile` with `SetProperties`, over the personality's value. It compiles and runs: `RMNet status` showed `RMNetProfile = 1` and the call came up on profile 1. The plist still says 1, so the published value does not by itself prove the read (the same number either way), and the `profile 1` log line was not in the stream (see the runtime findings below).

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

`IOUserNetworkEthernet` exports its own `SetPowerState_Impl`, so `SUPERDISPATCH` reaches it. AppleEthernetIXL overrides `SetPowerState`; AppleUserECM does not. **[runtime]** What the USB interface looks like after wake. The design already says to treat wake as a full restart. **Answered (owner's sleep test, 2026-11-14 17:22 to 17:23, build 317.9.11):** the modem stayed attached and the same driver instance carried on; no request completed while held (`RMNetSleepCompletions` 0), so the requests pending at the power-off stayed pending across the sleep, and the interface answered at once after the wake (link up 0.58 s after the wake call). Seen for sleeps of up to 28 s only; see "Runtime findings (sleep and wake)".

**As built (recovery plan, Task 3, 317.9.11).** `SetPowerState` has no `QUEUENAME` in `IOService.iig`, so it runs on the Default queue as a call of its own, never inside a Core call or a `UsbIo` listener call; `RestartSession` may be called from it. Every call is logged with its flags and passed to the superclass.
- Power off (`powerFlags == kIOServicePowerCapabilityOff`): Core is not called and nothing is sent. The driver marks itself asleep, counts `RMNetSleeps` and holds `UsbIo` (`UsbIo::hold`): nothing is posted, re-posted, submitted or sent, nothing is delivered to the listener, and completions that arrive are counted (`RMNetSleepCompletions`, `RMNetSleepLastStatus`) but never toward a failure limit, a recovery or `on_fatal`; a not-attached or no-device status still marks the device gone. While asleep the timer tick calls neither Core nor USB (it publishes status and counters only), and `DrainTx` keeps frames in the queue. A second power off while asleep does nothing new.
- Power on (`powerFlags & kIOServicePowerCapabilityOn`) while asleep: counts `RMNetWakes`. If USB had failed, or the stop sequence runs, nothing more. If the device went during the sleep, `OnUsbFatal("device gone during the sleep")`: the session stops, the link goes down, the state says `detached`, nothing is sent (`UsbIo` stays held), and a new instance follows the re-enumeration. Otherwise `UsbIo::resume` clears the failure memory (uplink stall count and its restart memory, per-read and interrupt failure counts, recovery counts), finishes a pipe recovery whose requests have returned, posts the interrupt read and every bulk read not posted, sends what is queued and reads waiting responses; then `RestartSession("wake")` takes the link down and starts the session from sync, and `EnsureTimer` makes sure a tick is pending. `RMNetLastWakeUpMs` is the time from that call to the next link up (0 until then).
- Power on while not asleep (one comes at every start: `RMNetLastPowerFlags` 2 on a fresh instance), and low power: nothing.
- `Stop` while asleep: `finish_sending` ends the hold and drops the messages waiting behind it; the stop sequence then runs as before.
- If a re-post is refused at the wake (`resume` fails), the port goes down as `usb failed` and stays down until a re-enumeration or a manual reload; nothing retries. *Changed 2026-11-14 (hardening), not yet on hardware:* a refusal that is not "device gone" is now retried from every tick for up to 5 s; see "Changed in code, not yet on hardware (hardening)".

**Seen on the Mac (2026-11-14 17:22 to 17:23).** Two sleeps and two wakes, each with the device kept and the requests pending: the power-off held `UsbIo`, the power-on resumed it and restarted the session, and the port came back up with new addresses in both families. Details, and what was not seen, in "Runtime findings (sleep and wake)".

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

**As built (Task 6): the bulk side joins the same sequence.** `outstanding()` counts the 32 posted bulk reads and the uplink transfers in flight. From step 1 (`finish_sending`) no bulk read is re-posted or delivered and no uplink transfer is started; step 3 aborts both bulk pipes with the others, and their aborted completions (`BulkInComplete`, `BulkOutComplete`) advance the sequence like the control ones. After `OnUsbFatal` has stopped the session, `TearDown` no longer calls `stop()` or `take_link_change()` again, and the timer no longer ticks the Session.

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

## 6. Serial ports (USBSerialDriverKit)

Date: 2026-11-15. The modem's DIAG (interface 0) and NMEA (interface 1) interfaces as `/dev/cu.RM520N-GL-DIAG` and `/dev/cu.RM520N-GL-NMEA`, by a second class, `RMNetSerial`, in the same dext. Built and linked with `make driver` (unsigned); **not yet loaded**, so everything marked **[runtime]** is open until the first load of the serial ports.

The class lives in the existing dext rather than a second one: one bundle, one version, one approval and one install path, so `scripts/install-driver.sh`, the app's activation and the version-matched removal stay as they are. A second dext would need its own bundle ID, provisioning profile, activation request, removal path and kept apps.

### 6.1 What `IOUserUSBSerial` does

`$FW/SerialDriverKit.framework/Headers/IOUserSerial.iig` declares `class KERNEL IOUserSerial : protected IOService`, and `$FW/USBSerialDriverKit.framework/Headers/IOUserUSBSerial.iig` declares `class IOUserUSBSerial : protected IOUserSerial`. macOS ships `com.apple.DriverKit-AppleUSBSerial.dext`, whose class `AppleGenericUSBSerial` is an `IOUserUSBSerial` that overrides only `Start` (the superclass's, then `RegisterService`). What `IOUserUSBSerial` does, read from its disassembly (the DriverKit shared cache):

- `Start` calls `IOUserSerial::Start`, then sets `IOTTYBaseName` = `usbserial-` and `IOTTYSuffix` = the USB serial number (or the location ID in hex), followed by the interface number in hex when the configuration has two or more interfaces. It reads the personality's `quirks` (a 16-bit number); bit 0 sends a zero-length packet after a write that is a whole number of max-size packets.
- `ConnectQueues` opens the interface (for client `this`); `DisconnectQueues` closes it. `HwActivate` (a port being opened) copies the pipes: a bulk IN and a bulk OUT are required (`kIOReturnError` without them), an interrupt IN is optional, so DIAG's two bulk endpoints are enough. Each read is one max-size packet.
- It does not implement `HwResetFIFO`, `HwSendBreak`, `HwProgramUART`, `HwProgramBaudRate`, `HwProgramMCR`, `HwGetModemStatus`, `HwProgramLatencyTimer` or `HwProgramFlowControl`, which are pure (`LOCAL = 0`) in `IOUserSerial.iig`. `RMNetSerial` implements all eight.

### 6.2 The class

`driver/RMNetSerial.iig` overrides `init`, `free`, `Start`, `Stop` and the ten `Hw*` methods, spelled as in `IOUserSerial.iig` (`HwProgramUART(uint32_t baudRate, uint8_t nDataBits, uint8_t nHalfStopBits, uint8_t parity)`, `HwGetModemStatus(bool * cts, bool * dsr, bool * ri, bool * dcd)`, `HwProgramFlowControl(uint32_t arg, uint8_t xon, uint8_t xoff)`). The `Hw*` methods are `LOCAL`, not `LOCALONLY`, so they follow the RPC rule (3.1): the bodies are `Name_Impl`, and `HwActivate(SUPERDISPATCH)` and `HwDeactivate(SUPERDISPATCH)` reach the superclass. The `.cpp` includes `<USBSerialDriverKit/USBSerialDriverKit.h>`, and `gen.rb`'s `OTHER_LDFLAGS` gains `-framework SerialDriverKit -framework USBSerialDriverKit`; `otool -L` on the dext then lists both frameworks, and `nm -m` shows twelve `RMNetSerial::*_Impl` symbols (`Start`, `Stop` and the ten `Hw*`).

`Start` works in this order:

1. It reads the interface descriptor (`CopyConfigurationDescriptor`, `GetInterfaceDescriptor`, `IOUSBHostFreeDescriptor`, as `RMNetDriver` does) and the personality (`CopyProperties`).
2. It refuses, with `kIOReturnUnsupported` and a log line, unless the provider is an `IOUSBHostInterface`, its descriptor was read, `RMNetSerialSubClass` and `RMNetSerialProtocol` are integers, `rmnet::serial_interface_matches` accepts the interface's class, subclass and protocol, and `rmnet::tty_name_ok` accepts `RMNetSerialName`. At that point nothing has been opened and the superclass's `Start` has not been called.
3. The superclass's `Start`, then `SetProperties` with the port's name (6.5), then `RegisterService`.

`Stop` releases the interface and passes `Stop` to the superclass. `HwActivate` and `HwDeactivate` forward to the superclass and log every call (`open`, `close`). `HwProgramMCR` sends DTR and RTS (6.6). `HwGetModemStatus` reports CTS, DSR and DCD on and RI off, so a program that waits for a carrier does not wait forever. The other six succeed without I/O and log their arguments on their first call only.

### 6.3 Personality keys

Two personalities in `driver/Info.plist`, `RMNetSerialDIAG` and `RMNetSerialNMEA`:

| Key | Value |
|---|---|
| `CFBundleIdentifier`, `IOUserServerName` | `$(PRODUCT_BUNDLE_IDENTIFIER)` |
| `CFBundleIdentifierKernel` | `com.apple.driver.driverkit.serial` (as Apple's serial dexts use; `AppleUSBSerial` has no `OSBundleLibraries` entry for it, and neither has ours) |
| `IOClass` | `IOUserSerial` |
| `IOProviderClass` | `IOUSBHostInterface` |
| `IOUserClass` | `RMNetSerial` |
| `idVendor`, `idProduct`, `bConfigurationValue` | 11388, 2049, 1 (the 4-key match proven for `RMNetDriver`, 4.1) |
| `bInterfaceNumber` | 0 (DIAG), 1 (NMEA) |
| `RMNetSerialName` | `RM520N-GL-DIAG`, `RM520N-GL-NMEA` |
| `RMNetSerialSubClass`, `RMNetSerialProtocol` | 255 and 48 (DIAG, `ff`/`ff`/`30`), 0 and 64 (NMEA, `ff`/`00`/`40`) |
| `quirks` | 1 (6.7) |

Matching by interface number alone could take an AT or QMI interface if the modem's USB configuration changed (switching DIAG off, for example, renumbers the rest), which is why `Start` checks the class, subclass and protocol first (6.2). `scripts/check-personalities.sh`, run by `make check-driverkit`, also refuses any personality on interface 2 or 3, an `RMNetSerial` one on any interface but 0 or 1 or without `IOClass` `IOUserSerial`, `CFBundleIdentifierKernel` `com.apple.driver.driverkit.serial` and a valid `RMNetSerialName`, `RMNetDriver` on any interface but 4, and a personality whose `IOUserClass` is neither `RMNetSerial` nor `RMNetDriver`.

DIAG is included because it costs one personality on the same class and lets Qualcomm DIAG tools that take a serial device (QCSuper, Quectel's QLog) run on the Mac.

### 6.4 Entitlement and profile

`driver/Driver.entitlements` gains `com.apple.developer.driverkit.family.serial` = true, after `family.networking`. Checked on 2026-11-15 at 03:40: a signed Release build of the `RMNetDriver` target alone, with that key added, `-allowProvisioningUpdates` and team `ABCDE12345`, succeeded. Xcode replaced the profile "DriverKit Team Provisioning Profile: io.rmnetdriver.RMNet.driver" (now `~/Library/Developer/Xcode/UserData/Provisioning Profiles/6d3b0ea4-cad5-43cf-8071-24af4e246bdc.provisionprofile`) with one granting `family.networking` and `family.serial`, and the signed dext carried both. Nothing was installed. The existing `transport.usb` entitlement (`idVendor` `*`) already covers interfaces 0 and 1.

### 6.5 Naming

`IOUserUSBSerial` would name the ports `usbserial-<serial number>0` and `...1`. `RMNetSerial` sets `IOTTYBaseName` to `RMNetSerialName` and `IOTTYSuffix` to `""` with `SetProperties` after the superclass's `Start` and before `RegisterService`: the BSD client, which makes `/dev/cu.*` and `/dev/tty.*`, is matched at registration and reads those two properties, and Apple's Bluetooth serial dext sets them the same way at run time. If `SetProperties` is refused, the port keeps Apple's name and the driver logs `RMNet: serial <name>: naming the port failed`. A name must be 1 to 31 of `A-Z`, `a-z`, `0-9`, `_` and `-` (`rmnet::tty_name_ok`, `rmnet::kTtyNameMax`); the script checks the same rule.

### 6.6 DTR and RTS

Linux's `option`/`usb_wwan` driver sends the CDC request SET_CONTROL_LINE_STATE (`bmRequestType` 0x21, `bRequest` 0x22, `wValue` DTR bit 0 and RTS bit 1, `wIndex` the interface number) when a port opens and closes. `HwProgramMCR` does the same, synchronously, with `IOUSBHostInterface::DeviceRequest` (its `bytesTransferred` is a `uint16_t *`) and a 1000 ms timeout, and logs the values and the status on every call. A failure is logged and the call still returns success, so opening a port never fails on it.

### 6.7 Zero-length packets (`quirks`)

Quectel's Linux driver sets `URB_ZERO_PACKET` on every bulk OUT for vendor 0x2C7C, so both personalities set `quirks` = 1, which makes `IOUserUSBSerial` send a zero-length packet after a write that fills its last packet.

### 6.8 Open questions for the first load **[runtime]**

*Answered 2026-11-15 on 317.20.51; see "Runtime findings (serial ports)": 1 yes; 2 as listed there; 3 yes, one process per instance; 4 yes (both ports started); 5 yes, the modem accepts the request before `HwActivate`; whether NMEA needs DTR was not tested.*

1. Whether our `SetProperties` names win: `ls /dev/cu.*` shows `cu.RM520N-GL-DIAG` and `cu.RM520N-GL-NMEA`, or Apple's `usbserial-...` names (and the log has `naming the port failed`).
2. Which `Hw*` calls the kernel makes, and in what order, when a port is opened and closed: `open` and `close`, the MCR line on every call, and the first-call lines of the others.
3. Whether the instances run in their own processes (`ps`). DriverKit starts a separate process for each matched provider unless the personality sets `IOUserServerOneProcess`, so a fault in a serial instance should not stop `en33`.
4. Whether `CopyProperties` and the interface's `CopyConfigurationDescriptor` answer before the superclass's `Start`. `RMNetDriver` reads both after it; if they do not, every port is refused with `properties not readable` or `the interface descriptor could not be read`.
5. Whether SET_CONTROL_LINE_STATE succeeds when `HwProgramMCR` is called (the interface is opened by `ConnectQueues`; a request before that may be refused), and whether the modem needs DTR for NMEA output at all.

---

## Build record

Spike settings: those of `spike-dext/gen.rb`, plus the Core settings above. There is no `DEVELOPMENT_TEAM` or `CODE_SIGN_STYLE`; signing is turned off on the command line.

```
cd .../scratchpad/dext-spike
/usr/bin/ruby gen.rb <path of the rmnet-driver checkout>
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
   *Status at the end of the driver plan (2026-11-14):* **open.** Task 7 measured 92.6 to 138.3 Mbit/s against the 150 gate, with no drops, starvation or CPU saturation in the driver seen ("Runtime findings (throughput, Task 7)").
2. **Which callbacks the framework actually invokes**: `SetInterfaceEnable` or `setInterfaceEnable`, the data-available handlers on the default queue, `SetPowerState` or `setPowerState`, and the MTU calls. All compile either way, and `= 0` is not enforced. The spike copies AppleUserECM's shipping pattern, which lowers but does not remove this risk. *Settles it:* the first load, with an `os_log` line in every override and handler.
   *Status:* **closed** by the first load: every override logs its first call, and "Runtime findings (first load)" lists which ones macOS calls, in what order, and which never.
3. **Teardown races on unplug and stop**: completions after `Stop`, synchronous `Abort` from the Default queue, and releasing actions and buffers while transfers are still in flight. *Settles it:* unplug and replug in a loop, and deactivate while traffic flows, watching for crashes in `log stream` and crash reports.
   *Status:* **open.** Every observed `Stop` (modem reboots) found no request outstanding; a `Stop` with transfers in flight, an unplug and a deactivation while traffic flows were never run.
4. **Personality matching on interface 4.** The 4-key form is proven on interface 3. Adding class keys is unproven. *Settles it:* the first install; `ioreg -r -n RmNet@4` shows the driver attached.
   *Status:* **closed** by the first install: the 4-key personality attached `RMNetDriver` to `RmNet@4` ("Runtime findings (first load)").
5. **RX and TX packet semantics**: the meaning of the data address and offset, whether `PoolFlagMapToDext` is needed, whether the RX submission queue is stocked before enable, and pool sizing at 32 posted reads. *Settles it:* the first ping, both directions, and `netstat -I` counters.
   *Status:* **closed in part** by Task 6: the TX data offset is 0, writing at `getDataVirtualAddress()` with `setDataOffAndLen(0, len)` delivers, `PoolFlagMapToDext` is enough, and the RX submission queue is stocked once the interface is enabled. Pool sizing is shown only up to the rates measured (no receive drop for want of a packet at 144 Mbit/s).
6. **Status publishing.** `SetProperties` may be refused for this kernel class. *Settles it:* `ioreg -l` on first load. Fallback: personality values or a user client.
   *Status:* **closed** by the first load: `SetProperties` works; no fallback needed ("Runtime findings (first load)").
7. **QMI over asynchronous control requests.** `Session::stop()` emits several frames back to back, so the driver needs a small ring of OUT buffers and in-order submission. There is also the interaction between the interrupt read and the STALL that answers an empty response. *Settles it:* bring-up on hardware, plus a forced `stop()` while connecting.
   *Status:* **open in part.** Bring-up, teardown at `Stop` and reboot recovery work on hardware (Task 5); a forced `stop()` while connecting was not run.
8. **Sleep and wake.** Whether `SetPowerState` arrives at all for a USB network dext, and in what state the pipes are on wake. *Settles it:* the sleep/wake test from the design's "Done means".
   *Status:* **open.** Not tested.
9. **Signing a networking-family dext.** The stub that was signed and loaded was an `IOUserService`, not an `IOUserNetworkEthernet`, though its profile already carries `family.networking`. *Settles it:* the first signed build and install.
   *Status:* **closed** by the first signed build and install ("Runtime findings (first load)", Packaging and signing).
10. **Zero-length packets.** These cannot be checked from the headers. Core's padding avoids the case, and the follow-ups list already asks whether the modem accepts the extra padding.
   *Status:* **open.** Nothing counts whether the exact-multiple-of-1024 case occurred.

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
- **Deactivation is matched against the exact driver version embedded in the app that asks.** With `/Applications/RMNet.app` carrying 316.16.1 and entries 316.15.49 and 316.15.56 installed, `RMNet deactivate` failed with `OSSystemExtensionErrorDomain` error 4 (sysextd: "deactivation request could not find extension ... buildNumber: 316.16.1"). Rebuilding the app with `CURRENT_PROJECT_VERSION` set to an installed entry's version, and deactivating from that app, worked: once per entry, each time with the owner's password. So an installed driver can be removed only by an app with the same driver version. `scripts/install-driver.sh` keeps that app in `build/installed/RMNet-<version>.app` before replacing `/Applications/RMNet.app` (docs/reference.md, "Removing the driver").

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
- After `AT+CFUN=1,1`: the old instance received a WDS Packet Service Status indication (disconnected) at once, went to `backoff` and sent its releases, then 4 s later its interrupt read failed with `0xe00002eb` (`kIOReturnAborted`), re-posting failed with `0xe00002d8` (`kIOReturnNotReady`; *corrected 2026-11-14: first misread as `kIOReturnNotAttached`, which is `0xe00002d9`*), so `usb failed` was reported, and `Stop` came 4 ms later. The new instance started about 11 s later and sent a sync every 2 s for about 18 s (10 in all) until the modem answered, then reached `link up` within 0.5 s.
- `setMaxTransferUnit` still returns `kIOReturnUnsupported` (0xe00002c7) after link up; the carrier MTU was 1500 in every run, so the interface MTU stays 1500 from `getMaxTransferUnit`.

**Stopping**
- `Stop` is asynchronous (section 3.9, "As built"): drain the control ring for up to 1 s, abort, wait up to 1 s for the aborted requests, then release and pass `Stop` to the superclass. The fix-round evidence is in the next bullets and the Task 5 report.
- On a modem reboot `Stop` arrived with no USB request outstanding (the failures had already completed): "stop: control messages sent 0, dropped 0; aborted with 0 requests outstanding", "stop: usb objects released", `free`. No crash report. Releasing after aborted completions that are still in flight has therefore not been seen yet.
- `Start` decisions: a failed `reportLinkStatus` or `SetProperties` is logged and does not fail `Start`. The link status is reported again whenever the stack enables the interface (and a status reported in `Start` is lost anyway); the properties are only for the app. Every other failure in `Start` tears down and fails it.

**macOS and the port**
- With the new MAC, the port kept the name `en33` and the hardware port `RM520N-GL` (`networksetup -listallhardwareports`: `Device: en33`, `Ethernet Address: 02:68:7a:43:12:f6`). No new service or interface appeared.
- Link active: `ifconfig en33` shows `status: active`, only a link-local IPv6 address (DHCP and RAs are unanswered without a data path). `scutil --nwi` lists only `utun5` and `en0`; `en33` is not a primary or listed service. The stack counted 32 frames sent on `en33` (`netstat -I en33 -b`); the driver completed and dropped them.
- Kernel `os_log` lines redact `%s` arguments as `<private>`; use `%{public}s`. Numbers are not redacted.

---

## Recommended source layout for the real driver

- `driver/RMNetDriver.iig` + `.cpp`: the network class, an `IOUserNetworkEthernet` subclass (*corrected 2026-11-15: this first said "the only DriverKit class"; since the serial ports, `RMNetSerial` (section 6) is the other*). It owns its lifecycle (`Start`, `Stop`, `SetPowerState`), the pool and the four queues, link reporting, the timer, and every `TYPE(...)` completion stub. Each stub is a few lines that forward to the classes below. Everything runs on the Default queue.
- `driver/usb_io.{h,cpp}`: plain C++ held in the ivars. It holds the interface and three pipes, the posted-read slots and their buffers, the ring of QMI OUT buffers, the uplink buffer, stall recovery and abort. It knows nothing about QMI.
- `driver/core_host.{h,cpp}`: plain C++ that implements `rmnet::SessionDelegate` and owns `Session`, `EthernetEmulator` and `QmapAggregator`. It turns USB completions into `on_qmi`, `qmap_next` and `wrap_rx` calls, turns TX packets into `handle_tx` and the aggregator, and calls `tick` and the periodic router advertisement. This is where Core is driven from, always on the Default queue, never re-entered from a delegate callback.
- `driver/Info.plist`, `driver/Driver.entitlements`, `app/` (SwiftUI host, activation, and a status read through `IORegistryEntryCreateCFProperty`), and `gen.rb` at the root, producing the project with `$(SRCROOT)`-relative paths and `core/src/*.cpp` in the dext target.

## Runtime findings (data path, Task 6, 2026-11-14)

From installing 316.17.10 and loading it with `AT+CFUN=1,1`. Logs: `build/logs/driver-20261114-010952.log` (load, first link up, traffic), `driver-20261114-011304.log` (modem reboot with a ping running), `driver-20261114-011445.log` (the refused `AT+CGACT=0,1`, no driver activity).

**Packets**
- TX: `getDataOff()` is 0 on the stack's frames (`first tx packet: data offset 0, length 86`), so `getDataVirtualAddress() + getDataOff()` and `getDataVirtualAddress()` agree; the question in 1.5 is moot for this stack.
- RX: writing at `getDataVirtualAddress()` and `setDataOffAndLen(0, len)` (returns 0), plus `setLinkHeaderLength(14)`, delivers frames the stack accepts (DHCP, ND, ping, TCP). `PoolFlagMapToDext` is enough for the dext to read and write packet data.
- The RX submission queue is stocked once the stack enables the interface; no receive drop for want of a packet was counted, even at 144 Mbit/s (`RMNetRxDropNoPacket = 0`).
- The completion queues never refused a packet (no "took N of M" line), and `RMNetPacketsHeld` (packets the driver holds) was 0 when idle after traffic and after the reboot.
- `IOUserNetworkPacketBufferPool::GetPacketCount` answers 4736 throughout, idle or loaded, for a pool created with `packetCount` 512: it is a fixed total, not a free count. DriverKit offers no free count; `RMNetPacketsHeld` is the driver's own measure of leaked packets.
- Completion handlers on the Default queue keep up: `networkQuality -I en33` reported 143.8 Mbit/s down with 32 posted `AsyncIO` reads, no bundling.

**What the modem sends**
- At low rates each packet comes in its own transfer followed by a 4-byte all-zero transfer, as in the harness (after the reboot: 92 transfers, 45 of them empty, for 47 packets).
- Under load the modem aggregates: during `networkQuality`, 277,784 packets arrived in 16,481 transfers (about 17 per transfer), only 18 transfers empty.
- No QMAP command frame arrived in any run (`RMNetQmapCommands = 0`): the flow-control reply path is still unproven on hardware.
- No malformed or truncated QMAP and no frame on another mux.

**Uplink**
- The bulk OUT endpoint reports 1024 bytes (SuperSpeed), read with `GetSpeed` and `IOUSBGetEndpointMaxPacketSize`; the aggregator gets that value.
- Bulk OUT `AsyncIO` with the transfer length as `dataBufferLength`, without `SetLength` on the buffer, works.
- During the upload phase of `networkQuality` 12,467 frames were dropped because all 8 uplink buffers were in flight (`RMNetTxDropBusy`), against 188,645 sent; uplink measured 13.5 Mbit/s. Eight buffers flushed whenever the TX queue empties means many small transfers; holding frames in the TX queue instead of dropping, or more buffers, is the lever if uplink matters.

**macOS and the port**
- `en33` had its IPv4 address (matching `RMNetIPv4`) and two global IPv6 addresses in the modem's /64 within 9 s of `link up`. `scutil --nwi` lists `en33` last for IPv4 (after `utun5` and `en0`) and second for IPv6 (after `utun5`; Wi-Fi has no IPv6), so it is not primary.
- The port received the modem's DNS servers (two IPv6, two IPv4) as a scoped resolver for `en33` (`scutil --dns`).
- Idle for 60 s with the link up, macOS sent 89 packets (7,643 bytes) and received 1 (86 bytes) on `en33`.
- Of the frames macOS sent, the emulator drops multicast and broadcast (`RMNetTxDropFiltered`, 96 by the end of the first session); frames sent before `link up` count as `RMNetTxDropLinkDown`.
- After a modem reboot the port came back with a new /30 and a new /64; the old /64's addresses were gone (the interface is recreated with the same name, `en33`, and its byte counters restart).
- A neighbour solicitation for the Mac's own address was not looked for.

**Calls dropped from the modem side**: `AT+CGACT=0,1` through the web console answered `ERROR` three times and changed nothing (the call that QMI started is not context 1 to the AT side, or AT may not tear it down). The IPv4 retry while up was therefore not exercised on hardware.

## Runtime findings (throughput, Task 7, 2026-11-14)

Measured with `scripts/measure.sh` (4 parallel HTTPS transfers bound to the port; figures from `netstat -I en33 -b -n` sampled about every 0.28 s; each download stopped at 50,000,000 bytes, the upload at 10,000,000 bytes or 6 s). The gate figure is the mean rate from 1.0 s after traffic starts to the last sample before the stop. Samples: `build/logs/measure-20261114-*.samples`; driver logs `build/logs/driver-20261114-014423.log` and `driver-20261114-014938.log`. Cell: NR5G SA band 41, as on 2026-11-13. Each modem reboot starts a new call (new /30 or /29 and /64).

| Run | Driver | Direction | Gate figure | Best 1 s | Bytes in / out on `en33` | Driver CPU |
|---|---|---|---|---|---|---|
| 1 | 316.17.31 | down | 129.2 Mbit/s | 150.0 | 51,347,480 / 148,333 | 0.38 s |
| 2 | 316.17.31 | up | 11.9 Mbit/s (port counters, dropped frames included) | 25.5 | 299,647 / 10,112,539 | 0.29 s |
| 3 | 316.17.44 | down | 138.3 Mbit/s | 182.3 | 54,666,535 / 116,991 | 0.30 s |
| 4 | 316.17.49 | down | 92.6 Mbit/s | 105.6 | 54,176,502 / 187,772 | 0.42 s |

The gate (150 Mbit/s by the definition above) was not passed. What the runs show, and what they cannot show:

**Shown.**
- **No sign of receive-path starvation, measured in run 4 only.** `RMNetRxLagMaxUs` (316.17.49) is the longest a successful bulk read waited between completing on the bus (`completionTimestamp`) and the entry of its handler. In run 4 (the slowest, about 92 Mbit/s) it was 1,051 µs at most, while a transfer arrived about every 2.4 ms (2,244 transfers in 5.3 s). Runs 1 and 3, the faster ones, had no such counter.
- **The completion timestamp is in mach ticks.** The first completion logged `completion timestamp 8136738486987, uptime 339030770332208 ns`: a ratio of 41.667, the 24 MHz tick of Apple silicon (timebase 125/3), not nanoseconds.
- **No read came back full.** `RMNetRxFullTransfers` (reads filled to their 31,744 bytes) stayed 0: the modem's aggregation ends each transfer (17 to 19 packets and 24 to 27 KB per transfer).
- **No drops and no refusals.** Every `RMNetRxDrop*` counter stayed 0, the completion queues never refused a packet (no "took N of M" line in either log), `RMNetPacketsHeld` was 0 afterwards, and `RMNetTxDropBusy` stayed 0 during all three downloads.
- **No CPU saturation in the driver process.** 0.30 to 0.42 s of CPU per 50 MB download: about 8 to 11 µs per received packet, about 8 to 11 % of one core at these rates.
- **The path can carry more than 150 Mbit/s briefly.** Run 3 carried 182 Mbit/s over its first 1.1 s, with one 0.27 s sample at 229 Mbit/s.

**Not measured.**
- Read headroom in runs 1 and 3. `RMNetRxLagMaxUs` also stops at handler entry: it leaves out the time spent in `on_bulk_in`, `FlushRx` and the re-post, so it understates how long a read is not posted. It is a maximum, not an occupancy, so it does not show how many reads were in flight at once.
- Latency in the transmit and acknowledgement path. The 8 uplink buffers and the transmit batching affect how fast TCP ramps up, and nothing measures them.
- What macOS does after `EnqueuePackets`, and kernel CPU outside the driver process.
- Whether the modem's data format and aggregation match those the userspace tool negotiates.
- Whether the rate curves come from the network. Run 1 sat near 50 Mbit/s for a second and climbed to 179 Mbit/s when the cap stopped it. Run 3 reached 229 Mbit/s within 0.6 s and fell to about 130. Run 4 climbed slowly from 40 to about 100. Runs 3 and 4 have the same receive path (316.17.49 only adds a counter), but they were different calls after a modem reboot. Their 46 Mbit/s spread therefore mixes network variation with whatever differed between the two instances.
- The 226 Mbit/s userspace figure came from a different day and a different method (uncapped 8 s runs), so it cannot be compared with these.

Only a same-day comparison with the userspace tool, run under this script and its caps, can separate the driver from the network.

**Why measuring stopped at three downloads.** One 50 MB run cannot show an effect smaller than the 46 Mbit/s spread between runs of the same receive path, so more runs would not settle anything. Batching was in place before this task: one `EnqueuePackets` per completed transfer (at most 64 packets per call), and 32 reads re-posted from their completions. `AsyncIOBundled` and a separate receive queue were not tried.

**Per-stream limit (added after these runs).** `scripts/measure.sh` now limits each of the 4 downloads to 15,000,000 bytes (curl's output goes through `head -c`), so a download run cannot pass 60,000,000 bytes of payload even if its watchdog dies. A stream that reaches its own limit before the watchdog's 50,000,000-byte stop ends early, and the run then carries fewer streams. The script prints how many streams ended that way. The four runs above were made before this limit existed.

**Uplink.** The 11.9 Mbit/s gate figure of run 2 is what the port's counters show, and they include the frames the driver dropped. What reached the modem is lower: the port counted 10.1 MB out, while the driver's `RMNetTxBytes` (IP bytes delivered to the modem) rose by 6.7 MB, about two thirds. Run 2 dropped 2,343 frames because all 8 uplink buffers were in flight (`RMNetTxDropBusy`), against 5,325 sent in 1,224 transfers. On the port's counters, the rate fell from about 17 to 25 Mbit/s in the first 3 s to under 10 once the drops began, as TCP backed off. Holding frames in the TX submission queue until a buffer frees, instead of dropping them, is the change to make; it was not made here because the gate is downlink only and no drop occurred during a download.

## Runtime findings (final review fix wave, 2026-11-14)

From installing 316.18.48 and loading it with `AT+CFUN=1,1`. Log: `build/logs/driver-20261114-024819.log`.

- The stream caught the old instance (316.17.49) to the end: `usb failed`, `Stop`, the stop sequence with nothing outstanding, `free`. Of the new instance it lost every line before `getMaxTransferUnit` (`init`, `Start`, the serial and MAC line, `profile 1`, `started`), although the stream was running and at the default level. Lines around a load can still be lost; evidence that must come from `Start` should also be published as a property.
- The reworded link-up line: `link up: ipv4 1 ipv6 1, carrier mtu 1500; the interface keeps the mtu it registered with (setMaxTransferUnit(1500) 0xe00002c7)`.
- The new instance took about 18 s (10 syncs) for the modem to answer after the reboot, then came up dual-stack in 0.5 s, as before.

## Runtime findings (uplink hold, 2026-11-14)

From installing 316.19.9 and loading it with `AT+CFUN=1,1`; link up about 21 s after the new instance started (`started` 03:09:55, `link up` 03:10:16 local). Log: `build/logs/driver-20261114-030928.log`. One burst with `scripts/uplink-burst.py en33` (1,500 UDP datagrams of 1,200 bytes to 192.0.2.1 port 9, sent by the stack in 0.018 s with no `ENOBUFS`).

**What changed.** `CoreHost::transmit` returns false, consuming and counting nothing, when a frame needs an uplink buffer and all 8 are in flight; while bulk OUT recovers, frames are still dropped (`RMNetTxDropRecovering`). `DrainTx` then keeps the rest of its batch (`txPending`) and stops (`txWaitUplink`); the frames behind it stay in the TX submission queue. A successful bulk OUT completion (`OnBulkOutDone`) and the modem resuming the uplink restart the drain at once; a failed completion, the end of a bulk OUT recovery and a link down are covered by the 100 ms timer tick, which restarts a held drain (a failed completion does not drain at once, because the pipe may be about to be recovered). Kept frames are offered first, in order. *(Corrected 2026-11-14 after the whole-stage review, which found the plan's claim that every event freeing a buffer restarts the drain at once.)* *Changed 2026-11-15 (driver features), not yet on hardware:* a failed completion that starts no recovery, the end of a recovery whose `ClearStall` succeeds and a link down now restart a held drain at once (kept QMAP command replies go first); see "Changed in code, not yet on hardware (driver features)". `EthernetEmulator::handle_tx` has no side effect for a `Forward` result (its IPv4 and IPv6 paths only read the frame), so a refused frame is simply offered again.

**Shown.**
- Every datagram of the burst reached the modem: `RMNetTxPackets` rose by 1,504 (46 to 1,550) and `RMNetTxBytes` by 1,842,132 (1,500 × 1,228 IP bytes plus 132), in 135 transfers (about 11 frames each). `RMNetTxDropBusy`, `RMNetTxDropUsb`, `RMNetTxDropRecovering` and `RMNetUsbBulkOutErrors` stayed 0. Before this change, uplink under load dropped 2,343 frames of 5,325 (Task 7, run 2, a 6-second TCP upload, not this burst).
- `RMNetTxHolds` rose from 0 to 999 in 316.19.9, which counted every stop of the drain, including each re-offer of a kept frame while all buffers were still in flight. (316.19.26 changes it to count hold episodes; that is a change in code, not yet seen: see "Runtime findings (receive batching)".) The first hold logged `first uplink hold: every uplink buffer in flight, 5 frames kept`.
- 1 s after the burst `RMNetTxPending` was 0 and `RMNetPacketsHeld` 0 (its idle value), and both pings worked afterwards. No crash report; `en33` first in neither `scutil --nwi` list.

**Not shown.**
- Throughput: the burst is UDP to an address that answers nothing, so it says nothing about the TCP upload rate. No upload measurement was made (data budget).
- Holding during a link down, a fatal USB error, a stall recovery or a QMAP pause: none occurred. Those paths are as reasoned in the code: after a link down (a fatal USB error brings one) kept frames are dropped as `RMNetTxDropLinkDown` on the next drain, and during a stall recovery as `RMNetTxDropRecovering`; during a QMAP pause they are not dropped but held until the resume.
- A `Stop` with frames kept: they are abandoned with the disabled queues, like other held packets.

## Runtime findings (receive batching, 2026-11-14): first run at 03:53 (316.19.26) and 03:57 (316.19.56)

Build 316.19.26 is installed (`scripts/install-driver.sh`, activated, replacing 316.19.9) but has not run: after `AT+CFUN=1,1` at 03:26:43 on 2026-11-14 the modem did not come back on USB (no device in `ioreg -p IOUSB`), so no instance of the new build started. Nothing below has been seen on hardware. Log: `build/logs/driver-20261114-032625.log`.

**What changed in code.**
- Receive packets: a stock of up to 32 empty packets (`kRxStock`), refilled with one `DequeuePackets` call when empty, replaces taking one packet per frame (section 1.6, "As built"). `RMNetRxStock` publishes the stock; `RMNetPacketsHeld` no longer counts it (idle value 0).
- Handler time: `RMNetRxHandlerMaxUs` and `RMNetRxHandlerTotalUs`, from the entry of `BulkInComplete_Impl` to the return of `UsbIo::bulk_in_complete` (parsing, handing packets up, the re-post), for successful reads while not stopping; two clock reads per transfer. `RMNetRxHandlerTotalUs` divided by `RMNetRxTransfers` is the mean. (Changed again after the whole-stage review: see the next section.)
- `RMNetTxHolds` counts hold episodes, not every refused re-offer.
- The link-up line says the interface keeps its registered MTU only when `setMaxTransferUnit` failed.

**Seen on hardware.** Only the old instance (316.19.9) stopping on the reboot: `usb failed: interrupt read could not be posted`, `Stop`, the stop sequence with 0 requests outstanding, `stop: usb objects released`, `free`. No crash report.

**Seen later, after the owner replugged the modem (about 03:53).** The status above was written before this; what follows is the first run of this code. 316.19.26 loaded by itself after the replug. Its successor 316.19.56 (the build of the next section, commit `8ba7c8e`) was installed with `scripts/install-driver.sh` and loaded with one `AT+CFUN=1,1` at 03:56:48; the modem was back on USB within about 15 s and link up at 03:57:23. Log: `build/logs/driver-20261114-035628.log`.

- On 316.19.26: idle `RMNetRxStock` 24, `RMNetPacketsHeld` 0. After `ping -c 5` on IPv4 and IPv6 (5 of 5 each, about 27 ms): `RMNetRxPackets` 10, `RMNetRxStock` 14 (24 less the 10 packets used), `RMNetRxDropNoPacket` and `RMNetReplyDropNoPacket` 0, `RMNetRxHandlerMaxUs` 272, `RMNetRxHandlerTotalUs` 2,021 over 16 transfers. Stock 12 just before the reboot.
- On 316.19.56: link up logged `link up: ipv4 1 ipv6 1, carrier mtu 1500; setMaxTransferUnit(1500) 0xe00002c7, so the interface keeps the mtu it registered with` (the reworded line, first seen). Both families on `en33`, `en33` first in neither `scutil --nwi` list, no new crash report (only the old `...-003648.ips`). Idle: `RMNetRxStock` 24, `RMNetPacketsHeld` 0, `RMNetPoolPacketCount` 4736, `RMNetQmapCommandRepliesKept` 0.
- On 316.19.56, `ping -c 100 -i 0.1 -s 1200`: 100 of 100 (19 to 73 ms, mean 36.5 ms). `RMNetRxStock`, sampled each second, moved between 7 and 29 and was 9 at the end; `RMNetRxDropNoPacket` and `RMNetReplyDropNoPacket` stayed 0; `RMNetPacketsHeld` 0. Handler time: `RMNetRxHandlerTotalUs` 22,611 over 217 timed transfers (218 `RMNetRxTransfers`, the first not timed), a mean of about 104 µs; `RMNetRxHandlerMaxUs` 457, about 4.4 times the mean. `RMNetRxLagMaxUs` 250.
- On 316.19.56, one `scripts/uplink-burst.py en33` (1,500 datagrams of 1,200 bytes, sent by the stack in 0.018 s, no `ENOBUFS`): `RMNetTxHolds` 0 to 2 (episodes, not hundreds), `RMNetTxPackets` +1,526 (176 to 1,702: the 1,500 and other traffic), `RMNetTxDropBusy`, `RMNetTxDropUsb`, `RMNetTxDropRecovering` and `RMNetUsbBulkOutErrors` 0; `RMNetRxDropNoPacket` unchanged at 0. One log line, `first uplink hold: every uplink buffer in flight, 8 frames kept`. About 2 s after the burst began, `RMNetTxPending` was still 4 (`RMNetPacketsHeld` 4) and `RMNetTxPackets` 1,419: the uplink took over 2 s for the 1.84 MB, so the frames were held, not dropped. 5 s later both were 0.
- A ping (`-c 20 -i 0.2`) running alongside the burst: 20 of 20, but the replies to the two pings sent during the burst came back after 498 and 294 ms, and the next after 87 ms, against about 15 to 38 ms before and after. A small packet waits behind the held frames, up to about half a second for this burst. *Corrected 2026-11-14 (hardening build): the wait is most likely inside the modem, not behind the driver's held frames; see "Runtime findings (hardening build)".*
- No QMAP command frame arrived (`RMNetQmapCommands` 0 throughout), so the kept-reply path did not run. After the burst both 5-ping checks were 5 of 5; no new crash report.

**Not seen.**
- The stop of 316.19.26 with packets in its stock (stock 12 at the reboot): the log stream was running but caught no line of the old instance (the file starts with the new instance's `sync sent (1)`), and `/usr/bin/log show` has none. No crash report followed. A second reboot was not made.
- An interface disable and enable with packets in the stock; a stall; a link down or a fatal error during a hold; a QMAP pause; the stop of 316.19.56.

## Whole-stage review fixes (2026-11-14): RUN ONCE, KEPT REPLIES NOT EXERCISED

Built after 316.19.26, with the modem off USB; installed later as 316.19.56 and run once (see the previous section): the drain changes and the first-transfer skip of the handler timing ran during that run's burst and pings, but nothing here could be told apart on hardware except that handler timing skipped the first transfer (`RMNetRxHandlerTotalUs` 0 after one transfer). Checked by `make driver`, `make test`, `make check-driverkit` and review only. No QMAP command frame has ever arrived from this modem, so the kept-reply path has never run.

**What changed in code.**
- QMAP command replies are kept through a hold. A reply that finds no uplink buffer (all 8 in flight, or bulk OUT recovering), or finds earlier replies still kept, is built into fixed storage in `CoreHost`: up to 4 (`kKeptReplies`), 64 bytes each (`kKeptReplyBytes`; a flow control reply is 4 + 16 bytes), in order. A full store, or a reply too large for a slot, drops the new reply and counts it in `RMNetQmapCommandReplyDrops`, as before. Kept replies are sent, oldest first, from `CoreHost::on_bulk_out_done` after a successful transfer, which runs before the driver's `OnBulkOutDone` restarts its drain, so a reply takes the freed buffer first; and from `CoreHost::data_tick` on every 100 ms tick, as a backstop. None is sent while bulk OUT recovers (`acquire_uplink` gives no buffer then). They are discarded, and counted in `RMNetQmapCommandReplyDrops`, on a link down, at `Stop` (`CoreHost::stop`) and on a fatal USB error (`OnUsbFatal`). A change from before: a reply that arrives during a bulk OUT recovery is now kept rather than dropped. `RMNetQmapCommandRepliesKept` publishes how many are kept now (0 to 4); the first kept reply logs `first qmap command reply kept`. The pause itself still takes effect before any reply is sent.
- `TxPacketsAvailable` during a hold (`txWaitUplink`) only completes sent packets (`FlushTxDone`) and returns, instead of running a whole drain that would be refused again (316.19.9 saw about 860 such drains in one burst). A successful bulk OUT completion, the modem resuming the uplink, or the timer tick restarts the drain.
- `RMNetRxHandlerMaxUs` and `RMNetRxHandlerTotalUs` no longer time a read until the receive path's first-call log lines are behind it: the first successful read (whose handling logs `BulkInComplete` and `first bulk read`) and the `first rx packet` line. Timing starts after the `BulkInComplete` first-call line, with its own clock read (three clock reads per timed transfer); `RMNetRxLagMaxUs` still uses the clock read on entry. The total then covers slightly fewer transfers than `RMNetRxTransfers`.

## Runtime findings (measurements after the uplink hold and receive batching, 2026-11-14 16:27)

Build 316.19.56, running since 03:57, same cell (NR5G SA band 41). One capped upload and one capped download with `scripts/measure.sh en33`, run by the controller. One run each; neither was repeated.

**Upload** (`build/logs/measure-20261114-162709-up.samples`). The 10,000,000-byte stop was reached after 2.2 s; the run moved 12.4 MB out.
- Gate figure 37.9 Mbit/s, but over 0.84 s only (the script notes the part after the first second is shorter than 1.0 s). Best 1-second window 43.2 Mbit/s.
- `RMNetTxDropBusy` stayed 0. `RMNetTxHolds` rose from 2 to 17. `RMNetTxBytes` rose by 12,261,600: everything the port's counters show was handed to the modem.
- For comparison, on build 316.17.31 (Task 7, run 2, at 01:42) the same script timed out at 6 s having moved 10.1 MB, of which about 6.7 MB reached the modem, with 2,343 `RMNetTxDropBusy`. The two runs were 15 hours apart, so the cell may differ as well as the driver.

**Download** (`build/logs/measure-20261114-162738-down.samples`). The 50,000,000-byte stop was reached 1.68 s after the start; the run moved 55.6 MB in. One of the four streams reached its own 15,000,000-byte limit before the stop.
- Samples, bytes in since the start: 5.4 MB at 0.27 s, 15.6 at 0.55, 23.8 at 0.84, 34.5 at 1.12, 44.6 at 1.40, 52.9 at 1.68. That is between 232 and 303 Mbit/s in every quarter-second interval.
- Best 1-second window 278.0 Mbit/s (0.27 s to 1.40 s). The gate figure as defined (the mean from 1.0 s after traffic starts) is 232.5 Mbit/s, but over 0.28 s only, because the byte cap ended the run; the script flags it as too short. By the definition fixed in advance this run therefore does not settle the gate, although every reading of it is above 150 Mbit/s.
- The driver during the run: 1,934 transfers carrying 38,825 packets (about 20 per transfer). Handler time 211,894 µs in total, about 110 µs per transfer, which is about 15 % of the 1.41 s the traffic lasted; `RMNetRxHandlerMaxUs` 816. `RMNetRxLagMaxUs` rose to 2,888 µs, against one transfer every 0.73 ms, so at most about four of the 32 reads were waiting for their handler at once. `RMNetRxDropNoPacket` 0, `RMNetRxFullTransfers` 0, `RMNetRxStock` between 18 and 27. The driver process used 0.33 s of CPU. `RMNetTxDropBusy` 0 and `RMNetTxHolds` unchanged, so no acknowledgement was held or dropped.
- Task 7's three runs at 01:41 to 01:51 gave 129.2, 138.3 and 92.6 Mbit/s. Two things differ between those runs and this one: the receive path (batched dequeue, the hold, fewer wasted drains) and the time of day. This run cannot say which made the difference.

**What this shows and what it does not.** At about 280 Mbit/s the driver spent about 15 % of the time in its receive handler, used about a fifth of one core, dropped nothing, and kept reads posted. It does not show a pass of the gate by the rule fixed in advance (two runs, each with at least a second measured after the first second): a 50 MB cap is too small at this rate, and the script's 300,000,000-byte ceiling (243,040,078 recorded) leaves no room for another download run.

**A longer download, four minutes later (16:31, same build and the same driver instance).** The owner asked for one longer run to settle the gate. It was made with a one-off copy of `scripts/measure.sh` in which five lines differed: the stop at 100,000,000 bytes, the per-stream limit at 30,000,000, the warning at 120,000,000, the ceiling at 400,000,000 (the owner's whole allowance), and a fixed working directory. The repository's script is unchanged. Samples: `build/logs/measure-20261114-163153-down.samples`.
- The run was stopped by its 8 s time limit after moving 35.9 MB. Gate figure 36.6 Mbit/s over 6.80 s; best 1-second window 103.8 Mbit/s. The rate was uneven: about 1.6 MB in the first half second, under 2 Mbit/s around 2.8 s, a burst of about 135 Mbit/s between 3.7 and 4.8 s, then about 15 Mbit/s to the end.
- By the rule fixed in advance this is a valid measurement and it is far below 150 Mbit/s. The gate is not passed.
- The driver during the run: 1,622 transfers, handler time about 117 µs per transfer, which is about 2.4 % of the 8 s; `RMNetRxHandlerMaxUs` 1,065; `RMNetRxLagMaxUs` 4,848 µs; `RMNetRxDropNoPacket`, `RMNetTxDropBusy`, `RMNetTxDropUsb`, `RMNetUsbBulkInErrors`, `RMNetUsbBulkOutErrors`, `RMNetUsbRecoveries` and every QMAP command counter 0; the uplink never paused. `RMNetTxHolds` rose by 2 during this download and by 0 during the fast one, so twice all eight uplink buffers were in flight while only acknowledgements were being sent: the modem was slow to take uplink data.
- The modem right after: the same cell as before (NR5G SA band 41, channel 504990, cell 32), RSRP -93 dBm, RSRQ -10 dB, SINR 6 dB, a second carrier on band 28, temperatures 29 to 31 °C. `ping -c 5 -b en33 223.5.5.5` averaged 71.6 ms (48.8 to 102.9), against 25 to 37 ms in the early morning.
- What the two runs together show: the same driver instance carried 278 Mbit/s over one second at 16:27 and 36.6 Mbit/s over seven seconds at 16:31, with nothing reloaded in between and no error or drop counter moving. The difference between them is therefore not in the driver's code. Whether it was the radio link, the cell's load, the path or the test server cannot be told from here. A single run on this cell does not measure the driver.

## Runtime findings (recovery: timer re-arm, uplink timeouts, pause limit, `detached`; 2026-11-14 16:45)

Build 317.8.44 (commit of this section). Installed with `scripts/install-driver.sh`, loaded with one `AT+CFUN=1,1` at 16:45:01; the modem was back on USB within about 15 s and the new instance reported `up` at 16:45:35. Log: `build/logs/driver-20261114-164447.log`.

What the build adds: `RMNetDriver::EnsureTimer` re-arms the 100 ms timer from every other entry into the driver after a failed `WakeAtTime` (`RMNetTimerArmFailures`); `UsbIo` ends an uplink after `kUplinkTimeoutsFatal` (3) bulk OUT timeouts in a row with no success between them (`on_fatal("uplink is not accepting data")`, `RMNetUsbBulkOutTimeouts`); a QMAP pause not lifted within `kPauseMaxMs` (30 s) restarts the session (`CoreHost::restart`, `RMNetUplinkPauseTimeouts`); `RMNetState` says `detached` instead of `usb failed` when `UsbIo` had seen a not-attached or no-device status.

**Seen on hardware.** Only that the build loads, links up (IPv4 and IPv6), carries the two 5-ping checks with no loss, publishes the three new counters at 0, leaves `en33` first in neither `scutil --nwi` list, and leaves no crash report. The old instance (316.19.56, the previous code) stopped as before: `interrupt read failed: 0xe00002eb`, `interrupt read not posted: 0xe00002d8`, `usb failed: interrupt read could not be posted`, `Stop` 4 ms later with 0 requests outstanding, `free`. That is the sequence the `detached` state is for. *Corrected 2026-11-14 (sleep and wake task):* `0xe00002d8` is `kIOReturnNotReady`, not `kIOReturnNotAttached` (`0xe00002d9`), so this sequence does not set `detached`: see "Runtime findings (sleep and wake)".

**Not seen, and not producible on this modem:** a failed timer arm (`WakeAtTime` has never failed), an uplink transfer that times out (none ever has), and a QMAP pause (the modem has never sent a command frame), so neither the fatal path for timeouts nor the session restart has ever run. `detached` itself was not seen either: the instance that stopped was the older build. The next reload of 317.8.44 or later is the first that can show it.

## Recovery fix round 1 (2026-11-14): BUILD ONLY, NOT INSTALLED, NOTHING SEEN

The commit after 317.8.44, built and tested but not installed (the next task installs it). The installed 317.8.44 still has the first form of each rule below.
- **Uplink stalls, not transfers.** The transfers queued on the NAKing endpoint all time out together, so 317.8.44 would have failed for good after one 5 s stall with three or more transfers in flight. Now each submitted transfer gets a sequence number; a failure counts as a new stall only if its transfer was submitted after the previous counted stall completed. Three stalls with no success between restart the session once (`RMNetUplinkStuckRestarts`); stuck again with no success since is `usb failed` (`uplink is not accepting data`). A dead uplink therefore costs about 15 s, a restart, then about 15 s of traffic more.
- **What counts as a stall.** `kIOReturnTimeout` and the legacy `0xe0004051` (transaction timeout), neither of which a header names as the status of a timed-out `AsyncIO`; and `kIOReturnAborted` while running and not in a bulk OUT recovery (the driver's own `abort()` leaves the running phase first). The legacy timeout no longer starts a stall recovery. None of these statuses has been seen on hardware.
- **Stop without its timer.** A failed arm counts as no timer in `AdvanceStop`'s two waits, and a failed re-arm in the stopping tick advances the stop at once.
- **Pause timing** runs only while the data link is up.

## Runtime findings (sleep and wake, 2026-11-14 17:11 and 17:22)

Build 317.9.11 (the sleep and wake commit). Installed with `scripts/install-driver.sh`, loaded with one `AT+CFUN=1,1` at 17:11:55; the new instance reported link up at 17:12:28.742. Log: `build/logs/driver-20261114-171124.log` (the load and the idle check; it was stopped before the sleep test, so no log line covers the sleeps).

**Seen.**
- A power-on call reaches each new instance at start: `RMNetLastPowerFlags` was 2 (`kIOServicePowerCapabilityOn`) with `RMNetSleeps` and `RMNetWakes` 0. The log line for it was lost with the instance's first lines, as usual.
- The Core liveness probe (first time on hardware): over 150 idle seconds after link up, one WDS Get Current Settings (`qmi tx WDS client 15 msg 0x002d`) every 30.0 to 30.1 s (17:12:58.749, 17:13:28.840, 17:13:58.845, 17:14:28.853, 17:14:58.870), each answered `result ok` within 3 to 5 ms; the link stayed up. Only the IPv4 client (15) is probed.
- Link up, both families, `en33` first in neither `scutil --nwi` list, both 5-ping checks 5 of 5, no new crash report.

**`detached` is never set by a modem reboot.** The old instance (317.8.44) ended as every reboot has: `interrupt read failed: 0xe00002eb` (`kIOReturnAborted`), `interrupt read not posted: 0xe00002d8`, `usb failed: interrupt read could not be posted` with no "(device gone)", `Stop` 4 ms later. `0xe00002d8` is `kIOReturnNotReady`; `kIOReturnNotAttached` is `0xe00002d9`. Earlier sections named it wrongly (corrected above), and `UsbIo`'s `Gone()` (not-attached or no-device) matches neither status seen, so `RMNetState` said `syncing`, then the entry was gone; polling every half second never showed `detached`. Whether to treat `kIOReturnNotReady` as gone is open: around a sleep it might also mean a bus not yet awake.

**The owner's sleep test (17:22 to 17:23).** The owner slept and woke the Mac; the controller read the results at 17:24. Sources: `RMNet status`, `ps` for the driver process, `pmset -g log`, `ifconfig`, `scutil --nwi`, the two pings, the `DiagnosticReports` folders. The log stream was not running across the sleep.
- **No re-enumeration.** The driver process was the same before and after (pid 82581, started 17:12:10): the modem stayed attached and the instance survived.
- **Power calls.** `RMNetSleeps` 2 and `RMNetWakes` 2. `pmset -g log` shows three sleep entries in that minute and a half: at 17:22:02 a clamshell sleep that became a dark wake 2 s later and a full wake at 17:22:07; at 17:22:13 a software sleep until 17:22:41 (28 s); at 17:23:10 a software sleep until 17:23:33 (23 s). The driver therefore saw two power-offs for three sleep entries; which entry did not reach it is not known. `RMNetLastPowerFlags` 2. The uppercase `SetPowerState` is the path macOS uses, with flags 0 (off) and 2 (on); the lowercase `setPowerState` and its first-call line were not looked for (no log).
- **Nothing completed while held.** `RMNetSleepCompletions` 0 and `RMNetSleepLastStatus` 0: the requests pending at the power-off stayed pending across the sleep, and the stack cancelled nothing.
- **Wake.** `RMNetLastWakeUpMs` 578: link up 0.58 s after the last wake call. `RMNetState` up with new addresses in both families: IPv4 10.66.47.163 before, 10.99.149.174/30 after; IPv6 prefix 2001:db8:8797:a840 before, 2001:db8:8db1:9c01 after. So the port came back with the new call's addresses, not the old ones.
- **No error.** `RMNetUsbBulkInErrors`, `RMNetUsbBulkOutErrors`, `RMNetUsbBulkOutTimeouts`, `RMNetUsbRecoveries`, `RMNetTimerArmFailures` and `RMNetUplinkStuckRestarts` all 0; `RMNetTxDropLinkDown` 17 (frames queued across the two restarts, dropped as link down, as designed); `RMNetPacketsHeld` 0; `RMNetRxStock` 25.
- **Checks.** `ping -c 5 -b en33 223.5.5.5` 5 of 5 (average 16.6 ms); `ping6 -c 5 -B en33 2400:3200::1` 5 of 5 (average 38.2 ms). No new crash report; `en33` first in neither `scutil --nwi` list.

**Not seen:** a sleep during which the stack cancels or fails transfers (`RMNetSleepCompletions` above 0); a re-enumeration on wake; a bus that answers not-ready (or refuses any re-post) at the wake call, which would leave the port down until a re-enumeration or a manual reload, since nothing retries; a sleep longer than half a minute; a `Stop` while asleep; a second power-off while asleep, or a power-on without one (the missing third sleep may be either, or neither); and the log lines of the power calls and of `resume`.

## Runtime findings (30-minute soak, 2026-11-14 17:25 to 17:55)

Build 317.9.11, the instance running since 17:12:10 (the one that went through the owner's sleep test). `scripts/soak.sh en33 30`, run once by the controller, started at 17:25:19 under `caffeinate` so the Mac would not idle-sleep; it did not sleep during the run (`RMNetSleeps` still 2 afterwards, from the sleep test). `scripts/driver-log.sh` ran alongside. Files: `build/logs/soak-run-20261114-172518.out` (the script's output), `build/logs/soak-20261114-172519.csv` (181 samples, one every 10 s), `build/logs/soak-20261114-172519-ping.log` and `soak-20261114-172519-ping6.log`, `build/logs/driver-20261114-172518.log`.

Traffic: `ping -i 0.5 -s 1000 -b en33 223.5.5.5` and `ping6 -i 0.5 -s 1000 -B en33 2400:3200::1` for the whole run, about 8 KB a second in all, chosen to fit the data allowance.

**Seen.**
- Verdict `soak: PASS`. Duration 1807 s of 1800; 181 samples; status and `RMNetState` `up` in every sample.
- First and last sample (`time,seconds,if_bytes_in,if_bytes_out,moved_in,moved_out,status,RMNetState`, then `RMNetUsbBulkInErrors`, `RMNetUsbBulkOutErrors`, `RMNetUsbBulkOutTimeouts`, `RMNetUsbRecoveries`, `RMNetRxDropNoPacket`, `RMNetRxDropBadQmap`, `RMNetTxDropBusy`, `RMNetTxDropUsb`, `RMNetTxDropRecovering`, `RMNetTimerArmFailures`, `RMNetPacketsHeld`):
  - `2026-11-14T09:25:19Z,0,5851,170740,0,0,up,up,0,0,0,0,0,0,0,0,0,0,0`
  - `2026-11-14T09:55:19Z,1800,7476097,7818850,7470246,7648110,up,up,0,0,0,0,0,0,0,0,0,0,0`
  - So every listed error and drop counter was 0 at the start and at the end (times in UTC; local time is 8 hours ahead).
- Pings: IPv4 3,560 sent, 3,560 answered, round trip 15.8 / 42.4 / 826.6 ms (min / avg / max); IPv6 3,559 sent, 3,559 answered, 14.2 / 37.1 / 770.1 ms. Loss 0.0 % in each.
- Data: 7,494,452 bytes in and 7,673,108 out on `en33` (about 15.2 MB). One line appended to `build/installed/measure-usage.log`; the recorded total went from 279,079,160 to 294,246,720 bytes.
- The driver's log over the run holds nothing but the Core liveness probe: 61 WDS Get Current Settings (`qmi tx WDS client 15 msg 0x002d`, txid 58 to 118, 17:25:34 to 17:55:38), one every 30 s, each answered `result ok` and followed by `settings IPv4: v4 1 (/30, 2 dns), v6 0 (/0, 0 dns), mtu 1500`. That is three log lines every 30 seconds while idle or busy. No link down, no USB error line, no restart.
- Afterwards (read by the controller): no new crash report named after the driver; `en33` first in neither `scutil --nwi` list.

**What this shows and what it does not.** Thirty minutes with no USB error, no recovery, no drop in the listed counters, no packet held at the end and no ping lost, under light traffic: two 1,000-byte pings a second in each family. It says nothing about behaviour under sustained heavy traffic (the longest heavy traffic on record is the 8 s download at 16:31 in "Runtime findings (measurements after the uplink hold and receive batching)"). It did not record the driver process's memory. Counters not in the soak's list (`RMNetTxDropLinkDown`, `RMNetTxDropFiltered`, `RMNetRxDropFiltered` and others) were not judged.

## Changed in code, not yet on hardware (hardening, 2026-11-14)

Built and tested (`make driver`, `make test`, `make check-driverkit`) and written before any of it had run. *Added after the install (317.11.33, 19:34 on 2026-11-14):* the build has since been loaded once; what ran and what did not is in "Runtime findings (hardening build)" below. In short: the 64-entry queue was accepted and carried two bursts, the quieter probe line was seen, and the stall counter ran only on its success path. **The wake retry and the queue fallback have still never run.**

- **A wake whose bus is not ready is retried.** `UsbIo::resume(last_try)` now returns `Done`, `NotYet` or `Failed`. If, at a wake, posting the interrupt read or a bulk read is refused with a status other than not-attached or no-device, `UsbIo` stays held and reports `NotYet`; requests that attempt did post stay posted (their completions are handled as held ones) and are not posted again, and a bulk IN recovery's `ClearStall` is not repeated. The driver then behaves as while asleep (no Core call, no `UsbIo::tick`, `DrainTx` holds, the asleep rules for the published state) except that every timer tick makes one more attempt (`RMNetDriver::ResumeUsb`), the last once `kResumeRetryMs` (5000 ms) have passed since the wake call; a refusal then is fatal exactly as before (`usb failed`), and one with not-attached or no-device at any attempt is fatal too, but with the device gone `OnUsbFatal` publishes the state `detached`. On success the tail of the old resume runs (control messages sent, responses read, the `usb resumed` line, which names the attempts when more than one) and the session restarts from sync. `Stop`, a fatal USB error and a new power-off end the pending state without another attempt; a device seen gone before a later attempt takes the port down as `detached`, as at the wake call. `RMNetWakeRetries` counts the attempts after the first; `RMNetLastWakeUpMs` still runs from the wake call. The failure memory is cleared once per wake, at the first attempt.
- **A shorter transmit submission queue.** `kTxQueueCapacity` (64) for the TX submission queue only; the other three stay at `kQueueCapacity` (256). During an upload the hold keeps that queue full; with 64 the frames that do not fit should wait in macOS's own interface queue, which schedules flows fairly, rather than in order in the driver's queue (the pings that waited 498 and 294 ms behind a 2 MB burst, "Runtime findings (receive batching)"). Whether the capacity really bounds what waits in the driver's queue is not known. Nothing documents which capacities `Create` accepts, so if it refuses 64 `Start` logs one line with the status and tries once more with `kQueueCapacity` (256, used on every load so far), and the capacity in use is published as `RMNetTxQueueCapacity` with the counters and named in the `started` line.
- **A quieter liveness probe.** `settings IPv…` is logged only when a Get Current Settings reply's settings differ (field by field) from the ones last logged for that family; the first reply of a session and the first after a restart are always logged. The probe should now cost two lines every 30 s instead of three.
- Also: the uplink stall counter is now `rmnet::UplinkStallCounter` from Core (unit-tested in `tests/test_stall.cpp`), with no change of behaviour intended; `UsbIo::acquire_uplink` refuses after a fatal failure; "timer armed again" is logged only at the power-of-two steps of the arm failures; the comment on a modem reboot's statuses is corrected; the dead `logged_bad_qmap_` is gone.

## Runtime findings (hardening build, 2026-11-14 19:34 to 19:40)

Build 317.11.33 (commit `23c0b77`, branch `hardening`), installed with `scripts/install-driver.sh` and loaded with one `AT+CFUN=1,1` at 19:34:00, by the controller with the owner away. Log: `build/logs/driver-20261114-193324.log`. The plan allowed one install and one reboot; both were used.

**The load.**
- Install: "replacing version 317.10.17 with 317.11.33", "activate: done", no approval asked; a copy is kept in `build/installed/RMNet-317.11.33.app`.
- The old instance (317.10.17) stopped as on every modem reboot: link down at 19:34:00.933, `interrupt read failed: 0xe00002eb`, `interrupt read not posted: 0xe00002d8`, `usb failed`, `Stop` at 19:34:05.173 with 0 requests outstanding, `free` 4 ms later.
- The modem was back on USB within about 7 s, the new process started at 19:34:15, sent ten syncs, and logged `link up: ipv4 1 ipv6 1` at 19:34:34.557, 33.6 s after the command. The stream lost the new instance's lines before `getMaxTransferUnit`, as on every load, so the `started; TX submission queue capacity` line was not captured.
- After it: only 317.11.33 listed (`activated enabled`); `RMNetState` `up`; IPv4 and two global IPv6 addresses on `en33`; `en33` first in neither `scutil --nwi` list; no new crash report; `ping -c 5 -b en33 223.5.5.5` 5 of 5 (35 to 52 ms) and `ping6 -c 5 -B en33 2400:3200::1` 5 of 5 (26 to 217 ms).

**The transmit queue of 64.** `RMNetTxQueueCapacity` reads 64: `IOUserNetworkTxSubmissionQueue::Create` accepts a capacity of 64 on macOS 27.0, and the fallback to 256 did not run.

**The liveness probe.** Sent at 19:35:04.644 and every 30 s after it through 19:39:34.902 (ten probes), each answered within 3 to 5 ms, with two log lines each (`qmi tx`, `qmi rx`). The `settings IPv…` line appears once per family at link up and not again: the quieter line works.

**Two uplink bursts** (`scripts/uplink-burst.py en33`: 1,500 UDP datagrams of 1,200 bytes to 192.0.2.1, 1.84 MB on the link, handed over by the stack in 0.020 s with no `ENOBUFS`), each with a ping to 223.5.5.5 every 0.2 s alongside.
- Burst 1, 19:35:29: `RMNetTxHolds` 0 to 2; `RMNetTxDropBusy`, `RMNetTxDropUsb`, `RMNetTxDropRecovering`, `RMNetUsbBulkOutErrors` and `RMNetUsbBulkOutTimeouts` 0; `RMNetTxPending` and `RMNetPacketsHeld` 0 afterwards. Ping 20 of 20: 19 to 69 ms before the burst; the three pings sent in the first half second of it came back together after 1,053, 843 and 633 ms; the next eleven came back together about 4 s after the burst began, after 3,468 ms falling by about 210 ms each to 1,376 ms.
- Burst 2, 19:39:31, with `netstat -I en33 -b -n` sampled about every 15 ms: the port's output counter had risen by 974 packets 72 ms after the burst began, by 1,296 at 266 ms, 1,301 at 457 ms, and by all 1,503 at 475 ms. After that it rose by one packet every 0.2 s: the echo requests left the Mac on time. Packets in: one by 266 ms, two by 672 ms, four by 1.5 s, then none until 3.15 s after the burst began, when eleven arrived together, then one every 0.2 s. Ping 30 of 30: 236 ms, then 1,012 and 802 ms, then 2,066 ms falling by about 205 ms each to 219 ms, then 23 to 83 ms. `RMNetTxHolds` 2 to 28, every drop and error counter still 0, `RMNetQmapCommands` 0.

**What the bursts show.**
- The driver with a 64-entry queue passed the whole 1.84 MB to the modem in under half a second (the first 1.2 MB within 72 ms), with nothing dropped. The shorter queue does not throttle a burst.
- The wait a small packet sees behind an upload burst is **not in the driver's queue**. The echo requests were handed to the modem on time; their replies came back late and in a batch. The modem took the burst over USB far faster than it sent it over the air (1.84 MB in about 3.1 s in burst 2, about 4.7 Mbit/s), queued the pings behind it, and sent no flow-control command. This last sentence is the controller's inference from the counters; the modem's own queue cannot be seen from the Mac.
- So the 64-entry queue neither helped nor hurt here, and the earlier reading in "Runtime findings (receive batching)" ("a small packet waits behind the held frames") named the wrong place: the 498 and 294 ms seen on 316.19.56 at 03:57 were most likely the same wait inside the modem, with a faster uplink at that hour. The two runs differ in time of day; the uplink rate was not measured separately in either.
- A queue that could shorten this wait would have to keep the data out of the modem: the modem pushing back (QMAP or QMI flow control, which this modem has never sent and which Core's data-format request does not ask for), or the driver limiting what it hands over to an estimate of the uplink's rate. Neither exists; see the follow-ups file.

**Not seen.**
- A sustained upload on this build, so nothing is known about the 64-entry queue's effect on TCP upload speed or on latency during a long upload (the project's capped measurement tools refuse to run: their 300 MB ceiling is reached).
- The wake retry: no sleep happened (`RMNetSleeps` 0, `RMNetWakes` 0, `RMNetWakeRetries` 0). Its first-attempt path will run at the Mac's next sleep and wake; its not-ready branch needs a bus that is not ready, which this Mac has never shown.
- The stall counter's failure paths (no uplink transfer has ever timed out here), the queue fallback, `acquire_uplink` after a failure.

**An IPv6 download (recorded here for completeness; made on 317.10.17 at about 18:49, before this build).** The AAAA record of `mirrors.tuna.tsinghua.edu.cn` was resolved through the port's own DNS server (`dig -b <the port's IPv4 address> @203.0.113.193`), and `/usr/bin/curl --noproxy '*' --interface en33 -6 --resolve ... -r 0-1048575 https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz` returned HTTP 206 with 1,048,576 bytes from `2402:f000:1:400::2` in 0.48 s; the port's counters rose by 1,118,483 bytes in and 6,215 out. That is the first HTTPS transfer over IPv6 on the port.

**Data.** This build's checks moved about 3.8 MB over the port (two bursts, 3,668,555 bytes recorded in `build/installed/measure-usage.log`; pings and background the rest). The usage file's total is 299,040,169 bytes.

## Changed in code, not yet on hardware (in-band flow control, 2026-11-14)

Built and tested (`make driver`, `make test`, `make check-driverkit`, `make app-test`) and written before any of it had run. *Added after the install (317.12.36 at 20:36, 317.14.28 running since 22:28 on 2026-11-14):* the request, the modem's answer and the reporting have run; the fallback, the give-up rule and the handling of QMAP flow commands have still never run, because the modem granted the request and sent no command. Results: "Runtime findings (in-band flow control)" below.

- **What is asked.** With the personality key `RMNetFlowControl` set to the integer 1 (as `driver/Info.plist` now sets it), Core's WDA Set Data Format request carries TLV `0x1A` "Flow Control" = 1, between the endpoint TLV (`0x17`) and `0x1B`; otherwise the request is byte for byte the recorded one. Absent, not an integer, or any value other than 0 or 1 means 0, with one log line, as for `RMNetProfile`. The aim: the modem should pause the uplink with QMAP flow commands instead of swallowing a burst over USB faster than the cell carries it.
- **What is reported.** The response's TLV `0x1B` "Flow Control" (one byte; 0 if absent; any other length fails the parse) goes to `DataFormat.flow_control` and so to `LinkConfig.format`. The `data format:` log line ends `, flow control: last request asked <0|1>, modem says <value>` ("last request": the session's last Set Data Format request, since a late answer to an earlier one can arrive after the fallback). Published with the counters: `RMNetFlowControlAsked` (the last Set Data Format request asked), `RMNetFlowControlRefused` and `RMNetFlowControlOn` (the modem's answer in the data format in use now; 0 whenever the session is not up). A Set Data Format answer whose result is ok but which does not parse is logged as `data format not parsed (result ok)`.
- **The fallback.** If a request that asked does not end in a usable data format (an error result, an answer that does not parse or is not usable, or its 10 s timeout), flow control counts as refused: Core sends Set Data Format again at once without the field, as the same bring-up step, with a new transaction ID and a fresh timeout, without backoff and without telling the driver, which logs one line (`flow control refused: ...`). The refusal is kept for the life of the `Session` object, so across `CoreHost::restart`; only a new driver instance asks again. A request without the field that fails goes to backoff as before.
- **A pause that does not end gives flow control up.** If the uplink stays paused by a QMAP flow disable for 30 s (`kPauseMaxMs`) while the data format in use was asked with flow control, the driver calls `Session::give_up_flow_control()` before the session restart that the pause limit asks for, and logs one line (`flow control given up: ...`). The restarted session's Set Data Format omits the field, and so does every later one of that driver instance (`RMNetFlowControlRefused` 1), so a modem that never sends flow enable cannot keep the port cycling every 30 s.
- **Never run.** The driver's handling of QMAP flow commands (flow disable and enable pausing and resuming the uplink, the kept replies, the 30 s pause limit) has never run on hardware: no QMAP command has arrived in any run so far (`RMNetQmapCommands` 0), and no build before this one asked for them. Whether it sends them once asked, and how often, is what the hardware test has to show.

## Runtime findings (in-band flow control, 2026-11-14 20:36 to 22:29)

Branch `flow-control`, commit `1b47ab2`. Builds, each installed with `scripts/install-driver.sh` and loaded with one `AT+CFUN=1,1` (the modem returned every time, link up 34 to 37 s after the command): 317.12.36 (20:36, flow control asked), 317.12.42 (20:42, comparison build with `RMNetFlowControl` 0 in the working tree only), 317.12.45 (20:45, asked), 317.14.26 (22:26, comparison build again), 317.14.28 (22:28, asked; **the build running now**). Logs: `build/logs/driver-20261114-203615.log`, `driver-20261114-222505.log`.

**The request and the answer.**
- `data format: ... usable 1, flow control: last request asked 1, modem says 1`: this firmware accepts TLV `0x1A` = 1 and answers `0x1B` = 1. `RMNetFlowControl` 1 (so `CopyProperties` does return the personality key), `RMNetFlowControlAsked` 1, `RMNetFlowControlOn` 1, `RMNetFlowControlRefused` 0. On the comparison builds: `asked 0, modem says 0`, and all three values 0.
- After each load: both address families, `en33` first in neither `scutil --nwi` list, no new crash report, 5 of 5 pings in each family.
- **No QMAP command has arrived in any run** (`RMNetQmapCommands`, `RMNetQmapFlowDisable`, `RMNetQmapFlowEnable` 0; `RMNetUplinkPaused` 0), including 1 h 39 min of idle running on 317.12.45. So the driver's pause path, the kept replies, the 30 s pause limit, the fallback and the give-up rule have still never run.

**What a burst does, with the request and without.** The same test as on the hardening build: `scripts/uplink-burst.py en33` (1.84 MB of UDP to an address that answers nothing) with a ping every 0.2 s alongside, the port's counters sampled every 15 ms, and from 20:44 the modem's own byte counter (`AT+QGDNRCNT?`, one poll about every 0.6 s).

| Time | Flow control | Cell (PCI) | The port passed the burst in | The modem's counter | Pings |
|---|---|---|---|---|---|
| 19:35 (317.11.33) | not asked | 32 | not sampled | not polled | 20 of 20; up to 3.5 s late |
| 19:39 (317.11.33) | not asked | 32 | 475 ms | not polled | 30 of 30; up to 2.1 s late |
| 20:37 | asked, on | 893 | 80 ms | not polled | 30 of 30; 13 to 37 ms, none late |
| 20:44 | not asked | 32 | 707 ms | +1.64 MB by 1.4 s, then still for 7 s | 7 of 40; the rest unanswered within the run; two uplink transfers timed out (`0xe00002d6`) |
| 22:25:38 | asked, on | 32 | 85 ms | +1.84 MB by its first poll at 0.8 s | 40 of 40; 407 and 199 ms at the burst, otherwise as idle (18 to 331 ms on this cell) |
| 22:27:46 | not asked | 32 | 886 ms | +0.85 MB at 0.8 s, +1.49 MB at 1.4 s, +1.84 MB at 3.9 s | 39 of 40; up to 2.1 s late, in two groups |

- The last two rows are the controlled pair: the same cell, two minutes apart, the same code but for the personality key. Asked: the modem counted the whole burst sent within 0.8 s and no ping waited more than 0.41 s. Not asked: about 3.9 s, and pings waited up to 2.1 s.
- All six runs agree, across two cells and three hours. Every run without the request on PCI 32 was slow; once (20:44) the uplink stalled outright for several seconds and two transfers reached the 5 s timeout (`RMNetUsbBulkOutTimeouts` 2, `RMNetTxDropUsb` 2; the link recovered by itself, 3 of 3 pings 20 s later). No run with the request was slow.
- A real upload with the request on (20:39, PCI 893): one HTTPS POST of 3,000,000 random bytes to `mensura.cdn-apple.com/api/v1/gm/slurp`, bound to the port: HTTP 200; the port sent 3.13 MB within 1.25 s (up to 32 Mbit/s in a quarter second); the server's acknowledgements kept arriving until about 2.0 s after the start. Ping every 0.2 s alongside: 45 of 45, 13 to 68 ms. So the data is delivered, not thrown away, and small packets are not held up behind it.
- `AT+QGDNRCNT?` after the 20:37 burst and the upload read 4,953,858 bytes sent, against 5,049,655 on the port's output counter less the frames the driver does not forward: the modem counts what it is given as sent.

**What this shows and what it does not.**
- Asking for flow control makes this modem send an upload burst several times faster and stops small packets waiting seconds behind it. That is shown by one back-to-back pair on one cell and is consistent with five other runs.
- It does not come from the driver pausing: the modem sent no flow command at all. What the modem does differently inside when the host declares that it handles flow control is not known; the natural guess, that without the request the modem applies a slow internal flow control of its own to the USB data path, is only a guess.
- Not measured: a long upload, a download while uploading, and download speed with the request on (the capped tools refuse: their ceiling of 310,000,000 recorded bytes is reached). If the modem ever does send flow disable, the pause path runs for the first time; the give-up rule bounds the damage to one 30 s pause.
- The comparison builds' kept copies (`build/installed/RMNet-317.12.42.app`, `RMNet-317.14.26.app`) have the key at 0; they exist only because every activation keeps a copy.

**A loss of the network with the modem attached (22:25).** `AT+CFUN=0`, then `AT+CFUN=1` three seconds later (radio off and on; no USB re-enumeration; used here to make the modem choose a cell again). The session went `up -> backoff` and the link down at once; each redial reached `connecting` and failed (`call IPv4: failed, error 0xe, end reason 3`), back to `backoff`; with the radio on again the port was up 11 s later, with flow control asked and granted again. This is the first time design goal 5's "the network dropping the connection" was seen on hardware; it took the backoff and redial path that Core's tests cover.

**Data.** This stage moved about 10.8 MB over the port: four bursts (7.45 MB), the upload (3.21 MB, recorded by hand), pings and background. The usage file's total is 309,701,068 bytes.

## Text messages in the app, on the modem (2026-11-14 23:00 to 2026-11-15 00:10)

Branch `sms`, commit `a17f979`; installed as 317.16.8 at 00:08 on 2026-11-15 (`scripts/install-driver.sh`, one modem reboot, link up 34 s later, flow control on, no approval asked). Nothing under `driver/` or `core/` changed on this branch. The ledger with every result is `.superpowers/sdd/2026-11-14-sms-in-the-app/progress.md`.

**How the app reaches the modem.** The modem has two AT ports. The owner's console (`webui.py`) holds USB interface 2; the app opens interface 3 from user space with IOUSBHost (bulk IN `0x86`, bulk OUT `0x04`, found from the descriptors), for each operation, and closes it after. This works while the driver holds interface 4 and the console holds interface 2. The registry shows who holds an interface (`UsbExclusiveOwner`); a second open of interface 3 fails with `kIOReturnInternalError`, not exclusive access. In Swift the synchronous pipe call is `__sendIORequest(with:bytesTransferred:completionTimeout:)`. The port echoes every command; the app uses the echo to tell an answer from late bytes of an earlier command. Never run `at.py` while the driver is attached: it sets the USB configuration.

**The modem's SMS state.** Store "ME", 255 entries; PDU mode (`+CMGF: 0`); `+CNMI: 2,1,0,0,0`; the service centre is set. Arrivals are announced with `+CMTI: "ME",<index>` on the console's port (interface 2), not on interface 3, so the app finds new messages by listing. `AT+CMGL=4` marks what it lists as read on the modem. Deleting a missing index answers `+CMS ERROR: 321`.

**IMS is needed on 5G standalone.** With `+QCFG: "ims",0,0` the modem refused a send at once with `+CMS ERROR: 350`, and delivered nothing: the network had been holding two days of the owner's messages. After `AT+QCFG="ims",1` (the owner's yes; a lasting setting, undone with `AT+QCFG="ims",0`) and a reboot, the "ims" profile (cid 2) came up, eleven stored parts arrived at once, and sending worked. The modem still reads `"ims",1,0` (its voice flag stays 0).

**What was seen.**
- Without the network (23:50): seven SMS-DELIVER PDUs built by an independent generator were written into the store as received (`AT+CMGW=<len>,0`, through the app's own send-prompt path). The service listed four messages with exactly the generator's texts: Chinese with an emoji, a three-part UCS-2 message written in the order 3, 1, 2, a 7-bit message with extension characters from an alphanumeric sender, and a two-part 7-bit message with a negative time zone. Deleting the three-part message removed its three entries and left the rest; the store was emptied again.
- With the network (23:34): `RMNet sms send 10086 10086` (the owner's test) printed "sms: sent to 10086 in 1 part(s)"; the reply, a two-part message, was listed five seconds later. `sms list` showed 13 real messages, single and two-, three- and four-part, all readable, with parts of different messages interleaved in the store. A four-part message arriving at 00:03 was listed as unread with its parts joined (the owner's own run).
- After the install (00:09): `/Applications/RMNet.app/Contents/MacOS/RMNet sms list` printed "sms: 16 message(s), 32 of 255 stored parts used"; `status --json` gave `Connected` with one entry, 317.16.8; both address families; `en33` first in neither `scutil --nwi` list; no new crash report; pings 3 of 3.

**Not seen.** The window's `Messages` tab (nobody but the owner can look at it); a send from the window; quitting during a send; a multi-part send; a full store; the app recovering a modem left at the `> ` prompt (only the collector's checks cover it).

## Runtime findings (measurements with the new budget, 2026-11-15 00:29 to 00:45)

Build 317.16.8 (main's driver code: flow control asked and granted, transmit queue of 64), cell PCI 893 on band n41, RSRP -88 to -92, SINR 14 to 15, idle pings 20 to 60 ms. The owner added 1 GB to the testing budget at about 00:19. `scripts/measure.sh` got two longer modes for this (`down-long`: four downloads, stop at 320 MB or 8 s; `up-long`: four uploads, stop at 60 MB or 8 s) and now waits for the port's counters to settle before it records a run. Each figure is from the port's own byte counters; the "gate figure" is the mean from 1.0 s after traffic starts to the last sample.

| Time | Mode | Moved | Gate figure | Best second | Ping every 0.2 s alongside |
|---|---|---|---|---|---|
| 00:29:44 | `up` (stop at 10 MB) | 17.8 MB out | 25.0 Mbit/s over 2.8 s | 33.7 Mbit/s | 45 of 45, 12 to 148 ms |
| 00:33:52 | `down-long` (8 s) | 145.6 MB in | **154.8 Mbit/s** over 6.7 s | 177.2 Mbit/s | not run |
| 00:44:20 | `up-long` (8 s) | 34.3 MB out | 33.6 Mbit/s over 6.4 s | 56.6 Mbit/s | 70 of 70, 11 to 122 ms |

**The 8-second download** is the design's own test. 154.8 Mbit/s is below its 200 Mbit/s line. Second by second: 77, 135, 139, 174, 173, 153, 135, 163 Mbit/s. The driver during the run: 5,311 transfers carrying 101,641 packets (about 19 per transfer, about 27 KB of the 31,744-byte read); handler time 421,529 µs in all, about 79 µs per transfer, which is 5.2 % of the 8.14 s; `RMNetRxHandlerMaxUs` 780; `RMNetRxLagMaxUs` 1,778; `RMNetRxFullTransfers` 0 (no read came back full, so the modem never had more waiting than one read takes); `RMNetRxDropNoPacket`, `RMNetRxDropBadQmap`, `RMNetRxDropTooBig`, `RMNetUsbBulkInErrors` and `RMNetUsbRecoveries` all 0. Nothing there shows the driver limiting the run. What another driver would have got from the same cell in the same half hour was not measured.

**Uploads with flow control on.**
- The rates are in the range seen before the change (37.9 Mbit/s and a best second of 43.2 on 316.19.56 at 16:27 on 2026-11-14, on a cell that was not recorded): 25.0 and 33.6 Mbit/s here, with a best second of 56.6. So neither the 64-entry queue nor the flow-control request shows as a loss of upload speed. The runs differ in cell and hour, so no finer comparison is made.
- Small packets are no longer held up: during 4 s and 8 s of upload every ping was answered, the slowest in 148 and 122 ms. Without the request, on 2026-11-14, pings behind a 1.84 MB burst waited 2 to 3.5 s.
- `RMNetTxHolds` rose by 121 in the short run and by 465 in the long one (it rose by 2 for a whole burst before the request), with `RMNetTxDropBusy`, `RMNetTxDropUsb`, `RMNetTxDropRecovering`, bulk OUT errors and timeouts all 0, `RMNetTxPending` and `RMNetPacketsHeld` 0 afterwards, and `RMNetQmapCommands` still 0. So with the request the modem takes an upload at about the rate it can send it: the driver's eight uplink buffers stay in flight, the frames wait in the transmit queue and in macOS's own interface queue, and small packets pass between them. This is the controller's reading of the hold count and the ping times; what the modem does inside is not visible.

**Not measured.** A download while an upload runs; the same tests on PCI 32; a second 8-second download (one run on this cell does not measure the driver: 278 and 37 Mbit/s were seen four minutes apart on 2026-11-14).

**Data.** The three runs moved 199,492,768 bytes (recorded; the usage file's total is 509,193,836). With traffic the usage file does not record, about 516 MB of the 1,400 MB is used.

## Runtime findings (two-way load, 2026-11-15 01:37)

Build 317.16.8 (flow control on, transmit queue of 64), cell PCI 893, RSRP -91, SINR 14, idle pings 21 to 38 ms. `scripts/measure.sh en33 both`: four downloads and four uploads started together, stopped by the 8 s time limit; samples `build/logs/measure-20261115-013715-both.samples`. Each direction's figures include the other direction's acknowledgements (a few percent; the output says so).

| | Two-way, 01:37 | One-way, 00:33 and 00:44, same cell |
|---|---|---|
| Download, gate figure | **143.2 Mbit/s** (best second 161.8) | 154.8 Mbit/s (best second 177.2) |
| Download, each second | 134, 143, 161, 128, 152, 144, 161, 118 | 77, 135, 139, 174, 173, 153, 135, 163 |
| Upload, gate figure | **30.4 Mbit/s** (best second 53.9) | 33.6 Mbit/s (best second 56.6) |
| Upload, each second | 15, 23, 22, 19, 56, 35, 56, 9 | |
| Moved | 145.1 MB in, 28.7 MB out | 145.6 MB in; 34.3 MB out |

- **A busy uplink does not hold the download back.** Both directions kept close to what each got alone a few minutes earlier (download about 8 % less, upload about 10 % less, within the run-to-run spread of this cell). Two of the four downloads reached their own 40 MB limit before the stop, so the download's last seconds ran on fewer streams: the download figure is if anything a little low.
- **Small packets during two-way load:** a ping every 0.2 s, 75 of 75 answered; during the 8 s of load the median was 78 ms and the slowest 202 ms, against 21 to 38 ms before and a median of 19 ms after. Busier than during an upload alone (slowest 122 ms), and nothing like the 2 to 3.5 s waits seen without flow control.
- **The driver:** 6,616 receive transfers carrying 111,605 packets; handler time 559,798 µs in all (about 85 µs per transfer, 6.8 % of the 8.2 s); `RMNetRxHandlerMaxUs` 3,338 and `RMNetRxLagMaxUs` 6,049 µs, both several times their one-way values; one read came back full (`RMNetRxFullTransfers` 1); `RMNetRxDropNoPacket` 0, so the receive side never lacked an empty packet. *(Corrected 2026-11-15 02:00: this line first read `RMNetRxStock` going from 24 to 3 as the stock running low. It is not: the stock is refilled in batches of up to 32 only when it reaches 0, so its value is just the position in the current batch. A shortage shows only as `RMNetRxDropNoPacket`.)* Transmit: 36,764 packets, `RMNetTxHolds` +75, every drop and error counter 0, nothing pending afterwards, `RMNetQmapCommands` 0.
- **What it means for the pool-margin concern** (follow-ups, "Pool margin"): under the heaviest load the port has carried, no packet was dropped for want of an empty one. No evidence of pressure on the pool. *(Corrected 2026-11-15 02:00; the first version of this line drew the opposite conclusion from the stock's value.)*

**Data.** 173,836,279 bytes recorded (the usage file's total is 683,030,115). With traffic the usage file does not record, about 690 MB of the 1,400 MB is used.

## The owner's steps (2026-11-15, about 01:50, on 317.16.8)

The owner wrote: "i tested 1. 2. 3. 4. 5. all seems good", meaning the owner steps then listed in the README (now `docs/status.md`, "Owner steps"): the window looked at; the cable pulled while a ping ran and plugged back; the port switched off and on under Network → RM520N-GL; `RM520N-GL` seen offered under Internet Sharing (sharing not turned on); `Remove…` in the window with the modem attached, then `Install`, then a replug. No driver log was running, so what the stopping instance did with its USB requests in flight was not captured; the result was read afterwards: one entry, 317.16.8, activated and enabled; a new driver instance started at 01:53:15; link up with both families; pings fine; no new crash report; the app's headline `Connected`; SMS listing working. With this, every line of the design's "Done means" is shown except the throughput line.

## Runtime findings (same-half-hour comparison with qmi-darwin, 2026-11-15 02:07 to 02:13)

> **Correction (2026-11-15, 02:48).** qmi-darwin's figures in this section are double. macOS counted every packet received on `utun12` twice in `netstat -I`, which `measure.sh` reads; qmi-darwin's real rate at 02:08 was about **153 Mbit/s**, not 305.9 (best second about 186, not 372.7; about 155 MB moved, not 309.2). Our driver's figures are right (`en33`'s counters equal the driver's own). So our driver was about 25 percent *faster* than qmi-darwin on the same cell, and the throughput line is met by its qmi-darwin test. The conclusions below ("ours is 63 percent", "the cell can deliver more than our driver takes", the flow-control lead as a reason for a gap) rest on the wrong figure and do not hold. The evidence is in "Runtime findings (receive speed, and qmi-darwin's double-counted interface)".

The design's throughput line allows "within 15 percent of qmi-darwin measured within the same half hour". With the owner at the Mac: our driver measured, then removed (`Remove…`, a replug), qmi-darwin started by the owner (`sudo qmictl run --pdn internet:1:0x81 --scoped`, release build of 0.17.2 at `fe6f25b`), measured, stopped, our driver reinstalled (`Install`, a replug; link up 12 s after the replug).

| | Our driver, 317.16.8, `en33` | qmi-darwin, `utun12` |
|---|---|---|
| Start | 02:07:26 | 02:08:53 |
| Cell | PCI 893, RSRP -92 to -94, SINR 16 | PCI 893, RSRP -92, SINR 14 to 15 |
| Gate figure (1.4 s to 8.0 s) | **193.3 Mbit/s** | **305.9 Mbit/s** |
| Best second | 212.5 Mbit/s | 372.7 Mbit/s |
| Each second | 109, 158, 183, 204, 198, 207, 201, 197 | 306, 324, 363, 353, 358, 334, 181, 235 |
| Moved | 182.6 MB in | 309.2 MB in |

- **Ours is 63 percent of qmi-darwin's figure: the line is not met**, by either of its two tests. Our run levels off near 200 Mbit/s after its third second; qmi-darwin's runs well above that from its first second on the same cell a minute and a half later. This overturns the reading of the 00:33 run ("the rate is what the cell delivered"): the cell can deliver more than our driver takes.
- Our driver's counters during its run: `RMNetRxDropNoPacket` 0, `RMNetRxFullTransfers` 0, bulk IN errors 0, recoveries 0. Nothing failed; the driver simply did not go faster.
- **What is the same** (from qmi-darwin's source, read for parameters only): both request raw IP, QMAP both ways, downlink at most 32 datagrams and 31,744 bytes per transfer, uplink 32 datagrams and 16,384 bytes, and both keep 32 bulk IN reads in flight.
- **What differs:**
  - our driver asks for in-band flow control (`RMNetFlowControl` 1, granted); `qmictl run` leaves the field out;
  - qmi-darwin hands each IN transfer to a `utun` with one batched system call; our driver copies each datagram into a packet buffer, adds an Ethernet header, and hands the packets to macOS through the DriverKit queues.
- **The flow-control lead:** every download measured since the request was added stayed at or under about 200 Mbit/s (154.8 at 00:33, 193.3 at 02:07, 143.2 with an upload at 01:37); the last downloads without it, on 316.19.56 at 16:27 on 2026-11-14, gave 232 to 303 Mbit/s per sample and a best second of 278. Those runs were hours apart, so this is a lead, not a finding. A download with the key at 0 and at 1 within minutes on the same cell would decide it (two installs, two modem reboots, two capped downloads).

**Data.** The two runs moved 491,774,999 bytes recorded (the usage file's total is 1,175,822,947). With traffic the usage file does not record, about 1,183 MB of the 1,400 MB is used and about 217 MB left; the scripts' ceiling (1,300,000,000) now refuses another `down-long` run.

## Runtime findings (flow control off against on, download, 2026-11-15 02:17 to 02:20)

> **Correction (2026-11-15, 02:48).** "qmi-darwin's 306 to 373" below were double counts (real: about 153 to 186; see the correction in the section before). The conclusion "the host path is the stronger lead" is withdrawn: there was no gap to explain. Full 8-second downloads later the same night gave 196.5 Mbit/s with flow control off and 183.9 to 197.4 with it on, so flow control costs nothing measurable either; these 50 MB runs ended while TCP was still ramping. See "Runtime findings (receive speed, and qmi-darwin's double-counted interface)".

To test the lead from the comparison with qmi-darwin: one capped download (`scripts/measure.sh en33 down`, stop at 50 MB) with the build as committed (flow control asked, 317.16.8), then a build with `RMNetFlowControl` 0 in the working tree only (317.18.17, one modem reboot), then the committed build back (317.18.19, one more reboot; flow control asked and granted again). Same cell throughout (PCI 893, RSRP -89 to -90, SINR 12 to 15).

| | Flow control on, 02:17:41 | Flow control off, 02:18:59 |
|---|---|---|
| Best second | **159.4 Mbit/s** | **190.2 Mbit/s** |
| Gate figure | 146.8 Mbit/s over 1.39 s | 179.4 Mbit/s over 1.69 s |
| Each 0.28 s sample | 107, 205, 104, 168, 161, 154, 133, 143, 147, 158 | 57, 93, 107, 124, 134, 146, 169, 175, 205, 187, 194 |
| Moved | 53.1 MB | 57.9 MB (one stream at its own 15 MB limit) |

- Without the request the run was faster by about a fifth in its best second, and it was still rising when the 50 MB cap stopped it; with it the rate hovered around 150 from the start. So the request may cost some download speed. One pair of short runs cannot say how much.
- **Neither came near qmi-darwin's 306 to 373 on the same cell half an hour earlier.** Flow control is therefore not the main reason our driver levels off near 200 Mbit/s; the host path is the stronger lead (a copy of every datagram, an Ethernet header, the DriverKit RX queues), against qmi-darwin's one batched `utun` call per transfer.
- After the last reboot the first IPv4 ping was sent before the port had its IPv4 address ("No route to host"); a few seconds later the address was there and pings worked.

**Data.** The two runs moved 111,344,554 bytes recorded (the usage file's total is 1,287,167,501). About 1,295 MB of the 1,400 MB is used, about 105 MB left; the scripts' ceiling (1,300,000,000) now refuses every capped run.

## Runtime findings (receive speed, and qmi-darwin's double-counted interface, 2026-11-15 02:31 to 02:52)

The owner added 5 GB at 02:24 ("start fixing. i'm giving you 5gb over next two hours") to close what looked like a gap to qmi-darwin. Diagnosis came first; it found no gap. Every run is `scripts/measure.sh <port> down-long` (4 streams, 8 s, capped), on build 317.18.19 or 317.18.40 (the committed code, flow control asked and granted) unless a row says otherwise.

| Time | What changed | Gate figure | Best second | What else was seen |
|---|---|---|---|---|
| 02:31 | nothing; pings and `nettop` alongside | 185.6 | 211.0 | receive windows 2.6 to 4.2 MB, round trip about 33 ms; pings rose to 77 to 214 ms in the first two seconds only |
| 02:32 | `netstat -s` before and after | 186.7 | | 123,639 frames on `en33` but 26,582 IP packets counted: macOS merges about 4.6 TCP segments per packet on this port (`kern.skywalk.flowswitch.rx_agg_tcp` 16384); about 8,400 packets out |
| 02:33 | two runs at once, 8 streams | 208.2 in total | 225.6 | the total stays near 200, not each stream; about 880 transfers a second of about 28 KB |
| 02:36 | `rx_agg_tcp` 0 (set by the owner, restored to 16384 afterwards) | 197.4 | 212.5 | 158,584 IP packets for 136,759 frames: no merging; 12,461 acknowledgements. Merging is not the limit. |
| 02:38 | flow control off (317.18.37, `RMNetFlowControl` 0 in the working tree only) | 196.5 | 218.5 | flow control is not the limit |
| 02:39 | `nettop` per connection every second (flow control off) | 189.2 | | out of order 0, retransmitted 0, duplicates 0 or about 800 bytes, round trip 18 to 22 ms, receive buffers 1.3 to 2.5 MB |
| 02:41 | 317.18.40, flow control on; cell PCI 32, RSRP -91, SINR 9 | 183.9 | 206.4 | 6,327 transfers, 126,269 datagrams (about 28.8 KB and 20 datagrams a transfer) |

- **No loss, no reordering, no window or round-trip limit, and the driver busy about 6 percent.** The senders settle near 200 Mbit/s in total with no loss and little queue, which is how a rate-estimating sender behaves at a bottleneck it does not own. Nothing measured from the Mac points at the host; the plateau is what the cell gave that night as far as anything shows. (On 2026-11-14 at 16:27 the same port had a best second of 278.)
- `RMNetRxFullTransfers` counts reads of exactly 31,744 bytes. The modem packs whole datagrams, so a "full" transfer is about 21 datagrams and rarely reaches 31,744; a count of 0 says little. The transfers averaged 19.6 datagrams and 28 KB, close to full.

**qmi-darwin, measured again** (started by the owner at about 02:46 after `Remove…` and a replug; the first start at 02:44 got IPv6 only, "ipv4 failed: 3GPP #36", while the old call was still being torn down; the second got IPv4 on `utun12`):

| Time | Cell | `measure.sh` printed (from `netstat -I utun12`) | qmictl's own `usb_in_bytes` | Real rate |
|---|---|---|---|---|
| 02:47:13 | PCI 893, RSRP -90 to -91, SINR 16 | 292.9 Mbit/s, 299,539,452 bytes in, 210,724 packets | 149,980,756 bytes, 105,362 packets, 5,639 transfers | about 146 Mbit/s |
| 02:50:18 | PCI 893 | 273,261,744 bytes in | 136,826,352 bytes; the four TCP connections' own byte counts at their last sample 125,396,561 | about 137 Mbit/s |

- **macOS counted every packet received on `utun12` twice.** Exactly twice the packets that qmictl delivered; interface bytes / modem-side bytes 1.997. Pings through `utun12`: 10 replies added 20 received packets to the interface, 20 added 40, and no ping saw a duplicate reply. So the traffic is delivered once and only the interface counters double. Whose fault it is (macOS's accounting on the batched `utun` write path qmi-darwin uses, or the way qmi-darwin calls it) is not proven; it does not change the result.
- **`en33`'s counters are right:** its input packets equal `RMNetRxPackets` exactly (140,837 and 140,837 in the 02:33 run).
- **Corrected comparison.** qmi-darwin 0.17.2: about 153 (02:08, PCI 893), 146 and 137 Mbit/s (02:47 and 02:50, PCI 893, SINR 16). Our driver: 193.3 (02:07, PCI 893), 183.9 to 197.4 in the runs above (02:31 to 02:41). Ours is about 25 percent faster, also when qmi-darwin had the better cell. The design's throughput line ("at least 200 Mbit/s, or within 15 percent of qmi-darwin measured within the same half hour") is met by its second test; the 200 Mbit/s test alone is not.
- **Ruling: no driver change for receive speed.** The gap it was meant to close does not exist.
- The ratio check above is the one to repeat before trusting `measure.sh` on any interface other than `en33`.

**Data.** The usage file records 2,093,606,693 bytes since 02:24 (total 3,380,774,194; the scripts' ceiling is 6,300,000,000). It over-records: the two runs at 02:33 each recorded the port's whole traffic (about 202 MB counted twice) and the two qmi-darwin runs were recorded at their doubled counts (about 286 MB too much), as was the 02:08 run (about 155 MB too much). With pings and background traffic, about 2.75 GB of the 6.4 GB allowed for testing is really used, about 3.65 GB left. The usage file is not edited; it errs on the safe side.

## Runtime findings (cleanup build, 2026-11-15 04:43 to 04:47)

Build 317.20.43, from `cleanup` at `bee6b41` (plan `docs/superpowers/plans/2026-11-15-cleanup.md`): the address helpers moved into Core, `CoreHost` reaches USB through the `UsbPort` interface, the wake-retry and no-result data-format log lines changed, and the unused DNS slot of a one-server settings reply is zeroed. Installed with `scripts/install-driver.sh` (its new kept-app check passed: only 317.18.40 was listed and its app is kept), loaded with `AT+CFUN=1,1` at 04:44:05, under the shared modem lock.

- The port was up in both families 30 s after the reboot, on the new build (the running driver's CDHash matches the installed one). `RMNetFlowControlOn` 1, `RMNetFlowControlRefused` 0.
- The moved helpers print as before: `RMNetIPv4 = 10.93.33.100/29 gw 10.93.33.101`, `RMNetIPv6 = 2001:db8:8ae9:25b5:b1dc:dffc:6574:41f1/64`. The driver's log lines were not captured (`log show` keeps none of the dext's default-level lines; `scripts/driver-log.sh` must run before the event).
- Pings 3 of 3 in each family; `sms list` works (29 messages, 74 of 255 parts); no new crash report.
- `scripts/measure.sh en33 up`: **23.0 Mbit/s** (best second 24.8), 20.0 MB moved, `RMNetTxHolds` 0 → 67, no drop. `scripts/measure.sh en33 down`: **58.4 Mbit/s** (best second 93.2), 53.0 MB moved. Cell PCI 32, RSRP -97, RSRQ -11, SINR 4 (weaker than every earlier run). The driver's receive work stayed what it was: about 76 µs per transfer, 14.5 datagrams per transfer, `RMNetRxDropNoPacket` 0; no error or drop counter moved except `RMNetTxDropFiltered` (multicast, by design). `AT+CFUN=0` then `AT+CFUN=1` re-selected the same cell (SINR 5), so a second download was skipped. The low download is the cell's: nothing on the receive path changed in this build, and the driver was no busier per transfer.
- The radio cycle took the link down and up once (`RMNetTxDropLinkDown` 11, frames sent while it was down); the port came back with new addresses in both families within 8 s.

**Data.** 72,994,373 bytes recorded for the two runs (usage file total 3,453,768,567; the scripts' ceiling 6,300,000,000). With pings and the radio cycle, about 75 MB of the owner's allowance, about 3.57 GB left of 6.4 GB.

## Runtime findings (serial ports, 2026-11-15 04:50 to 04:56)

Build 317.20.51 (`serial-ports` at `72d91a6`, which contains `main` at `61e2941`), installed with `scripts/install-driver.sh` over 317.20.43 and loaded with `AT+CFUN=1,1`; the coordinating session's modem lock was held from 04:50 to 04:55:50. Log: `build/logs/driver-20261115-045059.log` (in the `serial-ports` worktree).

**Loading.** After `activate` the new serial personalities did not attach to the free interfaces 0 and 1: the old entry stayed `terminating for upgrade via delegate` until the modem re-enumerated, and then all three instances of the new build started together. Link up 38 s after `AT+CFUN=1,1`.

**Attachment and names** (6.8 questions 1, 3 and 4):
- `RMNetSerial` (`IOUserSerial`) on `IOUSBHostInterface@0` and `@1`, `RMNetDriver` on `RmNet@4`, nothing on interfaces 2 and 3 (the console's libusb client came back on 2 a little later).
- `IOTTYBaseName` `RM520N-GL-DIAG` and `RM520N-GL-NMEA`, `IOTTYSuffix` empty: our names won over `IOUserUSBSerial`'s `usbserial-...`. Devices `/dev/cu.` and `/dev/tty.RM520N-GL-DIAG` and `-NMEA`, mode `crw-rw-rw-`, root:wheel.
- Three processes of the dext, one per instance (`ps`), so the serial instances do not share `RMNetDriver`'s process.
- The serial instances' `serial start` and `started on interface` lines of the first load were lost, as `RMNetDriver`'s own `init` and `Start` lines were (the stream loses lines around a load); at the second load (04:54:48) both came: `serial RM520N-GL-DIAG: started on interface 0`, `serial RM520N-GL-NMEA: started on interface 1`. So `CopyProperties` and the descriptor read answer before the superclass's `Start`.

**Calls on open and close** (6.8 questions 2 and 5), the same on every open:
- Open: `HwProgramMCR(1, 1)` (SET_CONTROL_LINE_STATE status `0x0`), then `HwActivate` (`0x0`), then the first `HwResetFIFO` (tx 1, rx 0), `HwGetModemStatus`, `HwProgramFlowControl` (arg 0, XON 0x11, XOFF 0x13), `HwProgramBaudRate` 9600 and `HwProgramUART` (9600, 8 data bits, 2 half stop bits, parity 1), within 2 ms.
- Close: the first `HwSendBreak(0)`, `HwProgramMCR(0, 0)` (`0x0`), `HwDeactivate` (`0x0`).
- So the modem accepts the control request before `HwActivate`: the interface is open by then. Whether NMEA needs DTR at all was not tested.
- A fresh port's settings had `ECHO` and `ICANON` off and `CLOCAL` off; `RMNet gps` sets `CLOCAL`, and the setting stays on the port for the next opener.

**NMEA.** `AT+QGPSCFG="outport"` answers `usbnmea`. With `AT+QGPS=1` (04:53:07), a 15-second raw read got 1,962 bytes: `GPGGA`, `GPGSA`, `GPRMC` and `GPVTG` once a second each, every checksum valid, `RMC` status `V` and `GGA` quality 0 throughout, no `GSV` (no satellites in view). `RMNet gps 20` printed `gps: no fix after 20 s (104 sentences, 0 satellites in view)` and `RMNet gps 3` the same for 32 sentences, exit 1; at four sentences a second both counts are above what that time delivers, so the first read after an open returns a few seconds of sentences sent before it. Two readers on the port at once split the bytes and each saw broken sentences. Whether an antenna is attached is not known; no fix was seen.

**DIAG.** Writing `00 78 F0 7E` (command 0x00, version) to `/dev/cu.RM520N-GL-DIAG` gave a 58-byte answer starting `00` and ending `7E`, with the firmware's compile and release dates in it; the same after the second load.

**Re-enumeration with the NMEA port open** (04:54:33, `AT+CFUN=1,1` with a raw reader and `RMNet gps 60` both reading): both readers ended with `ENXIO` (`Device not configured`); `RMNet gps` printed `gps: reading the NMEA port failed after 9 s: Device not configured`, exit 1. In the log, the DIAG instance stopped, then the NMEA port's close sent `HwProgramMCR(0, 0)`, which failed with `0xe00002d7` (`kIOReturnOffline`, logged and ignored), `HwDeactivate`, its stop, and `RMNetDriver`'s usual stop sequence. New instances of all three started 10 s later; the ports, `en33` (IPv4 and IPv6, pings 3 of 3 each), `sms list` and the console came back. No crash report. GNSS was off after the reboot (`AT+QGPS?` answered 0), as the owner wanted, so no `AT+QGPSEND` was sent.

**Not seen:** a fix; DTR's effect on NMEA output; a DIAG tool beyond the version request; sleep and wake with the serial instances; a serial instance failing while `en33` carries traffic.

**Data.** Pings and SMS listings only; no measurement was run.

## Runtime findings (modem controls in the app, 2026-11-15 03:40 to 06:01)

Branch `app-controls`, unsigned app built from the worktree (`build/xcode/Debug/RMNet.app`); the installed driver (317.20.51 at the end) was not changed. Every command that changed the modem ran under the shared modem lock and was put back before the lock was released, and `en33` answered three pings in each family (223.5.5.5 and 2400:3200::1, bound to the port) after each.

**The AT commands, read only (03:40, firmware `RM520NGLAAR03A04M4G_01.204.01.204`).** Every command answered in about 60 ms. `AT+CMEE?` is 1. `AT+CGAUTH` is not supported (`ERROR`), so a profile's user, password and authentication go through `AT+QICSGP=<id>[,…]` (profiles 1 to 16), which shows the same profiles as `AT+CGDCONT?`. `AT+QSPN` gives the operator's names in UCS-2 hex (alphabet 1). On 5G SA only `AT+C5GREG?` is registered (`AT+CEREG?`, `AT+CGREG?`, `AT+CREG?` read 0). `AT+QCAINFO` showed n41 with n28 aggregated. The SIM is ready, its PIN lock off (`AT+CLCK="SC",2` is 0), 3 PIN and 10 PUK attempts left (`AT+QPINC?`).

**A stored password is shown in clear, and a password with no authentication becomes CHAP** (05:22, profile 4, `CMWAP`, used by nothing). `AT+QICSGP=4` read back a test password exactly as set, so the app keeps the current password when only another field changes. The modem had stored the password sent with authentication 0 (none) as CHAP (2) on its own: the service's read-back check reported the change as not matching. The app now refuses a user name or password when the authentication is none. Profile 4 was put back; its `AT+CGDCONT?` line was the same byte for byte.

**LTE SINR.** `AT+QENG="servingcell"` gives LTE SINR as a raw value; the manual's conversion (dB = raw × 2 − 20) matched `AT+QSINR` on band 40 (raw 21, 22 dB).

**Radio** (`RMNet radio off|on`, 05:48): off took the driver to `backoff` and `RMNet network` showed `none (radio off)`; on registered (5GS) 1 s after `AT+CFUN=1` answered, and the driver was up with its addresses 6 s after the verb began.

**Network mode** (`RMNet mode lte`, then `auto`, 05:48 to 05:49): LTE (band 40, registered on EPS) within 1 s; back to 5G SA (n41) within 5 s of `auto`. The driver's connection stayed up through both, with the same addresses.

**APN** (`RMNet apn set --apn cmnet`, then the printed put-back command, 05:49): each redial (radio off, change, radio on) registered within 3 s; the driver was up 11 to 12 s after the verb began, with new addresses; profile 1's `AT+CGDCONT?` line afterwards was the same byte for byte as before.

**The window** (05:57 to 06:01). The Mac gives this session no screen recording, so the window was checked in two ways. The unsigned app, opened with `open -n`, showed one window of 480 by 472 points (the window list). A scratch program drove the window's own controller (`ModemController`) with the real service and drew the real `Network` and `SIM & APN` tabs off screen after each step: the live values; a mode change to LTE with `Put Back` offered, then put back to automatic; `Apply…` of the APN `cmnet` with the redial, then `Put Back…`; the radio off and on. Each did on the modem what the verbs did, and each was put back. The confirmation dialogs and the tab strip were not seen on screen.

**SIM.** `RMNet sim unlock` with the SIM ready says it does not ask for a PIN and sends nothing. No PIN or PUK was sent at any time.

**Data.** Pings only.

## Changed in code, not yet on hardware (driver features, 2026-11-15)

Built and tested (`make driver`, `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test`) and written before any of it had run. Plan: `docs/superpowers/plans/2026-11-15-driver-features.md`, Task 1 (the items below up to "Never run") and Task 3 with its fix round 1 ("Opt-in USB idle suspend", after them).

- **A held uplink drain restarts when the uplink is usable again.** `UsbIoListener` gains `on_uplink_usable`. `UsbIo` raises it at the end of `bulk_out_complete` only: for a failed transfer that leaves no recovery under way (a timeout or a stray abort, neither of which halts the endpoint), and when a recovery ends there with a successful `ClearStall`; only while running, not held, not failed and not recovering, and never from inside `send`, `send_uplink` or `resume`. The driver (`OnUplinkUsable`) then, as `OnBulkOutDone` does after a success, first lets `CoreHost::uplink_usable` give the free buffers to kept QMAP command replies, oldest first, and then drains at once if the drain waits for an uplink buffer (`txWaitUplink`) or is held (`txHeld`; `DrainTx` still holds while asleep, while a wake's resume is pending and while the modem pauses the uplink). Before, a failed completion and the end of a recovery left both the kept replies and a held drain to the next 100 ms tick ("Runtime findings (uplink hold)"). A successful completion sends kept replies and drains from `OnBulkOutDone` as before. New log line: `first uplink usable callback: drain waiting for a buffer|held|not held`.
- **Where the tick stays the fallback.** A recovery whose `ClearStall` fails raises nothing: the pipe may still be halted, and the next tick drains, as before. A recovery that a wake's `resume` finishes raises nothing either: the wake's session restart then drops the frames queued during the sleep as link down, as before. And when the completion that raises it also found the uplink stuck (`on_uplink_stuck`), the driver does nothing with it: the session restart that follows the completion takes the link down and `ApplyCore` drops the kept frames as link down, rather than putting another transfer on the stuck endpoint, which would count as the first stall of the restarted session.
- **A link down drains at once.** After a link down, `ApplyCore` drains if the drain still waits for an uplink buffer (no pause was lifted, which drains already): the kept frames go through `CoreHost::transmit` and are dropped as link down (`RMNetTxDropLinkDown`) at once instead of on the next tick.
- **Counters for the timer waits** (published with the others, once a second when changed): `RMNetUplinkUsable` (callbacks received, the ones ignored for a stuck uplink included); `RMNetTxCompleteRefused` and `RMNetRxCompleteRefused` (packets the TX and RX completion queues refused, each packet once however often it is offered again); `RMNetTickTxDrains` (ticks that drained because the drain was held, waited for an uplink buffer or had sent packets left to complete); `RMNetTickRxFlushes` (ticks that found refused receive packets still waiting, counted before the tick's first flush). What to read on hardware: frames held for want of room in `txDone` need TX refusals first, and receive packets wait for a tick only after an RX refusal, so if both refusal counters stay 0 under load, neither of the two remaining timer waits happens. `RMNetTickTxDrains` also moves when a tick finds an upload's drain waiting for a buffer, and on every tick of a QMAP pause (`txHeld`), so on its own it does not show the `txDone` wait.
- **Never run.** None of this has run on hardware. Failed uplink transfers are rare: the notes record two timeouts (20:44 on 2026-11-14, without flow control) and no bulk OUT recovery (`RMNetUsbRecoveries` 0 wherever it is given); whether the completion queues ever refuse packets is what the new counters are for.

**Opt-in USB idle suspend (Task 3, and its fix round 1).** Quectel's Linux driver guide (chapter 5) turns on USB auto suspend and remote wakeup. Ours keeps 32 bulk reads and the interrupt read posted, so the link never idles: in the controller's measurement of 2026-11-15 04:56 to 04:58 on build 317.20.51, the modem's `CurrentPowerState` (`ioreg -p IOUSB`) was 2 (on) in all 60 samples of an idle minute. Idle suspend is now available, but off unless a personality asks for it. No shipped personality does.

- **The key.** `RMNetIdleSuspendMs` is an integer in milliseconds, read like `RMNetProfile` and `RMNetFlowControl` and taken by `idle_suspend_key`, with the same rules in `RMNetDriver` and `RMNetSerial`:
  - Absent, 0, not an integer, or negative is off. The sign is the top bit of the `OSNumber`'s own width, and a plist integer is 64 bits, so -1 arrives as all ones.
  - 1 to 49 is raised to 50, because `IOUSBHostFamily.h` recommends 50 ms or more for an interface and for IN endpoints.
  - Above 60000 is taken as 60000.
  - One log line says how the key was taken: `RMNetIdleSuspendMs: <how>` (`idle_key_text`). For example `10 is below 50; raised to 50 ms` or `-1 is negative; idle suspend off`.
- **The decision** lives in `driver/idle_suspend.h`, which is DriverKit-free and host-tested in `tests/driver/test_idle_suspend.cpp` (14 tests):
  - `idle_suspend_key` and `idle_key_text` take and describe the key.
  - `idle_suspend_wanted` allows the calls only with a timeout and remote wakeup.
  - `idle_suspend_state` maps the timeout, the remote wakeup bit and the calls' result to the published text and the timeout in force.
  - `port_suspended` reads a port status.
  - `power_call` and `low_power_ask_after` say what a driver makes of a `SetPowerState` call.
- **At `Start`** (`RMNetDriver`, `SetUpIdleSuspend`, right after `OpenUsb` and the serial number, before `UsbIo::start`). The driver reads bit 5 of the configuration descriptor's `bmAttributes` (`ReadRemoteWakeup`, `kIOUSBConfigurationDescriptorAttributeRemoteWakeCapable`). It does this every time, with the same `CopyConfigurationDescriptor` call that `CheckQmiInterface` and `UsbIo::open` already make, and it changes nothing on the modem. Then:
  - Off: no USB call.
  - Asked for, but no remote wakeup: refused, with no USB call.
  - Asked for, with remote wakeup: `UsbIo::set_idle_policy(ms)` calls `SetIdlePolicy(ms)` on the interface, then on the bulk IN and interrupt IN pipes, and logs each result (`idle suspend: <what> SetIdlePolicy(<ms>) 0x<code>`). The first failure ends the calls; the calls before it stay made. With every call successful, idle suspend is on.
  - One summary line follows: `idle suspend <text> (asked <ms> ms, remote wakeup <0|1>)`.
  - Bulk OUT gets no policy. `IOUSBHostFamily.h` says to "only enable an idle policy on bulk or interrupt IN endpoints", an OUT pipe with nothing pending is idle already, and a suspend in the middle of an uplink transfer would end in its 5 s timeout and count as an uplink stall.
- **Why the calls there are safe.** They are synchronous calls on the Default queue, made once:
  - The interface and its pipes are open, and nothing is posted on them yet. DTR, the interrupt read and the response drain come later, at `UsbIo::start`; the bulk reads come only once the session is up.
  - No sleep can be in progress, because `SetPowerState` runs on the same queue, after `Start` returns.
  - Nothing is stopping.
  - A failure does not fail `Start`.
- **Published** once at `Start`:
  - `RMNetIdleSuspendMs`: the timeout in force, 0 unless on. It overrides a personality's value, as `RMNetProfile` does.
  - `RMNetRemoteWakeup`: 0 or 1.
  - `RMNetIdleSuspend`: `off`, `on`, `refused: no remote wakeup` or `failed: SetIdlePolicy(interface|bulk in|interrupt in) 0x<code>`.

  With the counters, once a second when changed:
  - `RMNetSuspendedTicks`: ticks whose `GetPortStatus` found the port suspended, each about 100 ms.
  - `RMNetPortStatusFailures`: `GetPortStatus` calls that failed.
  - `RMNetLowPowerAsks`: `ChangePowerState(low)` calls made.
  - `RMNetLowPowerLastResult`: the last call's result (0 for success, or when none was made).

  The low power results are published on their own rather than folded into `RMNetIdleSuspend`, because that text is the decision made once at `Start`, while the ask comes later and again after every on state. `RMNetLastPowerFlags` 65536 (`kIOServicePowerCapabilityLow`) shows that the low state came.
- **Why the drivers ask for the low power state.** `IOUSBHostFamily.h` says idle suspend "is disabled if a driver is the power child of the IOUSBHostDevice and resides in a power state with an input power requirement that does not include `kIOPMLowPower`". Its driver recommendations add "If joining the power plane, reside in a `kIOPMLowPower` state to enable idle suspend".
  - `ioreg -p IOPower` (read-only, 2026-11-15, by the Task 3 review and again before this fix) shows `RMNetDriver` and both `RMNetSerial` instances as direct power children of the RM520N-GL's `IOUSBHostDevice`, each through an `IOPowerConnection`, and not as children of the interfaces. Each was at `CurrentPowerState` 3 = `MaxPowerState` 3 with `CapabilityFlags` 2 (`kIOPMPowerOn`).
  - So the header answers the question the first version left open: as built in Task 3, `on` could never suspend.
  - The same listing shows the device itself with `"PowerOverrideOn"=Yes`, `MaxPowerState` 2 and `CurrentPowerState` 2. Its states are 0 off, 1 suspended and 2 on (`IOUSBHostDevice.h`, `tPowerState`). What the override means for its children's states is not documented.
- **When the low state is asked for.** `IOService.iig`'s comment on `ChangePowerState` says only "Allow provider to enter a low power state. A driver may allow a device to enter a lower power state." It says nothing about when the call may be made, or whether a state asked for during `Start` lasts. The Task 3 review recalls that xnu sets a dext's desired state to on once `Start` returns, and every fresh instance does get a `SetPowerState(on)` (`RMNetLastPowerFlags` 2). So:
  - `RMNetDriver` asks with `ChangePowerState(kIOServicePowerCapabilityLow)` on the first full timer tick after `Start` (`AskLowPower`), and again on the first full tick after every `SetPowerState` that carries the on bit (`low_power_ask_after`), whether that is the one after `Start` or a wake to on.
  - It never asks inside a `SetPowerState` call, nor while asleep, while a wake's resume is pending, or while stopping.
  - Each ask is counted. It is logged the first time, at power-of-two counts, and on a failure, with the last `SetPowerState` flags.
  - Assumed, not seen: the kernel's `ChangePowerState` returns without waiting for the state change. That wait would need this same Default queue to deliver `SetPowerState`.
- **`SetPowerState` with the low state** (`power_call`). With idle suspend on, the low state counts as powered:
  - While asleep it is the wake: the resume and the session restart run as for on. A wake may bring the driver straight back to the low state it asked for, which persists as its desired state.
  - While awake it changes nothing: `PowerOn` holds nothing and restarts nothing when not asleep, and the data path goes on.
  - With idle suspend off, the low state is nothing, as before. `kIOServicePowerCapabilityLPW` (0x20000) is never a wake.
- **`RMNetSerial`.**
  - It reads `RMNetIdleSuspendMs` from its own personality under the same rules, and the same remote wakeup bit from the descriptor it already reads in `Start`. It is on when both allow (`idle_suspend_wanted`).
  - It makes no `SetIdlePolicy` call: its pipes belong to `IOUserUSBSerial`, which copies them when a port opens.
  - When on, it asks for the low power state once `Start` has returned (`AskLowPowerLater`: `DispatchAsync` on the Default queue, with the port retained until the block has run) and again after every on state. Nothing is asked once `Stop` has begun or while asleep.
  - Its new `SetPowerState` override passes every call to the superclass. Neither `IOUserUSBSerial` nor `IOUserSerial` overrides it, so the call reaches `IOService`'s, as before.
  - With idle suspend on, the override also tracks asleep and awake with `power_call` and logs each call. With the key absent nothing runs and nothing is logged.
- **Port status sampling.** Only while idle suspend is on, from `UsbIo::tick`. So it never runs while held (asleep or a wake's resume pending, when the driver does not call `tick`), while stopping, after a fatal USB failure, or after close. A status counts as suspended only when its connected speed bits are not zero, because the SDK calls the suspended bit not valid otherwise. The first suspended tick is logged with the status. A failed call is counted and logged at power-of-two counts. It touches no failure limit, does not mark the device gone, and is never fatal. `static_assert`s in `usb_io.cpp` and `RMNetDriver.cpp` check that the port status bits and power flags `idle_suspend.h` restates equal the SDK's.
- **What else the SDK headers say.** `IOUSBHostInterface.iig` and `IOUSBHostPipe.iig` refer to "Idle suspend" and "Pausing IO" in `IOUSBHostFamily.h`. That header is not in the DriverKit SDK; it is in the macOS SDK's `Kernel.framework` headers (`IOKit/usb/IOUSBHostFamily.h`, "Power management").
  - Interfaces and pipes have no idle policy by default, and the device stays active while the Mac is awake.
  - An interface policy suspends the device once the wait after its endpoints have no pending IO has passed.
  - A pipe with a policy that has held an IO longer than its timeout counts as idle. Its transfers are paused at suspend, not aborted or returned, and resume after a remote wake or new IO.
  - With several interfaces, the device-wide policy is the largest one among the interfaces a driver has opened. Every endpoint of the device must be idle.
  - Control and isochronous pipes never take a policy, and pending IO on them "will always prevent idle suspend".
  - Firmware must cope with a transfer suspended midway, and should wake the bus when it has IN data.
- **Across a resume or a re-open.** No header says that a suspend, a resume, a system sleep and wake, `ClearStall` or `Abort` resets an idle policy. The policies belong to the interface and pipe objects: the kernel's `IOUSBHostInterface` keeps the timeout in a member, `_deviceIdleTimeout`, and the family pauses and resumes IO under them without the driver. Pipes are replaced only by `SelectAlternateSetting`, which closes the open pipes, or by the interface's `Close`; the driver calls neither while running. A re-enumeration brings a new instance, whose `Start` sets the policies again.
  - So the policies are set once, at `Start`, and not again after a wake.
  - The low power state is asked for again after every on state, as above.
  - On the modem: if `RMNetSuspendedTicks` still rises during an idle stretch after a sleep and wake, the policies survived.
- **What may keep the modem awake anyway.**
  - Core's liveness probe is control IO every 30 s while the link is up (`kLivenessIntervalMs` in `core/include/rmnet/session.h`). Pending control IO always prevents idle suspend, and new IO resumes a suspended device. The modem suspends about twice the timeout after the last IO: the IN pipes count as idle once their posted reads have waited the timeout, then the interface waits as long again. So a value above about 15 s never suspends between two probes, and every probe wakes the modem.
  - Device suspend needs the pipes of every opened interface idle. `RMNetSerial` on interfaces 0 and 1 sets no idle policy, and a port that is open keeps reads posted there. The owner's AT console holds interface 2 through libusb, with whatever it keeps posted. `RMNet sms` briefly holds interface 3.
  - Each of these can keep the modem active whatever the drivers set. The on-modem measurement (plan, Task 4) should note which of them were open.
- **What to look for on the modem (Task 4), without sudo.**
  - Put `RMNetIdleSuspendMs` in the working tree's `RMNetDriver` personality and in both serial personalities (`RMNetSerialDIAG`, `RMNetSerialNMEA`). A serial port without the key stays in its on state, which by the header's rule keeps the device from suspending.
  - `ioreg -p IOPower -w0 -l`, under the `RM520N-GL@...` `IOUSBHostDevice`: the three entries `RMNetDriver` and `RMNetSerial` (twice) should show `CurrentPowerState` below their `MaxPowerState` 3, with `CapabilityFlags` 65536 (`kIOPMLowPower`) instead of 2.
  - Then, in an idle stretch shorter than the probe interval allows, the device's own `CurrentPowerState` (in `IOPowerManagement` there, or in `ioreg -p IOUSB`) should drop to 1 (suspended), and `RMNetSuspendedTicks` should rise.
  - The driver's own figures: `RMNetLowPowerAsks` at least 1, `RMNetLowPowerLastResult` 0, `RMNetLastPowerFlags` 65536.
  - The port must still pass traffic in the low state. Nothing documents whether the networking family acts on its dext's low state.
- **Never run.** None of this has run on the modem. With the shipped `driver/Info.plist`, the only change on the modem is these log lines and properties: `RMNetIdleSuspend` `off`, `RMNetIdleSuspendMs` 0, `RMNetRemoteWakeup` with whatever the modem's descriptor says, and `RMNetLowPowerAsks` and `RMNetLowPowerLastResult` 0. The serial ports log nothing new.

## Runtime findings (driver features, 2026-11-15 04:56 to 12:41)

Plan `docs/superpowers/plans/2026-11-15-driver-features.md`. All runs under the shared modem lock, on cells PCI 32 and 893 with a weak uplink (RSRP -91 to -97, SINR 4 to 8).

| | Before: 317.20.51 (main's serial-ports build), 04:56 | After: 318.1.0 (driver-features, idle suspend off), 09:01 |
|---|---|---|
| Idle minute, modem's USB `CurrentPowerState` | 2 (on) in all 60 samples | 2 (on) in all 60 samples |
| First ping after the idle minute, then the next nine | 76 ms; 56 to 84 (one 275) | 59 ms; 61 to 120 |
| `measure.sh en33 up` | 1.9 Mbit/s (best second 15.5), 3.6 MB out in 6 s; pings alongside avg 189, max 564 | 3.6 Mbit/s (best 4.1), 2.8 MB out in 6 s; pings avg 84, max 202 |
| `measure.sh en33 both` | down 118.4 (best 144.9), up 13.5 (best 19.8); pings avg 177, max 875 | 1st: download 0 bytes in 8 s, up 1.2; 2nd (PCI 893): down 45.9 (best 60.8), up 0.5; pings avg 112 and 405 |
| `measure.sh en33 down` | — | 103.5 Mbit/s (best 123.4) |

- **The uplink was the radio's.** Both builds gave single-digit upload rates alone on the same cell; in the two-way runs a saturated uplink starved the other direction (the downloads' handshakes in the first, the upload in the second). The driver's counters show none of the branch's new uplink paths ran in these runs (`RMNetTxHolds` +1, `RMNetUplinkUsable` 0, no failed transfer, no error or drop), so the after figures exercise the same per-packet code as before.
- **The two 100 ms timer waits did not happen.** `RMNetTxCompleteRefused`, `RMNetRxCompleteRefused`, `RMNetTickTxDrains` and `RMNetTickRxFlushes` stayed 0 through every run. Neither wait needs changing.
- **The modem offers remote wakeup** (`RMNetRemoteWakeup` 1).
- **Idle suspend on (318.1.4, `RMNetIdleSuspendMs` 2000 in all three personalities, working tree only, 09:05):** `RMNetIdleSuspend` `on`; one low-power ask, result 0, not repeated; `RMNetLastPowerFlags` 65536; `RMNetDriver` and both `RMNetSerial` instances at `CurrentPowerState` 1, `CapabilityFlags` 65536 in `ioreg -p IOPower`; the modem's USB device at `CurrentPowerState` 1 and `RMNetSuspendedTicks` 234: **the modem suspends**. But **`en33` was gone**: not in `ifconfig -l`, `ping -b en33` "bad interface name", `ifconfig en33` stalling for minutes and failing with "Device not configured", while `RMNetState` stayed `up` (the QMI session). No traffic could be tested. The build was **not** reverted at once: the testing session stopped on an API error at about 09:05, and the build stayed installed until the owner pressed Remove in the window at 12:30:10.
- **Idle suspend on also hung macOS's `configd`, and with it the whole Mac's network** (09:06 to 12:31): the owner reported the Mac's internet down, back only after Remove. `configd`'s process ID changed about every minute from 09:06 (178 `InterfaceNamer` `addTimestamp: en33` restarts in the log), and `/Library/Logs/DiagnosticReports/` holds 20 `configd_2026-11-15-*.userspace_watchdog_timeout.spin` reports from 09:25:30 to 12:31:46. Reason, each time: unresponsive dispatch queues `IPConfigurationAgentQueue` and `com.apple.SystemConfiguration.KernelEventMonitor`. The stuck thread is a system call from `configd` into the kernel and `IOSkywalkFamily` that never returns, the same stall as `ifconfig en33`. The default route is the owner's VPN `utun5`, which needs `configd`, so DNS and the VPN failed with it. The driver logged nothing from 09:05 to 12:30. After Remove, `configd` restarted once more at 12:32:53 and then stayed up, through the 318.4.36 install, with no new report. So turning idle suspend on does not just lose `en33`: it takes down the Mac's networking until the driver is removed, which needs the owner's password.
- **Final build 318.4.36** (`driver-features` with `main` at `3304cdf` merged, idle suspend off), 12:40: up 37 s after `AT+CFUN=1,1`; `RMNetIdleSuspend` `off`, no low-power ask, the three dexts at full power; IPv4 and IPv6, pings 3 of 3 in each; `sms list` works; no new crash report.
- The 13 other Quectel models and the uplink-usable drain did not run on hardware. A sleep and wake on 318.4.36 is the owner's step.

**Data.** 205 MB recorded in all (102 MB before, 103 MB after); the idle-on build and the final checks moved only pings. On 2026-11-15 at 09:05 the owner gave 300 MB as all that is left for testing.

## Runtime findings (idle suspend: trial E1a, 2026-11-15 14:52), and idle suspend dropped

Plan `docs/superpowers/plans/2026-11-15-idle-suspend.md`. The trial tools are on branch `idle-suspend` (not on `main`): `scripts/power-trial.sh`, which installs a kept test build, samples the Mac's network once a second and always reinstalls a kept good build, and two experiment keys in the drivers, `RMNetLowPowerOnly` (ask for the low power state with no idle policy) and `RMNetLowPowerTrialSec` (a time box after which the driver returns itself to full power), with a trace of every power and interface call.

**E1a: the network dext in its low state, USB untouched.** Build 318.6.51 (`RMNetDriver` personality only: `RMNetLowPowerOnly` true, `RMNetLowPowerTrialSec` 20; no idle policy; the serial ports untouched), run by `scripts/power-trial.sh --detach` with good build 318.4.36. Results in `build/trials/20261115T065212Z-318.6.51/` of the main checkout.
- **The networking family disables the interface for the low state.** The trace, from `Start`: `SetPowerState 0x2` (t+6 ms), `setInterfaceEnable 1` (t+96), `ChangePowerState(low)` 0x0 (t+108), then **`setInterfaceEnable 0` (t+111) before `SetPowerState 0x10000` (t+112)**. The disable comes from the kernel side as part of the power change; the driver did nothing to ask for it. At the end of the time box (t+20187) `ChangePowerState(on)` was accepted (0x0), `SetPowerState 0x2` came, and then `setInterfaceEnable 1`. The same order happens for a power-off: the restore's re-enumeration gave `setInterfaceEnable 0` then `SetPowerState 0x0`.
- **What the Mac saw while the driver was low**: `en33` stayed in `ifconfig -l`, but `ipconfig getifaddr en33` timed out (3 s) in every sample, pings failed, and the QMI session stayed `syncing`. `configd` was not restarted in the 20 s. About 10 s after the driver went back to full power `en33` had its address, pings worked and the session was `up`. The restore put 318.4.36 back (CDHash checked), `en33` had its address and `configd` stayed steady.
- **So an `IOUserNetworkEthernet` dext cannot sit in its low state with a working interface, whatever USB does.** DriverKit gives every dext the same four power states (`IOUserServer.cpp`, `sPowerStates`: 0 off, 1 low with input `kIOPMLowPower`, 2 AOT, 3 on with input `kIOPMPowerOn`), and only the low one has an input requirement that includes `kIOPMLowPower`, which `IOUSBHostFamily.h` requires of every power child of the device before it may idle suspend. With the network dext a power child of the modem's `IOUSBHostDevice`, idle suspend and a working `en33` exclude each other. The 318.1.4 outage ("Runtime findings (driver features)") was this, permanent: the low state never ended, and `configd` hung on the dead interface.
- E1b (the full idle suspend) was not run: it would only repeat 318.1.4.
- **A way out the kernel source shows, untried** (`IOUserServer::serviceJoinPMTree`): a dext service does not join the power tree at all when its first ancestor in the power plane, or any ancestor above it, has the property `non-removable` = `yes` (no entry in this Mac's registry has it today). A network service created (`IOService::Create`, which attaches it to its creator) by a small USB-matched service that sets that property would stay outside the power tree, while the small service, as the device's only power child on that interface, could sit in the low state. Undocumented; whether a dext may set the property, whether the serial ports can sit low, and whether the modem's remote wakeup brings the link back are all unknown.

**Dropped (2026-11-15).** The owner chose not to restructure the driver ("Give up then"). The opt-in idle suspend (`RMNetIdleSuspendMs`, commits `00e5d1e` and `3f727cf`) was removed from the drivers: `driver/` and `tests/driver/` are as they were before `00e5d1e`, which nothing else had changed since. The remote wakeup bit (`RMNetRemoteWakeup`) and the power counters it published (`RMNetIdleSuspend`, `RMNetLowPowerAsks`, `RMNetSuspendedTicks`, `RMNetPortStatusFailures`) went with it.
- **Build 318.9.29** (this removal), installed 17:29 and loaded by `AT+CFUN=1,1`: the running dext's CDHash matched the installed one; `en33` had its IPv4 address about 30 s later; `RMNetState` `up`, IPv4 and IPv6; pings 3 of 3 on IPv4, 2 of 3 then 3 of 3 on IPv6; both serial ports present; `sms list` works; `configd` steady (up since 12:31, no new spin report); no `RMNetIdleSuspend` property, `RMNetLastPowerFlags` 2.

## Runtime findings (lid-closed sleep on 318.9.29, 2026-11-15 17:25 to 20:49)

The owner closed the lid with the modem attached and opened it again at 20:48 ("lid closed for some time, check again"); read by the controller at 20:49 to 20:51.
- **What `pmset -g log` shows:** from 17:25 "Clamshell Sleep" into DarkWake on AC with full wakes every few minutes; a real "Entering Sleep state" first at 18:48:27, then maintenance dark wakes about every 5 to 10 minutes (the longest sleep 1045 s, 19:37 to 19:54); on battery from about 19:08; a full wake at 19:15 to 19:16 (a notification), back to sleep at 19:16:12; the lid wake at 20:48:19.
- **The driver:** the same instances as at the install (`RMNetDriver` 0x1001ca3a6, the serial ports 0x1001ca3a7 and 0x1001ca3a8), so no re-enumeration and no `Stop`. `RMNetSleeps` 17, `RMNetWakes` 17, `RMNetWakeRetries` 0, `RMNetUsbRecoveries` 0, `RMNetSleepLastStatus` 0, every USB error counter 0; `RMNetLastWakeUpMs` 1191 (link up 1.19 s after the last wake call); `RMNetState` `up`, `RMNetLastPowerFlags` 2.
- **The Mac:** `en33` had a new IPv4 address (10.76.172.x, against 10.104.52.x before); pings 3 of 3 on IPv4 and IPv6; `www.apple.com` resolved through the port's own DNS server (`ipconfig getoption en33 domain_name_server`, 203.0.113.209); both serial devices present; `sms list` exit 0; `configd` up since 12:31 with no new spin report.
- So the wake path built after 317.9.11 (hold at power off, resume and restart at power on, the retry) works across many real sleeps with the modem kept powered. Its retry branch did not run (no not-ready bus). Not seen: a re-enumeration on wake (the modem stayed powered), transfers cancelled during sleep, `Stop` while asleep.

## Runtime findings (open-source cleanup, build 318.14.2, 2026-11-15 22:03)

Plan `docs/superpowers/plans/2026-11-15-open-source-cleanup.md`, "After the tasks"; checked by the coordinator.

- **`AT+QCFG="usbnet"` read and written, no restart** (2026-11-15 at about 20:55, on the console, USB interface 2): the read gave 0; the write `AT+QCFG="usbnet",1` answered `OK`, and the read then gave 1 (the query reports the saved value immediately after a write); the write `AT+QCFG="usbnet",0` answered `OK`, and the read gave 0. The modem was not restarted. The answer's form, `+QCFG: "usbnet",<n>`, is confirmed.
- **Build 318.14.2**, 22:03 to 22:06 (branch `open-source` at `695e35f`; `config.local` with the owner's team and the bundle ID `io.rmnetdriver.RMNet`): installed with `scripts/install-driver.sh`, whose check of the installed app's bundle ID passed (the same ID), and loaded by `AT+CFUN=1,1` through the console. The running dext's CDHash matched the installed one; `en33` had its IPv4 address about 37 s after; pings 3 of 3 on IPv4 and IPv6.
- **`RMNet usbmode` on the modem:** `RMNet usbmode` printed `usb mode: qmi (the RMNet driver works in this mode)`, and `RMNet usbmode --json` gave `mode` `qmi`, `value` 0, `driverWorks` true. `usbmode set qmi --yes`, and `usbmode set qmi` with no terminal, each printed `usb mode: already qmi; nothing changed` and exited 0, with no restart. `usbmode set ecm` with no terminal printed the warning for a mode other than qmi (`In ecm mode this driver does not work; …`), then the refusal line (`usb mode: no terminal to ask on, so nothing changed; …`), and exited 2; the mode stayed `qmi`.
- **The rest:** `sms list` works; both serial ports present; `configd` steady (up since 12:31, no new report).
- **Not run on hardware:** `usbmode set` into another mode (it would take the network port away), and the app's own `AT+CFUN=1,1` after a set. Earlier, the console's `AT+CFUN=1,1` (interface 2) answered `OK` before the modem left USB; that the app's interface 3 does the same is assumed, not seen.
