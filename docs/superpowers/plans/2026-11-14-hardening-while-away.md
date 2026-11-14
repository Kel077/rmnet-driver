# Hardening While the Owner Is Away Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the open items that need neither the owner nor more than a few megabytes: give the untestable driver logic unit tests, let a wake survive a bus that is not ready, stop small packets waiting behind a full transmit queue, and clear the small leftovers of the reviews.

**Architecture:** Logic that the modem can never exercise moves out of the DriverKit-only code into Core, where it is unit-tested on the Mac. The driver changes are few and are installed once, at the very end, because the modem reboot that loads a build once failed to bring the modem back and nobody is at the Mac to replug it.

**Tech Stack:** C++17 (Core and a DriverKit extension), Swift 5, POSIX `sh`.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (goal 4, throughput; goal 5, recovery), and `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, which lists every item this plan takes up.

## Global Constraints

- Branch `hardening`, cut from `recovery`. Core's rules are unchanged: `core/` is plain C++17 with no heap, STL, exceptions or RTTI, only `<stdint.h>`, `<stddef.h>`, `<string.h>`; `make test` needs no hardware; `make check-driverkit` must pass. Driver code uses no STL, no exceptions, no RTTI.
- Everything in the driver runs on the Default dispatch queue and nothing blocks it. Core is never called from inside one of its own delegate callbacks, and the `Session` is not called after `session.stop()` except by `RestartSession`.
- The asynchronous stop sequence, the stall recovery, the hold and resume around sleep, the transmit hold and the receive stock keep their behaviour unless a task says otherwise.
- **No task installs anything or touches the modem.** Tasks 1 to 3 are build-and-test only. The one install and the one modem reboot of this plan happen in Task 4, after every review, and Task 4 is run by the controller. The owner is away: if the modem does not return from that reboot, nothing more can be done until they replug it.
- Cellular data: about 100 MB is left for all testing. This plan may use at most 5 MB, all in Task 4: one run of `scripts/uplink-burst.py` (at most 2 MB), and pings. No `scripts/measure.sh`, no `scripts/soak.sh` on `en33`, no other transfer.
- No `sudo`, no System Settings, no `RMNet deactivate`, nothing that needs the owner. `build/installed/` is never edited by hand.
- Every DriverKit override and completion logs one `RMNet:`-prefixed line the first time it is called. No per-packet log lines.
- Commit at the end of every task, with the message given.

## Review Focus

- The stall counter moved into Core counts exactly as the driver's own fields did: a refactor that changes behaviour is a defect, and the tests must pin the three timelines the reviews worked out.
- A wake that finds the bus not ready: the retry ends, either in a working port or in the failure it would have reported before; it never leaves the driver held for ever, never runs after `Stop` has begun, and never posts a read twice.
- A smaller transmit queue: no frame is lost or reordered, the hold still works, and nothing waits for a wake-up that does not come.
- The app's removal rules after the leftovers are cleared: no button asks for a password for nothing or says something untrue.
- Tests that were vacuous or missing: each new or changed test fails when the behaviour it names is removed.

---

### Task 1: Core: the uplink stall counter as a tested unit, and the test gaps

**Files:**
- Create: `core/include/rmnet/stall.h`, `core/src/stall.cpp`, `tests/test_stall.cpp`
- Modify: `tests/test_session.cpp`, `tests/test_qmi.cpp`, `tests/test_qmi_msgs.cpp`, `tests/frames.h`, `Makefile` (only if the DriverKit check lists files by name)

**Interfaces:**
- Consumes: nothing from the driver.
- Produces, in `rmnet/stall.h`, namespace `rmnet`:
  - `enum : uint32_t { kUplinkStallsStuck = 3 };`
  - `enum class StallOutcome : uint8_t { None, Counted, Stuck, StuckAgain };`
  - `class UplinkStallCounter` with: `uint64_t submitted();` (call when a transfer has been accepted for sending; returns its sequence number, starting at 1), `void succeeded();` (any successful transfer: clears the count and the memory of a restart), `StallOutcome failed(uint64_t seq);` (a transfer that timed out or was aborted by the host: `None` if `seq` is not above the mark left by the previous counted failure; otherwise the failure is counted and the mark moves to the newest sequence number issued; on the third counted failure in a row the result is `Stuck` the first time and `StuckAgain` if `Stuck` was already returned with no success since, and the count starts again), `void clear();` (for a wake: clears the count and the restart memory and moves the mark to the newest sequence number issued), `uint32_t stalls() const;`.
  - This is the rule `driver/usb_io.cpp` implements today with `out_seq_`, `out_stall_mark_`, `out_stalls_`, `out_stuck_restarted_` and `out_submit_seq_`. Read it there first; the class must behave identically.

- [ ] **Step 1: Write `tests/test_stall.cpp`**, named: `transfers_queued_through_one_stall_count_once` (8 submitted, all 8 fail: one `Counted`, seven `None`), `three_stalls_in_a_row_are_stuck_then_stuck_again` (`Counted`, `Counted`, `Stuck`, then `Counted`, `Counted`, `StuckAgain`), `a_success_between_stalls_starts_the_count_again`, `a_success_after_stuck_forgets_the_restart`, `clear_ignores_transfers_submitted_before_it`, `a_failure_with_an_old_sequence_number_never_counts`.
- [ ] **Step 2: Run `make test FILTER=stall`.** Expected: it does not build, the class does not exist.
- [ ] **Step 3: Implement the class.**
- [ ] **Step 4: Close these test gaps** recorded in the follow-ups file, each as a new or corrected test: the Get Client ID retry path (a retry of a family whose client was never allocated); the reconfigure for the other family in the reverse order, a third indication for the family being refreshed, and a disconnect while one is remembered; the probe's reply really being ignored (a later `link_up` must not carry the probe reply's settings); `qmi_frame_length` at its minimum lengths (a buffer shorter than the QMUX header, a declared length shorter than the header, a declared length one more than the buffer holds); and move `without_tlv` into `tests/frames.h`, used by both test files.
- [ ] **Step 5: Run `make test` and `make check-driverkit`.** Expected: all pass; the DriverKit check now covers `stall.cpp` (10 files).
- [ ] **Step 6: Commit.**

```bash
git add -A && git commit -m "feat: the uplink stall counter in Core with tests, and Core test gaps closed"
```

---

### Task 2: Driver: use the Core counter, retry a wake, shorten the transmit queue

**Files:**
- Modify: `driver/usb_io.h`, `driver/usb_io.cpp`, `driver/RMNetDriver.cpp`, `driver/RMNetDriver.iig` (only if a declaration is needed), `driver/core_host.h`, `driver/core_host.cpp`, `gen.rb` (only if the project lists Core files by name), `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`

**Interfaces:**
- Consumes: `rmnet::UplinkStallCounter` from Task 1.
- Produces:
  - `UsbIo` holds one `rmnet::UplinkStallCounter` in place of `out_seq_`, `out_stall_mark_`, `out_stalls_`, `out_stuck_restarted_`; `out_submit_seq_[]` keeps each slot's sequence number. Behaviour is unchanged.
  - A wake that finds the bus not ready: `enum : uint32_t { kResumeRetryMs = 5000 };`. If, at resume, posting the interrupt read or a bulk read is refused with a status that is not "device gone", `UsbIo` stays held, reports "not yet" instead of failing, and the driver tries the whole resume again from each timer tick until it succeeds or `kResumeRetryMs` has passed since the wake call; only then does it fail as it does today. A read that was posted by an earlier attempt is not posted again. Nothing is retried once `Stop` has begun. Counter `RMNetWakeRetries` (attempts after the first). `RMNetLastWakeUpMs` still counts from the wake call.
  - `constexpr uint32_t kTxQueueCapacity = 64;` for the transmit submission queue only (the other three queues stay at `kQueueCapacity`, 256). Frames that do not fit wait in macOS's own interface queue, which schedules flows fairly, instead of in order inside the driver.
  - The `settings IPv…` log line is written only when the settings differ from the ones last logged for that family, so the liveness probe costs two lines every 30 seconds instead of three.
  - Small items: the comment about the status at a modem reboot says the interrupt read ends aborted and its re-post is refused with not-ready; `logged_bad_qmap_` is removed; `acquire_uplink` refuses after a failure; "timer armed again" is logged only at the same power-of-two steps as the failures.

- [ ] **Step 1: Replace the four fields with the Core counter.** No change of behaviour: every place that read or wrote them maps to one call.
- [ ] **Step 2: Implement the wake retry.**
- [ ] **Step 3: Set the transmit queue's capacity, the quieter log line, and the small items.**
- [ ] **Step 4: Run `make driver`, `make test`, `make check-driverkit`.** Expected: all pass, no warnings from `driver/`. Do not install.
- [ ] **Step 5: Record in the notes** what changed and that none of it has run on hardware; mark the follow-ups items as changed in code. Commit.

```bash
git add -A && git commit -m "feat: the driver uses Core's stall counter, retries a wake, and shortens its transmit queue"
```

---

### Task 3: The app, the scripts and the README: leftovers

**Files:**
- Modify: `app/StatusModel.swift`, `app/StatusView.swift`, `app/ExtensionManager.swift`, `tests/app/StatusModelTests.swift`, `scripts/soak.sh`, `scripts/measure.sh`, `README.md`

**Interfaces:**
- Consumes: the app's model as it is.
- Produces:
  - `canRemoveDirectly` compares the listed version with the bundled one through `compareVersions`, as `installTitle` does, so `317.9` and `317.9.0` are the same version everywhere.
  - The text for a removal that cannot go ahead says the bundled version is being removed when it is listed as uninstalling, instead of "is not listed".
  - With every entry uninstalling and the modem not in QMI mode, the two AT commands are still shown.
  - When the listing is unknown, the table's version rows say unknown instead of the last known versions.
  - The vacuous check in `tests/app/StatusModelTests.swift` ("no dangling text") is replaced by one that can fail, and the dead branch it guarded is removed.
  - `scripts/soak.sh`: the driver's process is found by a pattern that matches only the driver extension's own process (its path ends in `.dext/io.rmnetdriver.RMNet.driver`), not the log-capture tool or any command that mentions the name.
  - `scripts/measure.sh`: TERM exits 143 and HUP 129.
  - `README.md`, "Done means": the two rows that cite build 317.9.11 as the most recent cite 317.10.17 (`scripts/install-driver.sh` installed it; `status --json` from it gave `Connected`); the row "a download over IPv6" becomes **shown**, with: on 2026-11-14, on 317.10.17, the AAAA record of `mirrors.tuna.tsinghua.edu.cn` was resolved through the port's DNS server and the first 1,048,576 bytes of a file were fetched over HTTPS from `2402:f000:1:400::2` with `/usr/bin/curl --noproxy '*' --interface en33 -6`, HTTP 206, and the port's counters rose by 1,118,483 bytes in.

- [ ] **Step 1: Write the new and corrected checks** in `tests/app/StatusModelTests.swift`: `canRemoveDirectly` for `317.9` against `317.9.0`; the unknown-listing version rows (as a pure function of the model); the AT commands with every entry uninstalling and the modem not in QMI mode; the replaced "dangling text" check.
- [ ] **Step 2: Run `make app-test`.** Expected: the new checks fail.
- [ ] **Step 3: Implement the model, view and text changes.**
- [ ] **Step 4: Change the two scripts**, and test `soak.sh`'s pattern on `lo0` with a fake process whose command line contains the driver's name (it must not be counted), using `--pid-cmd` only where the real pattern cannot be tested.
- [ ] **Step 5: Run `make app-test`, `make driver`, `make test`, `sh -n scripts/*.sh`.** Expected: all pass. Update the README rows. Commit.

```bash
git add -A && git commit -m "fix: app, script and README leftovers from the reviews"
```

---

### Task 4: One install, one reload, and the checks that need the modem (controller)

**Files:**
- Modify: `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, `README.md`

- [ ] **Step 1:** After the final review and its fix wave: `scripts/driver-log.sh` in the background, `scripts/install-driver.sh`, then the reboot command once. If the modem is not back on USB within 3 minutes, stop here and tell the owner.
- [ ] **Step 2:** Link up; `ifconfig en33` with both address families; `scutil --nwi` with `en33` first in neither list; no new crash report; `ping -c 5 -b en33 223.5.5.5` and `ping6 -c 5 -B en33 2400:3200::1`, 5 of 5 each; the probe answered every 30 s over two minutes; `RMNetWakeRetries` 0.
- [ ] **Step 3:** `ping -c 20 -i 0.2 -b en33 223.5.5.5` in the background and, one second later, `/usr/bin/python3 scripts/uplink-burst.py en33` once. Expected: `RMNetTxDropBusy` 0, `RMNetTxPending` and `RMNetPacketsHeld` back to 0, and the round-trip times of the pings sent during the burst. On build 316.19.56, with a queue of 256, they were 498 and 294 ms against about 15 to 38 ms idle. Record what they are now, whatever they are.
- [ ] **Step 4:** Record the results in "Runtime findings", update the follow-ups and the README, and commit.

```bash
git add -A && git commit -m "docs: the hardening build on the modem"
```
