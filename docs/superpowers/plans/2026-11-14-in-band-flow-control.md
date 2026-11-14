# Asking the Modem for In-Band Flow Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find out whether this modem pushes back on the uplink when asked to, and whether that shortens the seconds a small packet waits behind an upload.

**Architecture:** The modem's Set Data Format response already carries a "Flow Control" field, and it reads 0 because the driver has never asked. Core adds the request field, reports what the modem answers, and falls back to today's request if the modem does not accept it, so the port always comes up. The driver already obeys QMAP flow commands (it pauses the uplink and holds frames, which backs traffic up into macOS's own queue); that code has never run on hardware and runs for the first time here.

**Tech Stack:** C++17 (Core and a DriverKit extension), Python and POSIX `sh` (scripts).

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (goal 4, throughput, and the anti-goal of a port that feels worse than the userspace tool); the finding that led here: `docs/driverkit-notes.md`, "Runtime findings (hardening build)", and the follow-ups file, "The wait behind an upload is inside the modem".

## Global Constraints

- Branch `flow-control`, cut from `main` at `2317e4c`. Core's rules are unchanged: `core/` is plain C++17 with no heap, STL, exceptions or RTTI, only `<stdint.h>`, `<stddef.h>`, `<string.h>`; `make test` needs no hardware; `make check-driverkit` must pass. Driver code uses no STL, no exceptions, no RTTI.
- Everything in the driver runs on the Default dispatch queue and nothing blocks it. Core is never called from inside one of its own delegate callbacks.
- The stop sequence, the stall recovery, the hold and resume around sleep, the transmit hold, the receive stock, and the handling of QMAP commands (pause, kept replies, the 30 s pause limit) keep their behaviour.
- Protocol facts (from libqmi's and uqmi's `qmi-service-wda.json`; no code is copied): WDA Set Data Format request TLV `0x1A` "Flow Control", one byte; response TLV `0x1B` "Flow Control", one byte. This modem's recorded response (`tests/captures.h`, `kWdaSetFormatResp`) ends `1b 01 00 00`: the field is present and 0.
- **Task 1 installs nothing and does not touch the modem.** The install, the modem reboot and every test on `en33` are Task 2, run by the controller. If the modem does not return from a reboot within 3 minutes, stop and tell the owner.
- Cellular data: about 96 MB of the owner's 400 MB is left. This plan may use at most 10 MB, all in Task 2. The scripts' own ceiling on recorded use goes from 300,000,000 to 310,000,000 bytes so that the bursts can run.
- No `sudo`, no System Settings, no `RMNet deactivate`. `build/installed/` is never edited by hand.
- Every DriverKit override and completion logs one `RMNet:`-prefixed line the first time it is called. No per-packet log lines.
- Commit at the end of every task, with the message given.

## Review Focus

- A modem that refuses, ignores or mangles the request with the new field: the port still comes up, with the old request, and says so.
- A request without the new field is byte-for-byte today's request.
- The answer is reported truthfully: asked or not, and what the modem said; an absent field is not reported as granted.
- A restart of the session (wake, pause limit, uplink stuck, liveness) neither loops on a refused request nor forgets a refusal.
- Nothing in the data path changes; the only new traffic is one byte in one control message.

---

### Task 1: Core asks for flow control and reports the answer; the driver switches it and shows it

**Files:**
- Modify: `core/include/rmnet/qmi_msgs.h`, `core/src/qmi_msgs.cpp`, `core/include/rmnet/session.h`, `core/src/session.cpp`
- Modify: `tests/test_qmi_msgs.cpp`, `tests/test_session.cpp`, `tests/captures.h` (new constants only)
- Modify: `driver/RMNetDriver.cpp`, `driver/core_host.h`, `driver/core_host.cpp`, `driver/Info.plist`
- Modify: `scripts/uplink-burst.py`, `scripts/measure.sh` (the ceiling only), `docs/driverkit-notes.md`, `README.md`

**Interfaces:**
- Consumes: Core and the driver as they are on `main`.
- Produces:
  - `size_t build_wda_set_data_format(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid, uint32_t iface_number, bool flow_control);` With `flow_control` false the frame is byte-for-byte today's (`kWdaSetFormatReq`). With true it also carries TLV `0x1A`, length 1, value 1, between the endpoint TLV (`0x17`) and `0x1B`.
  - `struct DataFormat` gains `uint8_t flow_control;`: the value of response TLV `0x1B`, or 0 if the TLV is absent; a TLV that is present but not one byte long is a parse failure, like a wrong size in the other fields. `data_format_usable` does not look at it.
  - `struct SessionConfig` gains `bool flow_control = false;`.
  - `Session`: while configured with `flow_control` and not refused, its Set Data Format request carries the field. If a request that carried it does not end in a usable data format (an error result, a response that fails `parse_wda_data_format` or `data_format_usable`, or the request's timeout), flow control counts as **refused**: the session sends Set Data Format again at once without the field, as the same step of the bring-up (not through backoff), and every later request of this `Session` object omits it, across `stop()` and `start()`. A request without the field that fails behaves exactly as today.
  - `bool Session::flow_control_asked() const;` (the last Set Data Format request carried the field) and `bool Session::flow_control_refused() const;`. `LinkConfig.format.flow_control` carries the modem's answer.
  - Driver: the personality key `RMNetFlowControl` (an integer, 0 or 1; `driver/Info.plist` sets 1; absent, not an integer, or any other value means 0, each logged once like `RMNetProfile`). Published with the counters: `RMNetFlowControlAsked` (0 or 1), `RMNetFlowControlRefused` (0 or 1), `RMNetFlowControlOn` (the modem's answer in the data format in use, 0 or 1). `kCounterCount` goes from 53 to 56. The existing `data format:` log line gains `, flow control asked %u, modem says %u`, and a refusal logs one line.
  - Scripts: `BUDGET` in `scripts/uplink-burst.py` and `scripts/measure.sh` becomes 310,000,000 (and the two comments that state the figure).

- [ ] **Step 1: Write the failing tests** in `tests/test_qmi_msgs.cpp`: `set_data_format_without_flow_control_is_the_recorded_request` (equal to `kWdaSetFormatReq`), `set_data_format_with_flow_control_adds_one_tlv` (equal to a new constant `kWdaSetFormatReqFlow`: the recorded request with `1a 01 00 01` inserted after the endpoint TLV and both length fields 4 larger), `data_format_reports_the_modems_flow_control` (the recorded response gives 0; the same response ending `1b 01 00 01` gives 1; with the TLV removed gives 0; with `1b 02 00 01 00` fails). In `tests/test_session.cpp`: `asks_for_flow_control_when_configured` (the request on the wire equals `kWdaSetFormatReqFlow` but for the transaction id, and `flow_control_asked()` is true), `does_not_ask_by_default`, `a_granted_flow_control_reaches_link_up` (`LinkConfig.format.flow_control == 1`), `a_refused_flow_control_falls_back_at_once` (an error result: the next frame sent is the request without the field, with no backoff wait; the bring-up then reaches link up; `flow_control_refused()` is true), `an_unusable_answer_with_flow_control_falls_back`, `a_timeout_with_flow_control_falls_back`, `a_refusal_is_remembered_across_a_restart` (after `stop()` and `start()` the request has no field), `a_failure_without_flow_control_is_as_before` (backoff, as today's test of that path expects).
- [ ] **Step 2: Run `make test`.** Expected: the new tests fail or do not build.
- [ ] **Step 3: Implement Core.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: all pass (120 tests before this task).
- [ ] **Step 5: Implement the driver side** (the personality key, the three published values, the log lines) and change the two script ceilings.
- [ ] **Step 6: Run `make driver`, `make test`, `make check-driverkit`, `make app-test`, `sh -n scripts/*.sh`, `/usr/bin/python3 -m py_compile scripts/uplink-burst.py`.** Expected: all pass, no warning from `driver/`. Do not install.
- [ ] **Step 7: Documents.** `docs/driverkit-notes.md`: a short section "Changed in code, not yet on hardware (in-band flow control)" saying what is asked, what is reported, the fallback, and that the driver's handling of QMAP flow commands has never run. `README.md`, the driver paragraph: one sentence on `RMNetFlowControl`. Commit.

```bash
git add -A && git commit -m "feat: ask the modem for in-band flow control, report its answer, fall back if refused"
```

---

### Task 2: One install, one reload, and what the modem does (controller)

**Files:**
- Modify: `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, `README.md`

- [ ] **Step 1:** After the review and any fix round: `scripts/driver-log.sh` in the background, `scripts/install-driver.sh`, the reboot command once. Modem back within 3 minutes or stop.
- [ ] **Step 2:** Link up; the `data format:` line and the three `RMNetFlowControl*` values; both address families; `scutil --nwi`; no new crash report; 5 pings in each family.
- [ ] **Step 3:** If the modem says flow control is on: two uplink bursts, each with a ping every 0.2 s alongside and the port's counters sampled every 15 ms (as on the hardening build). Record: `RMNetQmapCommands`, `RMNetQmapFlowDisable`, `RMNetQmapFlowEnable`, `RMNetUplinkPaused`, `RMNetUplinkPauseTimeouts`, `RMNetTxHolds`, every drop counter, how long the port took to pass the burst, and every ping's time. Compare with 19:35 and 19:39 on 317.11.33 (pings up to 3.5 s and 2.1 s late; the burst through the port in under 0.5 s).
- [ ] **Step 4:** If the link does not come up, or the uplink stays paused, or the session keeps restarting: set `RMNetFlowControl` to 0 in `driver/Info.plist`, install, reboot once more, and record that.
- [ ] **Step 5:** Record the results in "Runtime findings", update the follow-ups and the README, and commit.

```bash
git add -A && git commit -m "docs: in-band flow control on the modem"
```
