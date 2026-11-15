// The modem's DIAG and NMEA interfaces as serial ports. Start checks the interface against its
// personality before IOUserUSBSerial opens anything, then names the port from the personality;
// IOUserUSBSerial moves the bytes. The UART calls succeed without I/O, except DTR and RTS, which
// are sent to the modem as Linux's option driver sends them.
#include <os/log.h>
#include <string.h>

#include <DriverKit/DriverKit.h>
#include <USBDriverKit/USBDriverKit.h>  // umbrella: also declares IOUSBHostFreeDescriptor
#include <SerialDriverKit/SerialDriverKit.h>  // kIOTTYBaseNameKey, kIOTTYSuffixKey
#include <USBSerialDriverKit/USBSerialDriverKit.h>

#include "RMNetSerial.h"
#include "idle_suspend.h"
#include "rmnet/serial_port.h"
#include "rmnet/util.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "RMNet: " fmt, ##__VA_ARGS__)

namespace {

// The personality's keys (driver/Info.plist): the port name, and the subclass and protocol the
// interface must have (its class must be 0xff).
constexpr const char* kNameKey = "RMNetSerialName";
constexpr const char* kSubClassKey = "RMNetSerialSubClass";
constexpr const char* kProtocolKey = "RMNetSerialProtocol";
// Opt-in idle suspend, by RMNetDriver's rules (driver/idle_suspend.h); no shipped personality sets it.
constexpr const char* kIdleSuspendKey = "RMNetIdleSuspendMs";

// CDC SET_CONTROL_LINE_STATE: a class request to the interface, wValue bit 0 DTR and bit 1 RTS.
constexpr uint8_t kClassInterfaceOut = 0x21;
constexpr uint8_t kSetControlLineState = 0x22;
constexpr uint16_t kLineDtr = 1u << 0;
constexpr uint16_t kLineRts = 1u << 1;
constexpr uint32_t kControlTimeoutMs = 1000;

// One bit per Hw* call that is logged only the first time it runs.
enum : uint32_t {
  kLogResetFIFO = 1u << 0,
  kLogSendBreak = 1u << 1,
  kLogProgramUART = 1u << 2,
  kLogProgramBaudRate = 1u << 3,
  kLogGetModemStatus = 1u << 4,
  kLogProgramLatencyTimer = 1u << 5,
  kLogProgramFlowControl = 1u << 6,
};

}  // namespace

struct RMNetSerial_IVars {
  IOUSBHostInterface* interface;  // retained from Start (once the checks pass) to Stop or free
  uint8_t interfaceNumber;
  char name[rmnet::kTtyNameMax + 1];  // the port name from the personality; empty until Start's checks pass
  bool dtr;  // what HwProgramMCR was last given
  bool rts;
  uint32_t logged;  // kLog* bits already logged
  // Idle suspend (RMNetIdleSuspendMs with remote wakeup offered; all false or 0 otherwise). lowPower:
  // the port asks for the low power state (AskLowPowerLater) and tracks sleep and wake in asleep.
  // queue: the Default queue, retained when lowPower is set, for the asks. stopping: Stop has begun.
  bool lowPower;
  bool asleep;
  bool stopping;
  uint64_t lowPowerAsks;
  IODispatchQueue* queue;
};

namespace {

// True the first time it is called with flag for this port.
bool FirstCall(RMNetSerial_IVars* ivars, uint32_t flag) {
  if (ivars->logged & flag) return false;
  ivars->logged |= flag;
  return true;
}

// Idle suspend on: asks for the low power state (IOService::ChangePowerState) once the current call on
// the Default queue has returned: after Start, or after a SetPowerState call, never inside one. As
// RMNetDriver does (AskLowPower), and for the same reason: IOUSBHostFamily.h disables idle suspend
// while a power child of the IOUSBHostDevice, as each serial port is, is in a state whose input power
// requirement lacks kIOPMLowPower. The port is retained until the block has run; nothing is asked once
// Stop has begun or while asleep. Logged the first time, at power-of-two counts, and on a failure.
void AskLowPowerLater(IOService* service, RMNetSerial_IVars* ivars) {
  if (!ivars->queue) return;
  service->retain();
  ivars->queue->DispatchAsync(^{
    if (!ivars->stopping && !ivars->asleep) {
      kern_return_t ret = service->ChangePowerState(kIOServicePowerCapabilityLow);
      ivars->lowPowerAsks++;
      if (ret != kIOReturnSuccess || rmnet::worth(ivars->lowPowerAsks)) {
        LOG("serial %{public}s: idle suspend: ChangePowerState(low) 0x%x (ask %llu)", ivars->name, ret,
            ivars->lowPowerAsks);
      }
    }
    service->release();  // last: the port, and ivars with it, may be freed here
  });
}

// Opt-in idle suspend for a started port, by RMNetDriver's rules: the key as idle_suspend_key takes
// it, and remote wakeup offered (idle_suspend_wanted). The port makes no SetIdlePolicy call (its pipes
// are IOUserUSBSerial's); when on, it asks for the low power state once Start has returned and after
// every on state (SetPowerState_Impl). With the key absent nothing here runs and nothing is logged,
// so the port is as it was; with the key present one line says what was decided.
void StartIdleSuspend(IOService* service, RMNetSerial_IVars* ivars, IdleKeyKind kind, uint64_t value, uint32_t bits,
                      bool remoteWakeup) {
  if (kind == IdleKeyKind::Absent) return;
  IdleKey key = idle_suspend_key(kind, value, bits);
  IdleSuspendState s = idle_suspend_state(key.ms, remoteWakeup, IdlePolicyResult{IdlePolicyCall::None, 0});
  bool on = idle_suspend_wanted(key.ms, remoteWakeup);
  kern_return_t ret = kIOReturnSuccess;
  if (on) ret = service->CopyDispatchQueue(kIOServiceDefaultQueueName, &ivars->queue);
  if (on && (ret != kIOReturnSuccess || !ivars->queue)) {
    OSSafeReleaseNULL(ivars->queue);
    on = false;
  }
  ivars->lowPower = on;
  char how[96];
  idle_key_text(key, value, bits, how, sizeof how);
  LOG("serial %{public}s: RMNetIdleSuspendMs: %{public}s; idle suspend %{public}s (remote wakeup %u)%{public}s",
      ivars->name, how, s.text, remoteWakeup ? 1u : 0u,
      on ? "; the low power state is asked for after Start"
         : (s.ms > 0 ? "; not asked for: no Default queue" : ""));
  if (!on && s.ms > 0) LOG("serial %{public}s: CopyDispatchQueue 0x%x", ivars->name, ret);
  if (on) AskLowPowerLater(service, ivars);
}

}  // namespace

bool RMNetSerial::init() {
  if (!super::init()) return false;
  ivars = IONewZero(RMNetSerial_IVars, 1);
  return ivars != nullptr;
}

void RMNetSerial::free() {
  if (ivars) {
    OSSafeReleaseNULL(ivars->interface);
    OSSafeReleaseNULL(ivars->queue);
  }
  IOSafeDeleteNULL(ivars, RMNetSerial_IVars, 1);
  super::free();
}

// The interface's descriptor and the personality are checked before the superclass's Start, which
// is what leads to the interface being opened: an interface that is not the one the personality
// describes (after a change of the modem's USB configuration, say) is refused untouched.
kern_return_t RMNetSerial::Start_Impl(IOService* provider) {
  LOG("serial start");

  IOUSBHostInterface* intf = OSDynamicCast(IOUSBHostInterface, provider);
  bool haveDescriptor = false;
  uint8_t number = 0;
  uint8_t ifClass = 0;
  uint8_t ifSubClass = 0;
  uint8_t ifProtocol = 0;
  bool remoteWakeup = false;  // kIOUSBConfigurationDescriptorAttributeRemoteWakeCapable, as RMNetDriver reads it
  if (intf) {
    const IOUSBConfigurationDescriptor* cfg = intf->CopyConfigurationDescriptor();
    if (cfg) {
      remoteWakeup = (cfg->bmAttributes & kIOUSBConfigurationDescriptorAttributeRemoteWakeCapable) != 0;
      const IOUSBInterfaceDescriptor* id = intf->GetInterfaceDescriptor(cfg);
      if (id) {
        haveDescriptor = true;
        number = id->bInterfaceNumber;
        ifClass = id->bInterfaceClass;
        ifSubClass = id->bInterfaceSubClass;
        ifProtocol = id->bInterfaceProtocol;
      }
      IOUSBHostFreeDescriptor(cfg);
    }
  }

  OSDictionary* props = nullptr;
  kern_return_t propsRet = CopyProperties(&props);
  bool haveName = false;
  bool nameOk = false;
  char name[rmnet::kTtyNameMax + 1] = {};
  bool haveSubClass = false;
  bool haveProtocol = false;
  uint64_t subClass = 0;
  uint64_t protocol = 0;
  IdleKeyKind idleKind = IdleKeyKind::Absent;
  uint64_t idleValue = 0;
  uint32_t idleBits = 0;
  if (propsRet == kIOReturnSuccess && props) {
    OSObject* idleObj = props->getObject(kIdleSuspendKey);
    OSNumber* idleNum = OSDynamicCast(OSNumber, idleObj);
    if (idleNum) {
      idleKind = IdleKeyKind::Integer;
      idleValue = idleNum->unsigned64BitValue();
      idleBits = static_cast<uint32_t>(idleNum->numberOfBits());
    } else if (idleObj) {
      idleKind = IdleKeyKind::NotInteger;
    }
    OSString* str = OSDynamicCast(OSString, props->getObject(kNameKey));
    if (str) {
      haveName = true;
      const char* cstr = str->getCStringNoCopy();
      if (rmnet::tty_name_ok(cstr)) {
        nameOk = true;
        strlcpy(name, cstr, sizeof name);
      }
    }
    OSNumber* num = OSDynamicCast(OSNumber, props->getObject(kSubClassKey));
    if (num) {
      haveSubClass = true;
      subClass = num->unsigned64BitValue();
    }
    num = OSDynamicCast(OSNumber, props->getObject(kProtocolKey));
    if (num) {
      haveProtocol = true;
      protocol = num->unsigned64BitValue();
    }
  }
  bool propsRead = propsRet == kIOReturnSuccess && props;
  OSSafeReleaseNULL(props);  // getObject does not retain: nothing taken from it is used after this

  if (!intf) {
    LOG("serial refused: the provider is not a USB interface");
    return kIOReturnUnsupported;
  }
  if (!haveDescriptor) {
    LOG("serial refused: the interface descriptor could not be read");
    return kIOReturnUnsupported;
  }
  if (!propsRead) {
    LOG("serial refused interface %u: properties not readable (0x%x)", number, propsRet);
    return kIOReturnUnsupported;
  }
  if (!haveSubClass || !haveProtocol) {
    LOG("serial refused interface %u: %{public}s missing or not an integer", number,
        !haveSubClass ? kSubClassKey : kProtocolKey);
    return kIOReturnUnsupported;
  }
  if (!rmnet::serial_interface_matches(ifClass, ifSubClass, ifProtocol, subClass, protocol)) {
    LOG("serial refused interface %u (class %u subclass %u protocol %u), not class 255 subclass %llu protocol %llu",
        number, ifClass, ifSubClass, ifProtocol, subClass, protocol);
    return kIOReturnUnsupported;
  }
  if (!nameOk) {
    LOG("serial refused interface %u: %{public}s %{public}s", number, kNameKey,
        haveName ? "is not 1 to 31 of A-Z, a-z, 0-9, '_' and '-'" : "missing or not a string");
    return kIOReturnUnsupported;
  }

  ivars->interfaceNumber = number;
  strlcpy(ivars->name, name, sizeof ivars->name);
  intf->retain();
  ivars->interface = intf;

  kern_return_t ret = Start(provider, SUPERDISPATCH);
  if (ret != kIOReturnSuccess) {
    LOG("serial %{public}s: super Start failed 0x%x", ivars->name, ret);
    OSSafeReleaseNULL(ivars->interface);
    return ret;
  }

  // The BSD client that makes /dev/cu.* and /dev/tty.* is matched at RegisterService and reads
  // these two properties; IOUserUSBSerial's Start set them to usbserial-<serial number><n>.
  OSDictionary* names = OSDictionary::withCapacity(2);
  OSString* base = OSString::withCString(ivars->name);
  OSString* suffix = OSString::withCString("");
  kern_return_t nameRet = kIOReturnNoMemory;
  if (names && base && suffix && names->setObject(kIOTTYBaseNameKey, base) &&
      names->setObject(kIOTTYSuffixKey, suffix)) {
    nameRet = SetProperties(names);
  }
  OSSafeReleaseNULL(base);
  OSSafeReleaseNULL(suffix);
  OSSafeReleaseNULL(names);
  if (nameRet != kIOReturnSuccess) {
    LOG("serial %{public}s: naming the port failed 0x%x; it keeps IOUserUSBSerial's usbserial- name", ivars->name,
        nameRet);
  }

  ret = RegisterService();
  if (ret != kIOReturnSuccess) {
    LOG("serial %{public}s: RegisterService failed 0x%x", ivars->name, ret);
    OSSafeReleaseNULL(ivars->interface);
    Stop(provider, SUPERDISPATCH);
    return ret;
  }
  LOG("serial %{public}s: started on interface %u", ivars->name, ivars->interfaceNumber);
  StartIdleSuspend(this, ivars, idleKind, idleValue, idleBits, remoteWakeup);
  return kIOReturnSuccess;
}

kern_return_t RMNetSerial::Stop_Impl(IOService* provider) {
  LOG("serial %{public}s: stop", ivars->name);
  ivars->stopping = true;  // an ask still queued (AskLowPowerLater) asks nothing
  OSSafeReleaseNULL(ivars->interface);
  return Stop(provider, SUPERDISPATCH);
}

// Always passed to the superclass (neither IOUserUSBSerial nor IOUserSerial overrides SetPowerState,
// so this reaches IOService's, as before). With idle suspend off nothing else happens and nothing is
// logged. With it on (lowPower), as RMNetDriver does (idle_suspend.h, power_call): power off marks the
// port asleep; the on state, or the low state it asked for, while asleep is the wake; the low state
// while awake changes nothing; and after every call that brings the on state (at every start, or a
// wake to on) the low state is asked for again once this call has returned. The port has nothing to
// hold or restart: IOUserUSBSerial moves its bytes and does not act on power states.
kern_return_t RMNetSerial::SetPowerState_Impl(uint32_t powerFlags) {
  if (ivars && ivars->lowPower) {
    PowerCall call = power_call(powerFlags, true);
    if (call == PowerCall::Off && !ivars->asleep) {
      ivars->asleep = true;
      LOG("serial %{public}s: SetPowerState 0x%x: asleep", ivars->name, powerFlags);
    } else if (call == PowerCall::On && ivars->asleep) {
      ivars->asleep = false;
      LOG("serial %{public}s: SetPowerState 0x%x: awake", ivars->name, powerFlags);
    } else {
      LOG("serial %{public}s: SetPowerState 0x%x", ivars->name, powerFlags);
    }
    if (low_power_ask_after(powerFlags, true) && !ivars->stopping) AskLowPowerLater(this, ivars);
  }
  return SetPowerState(powerFlags, SUPERDISPATCH);
}

kern_return_t RMNetSerial::HwActivate_Impl() {
  kern_return_t ret = HwActivate(SUPERDISPATCH);
  LOG("serial %{public}s: open, HwActivate 0x%x", ivars->name, ret);
  return ret;
}

kern_return_t RMNetSerial::HwDeactivate_Impl() {
  kern_return_t ret = HwDeactivate(SUPERDISPATCH);
  LOG("serial %{public}s: close, HwDeactivate 0x%x", ivars->name, ret);
  return ret;
}

// DTR and RTS go to the modem as CDC SET_CONTROL_LINE_STATE, as Linux's option driver sends them
// when a port opens and closes. A failure is logged and the call still succeeds, so opening a port
// never fails on it.
kern_return_t RMNetSerial::HwProgramMCR_Impl(bool dtr, bool rts) {
  ivars->dtr = dtr;
  ivars->rts = rts;
  uint16_t lines = static_cast<uint16_t>((dtr ? kLineDtr : 0) | (rts ? kLineRts : 0));
  uint16_t transferred = 0;
  kern_return_t ret = kIOReturnNotAttached;
  if (ivars->interface) {
    ret = ivars->interface->DeviceRequest(kClassInterfaceOut, kSetControlLineState, lines, ivars->interfaceNumber, 0,
                                          nullptr, &transferred, kControlTimeoutMs);
  }
  LOG("serial %{public}s: DTR %u RTS %u, SET_CONTROL_LINE_STATE 0x%x", ivars->name, dtr ? 1u : 0u, rts ? 1u : 0u,
      ret);
  return kIOReturnSuccess;
}

// The modem's ports have no modem-status lines; report a carrier and a ready peer, so a program
// that waits for DCD or CTS does not wait forever.
kern_return_t RMNetSerial::HwGetModemStatus_Impl(bool* cts, bool* dsr, bool* ri, bool* dcd) {
  if (FirstCall(ivars, kLogGetModemStatus)) LOG("serial %{public}s: first HwGetModemStatus", ivars->name);
  if (cts) *cts = true;
  if (dsr) *dsr = true;
  if (ri) *ri = false;
  if (dcd) *dcd = true;
  return kIOReturnSuccess;
}

kern_return_t RMNetSerial::HwResetFIFO_Impl(bool tx, bool rx) {
  if (FirstCall(ivars, kLogResetFIFO)) {
    LOG("serial %{public}s: first HwResetFIFO tx %u rx %u", ivars->name, tx ? 1u : 0u, rx ? 1u : 0u);
  }
  return kIOReturnSuccess;
}

kern_return_t RMNetSerial::HwSendBreak_Impl(bool sendBreak) {
  if (FirstCall(ivars, kLogSendBreak)) {
    LOG("serial %{public}s: first HwSendBreak %u", ivars->name, sendBreak ? 1u : 0u);
  }
  return kIOReturnSuccess;
}

kern_return_t RMNetSerial::HwProgramUART_Impl(uint32_t baudRate, uint8_t nDataBits, uint8_t nHalfStopBits,
                                              uint8_t parity) {
  if (FirstCall(ivars, kLogProgramUART)) {
    LOG("serial %{public}s: first HwProgramUART baud %u data bits %u half stop bits %u parity %u", ivars->name,
        baudRate, nDataBits, nHalfStopBits, parity);
  }
  return kIOReturnSuccess;
}

kern_return_t RMNetSerial::HwProgramBaudRate_Impl(uint32_t baudRate) {
  if (FirstCall(ivars, kLogProgramBaudRate)) {
    LOG("serial %{public}s: first HwProgramBaudRate %u", ivars->name, baudRate);
  }
  return kIOReturnSuccess;
}

kern_return_t RMNetSerial::HwProgramLatencyTimer_Impl(uint32_t latency) {
  if (FirstCall(ivars, kLogProgramLatencyTimer)) {
    LOG("serial %{public}s: first HwProgramLatencyTimer %u", ivars->name, latency);
  }
  return kIOReturnSuccess;
}

kern_return_t RMNetSerial::HwProgramFlowControl_Impl(uint32_t arg, uint8_t xon, uint8_t xoff) {
  if (FirstCall(ivars, kLogProgramFlowControl)) {
    LOG("serial %{public}s: first HwProgramFlowControl arg 0x%x xon 0x%02x xoff 0x%02x", ivars->name, arg, xon,
        xoff);
  }
  return kIOReturnSuccess;
}
