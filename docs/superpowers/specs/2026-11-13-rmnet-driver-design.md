# RM520N-GL QMI network driver for macOS: design

Date: 2026-11-13. Status: awaiting the owner's approval. Nothing is built yet.

## Intent

Build a macOS driver that makes a Quectel RM520N-GL 5G modem, running in its QMI USB mode, appear as an ordinary wired network port. The owner plugs the modem in, the port shows up in System Settings, it configures itself, and the Mac has the carrier's connection on it.

QMI is Qualcomm's control protocol for the modem (connect, get addresses). In QMI mode the modem carries user traffic as raw IP packets wrapped in QMAP, a small framing that multiplexes and batches packets over USB. Linux calls this combination "rmnet".

Why, as far as it is known:

- macOS ships no driver for the modem's QMI mode. Its built-in driver only handles ECM mode, in which the modem acts as a NAT router in front of the Mac.
- Measured on this Mac on 2026-11-13, on the same cell, against the same server, with four parallel streams: QMI mode through a third-party userspace tool (qmi-darwin) gave 226 Mbit/s down and 36 Mbit/s up. ECM mode gave 38 and 62 Mbit/s down and 1 and 5 Mbit/s up over two runs. QMI was measured once and first, so a change in radio conditions is not ruled out.
- qmi-darwin presents a `utun` tunnel interface and needs a root process. After trying it, the owner chose to build a real driver instead.
- The owner has not stated a purpose beyond this. The author's reading is that they want the modem to behave like a first-class network port at full speed on their own machines.

## Goals for the first version

1. With the modem in QMI mode, plugging it in produces a network port that appears in System Settings like an Ethernet adapter, and can be chosen there as the source for Internet Sharing.
2. The port configures itself with no manual steps: IPv4 address, router and DNS, and IPv6 addresses, router and DNS.
3. One internet connection, using the modem's existing data profile 1, over IPv4 and IPv6.
4. Throughput in the region of the 226 Mbit/s measured through qmi-darwin, when the radio allows it.
5. It recovers by itself from unplug and replug, from sleep and wake, and from the network dropping the connection.
6. A small app installs and removes the driver and shows its status.

## Non-goals for the first version

- IMS, more than one connection at a time, QoS reporting, SMS.
- Band, mode, SIM or signal tools, and any editing of the modem's data profiles.
- Switching the modem between ECM and QMI mode. The owner does this once by AT command (`AT+QCFG="usbnet",0`, then `AT+CFUN=1,1`).
- Other modems, including other Quectel models.
- Checksum or segmentation offload, VLANs, wake-on-LAN.
- Distribution to Macs that are not registered on the signing team.
- Any policy for choosing between Wi-Fi and cellular. The port is one more network service, and macOS's service order decides.

## Anti-goals

These would make the result a failure even if it works:

- A root helper, a launch daemon, a `utun` interface, a kernel extension, or any step that changes System Integrity Protection.
- Use of private macOS interfaces.
- Any code copied from qmi-darwin. It has no license. It may be read to learn how the modem behaves.
- Persistent changes to the modem: profiles, the LTE attach list, autoconnect settings, operating mode. The driver may only make per-session requests.
- Claiming the modem's AT, NMEA or diagnostic interfaces. Other tools use them.

## Constraints

Signing and installation, all confirmed on this Mac on 2026-11-13:

- macOS 27.0, Xcode 27.1, DriverKit SDK 27.0, Apple silicon.
- Sign with team `ABCDE12345` using Xcode automatic signing. That team's development profile grants `com.apple.developer.driverkit`, `com.apple.developer.driverkit.transport.usb` with a wildcard vendor ID, and `com.apple.developer.driverkit.family.networking`, and grants the host app `com.apple.developer.system-extension.install`. No request to Apple was needed.
- The result runs only on Macs registered to that team. The team belongs to a different Apple ID from the owner's own, so anything that creates identifiers or registers devices there needs the owner's go-ahead.
- A development-signed driver extension loads when its host app is in `/Applications` and the owner approves it once in System Settings. No SIP change and no developer mode were needed.
- Xcode 27 leaves `com.apple.security.app-sandbox` out of the driver's signature even when the entitlements file lists it. The driver loaded anyway.
- macOS's own ECM driver for this modem is a DriverKit extension built on `IOUserNetworkEthernet`, so that class is known to work for a USB network device on this system.
- NetworkingDriverKit can only present an Ethernet interface.

The modem, as observed in QMI mode:

- Quectel RM520N-GL, firmware `RM520NGLAAR03A04M4G_01.204.01.204`, USB ID `2c7c:0801`, 10 Gbps link.
- Interface 4, named "RmNet", is the QMI interface: class, subclass and protocol all `0xff`, with three endpoints. Bulk in is `0x8e`, bulk out is `0x0f`, both with a 1024-byte packet size, and interrupt in is `0x88`. Interfaces 0 to 3 are diagnostics, NMEA and two AT ports.
- After a reboot the USB interfaces return in about 15 seconds. QMI may not answer for some seconds after that.
- Profile 1 has an empty APN, so the network chooses, and is IPv4v6. A call on it returned a private IPv4 address with a /29 mask and a gateway, a global IPv6 /64, IPv4 and IPv6 DNS servers, and an MTU of 1500. The addresses change on every call.
- The modem's own autoconnect is off and did not interfere.

The protocol, as it worked on this modem:

- QMI messages travel as CDC encapsulated commands on the control endpoint: send with request type `0x21`, request `0x00`; receive with `0xa1`, `0x01`; both with the interface number in `wIndex`. The interrupt endpoint signals that a response is waiting.
- The host must first raise DTR with `SET_CONTROL_LINE_STATE` (`0x21`, `0x22`, value 1). Quectel firmware stays silent otherwise.
- Bring-up order: CTL sync, which also clears clients left by an earlier process. Then WDA set data format. Then, for each IP family, a WDS client that binds to the USB data port and a mux ID, sets its IP family, starts the network interface on the profile, and reads the runtime settings.
- The modem granted raw IP with QMAP aggregation in both directions, with up to 32 packets and 31,744 bytes per downlink transfer and 32 packets and 16,384 bytes per uplink transfer, and flow control off. qmi-darwin's notes say larger sizes are accepted but unstable on a related modem.
- The QMAP header is four bytes: a command flag and pad length, the mux ID, and a big-endian length that includes the padding. Command frames carry flow control and must be acknowledged.
- An uplink transfer whose length is an exact multiple of the 1024-byte packet size needs a zero-length packet or extra padding.

## Decided with the owner

The owner approved these on 2026-11-13:

- Build our own driver; do not adopt qmi-darwin.
- A DriverKit extension in C++ that owns USB interface 4, speaks the needed QMI subset itself, and carries packets with QMAP aggregation.
- Because macOS only accepts Ethernet, the driver plays the far end of an Ethernet link and hands macOS the carrier's address over DHCP, so the port sets itself up like any Ethernet port.
- A small host app whose only job is to install the driver and show its status.
- Protocol code written once as plain C++ with unit tests, and proven against the real modem from a command-line harness before it goes into the driver.
- Its own folder and git repository, `rmnet-driver/`.
- The goals, non-goals and the first three anti-goals above.

## Calls made by the author

These were not discussed in detail. The owner should read them as proposals.

Ethernet emulation. The driver sits between macOS, which sends and expects Ethernet frames, and the modem, which sends and expects bare IP packets:

- The port has a fixed, locally administered MAC address, and the driver invents a second one for an imaginary router. Both are derived from the modem's USB serial number so they stay the same across replugs.
- From the modem to macOS, each IP packet gets an Ethernet header addressed from the router to the port.
- From macOS to the modem, the header is removed. Frames that are neither IPv4, IPv6 nor ARP are dropped.
- ARP: the driver answers every request with the router's MAC, except a probe for the port's own address, which gets no answer.
- DHCP: the driver answers the Mac's DHCP requests itself, from the runtime settings QMI returned: address, mask, router, DNS servers and MTU. DHCP packets never reach the modem.
- IPv6: the driver answers router solicitations itself with a router advertisement built from the runtime settings: the /64 prefix, the MTU, and DNS servers as an RDNSS option. It answers neighbour solicitations with the router's MAC, except duplicate-address checks. Router advertisements arriving from the network are dropped, so macOS sees one router. Reason: some networks only answer a solicitation sent from the link-local address they assigned, which macOS would not use. macOS then forms its own addresses inside the /64. That is allowed, since the whole /64 belongs to the device, and in ECM mode this Mac already used self-formed addresses in the carrier's prefix.
- When the connection drops, the port reports link down. When a new call comes up, it reports link up, and macOS asks for addresses again.

Other calls:

- The driver never writes persistent modem settings (the fourth anti-goal) and never claims the other interfaces (the fifth).
- The driver matches only this modem model's QMI interface.
- The profile number defaults to 1 and is a single driver property, so it can be changed without a code change.
- Status reaches the app as properties the driver publishes in the I/O registry. There is no control channel from the app to the driver in the first version.
- The harness talks to the modem from userspace without root. It brings a call up, sends a hand-built ping through QMAP, and prints the reply. It does not create a network interface. The harness and the driver cannot hold interface 4 at the same time, so the driver is deactivated while the harness is in use.
- The real project registers two new app identifiers on the paid team, one for the app and one for the driver. Approving this document is the owner's go-ahead for that.
- If the modem is attached but in ECM mode, the driver has nothing to attach to. The app says so and shows the two AT commands that switch it.
- A throughput gate comes early. As soon as the driver moves packets, measure it. macOS's own ECM driver uses the same driver framework and measured slow here for a reason not yet known. If our driver cannot pass 150 Mbit/s down when the userspace tool can on the same day, stop and return to the owner before building further.
- The first version targets macOS 27 only.
- Before the first install, the throwaway stub from the signing test (`io.rmnetspike.x7k2.host.driver`, attached to interface 3) is deactivated and its app removed. This asks for the owner's admin password.

## Parts

| Part | What it is | Depends on |
|---|---|---|
| Core | Plain C++ with no OS dependencies: QMI message encoding and decoding, the connection state machine, QMAP framing, and the Ethernet emulation | nothing |
| Tests | Unit tests for Core, driven by byte fixtures captured from this modem; run from the command line with no hardware | Core |
| Harness | Command-line tool that runs Core against the real modem from userspace | Core |
| Driver | The DriverKit extension: USB transfers, the network interface, power and unplug handling | Core |
| App | Installs, updates and removes the driver; shows status | Driver |

Core must compile unchanged for the driver, which has a restricted C++ runtime, and for the Mac, where the tests and harness run.

## Behaviour

Start-up: the driver opens interface 4, raises DTR, discards stale responses, and syncs. If QMI does not answer yet, it retries for up to a minute. It sets the data format, starts an IPv4 call and an IPv6 call on the profile, and reads their settings. One family failing is not an error if the other comes up. It then reports link up.

Running: several downlink reads stay posted at once. Each completed read is split into packets, which are given Ethernet headers and handed to macOS. Outgoing frames go through the emulation; packets for the modem are batched into uplink transfers. Flow-control commands pause and resume the uplink.

Recovery: if the network ends a call, the driver reports link down and redials with increasing delays. If the modem signals that a live call's addresses changed, the driver takes the link down and up so macOS asks again. After wake it syncs again and redials. On unplug it stops cleanly; the next plug starts a new instance. A failure it cannot handle leaves the link down; it must not leave a port that looks connected but passes nothing.

## Risks

| Risk | What to do about it |
|---|---|
| The DriverKit network path is slow, as ECM was | The throughput gate above |
| The driver's restricted C++ runtime rejects something Core uses | Compile Core into an empty driver target from the first day |
| macOS's DHCP or IPv6 behaviour differs from what the emulation expects | Capture real exchanges on the ECM port first and use them as test fixtures |
| QMI is slow to start after enumeration, or holds state from a crashed driver | Retry sync; sync clears old clients |
| Sleep and wake leave USB in an odd state | Treat any inconsistency after wake as a full restart of the connection |
| The carrier's gateway address lies outside the given mask | The emulation answers ARP for every address, so the mask does not matter |
| The development profile expires (the test profile runs to November 2027) | Rebuilding renews it |

## Done means

- With the modem in QMI mode, plugging it in makes a port appear in System Settings, and within about 30 seconds it has an IPv4 address by DHCP and IPv6 addresses.
- Ping, DNS lookup and a download work when bound to the port, over both IPv4 and IPv6. `networkQuality -I` runs on it; that test failed on the `utun` interface for lack of DNS.
- Four parallel download streams for 8 seconds reach at least 200 Mbit/s, or within 15 percent of qmi-darwin measured within the same half hour, whichever is lower.
- Unplugging and replugging restores the connection without touching the app. So does sleep and wake, within about 30 seconds of the modem being ready.
- A 30-minute run with traffic shows no USB errors and no dropped packets in the driver's counters.
- The port is offered as a source in Internet Sharing. Sharing itself is not tested in the first version.
- The unit tests pass with no modem attached.
- The app can install, update and remove the driver, and shows whether it is connected and with which addresses.

## Left to the builder

- File layout, class design, naming, and bundle identifiers. The driver's identifier must begin with the app's.
- How the Xcode project is produced. The signing test generated it from a script with the `xcodeproj` gem, which kept it reproducible.
- The test framework and the fixture format.
- Queue and buffer sizes, the number of posted reads, timers and backoff values. qmi-darwin's values are a reasonable starting point: 32 posted reads, 8 uplink buffers.
- The dispatch queue arrangement inside the driver.
- How much of the app is graphical. A single window is enough.
- The order of work, provided Core and the harness come before the driver, and the throughput gate comes before recovery and the app.

## Reference material

- `spike-dext/` in the parent folder: the throwaway signing test, with a working project generator, entitlements files and activation code.
- `modem-state-before-qmi.txt` in the parent folder: the modem's profiles and settings before any of this.
- AT commands: the owner's web console (`webui.py` in the parent folder) accepts a command as the body of a POST to `http://127.0.0.1:8730/at`. It holds AT interface 2 while it runs. As of this document the modem is in ECM mode.
- `~/personal/qmi-darwin`, at commit `fe6f25b45a6199d4fe2b5ff5d8a8d895b8bec36d`: behaviour reference only.
- Linux `qmi_wwan`, `rmnet` and `cdc_mbim`, and Quectel's `quectel-CM`: public references for the protocol and for presenting raw IP as Ethernet.
- When testing through one interface on this Mac: use `/usr/bin/curl --noproxy '*' --interface <name>`. The shell sets proxy variables, the default `curl` is Anaconda's and does not bind to the interface, and the default route is a proxy tunnel. Confirm with the interface's own counters.
