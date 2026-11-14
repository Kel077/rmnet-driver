# Recovery, Soak and the App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the design's first version: the port recovers by itself from a silent modem, a stuck uplink and sleep, a 30-minute run shows clean counters, and a small window app installs, updates and removes the driver and shows its status.

**Architecture:** Recovery that is protocol logic goes into Core, where it is unit-tested with no hardware (a liveness probe while the link is up, and two gaps in how settings are tracked). Recovery that is about USB, the timer and power goes into the driver. The app becomes a single SwiftUI window over the same two sources it reads today, the system-extension requests and the driver's I/O registry properties, and keeps its three command-line verbs for the scripts.

**Tech Stack:** C++17 (Core and a DriverKit extension), Swift 5 with SwiftUI and SystemExtensions, POSIX `sh`.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (goals 5 and 6, "Behaviour: Recovery", "Done means"), and `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md` for the open items this plan closes.

## Global Constraints

- Branch `recovery`, cut from `driver`. Core's rules are unchanged: `core/` is plain C++17 with no heap, STL, exceptions or RTTI, only `<stdint.h>`, `<stddef.h>`, `<string.h>`; `make test` needs no hardware; `make check-driverkit` must pass. Driver code uses no STL, no exceptions, no RTTI.
- Everything in the driver runs on the Default dispatch queue and nothing blocks it. Core is never called from inside one of its own delegate callbacks.
- The asynchronous stop sequence, the stall recovery, the transmit hold and the receive stock keep their behaviour unless a task says otherwise: every USB request stays counted in `outstanding()`; nothing is re-posted or started once draining begins; `ClearStall` runs only with nothing pending on the pipe.
- Every DriverKit override and completion logs one `RMNet:`-prefixed line the first time it is called. No per-packet log lines.
- No persistent modem changes, no private macOS interfaces, no root helper, no `utun`, no SIP change. The app never asks for more than the system-extension entitlement it has. Nothing uses `sudo`.
- The driver attaches only to USB interface 4 of device `2c7c:0801`.
- Cellular data is metered and nearly used: about 116 MB is left for all testing. This plan may use at most 60 MB: the soak of Task 5 at most 40 MB, every other task at most 3 MB (`ping -c 5 -b en33 223.5.5.5`, `ping6 -c 5 -B en33 2400:3200::1`, nothing else). No `scripts/measure.sh`, no `scripts/uplink-burst.py`, no `networkQuality`, no download or upload. Every report states the bytes its checks moved over the port.
- Install only with `scripts/install-driver.sh`; load a new build with `curl -s --noproxy '*' -X POST --data-binary 'AT+CFUN=1,1' http://127.0.0.1:8730/at`, sent once; if the modem is not back on USB within 3 minutes, stop and report. Start `scripts/driver-log.sh` first. Never deactivate the driver from a script or an agent; never touch System Settings. `build/installed/` is never deleted or edited by hand.
- After each reload: `scutil --nwi` must show `en33` first in neither list, and both `DiagnosticReports` folders must hold no new report named after the driver.
- Steps marked **Owner step** need the owner at the Mac (sleep and wake, pulling the cable, a password, an approval, looking at a window). An agent prepares them and stops; it never performs them.
- Commit at the end of every task, with the message given.

## Review Focus

- A modem that stops answering while the link is up: the link goes down within 45 seconds and the session starts again from sync; it does not stay up, and a probe does not disturb a call that is working. (Amended 2026-11-14 after Task 1's review: with one address family missing, a retry of that family may be outstanding when the modem goes silent; its Start Network request has a 60-second timeout and the probe waits for it, so in that case the bound is about 100 seconds. The session has one outstanding request at a time, and that is kept.)
- A timer that fails to re-arm during the stop sequence must not leave `Stop` waiting. (Added 2026-11-14 after Task 2's review: Task 2 may change the two conditions in `AdvanceStop` that wait on the timer so that a failed arm counts as no timer.)
- A request already outstanding (a retry of a missing family, a refresh) when a probe falls due, and an indication that arrives while a probe is outstanding: no request is lost, sent twice, or answered into the wrong handler.
- Wake from sleep: whatever state USB is in, the port ends either up with fresh addresses or down; never up with the addresses of the call that existed before sleep.
- A timer that fails to re-arm: ticks resume; a hold, a stop or a recovery deadline does not hang on it.
- The app removing a driver whose version differs from the one it carries, and the app meeting a state it did not create (two entries, an entry awaiting approval, the modem in ECM mode, no modem): it says what is true and never claims a removal or install that did not happen.

---

### Task 1: Core: a liveness probe while up, and two settings gaps

**Files:**
- Modify: `core/include/rmnet/session.h`, `core/src/session.cpp`, `core/include/rmnet/qmi_msgs.h`, `core/src/qmi_msgs.cpp`, `tests/test_session.cpp`, `tests/test_qmi_msgs.cpp`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`

**Interfaces:**
- Consumes: the existing `Session` state machine and its single outstanding request (`Pending`).
- Produces (no change to `SessionDelegate` or to the public methods):
  - `enum : uint32_t { kLivenessIntervalMs = 30000 };` in `session.h`. In state `Up`, when no request is outstanding and no retry is running, and `kLivenessIntervalMs` has passed since the link came up or since the last answered probe, the session sends WDS Get Current Settings on a family that is live. Any decodable response with the probe's transaction ID counts as an answer, whatever its result code; its contents are ignored. No answer within `kRequestTimeoutMs` is a dead modem: the session reports `link_down()` and goes to `Backoff`, as for a dropped call. A retry or refresh that falls due while a probe is outstanding waits for the probe; an indication that starts a refresh or reports a disconnect while a probe is outstanding abandons the probe.
  - A reconfigure indication for the other family that arrives during `Refreshing` is remembered and that family is refreshed next, instead of being dropped.
  - IPv4 counts as having settings only when the address, the subnet mask and the gateway are all present (`RuntimeSettings`/`family_has_settings`). With any missing, the family is treated as not up, so the retry logic applies.

- [ ] **Step 1: Write the failing tests** in `tests/test_session.cpp`, named: `probe_is_sent_30_s_after_link_up`, `answered_probe_schedules_the_next_one`, `probe_with_error_result_counts_as_alive`, `unanswered_probe_takes_the_link_down_and_backs_off` (asserts `link_down` exactly once, state `Backoff`, at up + 30000 + 10000), `probe_waits_for_an_outstanding_retry`, `retry_waits_for_an_outstanding_probe`, `disconnect_indication_during_a_probe_abandons_it`, `reconfigure_for_the_other_family_during_a_refresh_is_not_lost`, `ipv4_without_gateway_or_mask_is_not_up`. Use the existing `FakeModem` and capture helpers.
- [ ] **Step 2: Run `make test FILTER=probe` and the other new names.** Expected: they fail.
- [ ] **Step 3: Implement** the three behaviours.
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: all pass (the count rises by at least nine), 9 files ok.
- [ ] **Step 5: Mark the three items settled in Core in the follow-ups file, and commit.**

```bash
git add -A && git commit -m "feat: probe the modem while the link is up, and close two settings gaps"
```

---

### Task 2: Driver: ticks that survive a failed re-arm, and an uplink that cannot stay stuck

**Files:**
- Modify: `driver/RMNetDriver.cpp`, `driver/RMNetDriver.iig` (only if a declaration is needed), `driver/core_host.h`, `driver/core_host.cpp`, `driver/usb_io.h`, `driver/usb_io.cpp`, `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`

**Interfaces:**
- Consumes: the driver as it is at the head of `recovery`.
- Produces:
  - `void RMNetDriver::EnsureTimer()`: if the last `WakeAtTime` failed, tries again. Called from every completion handler, `TxPacketsAvailable_Impl` and `RxPacketsAvailable_Impl`. Counter `RMNetTimerArmFailures`.
  - Uplink timeouts: `enum { kUplinkTimeoutsFatal = 3 };` in `usb_io.h`. Three bulk OUT timeouts in a row with no successful bulk OUT between them call `on_fatal("uplink is not accepting data")`. Counter `RMNetUsbBulkOutTimeouts`.
  - A pause that is never lifted: `enum : uint32_t { kPauseMaxMs = 30000 };` in `core_host.h`. An uplink paused by a QMAP flow disable for `kPauseMaxMs` with no flow enable makes `CoreHost` ask the driver to restart the session (`bool CoreHost::take_restart_wanted()`, read by the driver after each Core call, outside any callback); the driver stops the session and starts it again, so the link goes down and the session begins from sync. Counter `RMNetUplinkPauseTimeouts`.
  - `RMNetState` shows `detached` instead of `usb failed` when the USB failure status is not-attached or the device has gone.
  - `void CoreHost::restart(uint64_t now_ms)`: `session_.stop()` then `session_.start(now_ms)`, with the data path's link state cleared between them. Task 3 uses it for wake.

- [ ] **Step 1: Implement** the four behaviours and `CoreHost::restart`.
- [ ] **Step 2: Run `make driver`, `make test`, `make check-driverkit`.** Expected: all pass, no warnings from `driver/`.
- [ ] **Step 3: Install, reload once, and check the port** as the Global Constraints say, with the two pings. Expected: link up; `RMNetTimerArmFailures`, `RMNetUsbBulkOutTimeouts` and `RMNetUplinkPauseTimeouts` 0; after the reload the old instance's `RMNetState` was `detached`, not `usb failed`, if it was seen at all.
- [ ] **Step 4: Record in "Runtime findings"** what ran and what did not (none of the three failure paths can be produced on this modem), mark the follow-ups, and commit.

```bash
git add -A && git commit -m "feat: keep ticking after a failed timer arm, and end an uplink that stays stuck"
```

---

### Task 3: Driver: sleep and wake

**Files:**
- Modify: `driver/RMNetDriver.cpp`, `driver/RMNetDriver.iig` (only if a declaration is needed), `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`

**Interfaces:**
- Consumes: `CoreHost::restart` from Task 2; the liveness probe from Task 1, merged into the branch.
- Produces:
  - `SetPowerState_Impl`: with `kIOServicePowerCapabilityOff` (the system is going to sleep) the driver stops the session, which reports the link down, and notes that it slept; with a flag set that includes `kIOServicePowerCapabilityOn` after a sleep, it restarts the session from sync through `CoreHost::restart` if USB has not failed, and does nothing if USB has failed (a new instance follows re-enumeration). It always passes the call to the superclass.
  - Counters `RMNetSleeps`, `RMNetWakes`, and `RMNetLastWakeUpMs` (milliseconds from the wake call to the next link up, 0 until then), so the result can be read after the Mac wakes even if the log stream missed it.

- [ ] **Step 1: Implement.** Keep the stop sequence untouched: a `Stop` that arrives while asleep must still finish.
- [ ] **Step 2: Run `make driver`, `make test`, `make check-driverkit`.** Expected: all pass.
- [ ] **Step 3: Install, reload once, and check the port** with the two pings. Record `RMNet status`.
- [ ] **Step 4: Owner step: sleep and wake.** Stop here and report. The controller asks the owner to put the Mac to sleep for at least 30 seconds and wake it. Expected afterwards: `RMNetSleeps` 1 and `RMNetWakes` 1 (or a new instance with both 0 and link up, if the modem re-enumerated), state up within about 30 seconds of the modem being ready, addresses present, `ping -c 5 -b en33 223.5.5.5` 5 of 5, no crash report, `en33` first in neither list.
- [ ] **Step 5: Record what macOS did** (the power flags seen, whether the modem re-enumerated, the time to link up) in "Runtime findings", and commit.

```bash
git add -A && git commit -m "feat: stop the session for sleep and start it again on wake"
```

---

### Task 4: The app: one window, and the three verbs kept

**Files:**
- Create: `app/StatusModel.swift`, `app/Registry.swift`, `app/ExtensionManager.swift`, `app/StatusView.swift`, `tests/app/StatusModelTests.swift`
- Modify: `app/main.swift`, `gen.rb` (only if the app target needs a setting), `Makefile`, `README.md`

**Interfaces:**
- Consumes: the driver's registry properties (`RMNetState`, `RMNetIPv4`, `RMNetIPv6`, `RMNetProfile`, the counters) and `OSSystemExtensionRequest` as `app/main.swift` uses them today.
- Produces:
  - `app/StatusModel.swift`, Foundation only: `struct ExtensionEntry { var version: String; var enabled: Bool; var awaitingApproval: Bool; var uninstalling: Bool }`, `enum ModemState { case absent, notQMI, qmi(interface: Int) }`, `struct DriverStatus { var entries: [ExtensionEntry]; var modem: ModemState; var attached: Bool; var properties: [String: String] }`, and pure functions `func headline(_ s: DriverStatus) -> String`, `func advice(_ s: DriverStatus, bundledVersion: String) -> [String]`, `func canRemoveDirectly(_ s: DriverStatus, bundledVersion: String) -> Bool`.
    - `headline` returns exactly one of: `Not installed`, `Waiting for approval in System Settings`, `Installed, modem not attached`, `Modem is not in QMI mode`, `Connecting`, `Connected`, `Link down`, `Needs attention`.
    - `advice` returns the lines the window shows under the headline: for `notQMI` the two AT commands `AT+QCFG="usbnet",0` and `AT+CFUN=1,1`; for more than one entry, or an entry that is installed and not enabled, that the driver was switched off in System Settings and how to clear it (Remove here, once per listed version); for a bundled version that differs from the installed one, that Update will replace it; always the line `Do not switch the driver off in System Settings while the modem is attached. Use Remove here.`
    - `canRemoveDirectly` is true only when exactly one entry is listed and its version equals `bundledVersion`.
  - `app/Registry.swift`: `func readStatus(entries: [ExtensionEntry]) -> DriverStatus` (the registry reads now in `main.swift`).
  - `app/ExtensionManager.swift`: `final class ExtensionManager` wrapping activation, deactivation and the properties request with completion handlers; `func remove(...)` activates the bundled version first when `canRemoveDirectly` is false, then deactivates.
  - `app/StatusView.swift`: one SwiftUI window, about 480 by 420 points: the headline, the advice lines, a table of state, addresses, driver version and the counters that are not 0, and two buttons, `Install` or `Update` (one button whose title depends on the state) and `Remove…`, which asks for confirmation and says a password will be asked for. It refreshes every 2 seconds.
  - `app/main.swift`: with one of the verbs `activate`, `deactivate`, `status` it behaves exactly as today (same output lines; the scripts depend on them), plus `status --json`, which prints the `DriverStatus` the window would show; with no argument it opens the window.
  - `make app-test`: compiles `app/StatusModel.swift` with `tests/app/StatusModelTests.swift` using `swiftc` and runs it; it needs no Xcode project and no hardware.

- [ ] **Step 1: Write `tests/app/StatusModelTests.swift`**: one check per `headline` value, the `notQMI` advice, the two-entries advice, the differing-version advice, and `canRemoveDirectly` for one matching entry, one differing entry and two entries. It exits non-zero on the first failure and prints which.
- [ ] **Step 2: Add `make app-test` and run it.** Expected: it fails to compile, the model does not exist yet.
- [ ] **Step 3: Implement the model, the registry reads, the manager, the window and the new `main.swift`.**
- [ ] **Step 4: Run `make app-test`, `make driver` and `make test`.** Expected: all pass; `build/xcode/.../RMNet.app/Contents/MacOS/RMNet status` prints the same lines as `/Applications/RMNet.app/Contents/MacOS/RMNet status` does now, and `status --json` prints valid JSON (check with `/usr/bin/python3 -m json.tool`).
- [ ] **Step 5: Update `README.md`** (the app section) and commit. Do not install: the window is looked at in the owner's session at the end of the plan.

```bash
git add -A && git commit -m "feat: a status window for the app, with the command-line verbs kept"
```

---

### Task 5: The soak, and the "Done means" record

**Files:**
- Create: `scripts/soak.sh`
- Modify: `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, `README.md`

**Interfaces:**
- Consumes: the final build of Tasks 1 to 4, installed; `RMNet status --json`.
- Produces: `scripts/soak.sh <interface> <minutes>`, POSIX `sh`, no `sudo`:
  - Traffic: `ping -i 0.5 -s 1000 -b <interface> 223.5.5.5` and `ping6 -i 0.5 -s 1000 -B <interface> 2400:3200::1` for the whole run (about 8 KB a second in all, about 15 MB in 30 minutes).
  - Every 10 seconds it appends one line to `build/logs/soak-<time>.csv`: the time, the port's byte counters, `RMNetState`, and the counters `RMNetUsbBulkInErrors`, `RMNetUsbBulkOutErrors`, `RMNetUsbBulkOutTimeouts`, `RMNetUsbRecoveries`, `RMNetRxDropNoPacket`, `RMNetRxDropBadQmap`, `RMNetTxDropBusy`, `RMNetTxDropUsb`, `RMNetTxDropRecovering`, `RMNetTimerArmFailures`, `RMNetPacketsHeld`.
  - It stops early, killing both pings, if the port's counters show more than 40,000,000 bytes moved since the start, if `RMNetState` is not `up` for three samples in a row, or on a signal.
  - At the end it prints a verdict: pass only if the state was `up` in every sample, every listed error and drop counter ended where it started, each ping lost at most 1 percent, and no new crash report named after the driver exists. It appends one line to `build/installed/measure-usage.log` in that file's format (`<UTC time> up <bytes in> <bytes out>`), refusing to start if that file is missing or malformed, and it leaves nothing running.

- [ ] **Step 1: Write `scripts/soak.sh` and test its logic for one minute on `lo0`** against a copy of the usage file (a `--usage-file` option accepted only with `lo0`, and a `--status-cmd` option, also `lo0` only, that replaces the status command with a fake).
- [ ] **Step 2: Run `scripts/soak.sh en33 30` once** on the installed final build, with `scripts/driver-log.sh` running. Do not run it twice.
- [ ] **Step 3: Record the verdict, the CSV's first and last lines and the data used** in "Runtime findings".
- [ ] **Step 4: Write a "Done means" table** in `README.md`: each line of the design's list with one of: shown (and where), owner step pending, or not shown (and why). The throughput line is "not shown: 278 Mbit/s over one second and 36.6 Mbit/s over seven seconds, four minutes apart on 2026-11-14; the owner chose to move on".
- [ ] **Step 5: Commit.**

```bash
git add -A && git commit -m "feat: a 30-minute soak script, its result, and the Done-means record"
```

---

## After this plan: the owner's session

These need the owner at the Mac and are run by the controller with them, in this order, after the final review: look at the app's window; sleep and wake (Task 3 Step 4, if not done); pull the cable while a ping runs and plug it back; switch the port off and on in System Settings with `RMNetRxStock` above 0; check that the port is offered under Internet Sharing; `Remove…` in the app with the modem attached (a password; this is the first stop with USB requests in flight), then `Install` (an approval). What each showed goes into the follow-ups file.
