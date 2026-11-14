// The opt-in USB idle suspend decision (driver/idle_suspend.h) on the host: the timeout the
// personality's RMNetIdleSuspendMs asks for, whether UsbIo's SetIdlePolicy calls are made, what is
// published from the calls' result, and the port status bits the tick counts as suspended.
#include "minitest.h"

#include <stdint.h>
#include <string.h>

#include <string>

#include "idle_suspend.h"

namespace {

constexpr IdlePolicyResult kAllSucceeded{IdlePolicyCall::None, 0};

std::string text(const IdleSuspendState& s) { return std::string(s.text); }

}  // namespace

TEST(idle_suspend_is_off_for_0_and_makes_no_call) {
  CHECK_EQ(idle_suspend_ms(0), 0u);
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

TEST(idle_suspend_timeout_is_taken_as_60000_above_60000) {
  CHECK_EQ(idle_suspend_ms(1), 1u);
  CHECK_EQ(idle_suspend_ms(2000), 2000u);
  CHECK_EQ(idle_suspend_ms(60000), 60000u);
  CHECK_EQ(idle_suspend_ms(60001), 60000u);
  CHECK_EQ(idle_suspend_ms(uint64_t{1} << 32), 60000u);  // not truncated to 0
  CHECK_EQ(idle_suspend_ms(UINT64_MAX), 60000u);
  IdleSuspendState s = idle_suspend_state(idle_suspend_ms(70000), true, kAllSucceeded);
  CHECK_EQ(s.ms, 60000u);
  CHECK_EQ(text(s), std::string("on"));
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
  struct Case {
    IdlePolicyCall call;
    uint32_t status;
    const char* expected;
  };
  const Case cases[] = {
      {IdlePolicyCall::Interface, 0xe00002c2u, "failed: SetIdlePolicy(interface) 0xe00002c2"},
      {IdlePolicyCall::BulkIn, 0xe00002bcu, "failed: SetIdlePolicy(bulk in) 0xe00002bc"},
      {IdlePolicyCall::BulkOut, 0xe00002c7u, "failed: SetIdlePolicy(bulk out) 0xe00002c7"},
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
