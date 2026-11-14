# Measurements With the New Data Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure what the old data budget did not allow: the design's 8-second download test, and upload speed and latency during a sustained upload, on the build that asks the modem for flow control and has the 64-entry transmit queue.

**Architecture:** `scripts/measure.sh` already runs capped transfers bound to the port, takes its figures from the port's own byte counters, and records every run in the usage file under a ceiling. It gets two longer modes and a higher ceiling; nothing else about it changes. The controller then runs the measurements and records them.

**Tech Stack:** POSIX `sh`, `/usr/bin/curl`, Python (the burst script's ceiling only).

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md`, goal 4 and the "Done means" line "Four parallel download streams for 8 seconds reach at least 200 Mbit/s, or within 15 percent of qmi-darwin measured within the same half hour". Open measurements: the follow-ups file, "Sent here by the hardening plan" (the 64-entry transmit queue under a sustained upload) and "Sent here by the flow-control plan" (not measured with flow control on).

## Global Constraints

- Branch `measure`, cut from `main` at `e9f48c1`. Only `scripts/measure.sh`, `scripts/uplink-burst.py` (the ceiling), `README.md` and documents change.
- The data budget: on 2026-11-15 the owner added 1 GB to the 400 MB for all testing. About 315 MB is used, about 1,085 MB is left. This plan may use at most 450 MB. The scripts' ceiling on recorded use becomes 1,300,000,000 bytes (it is 310,000,000; the usage file records 309,701,068), which leaves margin for traffic the usage file does not record.
- Every transfer is bound to the port, pinned to one server address, and stopped by the script's own watchdog; every run is recorded in `build/installed/measure-usage.log`, also when it fails or is interrupted. No `networkQuality`, no transfer outside the scripts.
- Task 1 runs the script only on `lo0` with its test settings. The measurements on `en33` are Task 2, run by the controller.
- No install, no modem reboot: build 317.16.8 is running and is what gets measured.
- Commit at the end of every task, with the message given.

## Review Focus

- A run can never move much more than its stop threshold: the per-stream limits and the watchdog still bound it in the new modes, also when the watchdog dies.
- The ceiling check uses the new modes' own reservations, and a refused run touches nothing.
- The existing `down` and `up` modes behave exactly as before, and `--analyse` still reads old samples files.
- What is recorded in the usage file for an interrupted long run.
- The figures printed for a long run mean what the header says (the gate figure starts 1.0 s after traffic starts).

---

### Task 1: Two longer modes and the new ceiling

**Files:**
- Modify: `scripts/measure.sh`, `scripts/uplink-burst.py` (`BUDGET` and the text that states it), `README.md` (the scripts' paragraph)

**Interfaces:**
- Consumes: `scripts/measure.sh` as it is.
- Produces:
  - `scripts/measure.sh <interface> down-long`: the `down` transfer (4 parallel downloads of `.../gm/large`) stopped when 320,000,000 bytes have arrived on the port or after 8 s; each download stops itself at 90,000,000 bytes.
  - `scripts/measure.sh <interface> up-long`: the `up` transfer (4 parallel uploads to `.../gm/slurp`) stopped when 60,000,000 bytes have left the port or after 8 s; each upload sends one 20,000,000-byte body.
  - The reservation of each mode is its stop threshold plus the existing margin (10,000,000). The warning threshold for a run that moved more than expected is the mode's stop threshold plus 20 percent (for `down` and `up` it stays 60,000,000).
  - `BUDGET` is 1,300,000,000 in both scripts, and every comment or docstring that states the figure says so.
  - `--analyse down-long|up-long <samples file>` works like `--analyse down|up`; the samples file's name carries the mode (`measure-<time>-down-long.samples`). The usage line's direction word stays `down` or `up` (the usage file's format does not change).
  - The usage text lists the four modes.

- [ ] **Step 1: Make the change.**
- [ ] **Step 2: Test on `lo0` only**, with `MEASURE_TEST_PORT`, `MEASURE_NETSTAT` and `MEASURE_USAGE_FILE` as the script's header describes and a local HTTP server of your own in a scratch directory: each new mode stops at its threshold (scale the test with the script's existing test settings; do not move hundreds of megabytes on loopback if a fake `netstat` can count them); a stream ends at its own limit when the watchdog is killed; a run is refused when the recorded total plus the mode's reservation would pass the ceiling, and nothing is written; `down` and `up` give the same output as before the change on the same fake input (show a diff of the two outputs); `--analyse` reads a samples file from before the change (`build/logs/` holds real ones); an interrupted `down-long` records a usage line.
- [ ] **Step 3: Run `sh -n scripts/*.sh`, `dash -n scripts/measure.sh` if `dash` exists, `/usr/bin/python3 -m py_compile scripts/uplink-burst.py`.** README. Commit.

```bash
git add scripts/measure.sh scripts/uplink-burst.py README.md && git commit -m "feat: two longer measuring modes and the ceiling for the new data budget"
```

---

### Task 2: The measurements (controller)

**Files:**
- Modify: `docs/driverkit-notes.md`, `README.md` (the "Done means" row), `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`

- [ ] **Step 1:** State before: the serving cell and signal, idle pings, the driver's counters, `RMNetFlowControlOn`.
- [ ] **Step 2:** `scripts/measure.sh en33 up` (about 12 MB) with a ping every 0.2 s alongside.
- [ ] **Step 3:** `scripts/measure.sh en33 down-long` once (at most about 330 MB). The gate figure against 200 Mbit/s; the driver's counters (drops, holds, handler time).
- [ ] **Step 4:** `scripts/measure.sh en33 up-long` once (at most about 80 MB) with a ping every 0.2 s alongside: the rate, the pings' times during the upload, `RMNetQmapCommands`, `RMNetTxHolds`, drops.
- [ ] **Step 5:** Record every figure, whatever it is, in "Runtime findings", the "Done means" row and the follow-ups; the data used; commit.

```bash
git add -A && git commit -m "docs: measurements with the new data budget"
```
