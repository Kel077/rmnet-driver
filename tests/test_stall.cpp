#include "minitest.h"

#include "rmnet/stall.h"

using rmnet::StallOutcome;
using rmnet::UplinkStallCounter;

// Submits one transfer and fails it at once: one stall with nothing else in flight.
static StallOutcome stall_once(UplinkStallCounter& c) { return c.failed(c.submitted()); }

TEST(transfers_queued_through_one_stall_count_once) {
  UplinkStallCounter c;
  uint64_t seq[8];
  for (int i = 0; i < 8; ++i) seq[i] = c.submitted();
  CHECK_EQ(seq[0], 1u);
  CHECK_EQ(seq[7], 8u);
  CHECK(c.failed(seq[0]) == StallOutcome::Counted);
  for (int i = 1; i < 8; ++i) CHECK(c.failed(seq[i]) == StallOutcome::None);
  CHECK_EQ(c.stalls(), 1u);
}

TEST(three_stalls_in_a_row_are_stuck_then_stuck_again) {
  UplinkStallCounter c;
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK_EQ(c.stalls(), 1u);
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK_EQ(c.stalls(), 2u);
  CHECK(stall_once(c) == StallOutcome::Stuck);
  CHECK_EQ(c.stalls(), 0u);
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::StuckAgain);
  CHECK_EQ(c.stalls(), 0u);
}

TEST(a_success_between_stalls_starts_the_count_again) {
  UplinkStallCounter c;
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::Counted);
  c.submitted();
  c.succeeded();
  CHECK_EQ(c.stalls(), 0u);
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK_EQ(c.stalls(), 2u);
  CHECK(stall_once(c) == StallOutcome::Stuck);
}

TEST(a_success_after_stuck_forgets_the_restart) {
  UplinkStallCounter c;
  for (int i = 0; i < 2; ++i) stall_once(c);
  CHECK(stall_once(c) == StallOutcome::Stuck);
  c.submitted();
  c.succeeded();
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::Stuck);  // not StuckAgain: a success came between
}

TEST(clear_ignores_transfers_submitted_before_it) {
  UplinkStallCounter c;
  for (int i = 0; i < 2; ++i) stall_once(c);
  CHECK(stall_once(c) == StallOutcome::Stuck);
  CHECK(stall_once(c) == StallOutcome::Counted);
  uint64_t before = c.submitted();
  c.clear();
  CHECK_EQ(c.stalls(), 0u);
  CHECK(c.failed(before) == StallOutcome::None);  // queued before the wake
  CHECK_EQ(c.stalls(), 0u);
  // The restart memory went too: three new stalls are Stuck, not StuckAgain.
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::Counted);
  CHECK(stall_once(c) == StallOutcome::Stuck);
}

TEST(a_failure_with_an_old_sequence_number_never_counts) {
  UplinkStallCounter c;
  uint64_t old_seq = c.submitted();  // 1
  uint64_t newer = c.submitted();    // 2
  CHECK(c.failed(newer) == StallOutcome::Counted);  // the mark moves to 2
  CHECK(c.failed(old_seq) == StallOutcome::None);
  CHECK(c.failed(newer) == StallOutcome::None);
  CHECK(c.failed(0) == StallOutcome::None);
  CHECK_EQ(c.stalls(), 1u);
  // A success does not move the mark: a transfer from before the counted stall still never counts.
  c.succeeded();
  CHECK(c.failed(old_seq) == StallOutcome::None);
  CHECK_EQ(c.stalls(), 0u);
  CHECK(c.failed(c.submitted()) == StallOutcome::Counted);
}

TEST(a_stale_failure_does_not_hide_a_later_stall) {
  UplinkStallCounter c;
  uint64_t seq[8];
  for (int i = 0; i < 8; ++i) seq[i] = c.submitted();
  CHECK(c.failed(seq[0]) == StallOutcome::Counted);  // the mark moves to 8
  uint64_t ninth = c.submitted();
  CHECK(c.failed(seq[1]) == StallOutcome::None);     // stale: must leave the mark at 8
  CHECK(c.failed(ninth) == StallOutcome::Counted);
  CHECK_EQ(c.stalls(), 2u);
}
