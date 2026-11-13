# rmnet-driver

A macOS driver that makes a Quectel RM520N-GL 5G modem in QMI USB mode appear as an ordinary wired network port. Its protocol logic (QMI control and QMAP framing) lives in a portable, allocation-free C++ core that is tested on the host without hardware.

## Make targets

- `make test` builds `build/tests` and runs every test; `make test FILTER=bytes` runs only tests whose name contains `bytes`.
- `make check-driverkit` syntax-checks every `core/src/*.cpp` against the installed DriverKit SDK.
- `make harness` builds `build/rmnet-harness`, the command-line harness (below).
- `make driver` generates `RMNet.xcodeproj` and builds the driver and the host app unsigned into `build/xcode/`, printing `driver build ok`.
- `make clean` removes `build/`, except `build/installed/` (the apps that can remove an installed driver, below).

## Driver

The driver is a DriverKit extension (`driver/`, bundle `io.rmnetdriver.RMNet.driver`) that links Core and presents the modem's QMI interface (USB `2c7c:0801`, interface 4) as an Ethernet port. It is carried and installed by a command-line host app (`app/`, `io.rmnetdriver.RMNet`).

What the driver does: it opens only interface 4 (after checking that its class, subclass and protocol are `0xff`), registers an Ethernet interface (`en33` on this Mac, hardware port `RM520N-GL`) with a MAC derived from the modem's serial number, and runs Core's QMI session over the control endpoints: CTL sync, the QMAP data format, then a WDS call for IPv4 and one for IPv6 on the data profile `RMNetProfile` (from the personality in `driver/Info.plist`; 1 unless set to another integer from 1 to 255). The link is reported up once both families have been tried, IPv4 then IPv6, and at least one has its settings; a family that failed is retried while the link is up (after 5 s, then backing off to 60 s). Data moves as QMAP over the bulk endpoints (32 reads posted, 8 uplink buffers; a frame that finds every uplink buffer busy is kept and offered again when one frees). Core's Ethernet emulator plays the router on the other end of the link, answering ARP, DHCP and IPv6 neighbour discovery and sending router advertisements, so macOS configures the port's addresses itself, and the modem's DNS servers reach the port. On this Mac macOS has not made the port its primary service (check with `scutil --nwi`). The driver publishes its state, the call's addresses, the profile in use and its counters as `RMNet*` registry properties, which `RMNet status` prints. The interface keeps the MTU it registered with (1500): macOS refuses `setMaxTransferUnit`, so a smaller carrier MTU reaches only IPv6 hosts, through the router advertisement. Measured downlink (Task 7, `docs/driverkit-notes.md`): 93 to 138 Mbit/s over 50 MB runs.

- `gen.rb` writes `RMNet.xcodeproj` (not in git) with two targets: `RMNetDriver` (every `driver/*.cpp`, `driver/*.iig` and `core/src/*.cpp`) and `RMNet` (the app, which embeds the driver). Run it with `/usr/bin/ruby gen.rb` for an unsigned project, or `/usr/bin/ruby gen.rb TEAM_ID` for automatic signing with that team. It needs the `xcodeproj` gem.
- `scripts/install-driver.sh` generates the project for team `ABCDE12345`, builds it signed (letting Xcode create or update the provisioning profiles) with a bundle version derived from the current time (`<days since 2026-01-01>.<hour>.<minute>` in UTC, the form a dext version must take), copies the app to `/Applications/RMNet.app` and runs `RMNet activate`. The first activation waits for approval in System Settings, under Login Items & Extensions, Driver Extensions; later builds replace it without a new approval. A running driver does not stop when it is replaced, so a new build loads only when the modem re-enumerates (unplug it, or send `AT+CFUN=1,1`); the script says which build is running. It keeps a copy of every app that asks for activation in `build/installed/RMNet-<version>.app` (the new app right after it is copied, before it asks; the app it replaces, before removing it, if the system lists any entry with its driver version), and it stops if the active driver has no kept copy.
- Do not switch the driver off in System Settings while the modem is attached: the driver cannot stop, the entry is left disabled next to later builds, and the system then refuses every activation until both entries are removed.
- `scripts/driver-log.sh` follows the driver's log lines, which all start with `RMNet:`, and saves them in `build/logs/driver-<time>.log`. The system log does not keep a driver's lines, so start it before the event you want to see.
- `scripts/measure.sh <interface> down|up` measures throughput on one port from the port's own byte counters (`netstat -I`), with 4 parallel HTTPS transfers bound to the port (`--interface`, a pinned server address, proxies bypassed). It is capped: a download stops at 50,000,000 bytes or 8 s, and each of its streams also stops itself at 15,000,000 bytes; an upload stops at 10,000,000 bytes or 6 s and can send 16 MB at most. **The modem's SIM is metered**, so every run that starts its transfers, also a failed or interrupted one, appends "time direction bytes-in bytes-out" to the usage file `build/installed/measure-usage.log` (kept by `make clean`; never edit or truncate it). A run refused at its checks, or one that stops before starting its transfers, leaves no line, since it sent nothing; so does a run killed outright (SIGKILL), which may have sent data. A run refuses to start (exit 2) if the recorded total plus its reservation would pass 300,000,000 bytes, or if the file has a malformed line. `scripts/measure.sh --analyse down|up <samples file>` re-prints a saved run's figures. For tests without the network, `MEASURE_TEST_PORT`, `MEASURE_NETSTAT` and `MEASURE_USAGE_FILE` are accepted with the interface `lo0` only; on `lo0`, always set `MEASURE_USAGE_FILE` to a scratch copy, or the run is charged to the real usage file.
- `/Applications/RMNet.app/Contents/MacOS/RMNet activate | deactivate | status`. `status` prints whether the driver extension is installed and enabled, whether the modem is attached in QMI mode, and, if the driver is attached, its `RMNet*` registry properties.

### Removing the driver

The system deactivates a driver only when asked by an app that embeds that exact driver version. Find the active version with `systemextensionsctl list` (`io.rmnetdriver.RMNet.driver (1.0/<version>)`), then:

```sh
rm -rf /Applications/RMNet.app
ditto build/installed/RMNet-<version>.app /Applications/RMNet.app
/Applications/RMNet.app/Contents/MacOS/RMNet deactivate   # asks for an administrator's password
```

If no copy exists, build one for that version: `/usr/bin/ruby gen.rb ABCDE12345`, then the `xcodebuild` command in `scripts/install-driver.sh` with `CURRENT_PROJECT_VERSION=<version>`, and deactivate from that app the same way. Each installed entry needs its own matching app.

## Harness

`build/rmnet-harness` runs the core against the real modem from userspace, through IOUSBHost.framework. It needs the modem attached in QMI mode (USB `2c7c:0801`; it uses only the QMI interface, the one whose class, subclass and protocol are all `0xff`) and nothing else holding that interface. It needs no root and creates no network interface.

- `rmnet-harness probe [-v]` finds the QMI interface, prints its endpoints and the modem's serial number, and exchanges one QMI CTL Sync. It prints `sync ok` and exits 0, or `sync: no answer` and exits 1 after 10 seconds. `-v` prints every QMI control message as hex, `>>` sent and `<<` received.
- `rmnet-harness connect [-v]` brings a data connection up on profile 1 with the core's connection state machine, prints `link up`, then the IPv4 address with its mask and gateway (`ipv4 none` if that family did not come up), the IPv6 address with its prefix length, the DNS servers and the MTU. It then stops the connection and exits 0. It exits 1 with `no link after 90 s` if the link does not come up. `-v` also prints every QMI message and the granted data format.
- `rmnet-harness ping [-v] [-6] [-c COUNT] ADDRESS` brings the connection up the same way, then sends COUNT ICMP echo requests (default 3), one a second, from the modem's IPv4 address (or IPv6 address with `-6`), framed as QMAP on mux `0x81` over the bulk endpoints. It answers QMAP flow-control commands from the modem and prints `reply from ADDRESS: seq=N time=T ms` for each echo reply that arrives within 2 seconds of its request. Two seconds after the last request it prints `COUNT sent, M received`, stops the connection and exits 0 if M is at least 1, 1 otherwise. It exits 1 at once if the link comes up without an address of the requested family. `-v` also prints every bulk transfer and every QMAP frame that is not a reply.

Both commands stop the connection (WDS Stop Network, then Release Client ID for every client) before exiting, also on Ctrl-C, so nothing is left running on the modem. The network takes a few seconds to finish tearing a connection down: a command started within about a second of the previous one often gets IPv6 but not IPv4 (WDS Start Network for IPv4 fails with call end reason 3GPP 36, regular deactivation). Wait a few seconds between runs.

## Design

See [docs/superpowers/specs/2026-11-13-rmnet-driver-design.md](docs/superpowers/specs/2026-11-13-rmnet-driver-design.md).
