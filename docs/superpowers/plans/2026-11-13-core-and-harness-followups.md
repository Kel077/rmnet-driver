# Core and harness: follow-ups

Date: 2026-11-13. The plan `2026-11-13-core-and-harness.md` is complete on branch `core-and-harness`: 83 unit tests pass, every Core file passes the DriverKit syntax check, and the harness connected and pinged over IPv4 and IPv6 through the real modem with no root.

This file records what the reviews left open, so the driver plan can pick it up.

## Required in the driver plan

These came from the whole-branch review and from running against the modem. Status as of the end of the plan `2026-11-13-driver-to-throughput-gate.md` (branch `driver`, 2026-11-14): **settled** only where a commit or a task report shows it.

- **Retry a family that failed while the other came up.** For about three seconds after a call is torn down, a new IPv4 Start Network often fails with call end 1008 (3GPP reason 36), and the link comes up IPv6-only. Core never retries the missing family, and a successful link-up resets the backoff, so the port stays IPv6-only until the next drop. Redial after a network drop and after wake both land inside that window, because the first backoff is 2000 ms. Retry the missing family while Up, without taking the link down. Revisit the first backoff value at the same time.
  - **Settled in Core, open on hardware.** The retry is in Core with unit tests (`e8f6c6a`, `9c22931`); the IPv4-behind-IPv6 case itself (`missing_v4_is_retried_while_up`, `failed_v4_retry_keeps_link_up_and_backs_off`) was tested in the final review's fix wave. It was never seen on hardware: `AT+CGACT=0,1` answered ERROR three times (Task 6 report, Step 5), so no family was lost while up. The first backoff is still 2000 ms (`kFirstBackoffMs`); it was not revisited.
- **Link Core into an empty driver target in the first task.**
  - **Settled.** `9f02d44` (Task 3 report: the nine Core files compile into the dext, 143 `rmnet` symbols in its binary); the driver has run Core on hardware since `f3ca9e7`.
- **Send unsolicited router advertisements.** `make_router_advert` must be sent on link up and at least every 600 seconds; the router and DNS lifetimes are 1800 seconds.
  - **Settled.** `2bd8077`: sent on link up when IPv6 is new and every 600 s (`kRouterAdvertMs`, `CoreHost::data_tick`); the port took its IPv6 addresses from them (Task 6 report, Step 3).
- **Check on the live driver:**
  - whether macOS accepts a broadcast DHCP ACK in answer to a unicast renewal; **open:** no renewal was looked for in any task.
  - what macOS does with addresses from an old /64 after a link bounce, since every call gets a new prefix; **open in part:** after a modem reboot no old address remained, but the interface is recreated then (Task 6 report, Step 4). A link bounce with the interface kept (a call drop while attached) was not produced.
  - whether a neighbour solicitation for the Mac's own address ever reaches the driver, and if so whether answering it causes harm; **open:** not looked for (Task 6 report, Step 4).
  - whether the modem accepts 4 to 7 bytes of padding on the last uplink frame (the exact-multiple-of-1024 case), which needs a throughput run to hit; **open:** the Task 7 upload showed no uplink error (`RMNetUsbBulkOutErrors` and `RMNetTxDropUsb` 0), but nothing counts whether that case occurred.
- **Decide when IPv4 counts as up.** Today the address TLV alone sets `has_v4`. If the gateway or mask were missing, DHCP would offer a zero router and mask.
  - **Settled in Core (`ec486d5`), under review.** `parse_wds_current_settings` sets `has_v4`, and takes the address, gateway and mask, only when all three TLVs are present; a family with any of them missing is treated as not up, so the other family carries the link and the retry applies (`ipv4_without_gateway_or_mask_is_not_up`, `parse_settings_ipv4_needs_address_mask_and_gateway`).
- **Do not copy the harness's synchronous bulk write** into the driver. It blocks its queue for up to 5 seconds.
  - **Settled.** Not copied: every bulk transfer in `driver/usb_io.cpp` is an asynchronous `AsyncIO` (`2bd8077`).
- **Move QMUX frame splitting into Core.** The harness splits a control read into frames itself; `qmi_decode` does not report how many bytes it consumed.
  - **Settled.** `74590e2`.
- **Count QMAP command frames.** The modem sent none during testing, so flow-control replies are unproven on hardware.
  - **Settled as counting, open on hardware.** `2bd8077` counts them (`RMNetQmapCommands`, flow disable and enable, replies); none arrived in any task, Task 7's runs included.
- **Add a liveness check for the Up state.** A modem that goes silent leaves the session Up.
  - **Settled in Core (`ec486d5`), under review, not yet seen on hardware.** In `Up`, 30 s (`kLivenessIntervalMs`) after link up and after each answered probe, `Session` sends WDS Get Current Settings on the first live family; any response counts, and none within 10 s takes the link down and goes to Backoff; a probe and a retry never run together, and a disconnect or reconfigure indication abandons the probe.
- **Handle a reconfigure for the second family during a refresh.** It is currently lost, leaving that family's settings stale until the next event.
  - **Settled in Core (`ec486d5`), under review.** A reconfigure indication for the other family during `Refreshing` is remembered and that family is refreshed right after the current one, before `link_up()` (`reconfigure_for_the_other_family_during_a_refresh_is_not_lost`).

## Left open by the driver plan

- **Paths never run on hardware:** a `Stop` with USB requests still in flight (every observed `Stop` found none outstanding), bulk stall recovery and its 1 s deadline, QMAP flow control (no command frame ever arrived), the IPv4 retry while up, and unplugging the modem with the driver running.
- **Uplink drops when busy.** With all 8 uplink buffers in flight the driver drops transmit frames instead of leaving them in the TX submission queue: 12,467 drops under `networkQuality` (Task 6) and 2,343 in Task 7's 6-second upload, which measured 11.9 Mbit/s on the port's counters (dropped frames included) against 36 for the userspace tool.
  - **Settled in code (2026-11-14, 316.19.9).** A frame that finds every uplink buffer in flight is kept by the driver and offered again when a transfer completes; the frames behind it stay in the TX submission queue. On hardware, one 1,800,000-byte UDP burst reached the modem whole (1,504 packets, `RMNetTxDropBusy` 0, `RMNetTxHolds` 999, `RMNetTxPending` and `RMNetPacketsHeld` back to 0 within a second; `docs/driverkit-notes.md`, "Runtime findings (uplink hold)"). Not seen on hardware: a TCP upload rate with the change, and holding across a link down, stall recovery or QMAP pause.
- **The throughput gate was not passed by its definition.** The download gate figures were 129.2, 138.3 and 92.6 Mbit/s, against 150 (`docs/driverkit-notes.md`, "Runtime findings (throughput, Task 7)").
  - **What was shown.** There was no sign of receive-path starvation, drops or CPU saturation in the driver. Read lag was measured in run 4 only: at most 1.05 ms from completion to handler. There were no drops or queue refusals, and the driver process used about 10 % CPU. The path carried 182 Mbit/s for about a second in run 3.
  - **What was not measured.** Read headroom in the faster runs; the time a read spends in its handler; latency in the transmit and acknowledgement path, which affects how TCP ramps up; macOS's work after `EnqueuePackets`; kernel CPU outside the driver process; and whether the modem's data format and aggregation match the userspace tool's.
  - **Why measuring stopped.** One 50 MB run cannot show an effect smaller than the 46 Mbit/s spread between runs of the same receive path.
  - **What decides it.** Only a same-day comparison with the userspace tool under `scripts/measure.sh` can separate the driver from the network, and it needs the owner.
- **Upload.** 11.9 Mbit/s on the port's counters, which include the dropped frames; the driver delivered about two thirds of those bytes to the modem (6.7 of 10.1 MB).
- **All hardware testing is under a data budget.** The SIM is metered: 400 MB was left on 2026-11-14 for all remaining testing, and Task 7 used about 171 MB of it (`build/installed/measure-usage.log` records each measurement). Measurements were therefore capped at 50 MB, which makes each one short and noisy.

## Sent here by the driver plan's final review (2026-11-14)

Line references were at commit `680948c`; since the code has moved, they are now given as names (changed 2026-11-14, after the uplink-hold plan's whole-stage review).

Port up but passing nothing (belongs with the Up-state liveness work):
- A bulk OUT that only ever times out is never escalated: a 5 s timeout frees the buffer and counts `RMNetTxDropUsb`, and nothing counts consecutive ones (`kUplinkTimeoutMs` and `Halts` in `driver/usb_io.cpp`, `UsbIo::bulk_out_complete`).
  - **Settled in code (2026-11-14), not seen on hardware.** Counted per stall, not per transfer: a timed-out (`kIOReturnTimeout` or legacy `0xe0004051`) or stray-aborted bulk OUT counts only if submitted after the previous counted stall completed. `kUplinkTimeoutsFatal` (3) stalls with no success between restart the session once (`on_uplink_stuck`, `RMNetUplinkStuckRestarts`); stuck again with no success since is `on_fatal("uplink is not accepting data")`. `RMNetUsbBulkOutTimeouts` counts the failed transfers. (317.8.44 had counted per transfer, so one 5 s stall with 3 transfers queued was fatal; fixed in the next commit.)
- A QMAP flow disable never followed by an enable pauses the uplink for good (`CoreHost::on_command` and `CoreHost::set_paused`, `driver/core_host.cpp`).
  - **Settled in code (2026-11-14, 317.8.44), not seen on hardware.** A pause not lifted within `kPauseMaxMs` (30 s, timed by `data_tick`) asks the driver to restart the session (`CoreHost::take_restart_wanted`, `RMNetDriver::RestartSession`, `CoreHost::restart`); `RMNetUplinkPauseTimeouts` counts them. The pause is timed only while the data link is up. No command frame has ever arrived, so this has never run.

Carrier MTU:
- A carrier MTU below 1500 never reaches the interface for IPv4: `setMaxTransferUnit` returns Unsupported and `getMaxTransferUnit` is read only at registration (`RMNetDriver::ApplyCore` and `RMNetDriver::getMaxTransferUnit`, `driver/RMNetDriver.cpp`); the router advertisement covers IPv6. Latent: every call so far had 1500.

Never run on hardware (add to the list above):
- A failed `Start` after `usb->start()` (the failure branch at the end of `RMNetDriver::Start_Impl`): `Start_Impl` returns the error while the stop sequence still waits on a request through the timer; whether DriverKit can free the object first is unknown, and `free()` releases the timer without `Cancel`.

Throughput, in the code and not yet measured:
- Acknowledgements share the 8 uplink slots and are dropped with data under a concurrent upload, so the backpressure fix matters for downloads too; when it is built, a freed slot must drain the transmit queue (`RMNetDriver::OnBulkOutDone` triggered nothing then). **Settled in code (2026-11-14):** a successful bulk OUT completion restarts a drain that stopped for want of a buffer; acknowledgements now wait for a buffer instead of being dropped.
- A read is re-posted only after its whole handler, and handler time is unmeasured; a per-completion maximum of handler duration is a cheap counter. **Changed in code (2026-11-14, Task 2 of the uplink-hold plan), seen on hardware (316.19.56):** `RMNetRxHandlerMaxUs` and `RMNetRxHandlerTotalUs` time each successful bulk read's handler, re-post included; in a 100-ping run the mean was about 104 µs and the maximum 457 µs.
- `RMNetDriver::RxBuffer` dequeued one receive packet per frame, about 17 calls per transfer; batch with `DequeuePackets`. **Changed in code (2026-11-14, Task 2 of the uplink-hold plan), seen on hardware (316.19.26 and 316.19.56):** a stock of up to 32 empty packets is refilled with one `DequeuePackets` call (`RMNetRxStock`); it stayed between 7 and 29 with no `RMNetRxDropNoPacket` in a 100-ping run. Its stop with a non-empty stock was not seen (the log lost it).
- One Default queue serialises receive and transmit, so a bulk-in handler delays acknowledgements by its duration.
- Two paths wait for the 100 ms timer instead of a completion: frames held for lack of `txDone` room, and receive packets the completion queue refused.
- At low rates the modem sends one packet per transfer plus a 4-byte filler, so TCP slow start pays two completions per packet, which weighs heavily in a 50 MB run.

Before the same-day comparison with the userspace tool:
- Add the handler-duration counter and the batched receive dequeue first, so the comparison can separate driver time from network. **Changed in code (2026-11-14, Task 2 of the uplink-hold plan), seen on hardware:** both ran on 316.19.26 and 316.19.56.
- The userspace tool runs on a `utun` outside `measure.sh`'s usage file, so its data must be added to the file by hand or the guard will be wrong.

## Sent here by the uplink-hold plan's whole-stage review (2026-11-14)

None of these has run on hardware.

- **Empty packets held across an interface disable and enable.** The driver now holds up to 32 empty receive packets (`RMNetRxStock`) and up to 32 kept transmit frames while idle or held, where before it held 0 or 1; whether the framework reclaims driver-held packets on `SetInterfaceEnable(false)` is unknown, and if it does they would be used twice. Needs the port switched off and on with `RMNetRxStock` above 0 (the owner's step).
- **Pool margin.** The driver alone can hold `rxOut` 256 + `rxStock` 32 + `txDone` and kept frames 256 = 544 packets against `kPacketCount` 512, with the four queues of 256 on top; no array can overflow, but during an upload the hold keeps the transmit queue full, so a download at the same time could find no empty packets (`RMNetRxDropNoPacket`), and the standing queue of about 288 frames adds latency in front of acknowledgements. If hardware shows it: raise `kPacketCount` to 1024, or give the transmit queue a smaller capacity. **Changed 2026-11-14 (hardening), changed in code, not yet seen on hardware:** the TX submission queue now has `kTxQueueCapacity` 64 (the other three queues keep `kQueueCapacity` 256), so the queues hold 64 + 3 × 256 = 832 packets at most against 4 × 256 = 1,024 before, and the standing queue in front of the driver during an upload is about 64 + 32 kept frames = 96 instead of about 256 + 32 = 288 (if the system refuses 64, `Start` falls back to 256, `RMNetTxQueueCapacity` shows it, and both figures are as before: 1,024 and 288); the rest waits in macOS's interface queue, which schedules flows fairly. The driver's own holding (`rxOut` 256 + `rxStock` 32 + `txDone` and kept frames 256 = 544) is unchanged, and so is `kPacketCount` (512). Whether the capacity really bounds what waits inside the driver's queue is measured after the install. **Seen on hardware 2026-11-14 (317.11.33):** the system accepted 64 (`RMNetTxQueueCapacity` 64); two 1.84 MB bursts passed with no drop, the second in under 0.5 s; the pings alongside still waited up to 3.5 s, and that wait is inside the modem, not in the driver (`docs/driverkit-notes.md`, "Runtime findings (hardening build)"; see "Sent here by the hardening plan" below). So the queue change is harmless for a burst and its benefit is not shown; a download during an upload, and a sustained upload, were not run. **Seen 2026-11-15 (two-way load, 317.16.8):** `RMNetRxStock` fell from 24 to 3 and `RMNetRxDropNoPacket` stayed 0; `RMNetRxHandlerMaxUs` 3,338 and `RMNetRxLagMaxUs` 6,049 µs. Close to the edge, not over it.
- **An "uplink usable" callback.** A failed bulk OUT completion, the end of a bulk OUT recovery (`UsbIo::end_out_recovery`) and a link down without a pause restart a held drain only on the next 100 ms tick; a `UsbIoListener` callback raised after `UsbIo::bulk_out_complete` has decided on recovery, and at the end of `UsbIo::end_out_recovery`, would remove that wait.
- **A host harness for `CoreHost`'s hold.** No automated test covers `CoreHost::transmit` returning false, the re-offer of the kept frame, or frame order; nor the kept QMAP command replies.
- **The burst tool's remaining signal cases.** A second signal inside the interrupt handler of `scripts/uplink-burst.py` ends with a traceback, though the usage line is written; SIGQUIT and SIGKILL leave no line.

Small hardening left open:
- The frame-length minimum tests. **Changed 2026-11-14 (hardening), Task 1 (`90755d8`): closed:** `frame_length_at_its_minimum_lengths` (`qmi_frame_length` at its minimum lengths).
- A refresh during a retry abandons an allocated client until the next sync.
- The Get Client ID retry path has no test. **Changed 2026-11-14 (hardening), Task 1 (`90755d8`): closed:** `retry_of_a_family_that_never_got_a_client_starts_from_get_client_id`.
- `tick` could check `!pending_.active ||`.
- An empty CDHash is reported as "older build running" by the install script.
- The install script's stop check sees only the `activated enabled` entry.
- `PrefixLength` is duplicated, and it and `FormatIPv6` are untested.
- "usb failed" is published for about 4 s on re-enumeration.
  - **Settled in code (2026-11-14, 317.8.44).** `RMNetState` says `detached` instead when UsbIo had seen a not-attached or no-device status (`UsbIo::device_gone`). Not yet seen: the instance replaced at the 317.8.44 load was the older 316.19.56, which still said `usb failed`; the next reload is the first that can show it.
  - **Reopened (2026-11-14, sleep and wake task).** The reload of 317.8.44 showed it never fires on a modem reboot: the re-post fails with `0xe00002d8`, which is `kIOReturnNotReady`, not `kIOReturnNotAttached` (`0xe00002d9`), and the interrupt read itself ends `kIOReturnAborted`. `Gone()` in `driver/usb_io.cpp` matches neither. Decide whether `kIOReturnNotReady` from a submission means gone (it may also come from a bus not yet awake after a sleep).
  - **Decided (2026-11-14, the recovery plan's final review): `kIOReturnNotReady` does not count as gone, and `Gone()` stays as it is.** See that review's section below.
- A failed `WakeAtTime` ends all ticks, and while stopping can stall `Stop`. Since the uplink-hold plan's fix wave it matters more: `TxPacketsAvailable_Impl` returns early while a hold is on, so after a failed bulk OUT completion, the end of a recovery or a link down, the 100 ms tick is the only thing that restarts a held drain. With no tick and no transfer in flight, the uplink would stay held for good. Not seen.
  - **Settled in code (2026-11-14, 317.8.44), not seen on hardware.** A failed arm is remembered and `RMNetDriver::EnsureTimer` retries it from every completion handler, `TxPacketsAvailable_Impl` and `RxPacketsAvailable_Impl`, also while stopping, never after the stop sequence has cancelled the timer; `RMNetTimerArmFailures` counts failures. A failed arm also counts as no timer in `AdvanceStop`'s two waits, and a failed re-arm in the stopping tick advances the stop at once, so `Stop` finishes without its timer (fix round 1, after 317.8.44).
- The first-time log line "first qmap command reply kept" (`CoreHost::keep_reply`), like `first qmap command` and `first uplink transfer`, can fall inside a bulk-read handler that `RMNetRxHandlerMaxUs` times, so one of them could set the maximum once.
- `docs/driverkit-notes.md` says build 316.19.9 "saw about 860" drains that did nothing during the burst. That figure is an estimate (999 refused offers minus 135 transfers), not a count.
- Packets held at `Stop` are abandoned (watch the driver process's memory in the soak).
  - **Soak run (2026-11-14, 317.9.11), memory not watched.** `scripts/soak.sh en33 30` passed (`docs/driverkit-notes.md`, "Runtime findings (30-minute soak)"), but it records no process memory, and no `Stop` happened during it. `RMNetPacketsHeld` was 0 in the first and the last sample.
- `acquire_uplink` ignores `failed_`. **Changed 2026-11-14 (hardening): done:** it refuses after a failure, as while recovering.
- `logged_bad_qmap_` is dead. **Changed 2026-11-14 (hardening): done:** removed.
- `Worth` is duplicated.
- A failed `setDataOffAndLen` is ignored.
- `RMNetPoolPacketCount` publishes a fixed total.
- `DrainTx` also flushes when it stops for lack of `txDone` room.
- A successful read during a recovery resets the recovery count.
- `measure.sh`: TERM exits 130. **Changed 2026-11-14 (hardening), Task 3 (`9966996`): done:** TERM now exits 143 and HUP 129 (INT stays 130); the usage record on an interruption is unchanged.
- `measure.sh`: the FAILED message blames curl when the interface vanished.
- `measure.sh`: the gate window starts up to one sample late.
- `measure.sh`: a counter reset loses up to 0.25 s of traffic.
- `measure.sh`: overhead can take a run a few MB past its reservation.
- `measure.sh`: a SIGKILLed run leaves no record.
- `measure.sh`: an empty usage file is accepted as 0.
- `measure.sh`: a loopback run charges the real usage file unless `MEASURE_USAGE_FILE` is set.

### Left by the re-review of the final fix wave

There was one fix wave, so these four wording errors are still in the tree at `67d40c9`. None changes behaviour. **Changed in code (2026-11-14, Task 2 of the uplink-hold plan):** all four are corrected; the reworded link-up line was seen in the log of 316.19.56 (`... so the interface keeps the mtu it registered with`).

- `README.md:18` says the link is reported up "as soon as one family has its settings". Core reports link up only after both families have been attempted, IPv4 then IPv6, and at least one has settings (`core/src/session.cpp:364-374`).
- `README.md:23` says every run of `scripts/measure.sh`, "also a failed or interrupted one", appends a usage line. A run killed with SIGKILL leaves none.
- `scripts/install-driver.sh:40` prints "stopping before anything is changed" on both reads of the driver listing. On the second read, after `activate`, the app has already been replaced and activated.
- The link-up line in `RMNetDriver::ApplyCore` logs "the interface keeps the mtu it registered with" unconditionally. That is true today because `setMaxTransferUnit` returns Unsupported; it would be wrong if that call ever succeeded.

Also open from that wave: the driver now reads `RMNetProfile` and passes it to Core, but this is proven only by reading the code. The published value is 1, which is also the fallback, and the log line that names the profile in use was lost by the log stream. Proving the read needs one install with a different value in `driver/Info.plist`.

## Observed on the modem

- Each downlink packet arrived in its own USB transfer, followed by a separate 4-byte all-zero transfer.
- An empty GET_ENCAPSULATED_RESPONSE is answered with a STALL, which the transport treats as "nothing waiting".
- The IPv4 address is not always in `10.0.0.0/8`; one call returned `172.25.136.104/28`. Masks seen: /28, /29, /30.
- Matching on vendor and product in an IOKit matching dictionary found nothing; the harness reads the registry properties itself.
- Only interface 4 has class, subclass and protocol all `0xff` on this firmware.

## Deferred minor findings

None of these is a known defect. Each is a missing test or a small hardening.

Tests that would pin existing behaviour:

- QMUX: a non-CTL frame with an invalid kind byte; a TLV chain with a 1 or 2 byte tail.
- QMI messages: short IPv6 and MTU TLVs; an IPv6 reply not clobbering IPv4 DNS; a failed parse leaving fields unchanged.
- QMAP: the 16-bit length limit; a zero-length packet; a non-zero header with zero length; `usb_packet_size` 0; a small reply buffer; an offset past the end.
- Session: the frames sent by the teardown on entering Backoff; the 60000 ms Start Network timeout; the backoff steps after the first.
- IP: buffer-too-small and length-overflow paths of the builders.
- Ethernet: padding trim; an IP length larger than the frame; version and EtherType mismatch; short IPv4; malformed ARP; a small ARP reply buffer.
- DHCP: the `0xffff` substitution when the UDP checksum computes to zero.
- Neighbour discovery: a multicast solicitation target; a small advertisement buffer; unicast IPv6 on a link with no IPv6; a packet with a next header other than 58 whose first payload byte is 134.

Small hardening:

- Drop a neighbour solicitation whose target is `::` or `::1`.
- A status-1 indication for a family whose own Start Network is still unanswered is forgotten if the start then succeeds.
- `family_has_settings` relies on which address TLVs a reply carries, not on which client replied.
- `qmap_write_header` truncates silently if its length precondition is broken; every caller checks first.
- Two tests index a list right after checking its size (`d.dns[0]`, `d.rdnss[0]`), so a regression would crash the run instead of failing one test.
- `CHECK_EQ` needs the `u` suffix for unsigned comparisons; `hex()` does not accept `\r`.
- Harness only: echo replies are not checked for destination; `sent` counts requests that never left; gateways print twice under `-v`.

## Sent here by the recovery plan's Task 3, sleep and wake (2026-11-14)

- **Sleep and wake.** Build 317.9.11 holds `UsbIo` at power off and resumes it and restarts the session at power on (`docs/driverkit-notes.md` 3.8, "As built").
  - **Seen on hardware (2026-11-14, 17:22 to 17:23), for one case:** the device stayed attached and its requests stayed pending. Two power-offs and two wakes (for three sleep entries in `pmset -g log`; which one did not reach the driver is unknown), the same driver instance throughout, `RMNetSleepCompletions` 0, link up 0.58 s after the last wake with new addresses in both families, both pings 5 of 5, every USB error counter 0 (`docs/driverkit-notes.md`, "Runtime findings (sleep and wake)").
  - **Open (not seen):** a sleep during which the stack cancels or fails transfers; a re-enumeration on wake; a bus that answers not-ready at the wake call; a sleep longer than half a minute; a `Stop` while asleep.
- **A bus not ready at the wake call is fatal.** If posting the interrupt read or a bulk read at resume fails (for example with `kIOReturnNotReady`), the port goes down as `usb failed` and stays down until a re-enumeration or a manual reload; nothing retries. That meets "fresh addresses or down", but a retry after a short delay may be needed if it is ever seen. Not seen in the one test. **Raised from minor by the recovery plan's final review; open** (below). **Changed 2026-11-14 (hardening): built, not seen on hardware;** see "No retry at the wake" below.
- **Uplink transfers that complete while held** are counted neither as sent nor as dropped (`RMNetTxPackets`, `RMNetTxDropUsb`), and reads that complete while held are discarded unread.

## Sent here by the recovery plan's Task 5, the soak (2026-11-14)

- **The 30-minute soak has been run.** `scripts/soak.sh en33 30` on 317.9.11, 17:25 to 17:55: `soak: PASS`, the state `up` in all 181 samples, every listed error and drop counter 0 first and last, 0.0 % loss on 3,560 IPv4 and 3,559 IPv6 pings, about 15.2 MB moved (`docs/driverkit-notes.md`, "Runtime findings (30-minute soak)"). Under light traffic only (two 1,000-byte pings a second in each family); sustained heavy traffic has not been soaked.
- **The liveness probe is noisy in the log.** Every 30 s, idle or not, it logs three lines: `qmi tx WDS client 15 msg 0x002d`, the `result ok` response, and `settings IPv4: ...` (61 probes, 183 lines, in the soak's 30 minutes, and nothing else). A candidate to quieten: log the probe's exchange and an unchanged settings line only when something differs or fails. **Changed 2026-11-14 (hardening): done in code, not yet seen on hardware:** the `settings IPv…` line is logged only when the reply's settings differ from the ones last logged for that family (the first of a session and the first after a restart always), so the probe should cost two lines every 30 s.

## Sent here by the recovery plan's final review (2026-11-14)

Decisions (the controller's rulings for the one fix wave):

- **`detached` and not-ready (decided).** `kIOReturnNotReady` does not count as "device gone": held completions, and a submission right at the wake, can plausibly return not-ready from a device still attached, and counting it as gone would turn a recoverable wake into a permanently detached port; so on a modem reboot the old instance shows `usb failed` for a few milliseconds before `Stop`, and the window may show "Link down" once. `Gone()` in `driver/usb_io.cpp` is unchanged.
- **No retry at the wake (decided: recorded, not built; the gap stays open, raised from minor).** If a re-post is refused when the driver resumes, the port goes down as `usb failed` and nothing retries until a re-enumeration or a manual reload; a retry of `resume` and the restart from the tick for about 5 s would close it. Not built because the bus was ready at the wake on 2026-11-14 and the new resume state could not be exercised here. **Changed 2026-11-14 (hardening): built, not seen on hardware:** a refused post at the wake (not "device gone") keeps `UsbIo` held and the driver tries the whole resume again from every tick until it succeeds or `kResumeRetryMs` (5000 ms) after the wake call, then fails as before; `RMNetWakeRetries` counts the attempts after the first (`docs/driverkit-notes.md`, "Changed in code, not yet on hardware (hardening)").
- **The window's 2-second refresh stays (decided).** The plan asked for it; it asks the system for the listing every 2 s.

Open:

- **A pause that keeps coming back.** A modem that keeps its flow-control pause makes the session restart about every 30 s with no "second time is fatal" rule; between restarts the link looks up and passes no uplink traffic. Never seen.
- **A gap in the design (seen once on hardware 2026-11-14 22:25: radio off and on with the modem attached; link down at once, up again 11 s after the radio returned; notes, "Runtime findings (in-band flow control)").** Goal 5 names "the network dropping the connection", but no "Done means" line covers it; a network-side drop with the modem still attached has never been seen on hardware (Core's tests and the disconnect indication at modem reboots cover the logic).
- **Testing the driver.** Nothing under `driver/` has a test; the cheapest worthwhile step is to move the uplink stall counter (`out_seq_`, `out_stall_mark_`, `out_stalls_`, `out_stuck_restarted_`) into a small plain C++ struct under `core/` and unit-test it (`CoreHost` would need a `UsbIo` interface to be testable on the host). **Changed 2026-11-14 (hardening): started:** the stall counter is `rmnet::UplinkStallCounter` in Core (`core/include/rmnet/stall.h`) with unit tests (`tests/test_stall.cpp`, Task 1, `90755d8`), and `UsbIo` uses it in place of the four fields (Task 2 of the hardening plan, `1f3beb1`). `CoreHost`, `UsbIo` and the rest of `driver/` still have no test.

Minor, one line each:

- Core: the probe's "contents ignored" check is weak. **Changed 2026-11-14 (hardening), Task 1 (`90755d8`): closed:** `probe_reply_settings_never_reach_a_later_link_up` checks it for real.
- Core: the teardown after the probe's redial is unchecked.
- Core: only one reconfigure order is tested. **Changed 2026-11-14 (hardening), Task 1 (`90755d8`): closed:** the other family in the reverse order (`reconfigure_for_ipv4_during_an_ipv6_refresh_is_not_lost`), a repeated indication for the family being refreshed (`another_reconfigure_for_the_family_being_refreshed_is_ignored`), a disconnect while one is remembered (`disconnect_while_a_refresh_is_remembered_forgets_it`).
- Core tests: `without_tlv` is duplicated. **Changed 2026-11-14 (hardening), Task 1 (`90755d8`): closed:** moved into `tests/frames.h`.
- Driver: "timer armed again" can flood the log. **Changed 2026-11-14 (hardening): done:** logged only at the power-of-two steps of the arm failures.
- Driver: `usbDetached` is fixed at the moment of the fatal report.
- Driver: with a failed timer arm, a held drain or an abort that never returns waits for unrelated traffic.
- Driver: the host stack's own aborts count as an uplink stall.
- Driver: whether the 5 s uplink timeout runs from submission or from the head of the queue is unknown.
- Driver: a pause-timeout restart does not reset the stall count.
- Driver: a timeout during a bulk OUT recovery still counts as a stall.
- App: the table keeps the last known versions when the listing turns unknown. **Changed 2026-11-14 (hardening), Task 3 (`9966996`): done:** the installed-version row reads `unknown` while the listing is unknown (and while the first listing is pending); the bundled row comes from the app's own bundle and stays.
- App: with no embedded driver, the "cannot" text gives the wrong reason.
- App: `Remove…` does nothing, silently, if the listing turns unknown while the confirmation is open.
- App: a properties request that never answers leaks one delegate every 10 s.
- App: the buttons stay off while an approval is pending.
- App: the "switched off" advice fires for any two-entry listing, an update in progress included.
- App: the window asks the system for the listing every 2 s.
- Sleep: a re-enumeration during the sleep shows `usb failed`.
- Sleep: uplink packets that complete while held are counted neither as sent nor as dropped.
- Sleep: "control request failed" is logged for requests aborted at suspend.
- Sleep: nothing tests hold, resume, or stopping while held.
- `soak.sh`: a sample whose status has an `error` key is classed unreadable even when the registry part says `up`.
- `soak.sh`: the crash-report listing hides a permission failure and does not list `Retired/`.
- `soak.sh`: the usage reader is a copy of `measure.sh`'s.
- The liveness probe writes three log lines every 30 s. **Changed 2026-11-14 (hardening): done, seen on hardware (317.11.33):** an unchanged `settings IPv…` line is no longer logged; ten probes wrote two lines each.

## Left by the recovery plan's last re-reviews (2026-11-14)

From the final fix wave's re-review (items (1), (2) and (4) of its eight Minor residuals were README statements, corrected in the "Done means" table and the app section):

- App: `ExtensionManager`'s "cannot" text says the bundled version "is not listed" when it is listed as uninstalling. **Changed 2026-11-14 (hardening), Task 3 (`9966996`): done:** the text comes from `cannotRemoveText`, a pure function in `app/StatusModel.swift` with checks, which says the system is already removing it.
- Driver: the corrected comment in `RMNetDriver.cpp` says the transfers end in `kIOReturnNotReady`, but the interrupt read ends in `kIOReturnAborted` and the re-post is refused with not-ready. **Changed 2026-11-14 (hardening): done:** the comment at `RMNetDriver::OnUsbFatal` says so.
- App: one vacuous check and one dead branch in the status model. **Changed 2026-11-14 (hardening), Task 3 (`9966996`): done:** the check is replaced by four that can fail; that dead branch and a second one (the one-entry uninstalling line in `advice`) are removed.
- App: the not-QMI advice lines are dropped while every entry is uninstalling. **Changed 2026-11-14 (hardening), Task 3 (`9966996`): done:** they are now kept.
- App: `installTitle` compares versions as numbers and `canRemoveDirectly` as text. **Changed 2026-11-14 (hardening), Task 3 (`9966996`): done:** both, `removalPlan`'s stuck branch and the install confirmation now use `compareVersions`.

From the soak fix's re-review (`scripts/soak.sh`):

- `pgrep -f io.rmnetdriver.RMNet.driver` also matches the `log stream` process of `scripts/driver-log.sh`, so starting or stopping the log during a soak gives a false "driver restarted" FAIL (anchor the pattern on the dext path). **Changed 2026-11-14 (hardening), Task 3 (`9966996`): done:** the pattern is anchored on the dext's own path (`^[^ ]*\.dext/io\.rmnetdriver\.RMNet\.driver( |$)`); checked read-only on this Mac, it finds only the driver's process.
- The default-route check cannot see a VPN tunnel carried over the port.
- A signal during the first sample leaves a hanging status command running.
- The first sample's seconds are measured from a different start.
- `netstat` has no timeout.

The owner's five steps are still open, as listed in the README ("Owner steps still to do"). With the owner away, the controller established on 317.10.17 that the app's window opens (one window, 480 by 452 points, up for 75 s, no crash report) and what its model (`status --json`) says, without seeing the window (step 1); and, read only, that the port and an enabled service `RM520N-GL` exist and Internet Sharing is off, without looking at the Sharing pane (step 4). Steps 2, 3 and 5 were not done.

## Sent here by the hardening plan (2026-11-14)

Plan `docs/superpowers/plans/2026-11-14-hardening-while-away.md`, branch `hardening` (on top of `recovery`), build 317.11.33 installed and running. Results: `docs/driverkit-notes.md`, "Runtime findings (hardening build)".

- **The wait behind an upload is inside the modem (new; largely answered, see the note at the end of this entry).** With a 1.84 MB burst on the uplink, pings sent alongside were answered 0.2 to 3.5 s late on 317.11.33 (19:35 and 19:39), although the driver had handed the whole burst to the modem in under 0.5 s and the echo requests left the Mac on time. The modem takes data over USB much faster than the cell takes it over the air, queues it in order, and has never sent a flow-control command (`RMNetQmapCommands` 0 in every run). No change to the driver's own queues can shorten this. Two ways to: get the modem to push back, or have the driver limit what it hands over to an estimate of the uplink's rate. For the first: Core's WDA Set Data Format request does not ask for in-band flow control (it sends no flow-control TLV; libqmi lists one for this message, to be checked there before relying on it), which may be why no command has ever arrived; QMI's data flow control service is another mechanism; what this firmware supports, and at how many queued bytes it would push back, is not known. For the second: watching how fast uplink transfers complete does not give the rate, because the modem accepted 1.84 MB within half a second. Either is a design decision for the owner; neither is planned. What a user would notice: interactive traffic stalls for as long as the modem needs to send whatever a bulk upload has queued, a few seconds on a slow uplink. **Changed 2026-11-14 (in-band flow control, branch `flow-control`, `1b47ab2`; seen on hardware):** Core now asks for flow control in Set Data Format (personality key `RMNetFlowControl`, 1), and this firmware grants it. On the same cell two minutes apart, the burst that took the modem about 3.9 s and held pings up to 2.1 s without the request went out within 0.8 s with it, and no ping waited more than 0.41 s; a 3 MB real upload with the request on delayed no ping (`docs/driverkit-notes.md`, "Runtime findings (in-band flow control)"). The modem sent no flow command in any run, so why it helps is not known, and the driver's pause path is still unrun.
- **The 64-entry transmit queue under a sustained upload: not measured.** Only bursts were run on 317.11.33. The capped measurement tools refuse (300 MB ceiling). If a later upload measurement is slower than the 38 Mbit/s recorded on 316.19.56 under comparable signal, set `kTxQueueCapacity` back to 256 before looking anywhere else. **Measured 2026-11-15 (317.16.8, flow control on):** an 8-second upload gave 33.6 Mbit/s with a best second of 56.6 and no drop, in the range of the 38 Mbit/s recorded before the change (another cell and hour); nothing points to the queue as a loss (`docs/driverkit-notes.md`, "Runtime findings (measurements with the new budget)").
- **Settled:** `IOUserNetworkTxSubmissionQueue::Create` accepts a capacity of 64 on macOS 27.0; the fallback to 256 exists and has not run.
- **The wake retry has not run in any form on 317.11.33** (no sleep since the load). The first sleep and wake on this build runs its first-attempt path, which the reviews found identical to the old code; the not-ready branch needs a bus that is not ready.
- "usb resumed on retry N" (`driver/RMNetDriver.cpp`, `ResumeUsb`) prints `wakeRetries`, the retries since the instance started, not those of this wake.
- The "N bulk reads posted" figure in the `usb resumed` line counts posts across attempts and can exceed 32 after a retried resume; exact on the first-attempt path.
- The wake retry is driven by the timer tick only: if the timer cannot be armed while a resume is pending, nothing retries until another entry re-arms it, and the next attempt is then already the last.
- Reads and interrupt notifications that complete while a resume is pending are discarded (the rule for every completion while held); the session restarts from sync after the resume.
- App: the install confirmation's version comparison (`app/StatusView.swift`) uses `compareVersions` but has no check, because it lives in the view.
- `make test FILTER=stall` runs 3 of the 6 stall tests (the other names do not contain "stall"); `make test` runs all.
- `scripts/measure.sh`: two different signals arriving while the transfers start, the last one sets the exit code.

## Sent here by the flow-control plan (2026-11-14)

Plan `docs/superpowers/plans/2026-11-14-in-band-flow-control.md`, branch `flow-control`, build 317.14.28 installed and running with flow control granted. Results: `docs/driverkit-notes.md`, "Runtime findings (in-band flow control)".

- **Never run, now reachable:** the modem has been told the host handles flow control, so it may one day send QMAP flow disable. Then `CoreHost::on_command`'s pause, the kept replies and the 30 s pause limit run for the first time; if the pause does not end, the driver gives flow control up for the life of the instance and restarts the session. None of that, nor the fallback after a refused request, has been seen. Watch `RMNetQmapCommands`, `RMNetUplinkPauseTimeouts` and `RMNetFlowControlRefused`.
- **Not measured with flow control on:** a long upload, a download during an upload, download speed. The earlier figures (38 Mbit/s up at 16:27, 232 to 303 Mbit/s down) are from builds that did not ask. **Measured 2026-11-15:** a short and an 8-second upload (25.0 and 33.6 Mbit/s; every ping alongside answered within 148 ms) and the 8-second download (154.8 Mbit/s, best second 177.2; the driver busy about 5 % of the time). A download during an upload is still not measured.
- **An uplink stall without flow control (seen once, 20:44, PCI 32):** after a 1.84 MB burst the modem's sent counter stood still for about 7 s and two uplink transfers reached the 5 s timeout; the stall counter counted them, no restart was needed, and the link recovered by itself. First time the uplink timeout path ran on hardware (two of the three stalls that would ask for a restart).
- **Why the request helps is unknown.** If a later firmware or another modem answers `0x1B` = 1 and behaves differently, the key `RMNetFlowControl` 0 restores the old request.
- A Set Data Format response with no result TLV is logged `data format refused (error 0x0)` (`driver/core_host.cpp`); the `qmi rx` line before it shows result `-`.
- A timeout of the request that asks counts as a refusal for the life of the driver instance (by the plan): a slow first answer turns flow control off until the next load.
- The capped test tools' ceiling is 310,000,000 recorded bytes and is reached again (309,701,068).
- `AT+CFUN=0` / `AT+CFUN=1` makes the modem choose a cell again without a USB re-enumeration; `AT+QGDNRCNT?` reads the modem's own sent and received byte counts. Both are useful in tests and change nothing lasting.

## Sent here by the SMS plan (2026-11-15)

Plan `docs/superpowers/plans/2026-11-14-sms-in-the-app.md`, branch `sms`, build 317.16.8 installed. Results: `docs/driverkit-notes.md`, "Text messages in the app, on the modem".

- **For the owner:** look at the `Messages` tab (nobody has seen it); send one message from it; quit during a send once (the app should wait, then quit; a failed send should cancel the quit); check that the window can be reopened after a cancelled quit (Window menu or Dock).
- **A lasting modem setting was changed:** `AT+QCFG="ims",1`, with the owner's yes on 2026-11-14. Without it this SIM has no SMS on 5G standalone (`+CMS ERROR: 350` on a send, nothing delivered). Undo with `AT+QCFG="ims",0` and a reboot.
- New messages are found by listing (every 15 s while the `Messages` tab is shown); there is no notification, by the owner's choice for this version. The modem's `+CMTI` lines go to the console's port.
- Listing marks messages read on the modem, so the window and `sms list` disagree about `unread`.
- The store is never emptied by the app; at 90 % the window and the verb warn. Whether the modem tells the network that room is free again after deletes from a full store is not tested.
- Multi-part messages: two different messages from one sender that reuse a reference and total within 15 minutes, with interleaved or missing parts, can exchange parts (documented at the grouping code). A surrogate pair split across two parts shows as two replacement characters. A CR LF split across two parts shows as two line breaks.
- Stored entries that are not received messages (sent copies, status reports) are listed as not readable.
- The AT port: a stale lone `OK` can still settle "no echo" at open if the probe's own `OK` comes more than 50 ms after its echo; unsolicited lines in the middle of an answer are returned as answer lines (the parsers ignore unknown lines); a failure before the send prompt is worded "not known".
- The window: if the text view goes away during an input-method composition, `Send` stays off until the next keystroke; the delete confirmation's identity check is as fresh as the last listing; `kill` (SIGTERM) to the window process ends it mid-send; the controller's checks do not cover a quit during a failing listing or a second quit after a cancelled one (a reviewer ran both by hand: fine).
- The verbs: an alphanumeric sender can make its own header line of `sms list` look odd (it cannot start or rewrite a line); U+2028 and U+2029 survive in texts.

## Sent here by the measurements plan (2026-11-15)

- **The design's throughput line is still not met by the letter:** 154.8 Mbit/s over the 8-second test against 200. The driver's counters show no limit in the driver. The remaining way to settle the line is the same-half-hour comparison with qmi-darwin, which needs the driver detached (the owner's step) and about 300 MB for the two runs.
- Not measured: the tests on PCI 32. **A download during an upload, measured 2026-11-15 01:37:** 143.2 Mbit/s down and 30.4 up at once, against 154.8 and 33.6 alone on the same cell; pings during the load median 78 ms, slowest 202 (`docs/driverkit-notes.md`, "Runtime findings (two-way load)").
- `scripts/measure.sh`: a pause of 0.25 s in an upload's drain ends the settle wait early (at most about 16 MB unrecorded); a signal during the settle can make the wait about 12 s; `netstat` has no timeout; a signal inside `advance` could count one step twice.
- The data budget is now 400 MB plus 1 GB (added by the owner on 2026-11-15); the scripts' ceiling on recorded use is 1,300,000,000 bytes; 509,193,836 are recorded.
