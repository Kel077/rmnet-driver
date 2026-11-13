# Core and harness: follow-ups

Date: 2026-11-13. The plan `2026-11-13-core-and-harness.md` is complete on branch `core-and-harness`: 83 unit tests pass, every Core file passes the DriverKit syntax check, and the harness connected and pinged over IPv4 and IPv6 through the real modem with no root.

This file records what the reviews left open, so the driver plan can pick it up.

## Required in the driver plan

These came from the whole-branch review and from running against the modem.

- **Retry a family that failed while the other came up.** For about three seconds after a call is torn down, a new IPv4 Start Network often fails with call end 1008 (3GPP reason 36), and the link comes up IPv6-only. Core never retries the missing family, and a successful link-up resets the backoff, so the port stays IPv6-only until the next drop. Redial after a network drop and after wake both land inside that window, because the first backoff is 2000 ms. Retry the missing family while Up, without taking the link down. Revisit the first backoff value at the same time.
- **Link Core into an empty driver target in the first task.** `make check-driverkit` only syntax-checks. Linking against the DriverKit runtime is unproven, for example the pure virtuals in `SessionDelegate`.
- **Send unsolicited router advertisements.** `make_router_advert` must be sent on link up and at least every 600 seconds; the router and DNS lifetimes are 1800 seconds.
- **Check on the live driver:**
  - whether macOS accepts a broadcast DHCP ACK in answer to a unicast renewal;
  - what macOS does with addresses from an old /64 after a link bounce, since every call gets a new prefix;
  - whether a neighbour solicitation for the Mac's own address ever reaches the driver, and if so whether answering it causes harm;
  - whether the modem accepts 4 to 7 bytes of padding on the last uplink frame (the exact-multiple-of-1024 case), which needs a throughput run to hit.
- **Decide when IPv4 counts as up.** Today the address TLV alone sets `has_v4`. If the gateway or mask were missing, DHCP would offer a zero router and mask.
- **Do not copy the harness's synchronous bulk write** into the driver. It blocks its queue for up to 5 seconds.
- **Move QMUX frame splitting into Core.** The harness splits a control read into frames itself; `qmi_decode` does not report how many bytes it consumed.
- **Count QMAP command frames.** The modem sent none during testing, so flow-control replies are unproven on hardware.
- **Add a liveness check for the Up state.** A modem that goes silent leaves the session Up.
- **Handle a reconfigure for the second family during a refresh.** It is currently lost, leaving that family's settings stale until the next event.

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
