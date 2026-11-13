# Uplink Hold and Receive Batching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the driver dropping transmit frames when all its uplink buffers are busy, and make the receive path cheaper and measurable, without spending cellular data on speed runs.

**Architecture:** The driver keeps a transmit frame it cannot place and offers it again when an uplink buffer frees, instead of dropping it; macOS's own transmit queue then provides the backpressure. On receive, empty packets are taken from macOS in batches and the time each bulk-read handler takes is counted, so a later measurement can separate the driver's time from the network's.

**Tech Stack:** C++17 in a DriverKit extension (NetworkingDriverKit, USBDriverKit), the project's portable Core, POSIX `sh` and Python 3 for one test tool.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (the design; the throughput gate and "must not leave a port that looks connected but passes nothing"), and `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, sections "Left open by the driver plan" and "Sent here by the driver plan's final review", which name these changes.

## Global Constraints

- Branch `driver`. Core's rules are unchanged: `core/` is plain C++17 with no heap, STL, exceptions or RTTI; `make test` and `make check-driverkit` must pass. Driver code uses no STL, no exceptions, no RTTI.
- Everything in the driver runs on the Default dispatch queue and nothing blocks it. Core is never called from inside one of its own delegate callbacks, and not at all after `session.stop()`.
- The stop sequence and the stall recovery keep their behaviour: every USB request stays counted in `outstanding()`; nothing is re-posted or started once draining begins; `ClearStall` runs only with nothing pending on the pipe; while bulk OUT is recovering, uplink frames are dropped and counted in `RMNetTxDropRecovering`.
- Every DriverKit override and completion logs one `RMNet:`-prefixed line the first time it is called. No per-packet log lines.
- Every transmit packet taken from the transmit queue is completed exactly once, whatever happens to it. Frames keep their order.
- Cellular data is metered: about 228 MB is left for all testing. This plan may use at most 5 MB in total. No run of `scripts/measure.sh` on `en33`, no `networkQuality`, no download or upload other than the burst tool of Task 1 (at most 2,000,000 bytes per run, at most two runs). Other checks use `ping -c 5 -b en33 223.5.5.5` and `ping6 -c 5 -B en33 2400:3200::1`.
- Install only with `scripts/install-driver.sh`; load a new build with `curl -s --noproxy '*' -X POST --data-binary 'AT+CFUN=1,1' http://127.0.0.1:8730/at`; start `scripts/driver-log.sh` first. Never deactivate the driver, never use `sudo`, never touch System Settings. `build/installed/` is never deleted or edited by hand.
- After each reload: `scutil --nwi` must show `en33` first in neither list, and both `DiagnosticReports` folders must hold no new report named after the driver.
- Commit at the end of every task on `driver`, with the message given.

## Review Focus

- A frame the driver could not place is offered again unchanged and in order: none lost, none sent twice, when a hold begins in the middle of a batch.
- A hold always ends: a successful bulk OUT completion and the modem resuming the uplink restart the drain at once; a failed completion, the end of a recovery and a link down are covered by the 100 ms timer tick, which restarts the drain while it is held. So frames never sit held with buffers free for longer than one tick, and there is always something due to wake the drain. *(Amended 2026-11-14 after the whole-stage review: this line first said every event that can free a buffer restarts the drain at once. The code drains at once only after a success or a resume, because draining from a failed completion would send into a pipe about to be recovered; an "uplink usable" callback that would remove the 100 ms is in the follow-ups file.)*
- Link down, a fatal USB error or `Stop` while frames are kept: each kept packet is completed once (dropped and counted) or, at `Stop` only, abandoned with the queues; `RMNetPacketsHeld` counts them.
- Empty receive packets taken in a batch and not yet used are not lost or handed up twice when the link bounces or the completion queue refuses packets; the `kRxHold` limit still holds.
- Timing the handler adds no per-packet work and no per-packet log line.

None of these can be pinned by a unit test: the code is DriverKit-only. Each is checked by the counters named in its task and by review.

---

### Task 1: Hold transmit frames instead of dropping them

**Files:**
- Modify: `driver/core_host.h`, `driver/core_host.cpp`, `driver/RMNetDriver.cpp`, `driver/RMNetDriver.iig` (only if a declaration is needed), `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`
- Create: `scripts/uplink-burst.py`

**Interfaces:**
- Consumes: `UsbIo::acquire_uplink()`, `send_uplink()`, `release_uplink()`, `uplink_recovering()` as they are; `rmnet::EthernetEmulator::handle_tx`.
- Produces:
  - `bool CoreHost::transmit(const uint8_t* frame, size_t len)`: returns `false` only when the frame needs an uplink buffer and none can be had because all are in flight. Nothing is consumed or counted as dropped then, and the same frame offered again later gives the same result as if it had been offered once. It returns `true` in every other case (forwarded, answered, dropped and counted, link down, recovering). Confirm in `core/src/ethernet.cpp` that `handle_tx` has no side effect for a `Forward` result; if it has one, test for a free buffer before calling it.
  - The driver keeps the frames of a batch it could not place: `IOUserNetworkPacket* txPending[kTxBatch]` with a count and a cursor, and a flag `txWaitUplink`. `DrainTx` offers the kept frames first, takes no new batch while any are kept, and stops at the first frame that is not taken. `OnBulkOutDone` calls `DrainTx` when `txWaitUplink` is set; the timer tick does the same, as it does today for `txHeld`.
  - Counters, published with the others: `RMNetTxHolds` (times the drain stopped because no uplink buffer was free) and `RMNetTxPending` (frames kept now). `RMNetTxDropBusy` stays published; nothing may increment it any more except a path the report names. `RMNetPacketsHeld` includes the kept frames.
  - `scripts/uplink-burst.py <interface> [datagrams] [bytes-each]`: sends UDP datagrams as fast as it can from the interface (bound with `IP_BOUND_IF`) to `192.0.2.1` port 9, which is a documentation address that answers nothing. Defaults 1,500 datagrams of 1,200 bytes. It refuses any request above 2,000,000 bytes in total, counts the sends the system refused (`ENOBUFS`), prints the interface's byte counters before and after, and appends one line to `build/installed/measure-usage.log` in that file's format (`<UTC time> up <bytes in> <bytes out>`), so the data guard stays truthful. It refuses to run if that file is missing or malformed.

- [ ] **Step 1: Write `scripts/uplink-burst.py` and test it on `lo0`** against a copy of the usage file (a `--usage-file` option that is accepted only with `lo0`). Expected: the refusal above 2,000,000 bytes, a correct appended line in the copy, the real file untouched.
- [ ] **Step 2: Change `CoreHost::transmit` and `forward`** so a frame that cannot get a buffer is not consumed. Keep the recovering case as it is (dropped, `RMNetTxDropRecovering`).
- [ ] **Step 3: Change `DrainTx`, `OnBulkOutDone`, the tick and the counters** as in the Interfaces block. A link down or a fatal error makes kept frames drop through the normal path (`transmit` returns `true` and counts `RMNetTxDropLinkDown`).
- [ ] **Step 4: Run `make driver`, `make test`, `make check-driverkit`.** Expected: all pass, no warnings from `driver/`.
- [ ] **Step 5: Install, reload, and check the port** as the Global Constraints say, with the two pings.
- [ ] **Step 6: Run the burst once.** Read `RMNet status` before and after. Expected: `RMNetTxHolds` rises above 0, `RMNetTxDropBusy` stays 0, `RMNetTxPending` returns to 0 and `RMNetPacketsHeld` to its idle value within a second, the pings still work afterwards, no crash report. If `RMNetTxHolds` stays 0, the burst did not fill the buffers: run it once more with 1,600 datagrams of 1,250 bytes, and if it is still 0 record that and stop; do not run a third.
- [ ] **Step 7: Record the result in "Runtime findings"**, mark the uplink item in the follow-ups file as settled in code with what was and was not seen on hardware, and commit.

```bash
git add -A && git commit -m "feat: hold transmit frames until an uplink buffer frees"
```

---

### Task 2: Batched receive packets and a handler-time counter

**Files:**
- Modify: `driver/RMNetDriver.cpp`, `driver/RMNetDriver.iig` (only if a declaration is needed), `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, `README.md`, `scripts/install-driver.sh`

**Interfaces:**
- Consumes: the driver as Task 1 left it; `IOUserNetworkPacketQueue::DequeuePackets`.
- Produces:
  - A stock of empty receive packets, `IOUserNetworkPacket* rxStock[kRxStock]` with `kRxStock = 32`, refilled with one `DequeuePackets` call when it is empty. `RxBuffer` takes from the stock. The `kRxHold` limit on filled packets is unchanged. The stock replaces `rxSpare`.
  - Counters: `RMNetRxHandlerMaxUs` and `RMNetRxHandlerTotalUs`, the longest and the summed time from the start of `BulkInComplete_Impl` to the return of `UsbIo::bulk_in_complete` (which covers parsing, handing packets up, and re-posting the read), for successful reads while not stopping; `RMNetRxStock`, the empty packets in the stock now. `RMNetPacketsHeld` no longer counts the stock; say so where it is documented.
  - Four wording corrections recorded in the follow-ups file under "Left by the re-review of the final fix wave": `README.md:18` (link up is reported after both families have been tried and at least one has settings), `README.md:23` (a run killed outright leaves no usage line), `scripts/install-driver.sh:40` (the message on the second read of the listing must not say nothing has changed), and the link-up log line in `driver/RMNetDriver.cpp` (say the interface keeps its registered MTU only when `setMaxTransferUnit` failed).

- [ ] **Step 1: Implement the stock and the two timing counters.** Two clock reads per completed transfer, none per packet.
- [ ] **Step 2: Make the four wording corrections.**
- [ ] **Step 3: Run `make driver`, `make test`, `make check-driverkit`, and `sh -n scripts/install-driver.sh`.** Expected: all pass.
- [ ] **Step 4: Install, reload, and check the port** as the Global Constraints say, with the two pings, then `ping -c 100 -i 0.1 -s 1200 -b en33 223.5.5.5` (about 250 KB) to move some receive traffic. Expected: at least 95 replies; `RMNetRxHandlerMaxUs` and `RMNetRxHandlerTotalUs` are above 0 and plausible (the total divided by `RMNetRxTransfers` is well under a millisecond); `RMNetRxStock` is between 0 and 32; `RMNetRxDropNoPacket` is 0; no crash report.
- [ ] **Step 5: Reboot the modem once more** to make this build stop, and check the old instance's stop lines run down to `free` and the new instance reaches link up: the stock is abandoned at `Stop` like other held packets, and that must not crash.
- [ ] **Step 6: Record the result in "Runtime findings"**, mark the receive items and the four wording items in the follow-ups file as settled, and commit.

```bash
git add -A && git commit -m "feat: take receive packets in batches and count handler time"
```

---

## After this plan

Whether to spend data on a capped upload and download run to see the effect, and the same-day comparison with the userspace tool, are the owner's decisions. Recovery, the soak, liveness in the Up state and the graphical app remain the next plan.
