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

## Design

See [docs/superpowers/specs/2026-11-13-rmnet-driver-design.md](docs/superpowers/specs/2026-11-13-rmnet-driver-design.md).
