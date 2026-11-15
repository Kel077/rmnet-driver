// Opt-in USB idle suspend: how the personality key RMNetIdleSuspendMs is taken, the driver's decision
// from it and the configuration descriptor's remote wakeup bit, what it publishes after UsbIo's
// SetIdlePolicy calls, which port status counts as suspended, and what the drivers (RMNetDriver and
// RMNetSerial) make of a SetPowerState call once they ask for the low power state. Free of DriverKit,
// so it is tested on the host (tests/driver/test_idle_suspend.cpp, make driver-test). The calls
// themselves are the drivers' and UsbIo's; docs/driverkit-notes.md says what the SDK headers say.
//
// Off unless asked for: with the key absent, 0, negative or not an integer, or without remote
// wakeup, no SetIdlePolicy, GetPortStatus or ChangePowerState call is made, SetPowerState is taken
// as it always was, and USB behaves as it always has (32 bulk reads and the interrupt read stay
// posted, so the modem never idles).
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

// The key's range. IOUSBHostFamily.h recommends an idle policy of 50 ms or more for an interface and
// for IN endpoints, so a smaller value is raised to it; a larger value than the maximum is lowered.
enum : uint32_t { kIdleSuspendMinMs = 50, kIdleSuspendMaxMs = 60000 };

// What the driver found under RMNetIdleSuspendMs.
enum class IdleKeyKind : uint8_t { Absent, NotInteger, Integer };

// How the key was taken, for the log line: off (Absent, NotInteger, Negative, Zero) or a timeout
// (AsIs, Raised to kIdleSuspendMinMs, Lowered to kIdleSuspendMaxMs).
enum class IdleKeyTaken : uint8_t { Absent, NotInteger, Negative, Zero, AsIs, Raised, Lowered };

struct IdleKey {
  uint32_t ms;  // the timeout asked for; 0 is off
  IdleKeyTaken taken;
};

// The key as the driver found it. For an integer, `value` is OSNumber::unsigned64BitValue and `bits`
// OSNumber::numberOfBits (8, 16, 32 or 64; anything else counts as 64): the top bit of that width is
// the sign, so a negative plist integer (64 bits, two's complement) is off rather than a huge value.
// Absent, not an integer, negative or 0 is off; 1 to 49 is raised to 50; above 60000 is 60000.
inline IdleKey idle_suspend_key(IdleKeyKind kind, uint64_t value, uint32_t bits) {
  if (kind == IdleKeyKind::Absent) return IdleKey{0, IdleKeyTaken::Absent};
  if (kind == IdleKeyKind::NotInteger) return IdleKey{0, IdleKeyTaken::NotInteger};
  if (bits != 8 && bits != 16 && bits != 32) bits = 64;
  if (value & (uint64_t{1} << (bits - 1))) return IdleKey{0, IdleKeyTaken::Negative};
  if (value == 0) return IdleKey{0, IdleKeyTaken::Zero};
  if (value < kIdleSuspendMinMs) return IdleKey{kIdleSuspendMinMs, IdleKeyTaken::Raised};
  if (value > kIdleSuspendMaxMs) return IdleKey{kIdleSuspendMaxMs, IdleKeyTaken::Lowered};
  return IdleKey{static_cast<uint32_t>(value), IdleKeyTaken::AsIs};
}

// The log text for how the key was taken, which both drivers put after "RMNetIdleSuspendMs: ".
// `value` and `bits` as given to idle_suspend_key; a negative value is shown with its sign.
inline void idle_key_text(IdleKey key, uint64_t value, uint32_t bits, char* out, size_t cap) {
  if (cap == 0) return;
  out[0] = '\0';
  switch (key.taken) {
    case IdleKeyTaken::Absent:
      snprintf(out, cap, "no such property; idle suspend off");
      break;
    case IdleKeyTaken::NotInteger:
      snprintf(out, cap, "not an integer; idle suspend off");
      break;
    case IdleKeyTaken::Negative: {
      if (bits != 8 && bits != 16 && bits != 32) bits = 64;
      uint64_t extended = bits == 64 ? value : value | ~((uint64_t{1} << bits) - 1);
      snprintf(out, cap, "%lld is negative; idle suspend off", static_cast<long long>(extended));
      break;
    }
    case IdleKeyTaken::Zero:
      snprintf(out, cap, "0; idle suspend off");
      break;
    case IdleKeyTaken::AsIs:
      snprintf(out, cap, "%u ms", static_cast<unsigned>(key.ms));
      break;
    case IdleKeyTaken::Raised:
      snprintf(out, cap, "%llu is below %u; raised to %u ms", static_cast<unsigned long long>(value),
               static_cast<unsigned>(kIdleSuspendMinMs), static_cast<unsigned>(key.ms));
      break;
    case IdleKeyTaken::Lowered:
      snprintf(out, cap, "%llu is above %u; taken as %u ms", static_cast<unsigned long long>(value),
               static_cast<unsigned>(kIdleSuspendMaxMs), static_cast<unsigned>(key.ms));
      break;
  }
}

// UsbIo::set_idle_policy's SetIdlePolicy calls, in the order it makes them; the first that fails
// ends them. None: no call failed. No bulk OUT call: IOUSBHostFamily.h says to "only enable an idle
// policy on bulk or interrupt IN endpoints", and an OUT pipe with nothing pending is idle already.
enum class IdlePolicyCall : uint8_t { None, Interface, BulkIn, Interrupt };

// What the calls did: the first that failed (None when every call succeeded) and its IOReturn.
struct IdlePolicyResult {
  IdlePolicyCall failed;
  uint32_t status;
};

// What is published: RMNetIdleSuspendMs (ms) and RMNetIdleSuspend (text).
struct IdleSuspendState {
  uint32_t ms;    // the timeout in force: the one asked for when on, 0 otherwise
  char text[64];  // "off", "on", "refused: no remote wakeup" or "failed: SetIdlePolicy(<what>) 0x<code>"
};

// Whether UsbIo makes its SetIdlePolicy calls (and, if they all succeed, samples the port status and
// the drivers ask for the low power state): a timeout is asked for and the modem offers remote
// wakeup. A suspended modem with idle policies on its IN pipes must wake the bus itself when it has
// data, so without remote wakeup it is refused. RMNetSerial, which makes no SetIdlePolicy call, is on
// exactly when this is true.
inline bool idle_suspend_wanted(uint32_t ms, bool remote_wakeup) { return ms > 0 && remote_wakeup; }

// The name of a call in RMNetIdleSuspend and the log.
inline const char* idle_policy_call_name(IdlePolicyCall call) {
  switch (call) {
    case IdlePolicyCall::None:
      return "none";
    case IdlePolicyCall::Interface:
      return "interface";
    case IdlePolicyCall::BulkIn:
      return "bulk in";
    case IdlePolicyCall::Interrupt:
      return "interrupt in";
  }
  return "unknown";
}

// What is published, from the timeout asked for (idle_suspend_key), the remote wakeup bit and the
// calls' result, which is read only when the calls were made (idle_suspend_wanted). Off comes first:
// with nothing asked for, nothing is refused. After a failed call the timeout in force is 0: the calls
// before it stay made, but the IN pipe whose call failed (or the interrupt pipe, always posted, whose
// call comes last) has no idle policy and keeps the modem active.
inline IdleSuspendState idle_suspend_state(uint32_t ms, bool remote_wakeup, IdlePolicyResult result) {
  IdleSuspendState s{0, ""};
  if (ms == 0) {
    snprintf(s.text, sizeof s.text, "off");
  } else if (!remote_wakeup) {
    snprintf(s.text, sizeof s.text, "refused: no remote wakeup");
  } else if (result.failed != IdlePolicyCall::None) {
    snprintf(s.text, sizeof s.text, "failed: SetIdlePolicy(%s) 0x%x", idle_policy_call_name(result.failed),
             static_cast<unsigned>(result.status));
  } else {
    s.ms = ms;
    snprintf(s.text, sizeof s.text, "on");
  }
  return s;
}

// The bits of IOUSBHostInterface::GetPortStatus's status read here, as IOUSBHostFamilyDefinitions.h
// gives them (usb_io.cpp checks them against the SDK): kIOUSBHostPortStatusConnectedSpeedMask (bits 8
// to 10) and kIOUSBHostPortStatusSuspended (bit 13).
enum : uint32_t {
  kPortStatusConnectedSpeedMask = 0x7u << 8,
  kPortStatusSuspended = 1u << 13,
};

// Whether a port status shows the modem's port suspended. The SDK: the suspended bit is "not valid
// unless kIOUSBHostPortStatusConnectedSpeedMask is nonzero", so a status with no connected speed is
// not counted.
inline bool port_suspended(uint32_t status) {
  return (status & kPortStatusConnectedSpeedMask) != 0 && (status & kPortStatusSuspended) != 0;
}

// SetPowerState's flags, as DriverKit's IOService.h gives them (the drivers check them against the
// SDK): kIOServicePowerCapabilityOff, On and Low.
enum : uint32_t {
  kPowerCapabilityOff = 0,
  kPowerCapabilityOn = 0x2,
  kPowerCapabilityLow = 0x10000,
};

// What a driver makes of a SetPowerState call. Off: the system is going to sleep. On: the device is
// powered; a driver that was asleep wakes. Other: nothing. `low_power`: idle suspend is on, so the
// driver asks for the low state (ChangePowerState(kIOServicePowerCapabilityLow)); then the low state
// counts as powered too, since a wake may bring the driver straight back to the state it asked for,
// while a low state that comes when the driver is awake changes nothing (RMNetDriver's PowerOn holds
// nothing and restarts nothing when not asleep). With `low_power` false a call is taken as it always
// was: only the on bit is a wake.
enum class PowerCall : uint8_t { Off, On, Other };

inline PowerCall power_call(uint32_t flags, bool low_power) {
  if (flags == kPowerCapabilityOff) return PowerCall::Off;
  if (flags & kPowerCapabilityOn) return PowerCall::On;
  if (low_power && (flags & kPowerCapabilityLow)) return PowerCall::On;
  return PowerCall::Other;
}

// Whether a driver with idle suspend on asks for the low state again after this SetPowerState call:
// after every call that brings the on state (the one at every start, and a wake that brings the driver
// to on rather than to low), never after the low state itself, so the asks cannot loop.
inline bool low_power_ask_after(uint32_t flags, bool low_power) {
  return low_power && (flags & kPowerCapabilityOn) != 0;
}
