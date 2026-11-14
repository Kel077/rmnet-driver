#include "rmnet/stall.h"

namespace rmnet {

uint64_t UplinkStallCounter::submitted() { return ++seq_; }

void UplinkStallCounter::succeeded() {
  stalls_ = 0;
  restarted_ = false;
}

StallOutcome UplinkStallCounter::failed(uint64_t seq) {
  if (seq <= mark_) return StallOutcome::None;  // queued before the previous counted stall
  stalls_++;
  mark_ = seq_;
  if (stalls_ < kUplinkStallsStuck) return StallOutcome::Counted;
  stalls_ = 0;
  if (restarted_) return StallOutcome::StuckAgain;
  restarted_ = true;
  return StallOutcome::Stuck;
}

void UplinkStallCounter::clear() {
  stalls_ = 0;
  restarted_ = false;
  mark_ = seq_;
}

uint32_t UplinkStallCounter::stalls() const { return stalls_; }

}  // namespace rmnet
