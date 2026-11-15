# Open-Source Cleanup: Build It Yourself

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** anyone with a paid Apple Developer team, a Mac and a Quectel RM520N-GL can clone this repository, put their own team and bundle ID in one file, set the modem's USB mode, build, install and use the driver, following a README written for them.

**Owner's words (2026-11-15):** "not shipping the binary, but for everyone to compile their own and use"; "keep cleaning up and improving to add more features."

**Why it is needed (found on 2026-11-15):** the team ID `ABCDE12345` is written into `scripts/install-driver.sh`, and the bundle ID `io.rmnetdriver.RMNet` into `gen.rb`, `app/ExtensionManager.swift`, `scripts/install-driver.sh`, `scripts/soak.sh` and `scripts/driver-log.sh`. App IDs are unique across Apple, so anyone else's signed build fails until both are theirs. A free Personal Team cannot sign DriverKit at all. The README (about 12,600 words) is test evidence, not a guide. Switching the modem into QMI mode needs an AT command, and without this driver macOS gives the modem's AT port no device, so a newcomer has no tool to send it; the app's AT port (`app/AtPort.swift`) opens USB interface 3 from user space with IOUSBHost and does not need the driver.

**Architecture:** one git-ignored file, `config.local`, holds `RMNET_TEAM_ID` and `RMNET_BUNDLE_ID` (environment variables of the same names win). A shell helper parses it without executing it; `gen.rb` takes both as options; the app derives the driver's ID from its own bundle ID. A new verb, `RMNet usbmode`, reads and sets the modem's USB network mode over the existing AT port. The README becomes a builder's guide; its reference and evidence move, nearly verbatim, into `docs/reference.md` and `docs/status.md`.

**Tech Stack:** POSIX `sh`, Ruby (`xcodeproj` gem) for `gen.rb`, Swift (app, `swiftc` tests through `make app-test`).

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (the driver and app as built) and the owner's words above. The design's non-goal "Distribution to Macs that are not registered on the signing team" stands: each builder's own team registers their own Mac; nobody ships binaries.

## Global Constraints

- Branch `open-source`, cut from `main` at `98f4655` (after this plan is committed). Tasks 1 and 2 run in parallel in worktrees `~/personal/RM520N-GL/worktrees/os-config` (branch `os-config`) and `~/personal/RM520N-GL/worktrees/os-usbmode` (branch `os-usbmode`), both cut from `open-source`; the coordinator merges them into `open-source`. Task 3 runs after both, in `~/personal/RM520N-GL/worktrees/os-docs` (branch `os-docs`).
- For this Mac nothing changes: the coordinator writes `config.local` with `RMNET_TEAM_ID=ABCDE12345` and `RMNET_BUNDLE_ID=io.rmnetdriver.RMNet`, so the installed driver keeps its identity and the kept apps in `build/installed/` stay valid.
- No hardware in any task: no install, no activation, no modem reboot, no AT command sent, never `~/personal/RM520N-GL/at.py`, no `sudo`, nothing sent on `en33`. Never write to or delete from `build/installed/`; never touch `/Applications/RMNet.app`. Never register an App ID or device: never run a signed `xcodebuild` or `gen.rb --team` followed by a build.
- Text messages and phone numbers stored in the modem are private: never log, print in tests' output, or commit any.
- After every task: `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test` all pass, and `make driver` (unsigned) succeeds.
- Commit at the end of every task with the message given; no attribution lines.

## Review Focus

- A builder who copies `config.example` to `config.local` and fills it in gets a signed build under their own IDs, with no other file to edit; one who forgets gets a refusal that names the file, not an Xcode signing error.
- `config.local` is data, never code: a value such as `$(touch /tmp/x)` or a line with backticks is refused or taken literally, never run.
- The owner's existing install keeps working: same bundle ID, same driver ID, `RMNet deactivate` from a kept app still finds its driver.
- `RMNet usbmode set` never reboots the modem when the mode is already the one asked for, and tells the user, before rebooting into a mode other than QMI, that this driver will not work in it.
- The new README is enough for a newcomer: requirements (paid team, Apple silicon, macOS 27, Xcode), one-time setup, the USB mode, build and install, the approval in System Settings, use, update, removal, troubleshooting, known limits.

---

### Task 1: Build identity from `config.local`

**Files:**
- Create: `config.example` (committed), `scripts/config.sh` (sourced helper), `tests/scripts/test-config.sh`
- Modify: `.gitignore` (add `config.local`), `gen.rb`, `Makefile` (`driver` passes `RMNET_BUNDLE_ID` when set; `script-test` runs the new test), `scripts/install-driver.sh`, `scripts/soak.sh`, `scripts/driver-log.sh`, `app/ExtensionManager.swift`

**Interfaces:**
- Produces: `config.example`:
  ```sh
  # Copy to config.local (git-ignored) and fill in. Environment variables of the same names win.
  # Your paid Apple Developer team ID (Xcode > Settings > Accounts; 10 characters). A free Personal
  # Team cannot sign DriverKit drivers.
  RMNET_TEAM_ID=
  # A bundle ID you own, for the app; the driver gets <this>.driver. Example: com.example.RMNet
  RMNET_BUNDLE_ID=
  ```
- Produces: `scripts/config.sh`, sourced (`. ./scripts/config.sh`) from the repository root. It defines `rmnet_config` (load, no validation of presence) and `rmnet_config_require` (load, then refuse unless both are set and valid). After either: `TEAM_ID`, `BUNDLE_ID` and `DRIVER_ID` (`$BUNDLE_ID.driver`) are set. Rules:
  - The environment's `RMNET_TEAM_ID` / `RMNET_BUNDLE_ID` win over the file; the file is `config.local` in the repository root, read line by line with `sed`/`read`, never sourced: only lines `NAME=value` for these two names count; `#` comments and blank lines are skipped; one pair of surrounding single or double quotes is removed; anything else is an error naming the line number.
  - `TEAM_ID` must match `^[A-Z0-9]{10}$`; `BUNDLE_ID` must match `^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$` (so `$`, backticks, spaces and slashes never pass).
  - `rmnet_config` with nothing set: `BUNDLE_ID=io.rmnetdriver.RMNet` (the default, for observing scripts and unsigned builds), `TEAM_ID` empty.
  - `rmnet_config_require` failing prints one line to stderr, `config: <what is wrong>; copy config.example to config.local and fill it in`, and returns 2.
- Produces: `gen.rb [--team TEAM_ID] [--bundle-id BUNDLE_ID]`: same validation as above (the team as today); default bundle ID `io.rmnetdriver.RMNet`; the driver's ID is `<bundle>.driver`; unknown arguments abort with the usage line. The positional `gen.rb TEAM_ID` form is removed (only `install-driver.sh` and docs used it).
- Produces: in `app/ExtensionManager.swift`, `let driverID` becomes `(Bundle.main.bundleIdentifier ?? "io.rmnetdriver.RMNet") + ".driver"`, computed once; every use stays as it is.

- [ ] **Step 1: Write `tests/scripts/test-config.sh`** in the style of `tests/scripts/test-install-checks.sh`, running the helper in a temporary copy of the repository root layout (a temp dir with `scripts/config.sh` and a `config.local` the test writes). Cases, at least: nothing set → `rmnet_config` gives the default bundle ID and empty team, `rmnet_config_require` returns 2 with the line starting `config: `; a valid file → both values, `DRIVER_ID` is `<bundle>.driver`; environment beats file; comments, blank lines and quoted values; a lowercase or 9-character team → 2; bundle IDs `com.example.RMNet` ok, `RMNet`, `com example.x`, `com.$(touch x).y` and ``com.`id`.y`` refused, and the `touch` never ran (no file `x` appears); an unknown name such as `PATH=/tmp` → error naming the line, and `PATH` unchanged.
- [ ] **Step 2: Run it:** `sh tests/scripts/test-config.sh`. Expected: FAIL (no helper).
- [ ] **Step 3: Implement** `scripts/config.sh`, `config.example`, `.gitignore`, and `gen.rb`'s options.
- [ ] **Step 4: Wire it in.** `install-driver.sh`: `. ./scripts/config.sh; rmnet_config_require || exit 2`, before anything is built; `TEAM`/`DRIVER_ID` come from it; `gen.rb --team "$TEAM_ID" --bundle-id "$BUNDLE_ID"`; every literal driver ID (including the `codesign` path) uses `$DRIVER_ID`. `soak.sh` and `driver-log.sh`: `rmnet_config` (no requirement) and `$DRIVER_ID` in place of the literal. `Makefile` `driver`: `/usr/bin/ruby gen.rb $(if $(RMNET_BUNDLE_ID),--bundle-id $(RMNET_BUNDLE_ID))`. `app/ExtensionManager.swift` as above. Add the test to `script-test`.
- [ ] **Step 5: Verify unsigned with another ID**, then restore: `RMNET_BUNDLE_ID=com.example.RMNetTest make driver`, then check `build/xcode/Debug/RMNet.app/Contents/Info.plist` has `CFBundleIdentifier` `com.example.RMNetTest` and the app embeds `Contents/Library/SystemExtensions/com.example.RMNetTest.driver.dext`; then `make driver` again (default ID). No signing, nothing registered.
- [ ] **Step 6: Run all five targets and `make driver`; commit:** `build: the team and bundle IDs come from config.local (or the environment), so anyone can build under their own Apple team`

### Task 2: `RMNet usbmode`: read and set the modem's USB network mode

**Files:**
- Modify: `app/ModemService.swift` (two methods on the service and its protocol), `app/ModemCli.swift` (the verb), the usage line, `app/main.swift` only if the verb list needs it
- Test: `tests/app/ModemServiceTests.swift` (scripted port), `tests/app/ModemCliTests.swift` (fake service)

**Interfaces:**
- Consumes: `ModemServing`, `ModemService`'s `withPort`/`Link` pattern and its scripted-port tests; `modemVerbs`, `parseModem`, `ModemCommand` in `app/ModemCli.swift`.
- Produces: `enum UsbNetMode: Int { case qmi = 0, ecm = 1, mbim = 2, rndis = 3 }` with names `qmi`, `ecm`, `mbim`, `rndis` (Quectel's `AT+QCFG="usbnet"` values: 0 RMNET/QMI, 1 ECM, 2 MBIM, 3 RNDIS); an unknown number is kept as `.other(Int)` or reported as `unknown (<n>)` (implementer's choice of representation; the text is fixed).
- Produces on `ModemServing`: `func usbMode() -> Result<UsbModeInfo, ModemFailure>` (sends `AT+QCFG="usbnet"`, parses `+QCFG: "usbnet",<n>`) and `func setUsbMode(_ mode: UsbNetMode, reboot: Bool) -> Result<UsbModeChange, ModemFailure>`: reads first; if already that mode returns `.unchanged` and sends nothing else; otherwise sends `AT+QCFG="usbnet",<n>`, reads back to confirm, then, only with `reboot`, sends `AT+CFUN=1,1` and returns `.rebooting` without waiting (the port goes away); without `reboot` returns `.setTakesEffectAfterRestart`.
- Produces: verbs `RMNet usbmode [--json]` and `RMNet usbmode set qmi|ecm|mbim|rndis [--no-reboot] [--yes]`, added to `modemVerbs` and the usage line.
  - `usbmode` prints `usb mode: qmi (the RMNet driver works in this mode)` or, for another mode, `usb mode: <name> (the RMNet driver needs qmi: RMNet usbmode set qmi)`; `--json` gives `{"mode":"qmi","value":0,"driverWorks":true}`.
  - `usbmode set qmi` when already QMI: `usb mode: already qmi; nothing changed`, exit 0, no reboot.
  - Setting any mode asks on the terminal, unless `--yes`: `The modem will restart (about 30 s) and the network port will go away until it is back. Continue? [y/N] `; for a mode other than `qmi` the question is preceded by the line `In <name> mode this driver does not work; to come back: RMNet usbmode set qmi`. Anything but `y`/`yes` cancels with `cancelled; nothing changed`, exit 1. Without a terminal on stdin and without `--yes`, it refuses (exit 2) rather than reboot unasked.
  - After a set with reboot: `usb mode set to <name>; the modem is restarting`; with `--no-reboot`: `usb mode set to <name>; it takes effect at the next restart (AT+CFUN=1,1 or a replug)`.
- The AT port is opened only on `2c7c:0801` today; whether the RM520N-GL keeps product ID `0x0801` in ECM, MBIM and RNDIS modes is not known here. If another mode changes it, `RMNet usbmode set qmi` cannot find the modem: the README (Task 3) must say so, and the verb's other-mode warning must say "(if RMNet cannot find the modem afterwards, switch back with any AT terminal: AT+QCFG=\"usbnet\",0 then AT+CFUN=1,1)".

- [ ] **Step 1: Write the failing tests.** `ModemServiceTests`: `usbMode` parses `+QCFG: "usbnet",0` → qmi and `,2` → mbim; a missing line → a failure; `setUsbMode(.qmi, reboot: true)` when the port answers `,0` sends only the read (scripted port asserts the exact lines sent); `setUsbMode(.ecm, reboot: true)` from qmi sends exactly `AT+QCFG="usbnet"`, `AT+QCFG="usbnet",1`, `AT+QCFG="usbnet"`, `AT+CFUN=1,1` in that order; `reboot: false` stops before `AT+CFUN`; a read-back that disagrees → a failure and no `AT+CFUN`. `ModemCliTests`: parsing (`usbmode`, `usbmode --json`, `usbmode set qmi`, `--no-reboot`, `--yes`, rejects `usbmode set`, `usbmode set foo`, `usbmode set qmi extra`); the printed lines above; `--json` shape; cancel path exit 1; no terminal and no `--yes` → exit 2 and no `setUsbMode` call on the fake.
- [ ] **Step 2: Run** `make app-test`. Expected: FAIL.
- [ ] **Step 3: Implement** in `ModemService.swift` and `ModemCli.swift`, following the existing verbs (`radio`, `mode`) for structure, prompting (use the existing confirmation or `readLine` pattern the CLI already has, if any; otherwise `readLine()` with an `isatty(0)` check) and exit codes.
- [ ] **Step 4: Run all five targets and `make driver`; commit:** `app: RMNet usbmode reads and sets the modem's USB network mode, so a new modem can be put in QMI mode without another tool`

### Task 3: A README for builders; reference and evidence move to docs

**Files:**
- Rewrite: `README.md`
- Create: `docs/reference.md` (from today's README sections "Make targets", "Driver" with its subsections "Removing the driver", "Serial ports", "Supported models", and "Harness"), `docs/status.md` (from "Done means" and "Owner steps")
- Modify: links in `docs/driverkit-notes.md` or other docs that say `README, "<section>"` for a moved section now say `docs/reference.md, "<section>"` or `docs/status.md`

**Interfaces:**
- Consumes: Task 1's `config.example`, `config.local`, `scripts/config.sh`, `gen.rb --team/--bundle-id`; Task 2's `RMNet usbmode` and its texts.

What the new README holds (plain English, short paragraphs and lists, about 1,500 to 2,500 words; no test evidence, no dates of test runs; link to `docs/status.md` for evidence):
1. What it is: a DriverKit driver that makes a Quectel RM520N-GL in QMI mode an ordinary network port, plus the RMNet app (status, SMS, modem controls, GPS, serial ports). Status in one paragraph: used daily on one Mac (Apple silicon, macOS 27) with one RM520N-GL; 13 other Quectel models are matched but untested; nobody ships binaries, you build your own.
2. Requirements: a Mac with Apple silicon on macOS 27; Xcode 27.1 or later, signed in to a **paid** Apple Developer Program team (a free Personal Team cannot sign DriverKit); the Ruby gem `xcodeproj` for the system Ruby (`gem install --user-install xcodeproj` if `/usr/bin/ruby -e 'require "xcodeproj"'` fails); the modem on USB.
3. One-time setup: `cp config.example config.local`, fill in the team ID and a bundle ID you own.
4. The modem's USB mode: what QMI mode is; `RMNet usbmode` to check and `RMNet usbmode set qmi` to switch (works before the driver is installed: the app talks to the modem's AT port directly); the product-ID caveat from Task 2.
5. Build and install: `scripts/install-driver.sh` (what it does in two lines: builds signed, keeps a copy in `build/installed/`, installs to `/Applications`, activates); the first time, approve the driver in System Settings (General → Login Items & Extensions → Driver Extensions); unplug and replug the modem (or `AT+CFUN=1,1`) when a newer build was installed over a running one; how to check: `RMNet status`, `en33`-style port name varies per Mac (`networksetup -listallhardwareports`, hardware port `RM520N-GL`).
6. Using it: a short table of the app's verbs (`status`, `sms`, `gps`, `network`, `radio`, `mode`, `apn`, `sim`, `usbmode`, `activate`, `deactivate`) with one line each, and the window's tabs.
7. Updating and removing: rerun the install script; removal from the window (`Remove…`) or `RMNet deactivate`, and why `build/installed/` must be kept (only an app embedding that exact driver version can remove it).
8. Troubleshooting: the driver does not appear (approval, `systemextensionsctl list`); the port has no address (`RMNet status`, the APN: `RMNet apn`); logs with `scripts/driver-log.sh`; after a macOS update; "an older build is still running" (replug).
9. Known limits: one data connection; no USB idle suspend (why, one sentence, link to the notes); IPv4 MTU stays 1500; macOS's service order decides whether the port is used, Wi-Fi usually comes first.
10. For developers: the layout (`core/`, `driver/`, `app/`, `harness/`, `scripts/`, `tests/`), the make targets (one line each, details in `docs/reference.md`), `docs/reference.md`, `docs/status.md`, `docs/driverkit-notes.md` (what was learned about DriverKit on hardware), `docs/superpowers/` (the design and the plans it was built from).
11. Licence: a heading with "Not yet chosen; until a LICENSE file is added, all rights are reserved by the author." (the owner decides).

The moved text keeps its content; only change what Tasks 1 and 2 made stale (for example `gen.rb ABCDE12345` becomes `gen.rb --team <your team> --bundle-id <yours>`), and section references.

- [ ] **Step 1: Move** the sections into `docs/reference.md` and `docs/status.md` (one commit-ready move; check with `git diff --stat` that the moved text is nearly all additions there and deletions in README).
- [ ] **Step 2: Write** the new README as above.
- [ ] **Step 3: Fix references**: `grep -rn 'README, "' docs app scripts driver core tests` and point each moved section at its new file.
- [ ] **Step 4: Check every command in the README** against the code: each verb and option exists in `app/main.swift`/`app/ModemCli.swift`, each script path exists, `config.example`'s names match `scripts/config.sh`.
- [ ] **Step 5: Run all five targets; commit:** `docs: a README for people who build their own; the reference and the evidence move to docs/reference.md and docs/status.md`

---

## After the tasks (coordinator, on the modem)

Write `config.local` for this Mac (team `ABCDE12345`, bundle `io.rmnetdriver.RMNet`), run `scripts/install-driver.sh` (same IDs: a normal update), `AT+CFUN=1,1` through the console, then check: the running CDHash matches; `en33` IPv4 and IPv6, pings; `RMNet usbmode` prints `qmi`; `RMNet usbmode set qmi --yes` prints `already qmi; nothing changed` and the modem does not restart; `configd` steady. Only pings move data. Record in `docs/status.md` and the notes; land on `main`.
