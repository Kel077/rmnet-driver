# Core and harness: follow-ups

Date: 2026-11-13. The plan `2026-11-13-core-and-harness.md` is complete on branch `core-and-harness`: 83 unit tests pass, every Core file passes the DriverKit syntax check, and the harness connected and pinged over IPv4 and IPv6 through the real modem with no root.

This file records what the reviews left open, so the driver plan can pick it up.

## Required in the driver plan

These came from the whole-branch review and from running against the modem. Status as of the end of the plan `2026-11-13-driver-to-throughput-gate.md` (branch `driver`, 2026-11-14): **settled** only where a commit or a task report shows it.

- **Retry a family that failed while the other came up.** For about three seconds after a call is torn down, a new IPv4 Start Network often fails with call end 1008 (3GPP reason 36), and the link comes up IPv6-only. Core never retries the missing family, and a successful link-up resets the backoff, so the port stays IPv6-only until the next drop. Redial after a network drop and after wake both land inside that window, because the first backoff is 2000 ms. Retry the missing family while Up, without taking the link down. Revisit the first backoff value at the same time.
  - **Settled in Core, open on hardware.** The retry is in Core with unit tests (`e8f6c6a`, `9c22931`). It was never seen on hardware: `AT+CGACT=0,1` answered ERROR three times (Task 6 report, Step 5), so no family was lost while up. The first backoff is still 2000 ms (`kFirstBackoffMs`); it was not revisited.
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
  - **Open.** Unchanged: `parse_wds_current_settings` still sets `has_v4` from the address TLV alone.
- **Do not copy the harness's synchronous bulk write** into the driver. It blocks its queue for up to 5 seconds.
  - **Settled.** Not copied: every bulk transfer in `driver/usb_io.cpp` is an asynchronous `AsyncIO` (`2bd8077`).
- **Move QMUX frame splitting into Core.** The harness splits a control read into frames itself; `qmi_decode` does not report how many bytes it consumed.
  - **Settled.** `74590e2`.
- **Count QMAP command frames.** The modem sent none during testing, so flow-control replies are unproven on hardware.
  - **Settled as counting, open on hardware.** `2bd8077` counts them (`RMNetQmapCommands`, flow disable and enable, replies); none arrived in any task, Task 7's runs included.
- **Add a liveness check for the Up state.** A modem that goes silent leaves the session Up.
  - **Open.** None exists; it is in the next plan.
- **Handle a reconfigure for the second family during a refresh.** It is currently lost, leaving that family's settings stale until the next event.
  - **Open.** Unchanged: `Session` acts on a reconfigure indication only in the Up state, so one arriving while Refreshing is still dropped.

## Left open by the driver plan

- **Paths never run on hardware:** a `Stop` with USB requests still in flight (every observed `Stop` found none outstanding), bulk stall recovery and its 1 s deadline, QMAP flow control (no command frame ever arrived), the IPv4 retry while up, and unplugging the modem with the driver running.
- **Uplink drops when busy.** With all 8 uplink buffers in flight the driver drops transmit frames instead of leaving them in the TX submission queue: 12,467 drops under `networkQuality` (Task 6) and 2,343 in Task 7's 6-second upload, which measured 11.9 Mbit/s on the port's counters (dropped frames included) against 36 for the userspace tool. Not changed.
- **The throughput gate was not passed by its definition.** The download gate figures were 129.2, 138.3 and 92.6 Mbit/s, against 150 (`docs/driverkit-notes.md`, "Runtime findings (throughput, Task 7)").
  - **What was shown.** There was no sign of receive-path starvation, drops or CPU saturation in the driver. Read lag was measured in run 4 only: at most 1.05 ms from completion to handler. There were no drops or queue refusals, and the driver process used about 10 % CPU. The path carried 182 Mbit/s for about a second in run 3.
  - **What was not measured.** Read headroom in the faster runs; the time a read spends in its handler; latency in the transmit and acknowledgement path, which affects how TCP ramps up; macOS's work after `EnqueuePackets`; and whether the modem's data format matches the userspace tool's.
  - **Why measuring stopped.** One 50 MB run cannot show an effect smaller than the 46 Mbit/s spread between runs of the same receive path.
  - **What decides it.** Only a same-day comparison with the userspace tool under `scripts/measure.sh` can separate the driver from the network, and it needs the owner.
- **Upload.** 11.9 Mbit/s on the port's counters, which include the dropped frames; the driver delivered about two thirds of those bytes to the modem (6.7 of 10.1 MB).
- **All hardware testing is under a data budget.** The SIM is metered: 400 MB was left on 2026-11-14 for all remaining testing, and Task 7 used about 171 MB of it (`build/installed/measure-usage.log` records each measurement). Measurements were therefore capped at 50 MB, which makes each one short and noisy.

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
