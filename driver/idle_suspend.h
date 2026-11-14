// Opt-in USB idle suspend: the driver's decision from the personality key RMNetIdleSuspendMs and the
// configuration descriptor's remote wakeup bit, what it publishes after UsbIo's SetIdlePolicy calls,
// and which port status counts as suspended. Free of DriverKit, so it is tested on the host
// (tests/driver/test_idle_suspend.cpp, make driver-test). The USB calls themselves are UsbIo's
// (set_idle_policy at Start, GetPortStatus from tick); docs/driverkit-notes.md says what the SDK
// headers say about idle policies.
//
// Off unless asked for: with the key absent or 0, or without remote wakeup, no SetIdlePolicy and no
// GetPortStatus call is made, and USB behaves as it always has (32 bulk reads and the interrupt read
// stay posted, so the modem never idles).
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

enum : uint32_t { kIdleSuspendMaxMs = 60000 };  // a larger RMNetIdleSuspendMs is taken as this

// UsbIo::set_idle_policy's SetIdlePolicy calls, in the order it makes them; the first that fails
// ends them. None: no call failed.
enum class IdlePolicyCall : uint8_t { None, Interface, BulkIn, BulkOut, Interrupt };

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

// The timeout RMNetIdleSuspendMs asks for, in milliseconds: its value, at most kIdleSuspendMaxMs.
// 0 is off; the driver passes 0 when the key is absent or not an integer.
inline uint32_t idle_suspend_ms(uint64_t key) {
  return key > kIdleSuspendMaxMs ? kIdleSuspendMaxMs : static_cast<uint32_t>(key);
}

// Whether UsbIo makes its SetIdlePolicy calls (and, if they all succeed, samples the port status):
// a timeout is asked for and the modem offers remote wakeup. A suspended modem with idle policies on
// its IN pipes must wake the bus itself when it has data, so without remote wakeup it is refused.
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
    case IdlePolicyCall::BulkOut:
      return "bulk out";
    case IdlePolicyCall::Interrupt:
      return "interrupt in";
  }
  return "unknown";
}

// What is published, from the timeout asked for (idle_suspend_ms), the remote wakeup bit and the
// calls' result, which is read only when the calls were made (idle_suspend_wanted). Off comes first:
// with nothing asked for, nothing is refused. After a failed call the timeout in force is 0: the calls
// before it stay made, but the pipe whose call failed (or the interrupt pipe, always posted, whose call
// comes last) has no idle policy and keeps the modem active.
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
