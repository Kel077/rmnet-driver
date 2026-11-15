// The opt-in USB idle suspend decision (driver/idle_suspend.h) on the host: how the personality's
// RMNetIdleSuspendMs is taken, whether UsbIo's SetIdlePolicy calls are made, what is published from
// the calls' result, the port status bits the tick counts as suspended, and what the drivers make of
// a SetPowerState call once they ask for the low power state.
#include "minitest.h"

#include <stdint.h>
#include <string.h>

#include <string>

#include "idle_suspend.h"

namespace {

constexpr IdlePolicyResult kAllSucceeded{IdlePolicyCall::None, 0};

std::string text(const IdleSuspendState& s) { return std::string(s.text); }

// The key as a plist integer: 64 bits.
IdleKey integer(uint64_t value) { return idle_suspend_key(IdleKeyKind::Integer, value, 64); }

}  // namespace

TEST(idle_suspend_key_absent_not_an_integer_or_0_is_off) {
  IdleKey k = idle_suspend_key(IdleKeyKind::Absent, 0, 0);
  CHECK_EQ(k.ms, 0u);
  CHECK_EQ(k.taken, IdleKeyTaken::Absent);
  // Whatever value comes with it, a key that is not an integer is off.
  k = idle_suspend_key(IdleKeyKind::NotInteger, 2000, 64);
  CHECK_EQ(k.ms, 0u);
  CHECK_EQ(k.taken, IdleKeyTaken::NotInteger);
  k = integer(0);
  CHECK_EQ(k.ms, 0u);
  CHECK_EQ(k.taken, IdleKeyTaken::Zero);
}

TEST(idle_suspend_key_negative_is_off_not_60000) {
  // A negative plist integer arrives as its two's complement: -1 is all ones.
  IdleKey k = integer(UINT64_MAX);
  CHECK_EQ(k.ms, 0u);
  CHECK_EQ(k.taken, IdleKeyTaken::Negative);
  k = integer(static_cast<uint64_t>(-2000));
  CHECK_EQ(k.ms, 0u);
  CHECK_EQ(k.taken, IdleKeyTaken::Negative);
  k = integer(uint64_t{1} << 63);
  CHECK_EQ(k.taken, IdleKeyTaken::Negative);
  // The sign is the top bit of the number's own width.
  k = idle_suspend_key(IdleKeyKind::Integer, 0xffffffffu, 32);
  CHECK_EQ(k.ms, 0u);
  CHECK_EQ(k.taken, IdleKeyTaken::Negative);
  k = idle_suspend_key(IdleKeyKind::Integer, 0xffffu, 16);
  CHECK_EQ(k.taken, IdleKeyTaken::Negative);
  // The same bits in a wider number are a large positive value, taken as 60000.
  k = integer(0xffffffffu);
  CHECK_EQ(k.ms, 60000u);
  CHECK_EQ(k.taken, IdleKeyTaken::Lowered);
}

TEST(idle_suspend_key_below_50_is_raised_to_50) {
  IdleKey k = integer(1);
  CHECK_EQ(k.ms, 50u);
  CHECK_EQ(k.taken, IdleKeyTaken::Raised);
  k = integer(49);
  CHECK_EQ(k.ms, 50u);
  CHECK_EQ(k.taken, IdleKeyTaken::Raised);
  k = integer(50);
  CHECK_EQ(k.ms, 50u);
  CHECK_EQ(k.taken, IdleKeyTaken::AsIs);
  k = idle_suspend_key(IdleKeyKind::Integer, 10, 32);
  CHECK_EQ(k.ms, 50u);
  CHECK_EQ(k.taken, IdleKeyTaken::Raised);
}

TEST(idle_suspend_key_above_60000_is_taken_as_60000) {
  IdleKey k = integer(2000);
  CHECK_EQ(k.ms, 2000u);
  CHECK_EQ(k.taken, IdleKeyTaken::AsIs);
  k = integer(60000);
  CHECK_EQ(k.ms, 60000u);
  CHECK_EQ(k.taken, IdleKeyTaken::AsIs);
  k = integer(60001);
  CHECK_EQ(k.ms, 60000u);
  CHECK_EQ(k.taken, IdleKeyTaken::Lowered);
  k = integer(uint64_t{1} << 32);  // not truncated to 0
  CHECK_EQ(k.ms, 60000u);
  CHECK_EQ(k.taken, IdleKeyTaken::Lowered);
  IdleSuspendState s = idle_suspend_state(integer(70000).ms, true, kAllSucceeded);
  CHECK_EQ(s.ms, 60000u);
  CHECK_EQ(text(s), std::string("on"));
}

TEST(idle_suspend_is_off_for_0_and_makes_no_call) {
  CHECK(!idle_suspend_wanted(0, true));
  CHECK(!idle_suspend_wanted(0, false));
  IdleSuspendState s = idle_suspend_state(0, true, kAllSucceeded);
  CHECK_EQ(s.ms, 0u);
  CHECK_EQ(text(s), std::string("off"));
  // Off comes before the remote wakeup check: nothing was asked, so nothing was refused.
  s = idle_suspend_state(0, false, kAllSucceeded);
  CHECK_EQ(s.ms, 0u);
  CHECK_EQ(text(s), std::string("off"));
}

TEST(idle_suspend_is_refused_without_remote_wakeup_and_makes_no_call) {
  CHECK(!idle_suspend_wanted(2000, false));
  IdleSuspendState s = idle_suspend_state(2000, false, kAllSucceeded);
  CHECK_EQ(s.ms, 0u);
  CHECK_EQ(text(s), std::string("refused: no remote wakeup"));
  // No call was made, so a result passed anyway is not read.
  s = idle_suspend_state(2000, false, IdlePolicyResult{IdlePolicyCall::BulkIn, 0xe00002c2u});
  CHECK_EQ(s.ms, 0u);
  CHECK_EQ(text(s), std::string("refused: no remote wakeup"));
}

TEST(idle_suspend_is_on_with_the_timeout_in_force_when_every_call_succeeds) {
  CHECK(idle_suspend_wanted(2000, true));
  IdleSuspendState s = idle_suspend_state(2000, true, kAllSucceeded);
  CHECK_EQ(s.ms, 2000u);
  CHECK_EQ(text(s), std::string("on"));
}

TEST(idle_suspend_failure_names_the_failed_call_and_its_code) {
  // The calls are the interface's and the IN pipes' only: no bulk OUT call (IOUSBHostFamily.h, "only
  // enable an idle policy on bulk or interrupt IN endpoints").
  struct Case {
    IdlePolicyCall call;
    uint32_t status;
    const char* expected;
  };
  const Case cases[] = {
      {IdlePolicyCall::Interface, 0xe00002c2u, "failed: SetIdlePolicy(interface) 0xe00002c2"},
      {IdlePolicyCall::BulkIn, 0xe00002bcu, "failed: SetIdlePolicy(bulk in) 0xe00002bc"},
      {IdlePolicyCall::Interrupt, 0x1u, "failed: SetIdlePolicy(interrupt in) 0x1"},
  };
  for (const Case& c : cases) {
    IdleSuspendState s = idle_suspend_state(2000, true, IdlePolicyResult{c.call, c.status});
    CHECK_EQ(s.ms, 0u);  // not in force: the failed pipe, or the interrupt pipe after it, stays busy
    CHECK_EQ(text(s), std::string(c.expected));
  }
}

TEST(idle_suspend_texts_fit_their_buffer) {
  // The longest text: the longest call name with an eight-digit code.
  IdleSuspendState s = idle_suspend_state(60000, true, IdlePolicyResult{IdlePolicyCall::Interrupt, 0xffffffffu});
  CHECK_EQ(text(s), std::string("failed: SetIdlePolicy(interrupt in) 0xffffffff"));
  CHECK(strlen(s.text) + 1 <= sizeof s.text);
}

TEST(port_is_suspended_only_with_the_suspended_bit_and_a_connected_speed) {
  constexpr uint32_t kSuspended = 1u << 13;  // kIOUSBHostPortStatusSuspended
  constexpr uint32_t kEnabled = 1u << 12;    // kIOUSBHostPortStatusEnabled
  constexpr uint32_t kHigh = 3u << 8;        // kIOUSBHostPortStatusConnectedSpeedHigh
  constexpr uint32_t kSuper = 4u << 8;       // kIOUSBHostPortStatusConnectedSpeedSuper
  CHECK(port_suspended(kHigh | kEnabled | kSuspended));
  CHECK(port_suspended(kSuper | kSuspended));
  CHECK(!port_suspended(kHigh | kEnabled));
  // The SDK: the suspended bit is "not valid unless kIOUSBHostPortStatusConnectedSpeedMask is nonzero".
  CHECK(!port_suspended(kSuspended));
  CHECK(!port_suspended(kSuspended | kEnabled));
  CHECK(!port_suspended(0));
}

TEST(power_call_without_low_power_is_as_before) {
  // Idle suspend off: the drivers never ask for the low state, and a call is taken as it always was.
  CHECK_EQ(power_call(0, false), PowerCall::Off);
  CHECK_EQ(power_call(0x2, false), PowerCall::On);
  CHECK_EQ(power_call(0x10000, false), PowerCall::Other);
  CHECK_EQ(power_call(0x20000, false), PowerCall::Other);
}

TEST(power_call_with_low_power_takes_the_low_state_as_powered) {
  // A wake may bring a driver that asked for the low state straight back to it: that is the wake.
  // While awake, the driver's own PowerOn does nothing for it (no hold, no restart).
  CHECK_EQ(power_call(0, true), PowerCall::Off);
  CHECK_EQ(power_call(0x2, true), PowerCall::On);
  CHECK_EQ(power_call(0x10000, true), PowerCall::On);
  CHECK_EQ(power_call(0x10002, true), PowerCall::On);
  CHECK_EQ(power_call(0x20000, true), PowerCall::Other);  // kIOServicePowerCapabilityLPW: not taken as a wake
}

TEST(low_power_is_asked_again_after_every_on_state) {
  // The on state at every start and at a wake that brings the driver to on: ask for low again.
  CHECK(low_power_ask_after(0x2, true));
  CHECK(low_power_ask_after(0x10002, true));
  // Not after the low state itself (no loop), a sleep, or anything while idle suspend is off.
  CHECK(!low_power_ask_after(0x10000, true));
  CHECK(!low_power_ask_after(0, true));
  CHECK(!low_power_ask_after(0x20000, true));
  CHECK(!low_power_ask_after(0x2, false));
  CHECK(!low_power_ask_after(0x10000, false));
}

TEST(idle_suspend_key_log_text_says_how_the_key_was_taken) {
  // Both drivers log "RMNetIdleSuspendMs: " and this text, so the same key reads the same in each.
  struct Case {
    IdleKeyKind kind;
    uint64_t value;
    uint32_t bits;
    const char* expected;
  };
  const Case cases[] = {
      {IdleKeyKind::Absent, 0, 0, "no such property; idle suspend off"},
      {IdleKeyKind::NotInteger, 0, 0, "not an integer; idle suspend off"},
      {IdleKeyKind::Integer, UINT64_MAX, 64, "-1 is negative; idle suspend off"},
      {IdleKeyKind::Integer, 0xfffffc18u, 32, "-1000 is negative; idle suspend off"},
      {IdleKeyKind::Integer, 0, 64, "0; idle suspend off"},
      {IdleKeyKind::Integer, 2000, 64, "2000 ms"},
      {IdleKeyKind::Integer, 10, 64, "10 is below 50; raised to 50 ms"},
      {IdleKeyKind::Integer, 70000, 64, "70000 is above 60000; taken as 60000 ms"},
  };
  for (const Case& c : cases) {
    char out[96];
    idle_key_text(idle_suspend_key(c.kind, c.value, c.bits), c.value, c.bits, out, sizeof out);
    CHECK_EQ(std::string(out), std::string(c.expected));
  }
}
