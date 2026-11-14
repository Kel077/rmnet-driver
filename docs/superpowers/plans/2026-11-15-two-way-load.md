# Two-Way Load Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure a download and an upload running at the same time on the port, to see whether a busy uplink holds back the download (its acknowledgements wait behind upload data) and how small packets fare.

**Architecture:** `scripts/measure.sh` gets one more mode, `both`, that starts the four downloads and the four uploads together under the same watchdog, stops on time or on either direction's cap, waits for both directions to settle, records one usage line, and prints the figures for each direction from the same samples. The controller runs it once.

**Tech Stack:** POSIX `sh`, `/usr/bin/curl`.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md`, goal 4; the follow-ups file, "Sent here by the measurements plan" (a download during an upload is not measured) and "Pool margin" (the standing queue in front of acknowledgements during an upload).

## Global Constraints

- Branch `two-way`, cut from `main` at `0f8caf3`. Only `scripts/measure.sh`, `README.md` and documents change.
- The data budget: 400 MB plus 1 GB; about 516 MB used, about 884 MB left. This plan may use at most 260 MB. The scripts' ceiling stays 1,300,000,000 recorded bytes (509,193,836 recorded).
- Every transfer is bound to the port, pinned to one server address, stopped by the script's own watchdog, and recorded, also when it fails or is interrupted. The usage file's line format does not change (`<time> <down|up> <bytes in> <bytes out>`); a `both` run is recorded with the word `down` and its real in and out counts.
- Task 1 runs the script only on `lo0` with its test settings. The run on `en33` is Task 2, by the controller. No install, no modem reboot.
- `down`, `up`, `down-long` and `up-long` keep their behaviour and output exactly.
- Commit at the end of every task, with the message given.

## Review Focus

- A `both` run cannot move much more than its two caps together, also if the watchdog dies (each stream's own limit, each body's size, curl's time limit).
- The settle wait covers both directions, so the record includes what was in flight in both.
- The figures for each direction mean what the header says, computed from the same samples taken before the stop.
- The reservation used by the ceiling check is the sum of both caps and the margin.
- The other four modes unchanged.

---

### Task 1: The `both` mode

**Files:**
- Modify: `scripts/measure.sh`, `README.md` (the scripts' paragraph)

**Interfaces:**
- Consumes: `scripts/measure.sh` at `0f8caf3`.
- Produces:
  - `scripts/measure.sh <interface> both`: the four downloads of `down` (each stopping itself at 40,000,000 bytes) and the four uploads of `up` (each one 15,000,000-byte body) started together; the run stops when 150,000,000 bytes have arrived on the port, or 50,000,000 bytes have left it, or after 8 s, whichever is first. Reservation: 150,000,000 + 50,000,000 + a margin of 40,000,000 = 240,000,000. Warning when a run moved more than 288,000,000 bytes in both directions together. The run fails if fewer than 1,000,000 bytes crossed the port in either direction.
  - After the stop, the settle wait runs until BOTH directions move less than 100,000 bytes between two samples (at most 6 s, as now). If the counters cannot be read at the end, the run is charged 150,000,000 in and 50,000,000 out.
  - The printed figures: "traffic started", "gate figure" and "best 1 s window" for the download (bytes in) and then for the upload (bytes out), each labelled, from the same samples file (`measure-<time>-both.samples`). `--analyse both <samples file>` prints the same.
  - The usage line's direction word for `both` is `down`; the header says so.
  - The usage text and the header list the five modes and describe `both` in the same style as the others, including its worst cases (about 165,000,000 + 16,000,000 in flight in, about 63,000,000 out; with the watchdog dead about 160,000,000 of payload in and 60,000,000 out).

- [ ] **Step 1: Make the change.**
- [ ] **Step 2: Test on `lo0` only** with the script's test settings (a local server that streams and accepts uploads, a fake `netstat`, a scratch usage file): a `both` run stopping on each of its three conditions; the settle wait waiting for the slower direction; an interrupted run recording one line; a refusal at the ceiling with the new reservation; each download stream ending at its own limit and each upload at its body size when the watchdog is killed; the two directions' figures checked against the fake counters by hand; `down`, `up`, `down-long` and `up-long` giving the same output as at `0f8caf3` on the same input.
- [ ] **Step 3: `sh -n` and `dash -n` (if present) on the script.** README. Commit.

```bash
git add scripts/measure.sh README.md && git commit -m "feat: a two-way measuring mode"
```

---

### Task 2: The run (controller)

**Files:**
- Modify: `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, `README.md` if a row changes

- [ ] **Step 1:** State before: the cell and signal, idle pings, the driver's counters.
- [ ] **Step 2:** `scripts/measure.sh en33 both` once, with a ping every 0.2 s alongside; the driver's counters before and after (receive and transmit paths, holds, drops, handler time).
- [ ] **Step 3:** Record the figures, whatever they are, against the one-way runs of 2026-11-15 (download 154.8 Mbit/s, upload 33.6 Mbit/s, same cell); the data used; commit.

```bash
git add -A && git commit -m "docs: two-way load on the modem"
```
