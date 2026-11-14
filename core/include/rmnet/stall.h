// The uplink stall counter: decides when failed uplink transfers mean the uplink is stuck.
//
// A transfer that timed out, or was aborted by the host and not by the driver's own recovery,
// means the modem did not take the data. The caller decides which failures are of that kind and
// reports only those to failed(); this class only counts them.
//
// The transfers queued together on a NAKing endpoint all fail together, so a failure counts as a
// new stall only if its transfer was submitted after the previous counted stall (its sequence
// number is above the mark that stall left). kUplinkStallsStuck stalls in a row with no successful
// transfer between them make the uplink stuck: the first time the result is Stuck (the owner
// restarts the session) and the count starts again; stuck again with no success since is
// StuckAgain (the owner gives up). A success clears the count and the memory of the restart.
#pragma once

#include <stdint.h>

namespace rmnet {

enum : uint32_t { kUplinkStallsStuck = 3 };

enum class StallOutcome : uint8_t {
  None,        // not a new stall: the transfer was queued before the previous counted stall
  Counted,     // a new stall, fewer than kUplinkStallsStuck in a row
  Stuck,       // kUplinkStallsStuck in a row: restart; the count starts again
  StuckAgain,  // stuck again with no success since the restart; the count starts again
               // and the restart stays remembered, so the next third stall in a row with no
               // success or clear() between is StuckAgain again
};

class UplinkStallCounter {
 public:
  UplinkStallCounter() : seq_(0), mark_(0), stalls_(0), restarted_(false) {}

  // A transfer was accepted for sending. Returns its sequence number, 1 for the first.
  uint64_t submitted();
  // Any transfer completed successfully: clears the count and the memory of a restart.
  void succeeded();
  // The transfer with sequence number `seq` timed out or was aborted by the host.
  StallOutcome failed(uint64_t seq);
  // A wake: clears the count and the memory of a restart; transfers submitted before it never
  // count as a new stall.
  void clear();
  // Stalls counted in a row since the last success, clear() or Stuck/StuckAgain.
  uint32_t stalls() const;

 private:
  uint64_t seq_;    // the newest sequence number issued
  uint64_t mark_;   // a failure counts only if its sequence number is above this
  uint32_t stalls_;
  bool restarted_;  // Stuck was returned with no success or clear() since
};

}  // namespace rmnet
