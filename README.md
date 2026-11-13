# rmnet-driver

A macOS driver that makes a Quectel RM520N-GL 5G modem in QMI USB mode appear as an ordinary wired network port. Its protocol logic (QMI control and QMAP framing) lives in a portable, allocation-free C++ core that is tested on the host without hardware.

## Make targets

- `make test` builds `build/tests` and runs every test; `make test FILTER=bytes` runs only tests whose name contains `bytes`.
- `make check-driverkit` syntax-checks every `core/src/*.cpp` against the installed DriverKit SDK.
- `make harness` builds `build/rmnet-harness`, the command-line harness (below).
- `make clean` removes `build/`.

## Harness

`build/rmnet-harness` runs the core against the real modem from userspace, through IOUSBHost.framework. It needs the modem attached in QMI mode (USB `2c7c:0801`; it uses only the QMI interface, the one whose class, subclass and protocol are all `0xff`) and nothing else holding that interface. It needs no root and creates no network interface.

- `rmnet-harness probe [-v]` finds the QMI interface, prints its endpoints and the modem's serial number, and exchanges one QMI CTL Sync. It prints `sync ok` and exits 0, or `sync: no answer` and exits 1 after 10 seconds. `-v` prints every QMI control message as hex, `>>` sent and `<<` received.
- `rmnet-harness connect [-v]` brings a data connection up on profile 1 with the core's connection state machine, prints `link up`, then the IPv4 address with its mask and gateway (`ipv4 none` if that family did not come up), the IPv6 address with its prefix length, the DNS servers and the MTU. It then stops the connection and exits 0. It exits 1 with `no link after 90 s` if the link does not come up. `-v` also prints every QMI message and the granted data format.
- `rmnet-harness ping [-v] [-6] [-c COUNT] ADDRESS` brings the connection up the same way, then sends COUNT ICMP echo requests (default 3), one a second, from the modem's IPv4 address (or IPv6 address with `-6`), framed as QMAP on mux `0x81` over the bulk endpoints. It answers QMAP flow-control commands from the modem and prints `reply from ADDRESS: seq=N time=T ms` for each echo reply that arrives within 2 seconds of its request. Two seconds after the last request it prints `COUNT sent, M received`, stops the connection and exits 0 if M is at least 1, 1 otherwise. It exits 1 at once if the link comes up without an address of the requested family. `-v` also prints every bulk transfer and every QMAP frame that is not a reply.

Both commands stop the connection (WDS Stop Network, then Release Client ID for every client) before exiting, also on Ctrl-C, so nothing is left running on the modem. The network takes a few seconds to finish tearing a connection down: a command started within about a second of the previous one often gets IPv6 but not IPv4 (WDS Start Network for IPv4 fails with call end reason 3GPP 36, regular deactivation). Wait a few seconds between runs.

## Design

See [docs/superpowers/specs/2026-11-13-rmnet-driver-design.md](docs/superpowers/specs/2026-11-13-rmnet-driver-design.md).
