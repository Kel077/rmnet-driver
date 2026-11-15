# rmnet-driver

A macOS DriverKit driver that makes a Quectel RM520N-GL 5G modem in QMI mode an ordinary wired network port, and RMNet, the app that installs the driver and talks to the modem: its status, text messages (SMS), network and SIM controls, GPS position, and the modem's DIAG and NMEA interfaces as serial ports.

**Status.** Used daily on one Mac (Apple silicon, macOS 27) with one RM520N-GL. The driver also matches 13 other Quectel QMI modems, none of them tried. Nobody ships binaries: you build your own and sign it with your own Apple Developer team. What has been tested, and how, is in [docs/status.md](docs/status.md).

In QMI mode the modem offers a USB interface that speaks Qualcomm's QMI protocol, which macOS has no driver for. This driver starts a data call over it and gives macOS an Ethernet port, playing the router behind it (DHCP, IPv6 router advertisements), so macOS configures the port like any wired network.

## Requirements

- A Mac with Apple silicon, on macOS 27.
- Xcode 27.1 or later, signed in to a team in the **paid** Apple Developer Program. A free Personal Team cannot sign DriverKit drivers. On the author's paid team no request to Apple was needed: for a development build, Xcode's automatic signing registered the App IDs and the Mac and made profiles with the driver's entitlements (DriverKit, USB, networking, serial).
- The Ruby gem `xcodeproj` for macOS's own Ruby (it generates the Xcode project). Check with `/usr/bin/ruby -e 'require "xcodeproj"'`; if that fails, run `/usr/bin/gem install --user-install xcodeproj`.
- A Quectel RM520N-GL on USB, with a SIM that has a data plan.

## One-time setup

In the repository's root:

```sh
cp config.example config.local
```

Fill in its two lines, for example:

```sh
RMNET_TEAM_ID=ABCDE12345
RMNET_BUNDLE_ID=com.example.RMNet
```

- `RMNET_TEAM_ID` is your paid team's ID, 10 capital letters and digits. The sure place to find it is developer.apple.com → Account → Membership details, "Team ID"; Xcode's Accounts pane may not show it. Do not use the code in parentheses in your "Apple Development" certificate's name: that is a different identifier.
- `RMNET_BUNDLE_ID` is a bundle ID you own, such as your domain reversed; the driver gets it with `.driver` added. App IDs are unique across all of Apple, so the project's default, `io.rmnetdriver.RMNet`, is taken.
- `config.local` is ignored by git and read as data, never run: it may hold only these two lines (with no comment after a value), comment lines and blank lines. Environment variables of the same names win over it.
- Choose the bundle ID once: the install script refuses to replace an installed `/Applications/RMNet.app` with another bundle ID, whose driver could be left with no app able to remove it. To change the ID, remove the old driver (below); when `systemextensionsctl list` shows no entry for it, or only an uninstalling one, delete `/Applications/RMNet.app`, then change `config.local`.

## The modem's USB mode

Quectel modems offer their network function over USB in one of several modes, chosen with the AT command `AT+QCFG="usbnet"`: QMI (0, which Quectel calls RMNET), ECM (1), MBIM (2) or RNDIS (3). This driver works only in QMI mode. The modem keeps the mode it is set to and uses it from its next restart.

The app reads and sets the mode:

```sh
RMNet usbmode            # prints: usb mode: qmi (the RMNet driver works in this mode)
RMNet usbmode set qmi    # asks, then restarts the modem (about 30 s)
```

- `RMNet` here and below is the app's command-line side, `/Applications/RMNet.app/Contents/MacOS/RMNet`. An alias saves typing: `alias RMNet=/Applications/RMNet.app/Contents/MacOS/RMNet`.
- These commands talk to the modem's spare AT port (USB interface 3) directly, from user space, so they work before the driver is installed or approved. They need the app, which the next section builds: on a new modem, install first, then check the mode. When the modem comes back in QMI mode, the driver attaches by itself.
- `usbmode set` changes nothing when the modem is already in that mode. `--yes` skips the question; `--no-reboot` saves the mode for the next restart (a replug, or `AT+CFUN=1,1`).
- **This project has no general AT terminal.** macOS gives the modem's AT ports no device (no `/dev/cu.*` to open with a terminal program, with or without the driver), and RMNet sends only the AT commands behind its own verbs and tabs. Setting the USB mode (`RMNet usbmode`) is the one AT task in this README that the app does for you; for any other AT command named here (`AT+QGPS=1` for `RMNet gps`, and the caveat below) you need another tool that can reach the modem's AT port.
- **Caveat.** RMNet looks for the modem's AT port only on USB product `2c7c:0801`, the RM520N-GL's ID in QMI mode. Whether the RM520N-GL keeps that ID in ECM, MBIM or RNDIS mode is not known. If it does not, RMNet cannot find the modem (`usb mode: The RM520N-GL (USB 2c7c:0801) is not attached.`), and another AT terminal must send `AT+QCFG="usbnet",0`, then `AT+CFUN=1,1` (or, instead of the second, unplug the modem and plug it back in). So do not switch to another mode without such a terminal; a modem that arrives in another mode may need one too.

## Build and install

```sh
scripts/install-driver.sh
```

The script builds the app and its driver signed, under your team and bundle ID, with a new version number on each run. It keeps a copy of the app in `build/installed/`, copies it to `/Applications/RMNet.app` (only an app there can activate a driver) and runs `RMNet activate`.

- **The first time**, macOS asks for your approval: open System Settings → General → Login Items & Extensions → Driver Extensions, and turn the RMNet driver on. The script waits (`waiting for approval in System Settings`) until you do. Later builds need no new approval.
- The script refuses, changing nothing, when `config.local` is missing or invalid, when `/Applications/RMNet.app` has another bundle ID, when an installed driver version has no kept app in `build/installed/`, or when a build was already installed in the same minute (wait a minute).
- **A newer build does not replace a running one at once.** If the script's last step prints `an older build is still running`, unplug the modem and plug it back in (or send it `AT+CFUN=1,1`), and the new build loads.

Check that it works:

```sh
RMNet status
```

It prints the driver extension and whether it is enabled, a `modem:` line saying whether the modem is attached and in QMI mode, and, once the driver is attached, its properties: `RMNetState = up` when connected, and the addresses (`RMNetIPv4`, `RMNetIPv6`). The window's `Driver` tab then shows `Connected`.

macOS names the port `en` and a number, which varies from Mac to Mac (`en33` on the author's). Find yours with `networksetup -listallhardwareports`, under the hardware port `RM520N-GL`. Then:

```sh
ifconfig en33                   # an IPv4 address and global IPv6 addresses
ping -c 3 -b en33 1.1.1.1       # bound to the port, whatever the service order
```

## Using it

| Command | What it does |
|---|---|
| `RMNet status [--json]` | Whether the driver is installed and the modem attached in QMI mode; the driver's state, addresses and counters. |
| `RMNet sms list [--json]`<br>`RMNet sms send <number> <text>`<br>`RMNet sms delete <index>...` | List, send and delete the modem's text messages. Each message sent costs a carrier fee. |
| `RMNet gps [seconds]` | The position from the modem's GNSS receiver. It needs the driver attached (it reads the NMEA serial port) and GNSS already switched on with `AT+QGPS=1`, which RMNet does not send: use another AT terminal (this project has none, see "The modem's USB mode"). |
| `RMNet network [--json]` | Registration, operator, technology, band, signal and cell. |
| `RMNet radio [on\|off]` | Show the radio's state, or switch it. `off` is airplane mode: no connection until `radio on`. |
| `RMNet mode [auto\|nr5g\|lte\|lte:nr5g\|…]` | Show or set the network mode. The modem keeps it; the command prints how to put it back. |
| `RMNet apn [show] [--json]`<br>`RMNet apn set [--apn <name>] [--type ipv4\|ipv6\|ipv4v6] [--user <name>] [--password \| --no-password] [--auth none\|pap\|chap\|pap-or-chap] [--no-redial]` | Show the data profiles, or change the one the driver dials. A change redials: the connection drops for about 10 to 30 s. |
| `RMNet sim [--json]`<br>`RMNet sim unlock [--last-attempt]` | The SIM's state and the attempts left; enter its PIN (asked without echo; the last attempt only with `--last-attempt`). |
| `RMNet usbmode [--json]`<br>`RMNet usbmode set qmi\|ecm\|mbim\|rndis [--no-reboot] [--yes]` | Show or set the modem's USB mode (above). |
| `RMNet activate` | Install or update the driver this app carries (the install script runs it). |
| `RMNet deactivate` | Remove the driver; macOS asks for an administrator's password (below). |

- The modem commands (`sms`, `network`, `radio`, `mode`, `apn`, `sim`, `usbmode`) use the modem's spare AT port, USB interface 3. They exit 0 on success, 1 on a failure (one line saying why) and 2 on wrong usage; `usbmode set` also exits 2, changing nothing, when it has no terminal to ask on (run from a script, give it `--yes`).
- Ctrl-C does not interrupt a command that changes the modem (except at a password or PIN prompt, before anything is sent), so a redial is never cut short with the radio off.
- RMNet never logs or writes to disk message texts, phone numbers, passwords, PINs or your position.
- Every option and every line each command prints is in [docs/reference.md](docs/reference.md), "Driver".

Opened with no argument (from the Finder, or `open /Applications/RMNet.app`), the app shows one window with four tabs:

- **Driver**: a headline such as `Connected`, advice on what to do, the addresses, versions and counters; `Install` (or `Update`) and `Remove…`.
- **Messages**: the modem's text messages; `Delete…`, and a form to send one.
- **Network**: registration, signal and cell; `Radio Off…` or `Radio On`; the network mode, with `Change…`.
- **SIM & APN**: the SIM's state and PIN entry; the data profiles, and an editor for the one the driver dials.

The driver also presents two of the modem's other USB interfaces as serial ports: `/dev/cu.RM520N-GL-NMEA` (GNSS sentences, while GNSS is on) and `/dev/cu.RM520N-GL-DIAG` (Qualcomm's DIAG protocol, for tools such as QCSuper). Like every serial port on macOS, any local user can read and write them while the driver is attached.

## Updating and removing

**To update**, pull the new code and run `scripts/install-driver.sh` again. No new approval is needed; unplug and replug the modem if the script says an older build is still running.

**To remove** the driver, press `Remove…` on the window's `Driver` tab, or run `RMNet deactivate`. macOS asks for an administrator's password. The driver keeps the port until the modem is unplugged or the Mac restarts.

macOS removes a driver only when asked by an app that embeds that exact driver version. That is why the install script keeps a copy of every app it installs, as `build/installed/RMNet-<version>.app`, and why `make clean` leaves that folder alone. **Never delete `build/installed/`**: without the matching app, an installed driver cannot be removed until that exact version is built again. It lives inside your clone, so deleting the clone or cloning afresh in its place deletes it too: keep the clone for as long as a driver built from it is installed, or copy `build/installed/` somewhere safe first and put it back into the new clone (the install script refuses to run while an installed version has no kept app there). If `/Applications/RMNet.app` no longer carries the installed version, follow [docs/reference.md](docs/reference.md), "Removing the driver".

Do not switch the driver off in System Settings while the modem is attached: the driver cannot stop, its switched-off entry stays next to later builds, and the system refuses every activation until both entries are removed.

## Troubleshooting

- **The driver does not appear.** Run `RMNet status`, or `systemextensionsctl list` (look for `<your bundle ID>.driver`). `Waiting for approval in System Settings` means the approval above is still to be given; `Not installed` means no activation got through: run the install script again and read what it printed. For more than one entry, or a switched-off one, the window's `Driver` tab says what to do.
- **`Modem is not in QMI mode`.** Run `RMNet usbmode set qmi` (above).
- **`Installed, modem not attached`.** No matching modem is on USB; the `modem:` line of `RMNet status` lists the products looked for.
- **The port has no address.** `RMNet status` shows `RMNetState`. `RMNet network` says whether the modem is registered and the radio on, `RMNet sim` whether the SIM waits for its PIN, and `RMNet apn` which profile the driver dials and its APN. A wrong APN breaks the connection: set your carrier's with `RMNet apn set --apn <name>`.
- **The driver's log.** `scripts/driver-log.sh` follows the driver's lines (they start with `RMNet:`) and saves them in `build/logs/`. macOS does not keep them for later, so start it before you replug, reinstall or reproduce the problem.
- **`an older build is still running`.** Unplug the modem and plug it back in, or send it `AT+CFUN=1,1`.
- **After a macOS update.** Not tried yet. If the driver stops loading, check `RMNet status` and `systemextensionsctl list`, update Xcode if the new macOS needs it, and run `scripts/install-driver.sh` again.
- **Connected, but nothing goes over the modem.** See the service order below.

## Known limits

- **One data connection**: the driver dials one data profile (profile 1, unless `RMNetProfile` in `driver/Info.plist` names another), for IPv4 and IPv6, on one port.
- **No USB idle suspend**: the modem stays fully powered while the driver runs, because macOS switches a network interface off whenever its driver enters the low-power state the modem needs in order to suspend ([docs/driverkit-notes.md](docs/driverkit-notes.md), "Runtime findings (idle suspend: trial E1a), and idle suspend dropped").
- **The IPv4 MTU stays 1500**: macOS refuses the driver's request to change it, so a smaller carrier MTU reaches only IPv6, through the router advertisement.
- **macOS decides whether the port is used.** The port is one more network service, `RM520N-GL`, and macOS uses the first connected service in its service order; Wi-Fi usually comes first. To use the modem while Wi-Fi is on, move `RM520N-GL` above Wi-Fi (System Settings → Network, the `…` button, Set Service Order), or bind a program to the port, as `ping -b` does above.
- **Tested on one setup only**: Apple silicon, macOS 27, Xcode 27.1 and one RM520N-GL. The 13 other matched models get only the network port, untested; the serial ports and the modem commands need the RM520N-GL (`2c7c:0801`). The models are listed in [docs/reference.md](docs/reference.md), "Supported models".

## For developers

The layout:

- `core/`: the portable, allocation-free C++ core: QMI messages, QMAP framing, and the Ethernet emulator that answers ARP, DHCP and IPv6 neighbour discovery.
- `driver/`: the DriverKit extension: `RMNetDriver` (the network port), `RMNetSerial` (the serial ports) and their personalities in `driver/Info.plist`.
- `app/`: RMNet, the window and the command-line verbs.
- `harness/`: `rmnet-harness`, which runs the core against the modem from user space, without the driver.
- `scripts/`: installing, the driver's log, the build configuration (`scripts/config.sh`), throughput measurement, the soak test and the personality checks.
- `tests/`: tests of the core, the driver's host side, the app and the scripts.
- `gen.rb`: writes `RMNet.xcodeproj` (not in git): `/usr/bin/ruby gen.rb [--team TEAM_ID] [--bundle-id BUNDLE_ID]`.

The make targets (none needs the modem, an install or signing; details in [docs/reference.md](docs/reference.md)):

- `make test`: the core's tests (`FILTER=<text>` picks tests by name).
- `make driver-test`: the driver's `CoreHost` on the host, against a fake USB interface.
- `make check-driverkit`: syntax-checks the core against the DriverKit SDK and checks the driver's personalities.
- `make app-test`: the app's models, verbs and controllers, without an Xcode project or a window.
- `make script-test`: the scripts' decisions, on saved listings and temporary configurations.
- `make harness`: builds `build/rmnet-harness`.
- `make driver`: an unsigned build of the driver and the app into `build/xcode/` (`RMNET_BUNDLE_ID=<id> make driver` for another bundle ID).
- `make clean`: removes `build/`, except `build/installed/`.

The documents:

- [docs/reference.md](docs/reference.md): every make target, script, command and window tab in detail; removing a driver by hand; the serial ports; the supported models; the harness.
- [docs/status.md](docs/status.md): where each line of the design's "Done means" stands, with the evidence.
- [docs/driverkit-notes.md](docs/driverkit-notes.md): what was learned about DriverKit, from compiling and on hardware.
- [docs/superpowers/](docs/superpowers/): the [design](docs/superpowers/specs/2026-11-13-rmnet-driver-design.md) and the plans the code was built from.

## Licence

Not yet chosen; until a LICENSE file is added, all rights are reserved by the author.
