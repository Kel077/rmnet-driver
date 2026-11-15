# Serial Ports (NMEA and DIAG) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The modem's NMEA (GNSS) interface and its DIAG interface appear as macOS serial devices, `/dev/cu.RM520N-GL-NMEA` and `/dev/cu.RM520N-GL-DIAG`, as Quectel's own drivers expose them on Linux (`/dev/ttyUSB*`) and Windows (COM ports); `RMNet gps` prints the position read from the NMEA port.

**Architecture:** A second DriverKit class, `RMNetSerial`, a subclass of USBSerialDriverKit's `IOUserUSBSerial`, lives in the existing dext beside `RMNetDriver`, with two new personalities matching USB interfaces 0 (DIAG) and 1 (NMEA) only. Apple's `IOUserUSBSerial` does the bulk I/O and the tty rings; our class checks that the interface is the one the personality expects before anything is opened, names the port, and answers the UART calls. Two pure checks live in Core so `make test` covers them; the `gps` verb's NMEA parsing is pure Swift covered by `make app-test`.

**Tech Stack:** DriverKit 27.0 (USBSerialDriverKit, SerialDriverKit, USBDriverKit), C++17 Core with `tests/minitest.h`, Swift 5 app (`swiftc` tests), `plutil`, POSIX termios.

**Spec:** the brief from the controlling session (no design document); its requirements are restated in "Requirements" below, and the decisions it asked for are recorded in "Decisions".

## Requirements (from the brief)

- NMEA (GNSS) interface, and DIAG if worthwhile, appear as `/dev/cu.*` serial devices.
- Never claim interfaces 2, 3 (AT ports: the owner's console holds 2 through libusb, the app's SMS opens 3) or 4 (QMI, held by `RMNetDriver`).
- The installed build must keep the network driver working: `en33` IPv4 and IPv6, pings in both families, and `RMNet sms list`.
- Optional, if cheap: an `RMNet gps` verb that prints the position read from the port.
- `make test`, `make check-driverkit` and `make app-test` pass; `README.md` and `docs/driverkit-notes.md` are updated; everything is committed on `serial-ports`.

## Decisions

**USB layout** (read with `ioreg` on 2026-11-15; `AT+QCFG="usbcfg"` reports `0x2C7C,0x0801,1,1,1,1,1,0,0`):

| Interface | Class / subclass / protocol | Endpoints | Function | Who has it |
|---|---|---|---|---|
| 0 | ff / ff / 30 | 2 (bulk IN, bulk OUT) | DIAG | nobody → `RMNetSerial` |
| 1 | ff / 00 / 40 | 3 (with interrupt IN) | NMEA | nobody → `RMNetSerial` |
| 2 | ff / 00 / 00 | 3 | AT | the owner's console (libusb) |
| 3 | ff / 00 / 00 | 3 | AT | the app's SMS (user space) |
| 4 | ff / ff / ff | 3 | QMI | `RMNetDriver` |

**Where the code lives: new classes in the existing dext.** One bundle, one version, one approval, one install path: `scripts/install-driver.sh`, the app's activation and the version-matched removal (docs/reference.md, "Removing the driver") all stay as they are, and the app (which the `app-controls` session is changing) needs no driver-management change. A second dext would need its own bundle ID, provisioning profile, activation request and removal path in the app, and its own kept apps. DriverKit starts a separate process for each matched provider unless the personality sets `IOUserServerOneProcess`, so a fault in a serial instance should not stop `en33` (Task 4 checks this with `ps`).

**Family: USBSerialDriverKit's `IOUserUSBSerial`.** The SDK (`DriverKit27.0.sdk`) has `SerialDriverKit` (`IOUserSerial`) and `USBSerialDriverKit` (`IOUserUSBSerial`). macOS ships `com.apple.DriverKit-AppleUSBSerial.dext`, whose class `AppleGenericUSBSerial` is an `IOUserUSBSerial` that overrides only `Start` (super, then `RegisterService`). What `IOUserUSBSerial` does, read from its disassembly (the DriverKit shared cache, extracted to the scratchpad):
- `Start`: calls `IOUserSerial::Start`, then sets `IOTTYBaseName` = `usbserial-` and `IOTTYSuffix` = the USB serial number (or the location ID in hex), followed by the interface number in hex when the configuration has two or more interfaces. It reads the personality's `quirks` (a 16-bit number); bit 0 sends a zero-length packet after a write that is a whole number of max-size packets.
- `ConnectQueues` opens the interface (for client `this`); `DisconnectQueues` closes it. `HwActivate` (a port being opened) copies the pipes: a bulk IN and a bulk OUT are required (`kIOReturnError` without them), an interrupt IN is optional. So DIAG's two bulk endpoints are enough. Each read is one max-size packet.
- It does not implement `HwResetFIFO`, `HwSendBreak`, `HwProgramUART`, `HwProgramBaudRate`, `HwProgramMCR`, `HwGetModemStatus`, `HwProgramLatencyTimer` or `HwProgramFlowControl` (pure in `IOUserSerial.iig`). `RMNetSerial` implements all eight.

**Entitlement: `com.apple.developer.driverkit.family.serial`, checked.** On 2026-11-15 at 03:40, a signed Release build of the `RMNetDriver` target alone, with that key added to `driver/Driver.entitlements`, `-allowProvisioningUpdates` and team `ABCDE12345`, succeeded: Xcode replaced the profile "DriverKit Team Provisioning Profile: io.rmnetdriver.RMNet.driver" (now `~/Library/Developer/Xcode/UserData/Provisioning Profiles/6d3b0ea4-cad5-43cf-8071-24af4e246bdc.provisionprofile`) with one granting `family.networking` and `family.serial`, and the signed dext carried both. Nothing was installed. The existing `transport.usb` entitlement (`idVendor` `*`) already covers interfaces 0 and 1.

**Personalities.** Kernel class `IOUserSerial` from `com.apple.driver.driverkit.serial` (as Apple's serial dexts use), `IOUserClass` `RMNetSerial`, the proven 4-key USB match (`idVendor` 11388, `idProduct` 2049, `bConfigurationValue` 1, `bInterfaceNumber` 0 or 1), plus our keys: `RMNetSerialName`, `RMNetSerialSubClass`, `RMNetSerialProtocol`, and `quirks` = 1. Matching by interface number alone could take an AT or QMI interface if the modem's USB configuration changed (for example DIAG switched off renumbers the rest), so `Start` refuses, before the superclass opens anything, unless the interface's class, subclass and protocol are `ff` and the personality's subclass and protocol. A static check (`scripts/check-personalities.sh`, run by `make check-driverkit`) refuses any personality on interface 2 or 3, a serial one on any interface but 0 or 1, and `RMNetDriver` on any but 4.

**Port names.** `IOUserUSBSerial` would name the ports `usbserial-<serial number>0` and `...1`. `RMNetSerial` sets `IOTTYBaseName` to `RMNetSerialName` and `IOTTYSuffix` to `""` with `SetProperties` after the superclass's `Start` and before `RegisterService` (the BSD client, which makes `/dev/cu.*` and `/dev/tty.*`, is matched at registration and reads those two properties; Apple's Bluetooth serial dext sets them the same way at run time). If that is refused, the port keeps Apple's name and the driver logs it. Names: `RM520N-GL-DIAG` and `RM520N-GL-NMEA`.

**DTR and RTS.** Linux's `option`/`usb_wwan` driver sends the CDC request SET_CONTROL_LINE_STATE (`bmRequestType` 0x21, `bRequest` 0x22, `wValue` DTR bit 0 and RTS bit 1, `wIndex` the interface number) when a port opens and closes. `HwProgramMCR` does the same, synchronously, with a 1000 ms timeout; a failure is logged and the call still returns success, so opening a port never fails on it.

**Zero-length packets.** Quectel's Linux driver sets `URB_ZERO_PACKET` on every bulk OUT for vendor 0x2C7C, so both personalities set `quirks` = 1.

**DIAG is included.** It costs one personality on the same class, and it lets Qualcomm DIAG tools that take a serial device (QCSuper, Quectel's QLog) run on the Mac. Task 4 checks it with the read-only version request (bytes `00 78 F0 7E`, an HDLC-framed command 0x00).

**`RMNet gps` is included.** It only reads `/dev/cu.RM520N-GL-NMEA`; it never changes a modem setting (GNSS on and off stay on the owner's console). Positions are printed to the terminal only; nothing logs or stores them.

**Proven compile.** A spike with the class below, built by `make driver` on 2026-11-15, compiled and linked (`** BUILD SUCCEEDED **`, `driver build ok`): `/private/tmp/claude-501/-Users-you-personal-RM520N-GL/3397de07-3dc6-4077-a22d-37ade8341883/scratchpad/spike/RMNetSerial.iig` and `RMNetSerial.cpp` (scratch; may be gone). Its override signatures are the ones in Task 2.

## Global Constraints

- Work only in `~/personal/RM520N-GL/worktrees/serial-ports` on branch `serial-ports`. Never touch `~/personal/RM520N-GL/rmnet-driver` or `~/personal/RM520N-GL/worktrees/app-controls`.
- No serial personality on interface 2, 3 or 4; serial personalities on interfaces 0 and 1 only.
- Implementer subagents never install (`scripts/install-driver.sh`), never re-enumerate the modem, never send AT commands, never run `~/personal/RM520N-GL/at.py`, and never run `measure.sh` or `soak.sh` (the SIM is metered). Task 4 is the controller's, with the owner's approval.
- No sudo, no passwords, no System Settings or `sysctl` changes. Never edit or delete `build/installed/` in the main checkout.
- Commits: only the files of the task, `git add <paths>` (never `-A`), conventional prefixes (`feat:`, `test:`, `docs:`, `chore:`), no attribution or co-author lines. Never push. If `git commit` reports `index.lock`, wait a few seconds and retry.
- Core code (`core/`): C++17, `-Wall -Wextra -Werror -fno-exceptions -fno-rtti`, no heap, no STL; namespace `rmnet`.
- Driver log lines start with `RMNet: ` (so `scripts/driver-log.sh` keeps them); strings use `%{public}s`.
- Device names exactly `RM520N-GL-DIAG` and `RM520N-GL-NMEA` (`/dev/cu.` and `/dev/tty.`).
- Never log, print to notes or commit a position, an SMS text or a phone number.
- `make test`, `make check-driverkit`, `make app-test` pass and `make driver` prints `driver build ok` at the end of every task.
- Comments and docs follow the repository's style: plain full sentences saying what is true and why.

## Review Focus

- The modem's USB configuration changes (`AT+QCFG="usbcfg"` switches DIAG or NMEA off, interfaces renumber): a serial personality must never end up on an AT or QMI interface. Task 1 tests the triple check against the AT and QMI triples; Task 2's static check refuses personalities on 2 and 3.
- GNSS off or no antenna: the NMEA port is silent or sends empty sentences. `RMNet gps` must end within its time and say what it saw, never hang. Task 3 tests the zero-sentence and no-fix outcomes; its reader has a hard deadline.
- Garbled input on the NMEA port: sentences split across USB transfers, CR LF or bare LF, bad checksums, a runaway line with no LF, bytes that are not UTF-8. Bad lines are dropped; nothing crashes. Task 3's line-buffer and parser tests.
- The modem re-enumerates (`AT+CFUN=1,1`, unplug) while a serial port is open (`cat` running): the reader gets an error or end of file, the instances stop cleanly, the ports return after the modem does, and `RMNetDriver` is unaffected. Task 4 runs it.
- A serial instance fails or crashes: `en33` keeps working. Task 4 checks that the serial instances run in their own processes and that `en33` passes its checks after every step.

---

### Task 1: Core checks for the serial personalities

**Files:**
- Create: `core/include/rmnet/serial_port.h`
- Create: `core/src/serial_port.cpp`
- Test: `tests/test_serial_port.cpp`

**Interfaces:**
- Produces (namespace `rmnet`, header `rmnet/serial_port.h`):
  - `enum : size_t { kTtyNameMax = 31 };`
  - `bool serial_interface_matches(uint8_t iface_class, uint8_t subclass, uint8_t protocol, uint64_t want_subclass, uint64_t want_protocol);` true only when `iface_class == 0xff`, `subclass == want_subclass` and `protocol == want_protocol` (a wanted value above 255 never matches; no truncation).
  - `bool tty_name_ok(const char* name);` true when `name` is not null and is 1 to `kTtyNameMax` characters, each `A-Z`, `a-z`, `0-9`, `-` or `_`, then a NUL. It reads at most `kTtyNameMax + 1` bytes.

- [ ] **Step 1: Write the failing tests** in `tests/test_serial_port.cpp` (style of `tests/test_stall.cpp`; header comment says what is tested):

```cpp
TEST(serial_interface_matches_diag_and_nmea) {
  CHECK(rmnet::serial_interface_matches(0xff, 0xff, 0x30, 255, 48));
  CHECK(rmnet::serial_interface_matches(0xff, 0x00, 0x40, 0, 64));
}
TEST(serial_interface_refuses_at_and_qmi) {
  CHECK(!rmnet::serial_interface_matches(0xff, 0x00, 0x00, 0, 64));    // AT, interfaces 2 and 3
  CHECK(!rmnet::serial_interface_matches(0xff, 0xff, 0xff, 255, 48));  // QMI, interface 4
  CHECK(!rmnet::serial_interface_matches(0xff, 0x00, 0x00, 255, 48));
}
TEST(serial_interface_refuses_other_class_and_out_of_range_wants) {
  CHECK(!rmnet::serial_interface_matches(0x02, 0xff, 0x30, 255, 48));
  CHECK(!rmnet::serial_interface_matches(0xff, 0xff, 0x30, 255 + 256, 48));
  CHECK(!rmnet::serial_interface_matches(0xff, 0xff, 0x30, 255, 48 + 256));
}
TEST(tty_name_ok_accepts_port_names) {
  CHECK(rmnet::tty_name_ok("RM520N-GL-NMEA"));
  CHECK(rmnet::tty_name_ok("RM520N-GL-DIAG"));
  CHECK(rmnet::tty_name_ok("a_1"));
  CHECK(rmnet::tty_name_ok("abcdefghijklmnopqrstuvwxyz01234"));  // 31
}
TEST(tty_name_ok_refuses_bad_names) {
  CHECK(!rmnet::tty_name_ok(nullptr));
  CHECK(!rmnet::tty_name_ok(""));
  CHECK(!rmnet::tty_name_ok("abcdefghijklmnopqrstuvwxyz012345"));  // 32
  CHECK(!rmnet::tty_name_ok("a b"));
  CHECK(!rmnet::tty_name_ok("a/b"));
  CHECK(!rmnet::tty_name_ok("a.b"));
  CHECK(!rmnet::tty_name_ok("caf\xc3\xa9"));
}
```

- [ ] **Step 2: Run them and see them fail**

Run: `make test FILTER=serial`
Expected: the build fails (`rmnet/serial_port.h` not found).

- [ ] **Step 3: Write `core/include/rmnet/serial_port.h` and `core/src/serial_port.cpp`** with the Interfaces above; the header's opening comment says these are the checks `RMNetSerial` makes before it takes an interface, and why (an interface number alone could name an AT or QMI interface after a USB configuration change).

- [ ] **Step 4: Run the tests and see them pass**

Run: `make test FILTER=serial` then `make test` then `make check-driverkit`
Expected: the five new tests pass; every test passes; `driverkit check: 11 files ok`.

- [ ] **Step 5: Commit**

```bash
git add core/include/rmnet/serial_port.h core/src/serial_port.cpp tests/test_serial_port.cpp
git commit -m "feat: core checks for the serial ports' interface and name"
```

---

### Task 2: `RMNetSerial`, its personalities and its entitlement

**Files:**
- Create: `driver/RMNetSerial.iig`, `driver/RMNetSerial.cpp`
- Create: `scripts/check-personalities.sh`
- Modify: `driver/Info.plist` (two personalities), `driver/Driver.entitlements` (one key), `gen.rb` (`OTHER_LDFLAGS`), `Makefile` (`check-driverkit`)
- Modify: `README.md` (Driver section and Make targets), `docs/driverkit-notes.md` (new section 6)

**Interfaces:**
- Consumes: `rmnet::serial_interface_matches`, `rmnet::tty_name_ok` (Task 1).
- Produces: the devices `/dev/cu.RM520N-GL-DIAG` and `/dev/cu.RM520N-GL-NMEA` (once installed); registry class `IOUserSerial` with `IOUserClass` `RMNetSerial`.

- [ ] **Step 1: Write the static personality check and see it fail**

`scripts/check-personalities.sh [plist]` (default `driver/Info.plist`), POSIX sh, using `plutil -extract IOKitPersonalities raw -o - <plist>` to list personality names and `plutil -extract IOKitPersonalities.<name>.<key> raw -o - <plist>` for values. Rules, each failure printed as `personality check: <name>: <reason>`:
- no personality has `bInterfaceNumber` 2 or 3;
- a personality with `IOUserClass` `RMNetSerial` has `bInterfaceNumber` 0 or 1, `IOClass` `IOUserSerial`, `CFBundleIdentifierKernel` `com.apple.driver.driverkit.serial`, and `RMNetSerialName` matching `^[A-Za-z0-9_-]{1,31}$`;
- a personality with `IOUserClass` `RMNetDriver` has `bInterfaceNumber` 4;
- at least one `RMNetDriver` personality exists.
It ends with `personality check: <n> personalities ok` (exit 0) or `personality check: failed` (exit 1). Add it to the `check-driverkit` target after `./scripts/check-driverkit-compile.sh`.

Run: `./scripts/check-personalities.sh` (passes: one personality). Then make a scratch copy with `RMNetDriver`'s `bInterfaceNumber` set to 3 (`plutil -replace IOKitPersonalities.RMNetDriver.bInterfaceNumber -integer 3 <copy>`, the copy in `$TMPDIR` or the scratchpad, never in the repository) and run the script on it.
Expected: exit 1, naming `RMNetDriver`, both for "interface 3" and "not 4".

- [ ] **Step 2: Add the personalities, the entitlement and the link flags**

- `driver/Info.plist`: personalities `RMNetSerialDIAG` and `RMNetSerialNMEA`, each with `CFBundleIdentifier` and `IOUserServerName` `$(PRODUCT_BUNDLE_IDENTIFIER)`, `CFBundleIdentifierKernel` `com.apple.driver.driverkit.serial`, `IOClass` `IOUserSerial`, `IOProviderClass` `IOUSBHostInterface`, `IOUserClass` `RMNetSerial`, `idVendor` 11388, `idProduct` 2049, `bConfigurationValue` 1, `quirks` 1, and:

| Personality | `bInterfaceNumber` | `RMNetSerialName` | `RMNetSerialSubClass` | `RMNetSerialProtocol` |
|---|---|---|---|---|
| `RMNetSerialDIAG` | 0 | `RM520N-GL-DIAG` | 255 | 48 |
| `RMNetSerialNMEA` | 1 | `RM520N-GL-NMEA` | 0 | 64 |

  Update `OSBundleUsageDescription` to mention the serial ports. Leave `RMNetDriver` unchanged.
- `driver/Driver.entitlements`: `com.apple.developer.driverkit.family.serial` = true, after `family.networking`.
- `gen.rb`: `OTHER_LDFLAGS` gains `-framework SerialDriverKit -framework USBSerialDriverKit`.

Run: `plutil -lint driver/Info.plist driver/Driver.entitlements && ./scripts/check-personalities.sh`
Expected: both OK; `personality check: 3 personalities ok`.

- [ ] **Step 3: Write `driver/RMNetSerial.iig`**

`class RMNetSerial : public IOUserUSBSerial` (includes `<DriverKit/IOService.iig>`, `<USBSerialDriverKit/IOUserUSBSerial.iig>`), with exactly these overrides (spellings proven by the spike):

```
virtual bool init() override;
virtual void free() override;
virtual kern_return_t Start(IOService * provider) override;
virtual kern_return_t Stop(IOService * provider) override;
virtual kern_return_t HwActivate() override;
virtual kern_return_t HwDeactivate() override;
virtual kern_return_t HwResetFIFO(bool tx, bool rx) override;
virtual kern_return_t HwSendBreak(bool sendBreak) override;
virtual kern_return_t HwProgramUART(uint32_t baudRate, uint8_t nDataBits, uint8_t nHalfStopBits, uint8_t parity) override;
virtual kern_return_t HwProgramBaudRate(uint32_t baudRate) override;
virtual kern_return_t HwProgramMCR(bool dtr, bool rts) override;
virtual kern_return_t HwGetModemStatus(bool * cts, bool * dsr, bool * ri, bool * dcd) override;
virtual kern_return_t HwProgramLatencyTimer(uint32_t latency) override;
virtual kern_return_t HwProgramFlowControl(uint32_t arg, uint8_t xon, uint8_t xoff) override;
```

The class comment says what it is (the modem's DIAG and NMEA interfaces as serial ports; Apple's `IOUserUSBSerial` moves the bytes) and that it must never be matched to interfaces 2, 3 or 4.

- [ ] **Step 4: Write `driver/RMNetSerial.cpp`**

Each method body is `Name_Impl` (`IOService` RPC rule, notes 3.1); call the superclass with `Name(args, SUPERDISPATCH)` for `Start`, `Stop`, `HwActivate`, `HwDeactivate`, and `super::init()`/`super::free()`. Include `<os/log.h>`, `<DriverKit/DriverKit.h>`, `<USBDriverKit/USBDriverKit.h>`, `<USBSerialDriverKit/USBSerialDriverKit.h>`, `"RMNetSerial.h"` and `"rmnet/serial_port.h"`. Ivars (`RMNetSerial_IVars`, made with `IONewZero` in `init`, freed in `free`): the retained `IOUSBHostInterface*`, the interface number, the port name (a `char[rmnet::kTtyNameMax + 1]`), the last DTR and RTS, and a bit set of which `Hw*` calls have been logged.

- `Start_Impl(provider)`, in this order:
  1. Log `RMNet: serial start`.
  2. `OSDynamicCast(IOUSBHostInterface, provider)`; read the interface descriptor (`CopyConfigurationDescriptor`, `GetInterfaceDescriptor`, `IOUSBHostFreeDescriptor`, as `RMNetDriver` does) for `bInterfaceNumber`, class, subclass, protocol.
  3. `CopyProperties`: `RMNetSerialName` (`OSString`), `RMNetSerialSubClass` and `RMNetSerialProtocol` (`OSNumber`, `unsigned64BitValue`).
  4. Unless the provider is an interface, its descriptor was read, both numbers are present, `rmnet::serial_interface_matches(...)` and `rmnet::tty_name_ok(name)`: log `RMNet: serial refused interface <n> (class <c> subclass <s> protocol <p>)` (or which property is missing or bad) and return `kIOReturnUnsupported`. Nothing has been opened, and the superclass's `Start` has not been called.
  5. `Start(provider, SUPERDISPATCH)`; on failure log it and return its result.
  6. `SetProperties` with `IOTTYBaseName` = the name and `IOTTYSuffix` = `""`; log a failure (the port then keeps Apple's `usbserial-...` name) and go on.
  7. `RegisterService()`; log `RMNet: serial <name>: started on interface <n>` and return its result.
- `Stop_Impl`: log `RMNet: serial <name>: stop`, release the interface, `Stop(provider, SUPERDISPATCH)`.
- `HwActivate_Impl`/`HwDeactivate_Impl`: forward to the superclass; log every call with its result (`open`/`close`, once per port open or close).
- `HwProgramMCR_Impl(dtr, rts)`: remember both; send SET_CONTROL_LINE_STATE with `ivars->interface->DeviceRequest(0x21, 0x22, (dtr ? 1 : 0) | (rts ? 2 : 0), interfaceNumber, 0, nullptr, &transferred, 1000)`; log the values and the status every call; always return `kIOReturnSuccess`.
- `HwGetModemStatus_Impl`: `*cts = *dsr = *dcd = true`, `*ri = false`; success.
- The other five: success, no I/O; each logs its arguments on its first call only (`HwProgramUART` with baud, data bits, half stop bits, parity).

- [ ] **Step 5: Build**

Run: `make driver` then `make test` then `make check-driverkit` then `make app-test`
Expected: `driver build ok`; all pass. Then `nm -m build/xcode/Debug-driverkit/io.rmnetdriver.RMNet.driver.dext/io.rmnetdriver.RMNet.driver | c++filt | grep -c 'RMNetSerial::.*_Impl'` prints 14 (Start, Stop and twelve `Hw*`).

- [ ] **Step 6: Document**

- `README.md`: in "Driver", a subsection "### Serial ports" saying which interfaces become which devices, that nothing else on the modem is claimed (2 and 3 stay free for the console and the app, 4 is `RMNetDriver`), that `Start` refuses an interface whose class, subclass and protocol differ from the personality's, how to read NMEA (`cat /dev/cu.RM520N-GL-NMEA`; GNSS must be on: `AT+QGPS=1` on the console, `AT+QGPSEND` off; without a fix the sentences are empty), and that the DIAG port speaks Qualcomm's HDLC-framed DIAG protocol for tools such as QCSuper. Mark the hardware behaviour **not yet shown** (Task 4 replaces it). In "Make targets", `make check-driverkit` also runs `scripts/check-personalities.sh`.
- `docs/driverkit-notes.md`: a new "## 6. Serial ports (USBSerialDriverKit)" after section 5, carrying this plan's findings: what `IOUserUSBSerial` does (from "Decisions"), the personality keys, the entitlement check and profile, the naming, DTR, `quirks`, and the open runtime questions Task 4 answers: whether our `SetProperties` names win, which `Hw*` calls the kernel makes and in what order, whether the instances run in their own processes.

- [ ] **Step 7: Commit**

```bash
git add driver/RMNetSerial.iig driver/RMNetSerial.cpp driver/Info.plist driver/Driver.entitlements gen.rb Makefile scripts/check-personalities.sh README.md docs/driverkit-notes.md
git commit -m "feat: the modem's DIAG and NMEA interfaces as serial ports"
```

---

### Task 3: `RMNet gps`

**Files:**
- Create: `app/Nmea.swift` (pure: parsing, line buffer, report, outcome, argument parsing; Foundation only)
- Create: `app/GpsCommand.swift` (the port: open, termios, read loop; `runGps`)
- Test: `tests/app/NmeaTests.swift`
- Modify: `Makefile` (`build/nmea-tests`, run by `app-test`), `app/main.swift` (usage line, header comment, the hook), `README.md` (the verb; `make app-test` runs five programs)

**Interfaces:**
- Consumes: the device path `/dev/cu.RM520N-GL-NMEA` (Task 2's personality; this task needs no driver code).
- Produces (all in `app/Nmea.swift`):
  - `struct NmeaSentence: Equatable { let talker: String; let type: String; let fields: [String] }`; for `$GPRMC,123519,A,...*6A`, talker `GP`, type `RMC`, `fields[0]` = `123519` (the address is not a field).
  - `enum Nmea { static func parse(_ line: String) -> NmeaSentence?; static func coordinate(_ value: String, _ hemisphere: String) -> Double? }`
  - `struct NmeaLineBuffer { mutating func append(_ bytes: [UInt8]) -> [String] }`
  - `struct GpsReport { var sentences: Int; var latitude: Double?; var longitude: Double?; var altitude: Double?; var satellitesUsed: Int?; var time: String?; var satellitesInView: Int; var hasFix: Bool; mutating func add(_ s: NmeaSentence) }` (read-only from outside where Swift allows)
  - `func gpsOutcome(_ report: GpsReport, seconds: Int) -> (lines: [String], code: Int32)`
  - `func parseGps(_ words: [String]) -> Int?` (seconds)
  - in `app/GpsCommand.swift`: `let nmeaPortPath = "/dev/cu.RM520N-GL-NMEA"`, `func runGps(seconds: Int) -> Int32`

Rules the tests pin:
- `parse`: the line (trailing CR, LF and spaces ignored) starts with `$`; the address (up to the first comma) is 3 to 10 letters or digits; it ends with `*` and two hex digits (either case) equal to the XOR of every byte between `$` and `*`. Anything else is `nil`.
- `coordinate`: `ddmm.mmmm` with `N`/`S`, `dddmm.mmmm` with `E`/`W`; `S` and `W` negative; `nil` for an empty value, another hemisphere letter, minutes of 60 or more, or more than 90 or 180 degrees.
- `GpsReport.add`: every parsed sentence counts in `sentences`. `RMC`: status (`fields[1]`) `A` takes the position from `fields[2...5]` and `time` from `fields[0]`; any other status clears the position. `GGA`: quality (`fields[5]`) of 1 or more takes the position from `fields[1...4]`, `time` from `fields[0]`, `satellitesUsed` from `fields[6]`, `altitude` from `fields[8]`; quality 0 or empty clears the position, `satellitesUsed` and `altitude`. The latest `RMC` or `GGA` decides. `GSV`: `fields[2]` is that talker's satellites in view; `satellitesInView` is the sum of each talker's latest. A position whose coordinate fails to parse is no position. `hasFix` is latitude and longitude both present.
- `NmeaLineBuffer.append`: returns the complete lines (split at LF, a CR before it dropped, empty lines skipped), keeps a partial line for the next call; a line longer than 512 bytes is dropped up to its LF; bytes that are not UTF-8 are decoded lossily (the checksum then rejects the line).
- `gpsOutcome`, exact text:
  - no sentences: `["gps: no NMEA sentences in <seconds> s; GNSS may be off (AT+QGPS? on the console shows it, AT+QGPS=1 switches it on)"]`, 1
  - no fix: `["gps: no fix after <seconds> s (<sentences> sentences, <satellitesInView> satellites in view)"]`, 1
  - fix: `["gps: fix <lat>, <lon>"]` with `%.6f`, then, if any part is known, one line `"  " + parts.joined(separator: ", ")` with parts in this order: `altitude <%.1f> m`, `<n> satellites used`, `<hh:mm:ss> UTC` (from `time`'s first six digits); code 0.
- `parseGps`: `[]` → 10; one integer word 1 to 600 → it; anything else → `nil`.
- `runGps(seconds:)`: if `nmeaPortPath` does not exist, print `gps: /dev/cu.RM520N-GL-NMEA not found (the driver is not attached to the modem's NMEA interface)` and return 1. Open with `O_RDONLY | O_NOCTTY | O_NONBLOCK` (`gps: cannot open /dev/cu.RM520N-GL-NMEA: <strerror>` and 1 on failure), make it raw with `tcgetattr`/`cfmakeraw`/`tcsetattr` (a failure there is not fatal), and read with `poll(2)` until the deadline (`seconds` from the start) or, after the first fix, for at most one more second (the rest of that second's sentences). A read error ends the loop (the port went away). Close the port, print `gpsOutcome`'s lines, return its code. It writes nothing to the port and logs nothing.
- `main.swift`: before the `Command` guard, `if verbs.first == "gps" { guard let seconds = parseGps(Array(verbs.dropFirst())) else { print(usage); exit(2) }; exit(runGps(seconds: seconds)) }`; `usage` gains ` | gps [seconds]`; the header comment lists the verb. Keep the change to these lines (another session edits this file).

- [ ] **Step 1: Write the failing tests** in `tests/app/NmeaTests.swift`, in the style of `tests/app/AtPortTests.swift` (a `check` helper, stops at the first failure, prints `nmea-test: <n> checks passed`). Sentences (checksums correct):

```
$GPRMC,123519,A,4807.038,N,01131.000,E,022.4,084.4,230394,003.1,W*6A
$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47
$GPRMC,,V,,,,,,,,,,N*53
$GPGGA,,,,,,0,,,,,,,,*66
$GPGSV,1,1,00*79
$GPVTG,,T,,M,,N,,K,N*2C
$GNRMC,021500.00,A,3330.1234,S,07040.5678,W,0.0,,151126,,,A,V*15
$GPGSV,3,1,11,01,40,083,46,02,17,308,41,12,07,344,39,14,22,228,45*7C
$GLGSV,1,1,03,65,30,100,20,66,40,200,25,67,50,300,*53
$GPGGA,021500.00,3330.1234,S,07040.5678,W,0,,,,,,,,*72
```

Checks (coordinates compared to within 1e-6):
- `parse` of the first: talker `GP`, type `RMC`, 11 fields, `fields[0] == "123519"`; the same with `*6a`; with a trailing `\r` and spaces.
- `parse` is `nil` for: the first with `*6B`; without `*6A`; without `$`; `!AIVDM,1,1,,A,1,0*00`; `$G*00`; an empty line.
- `coordinate`: `("4807.038","N")` → 48.1173; `("01131.000","E")` → 11.516667; `("3330.1234","S")` → -33.502057; `("07040.5678","W")` → -70.676130; `nil` for `("","N")`, `("4807.038","X")`, `("4860.000","N")`, `("9100.000","N")`, `("18100.000","E")`.
- Report from the first two: `hasFix`, 48.1173 / 11.516667, altitude 545.4, 8 used, time `123519`; `gpsOutcome(_, seconds: 10)` is `(["gps: fix 48.117300, 11.516667", "  altitude 545.4 m, 8 satellites used, 12:35:19 UTC"], 0)`.
- Report from lines 3 to 6 (a receiver with no fix): 4 sentences, no fix, 0 in view; outcome `(["gps: no fix after 10 s (4 sentences, 0 satellites in view)"], 1)`.
- Report from lines 8 and 9: 14 in view. Then line 8 again: still 14 (latest per talker, not a running sum).
- Report from line 7 alone: fix -33.502057 / -70.676130, time `021500.00`, outcome lines `["gps: fix -33.502057, -70.676130", "  02:15:00 UTC"]`. Then line 10: no fix (the latest decides).
- Empty report: `(["gps: no NMEA sentences in 10 s; GNSS may be off (AT+QGPS? on the console shows it, AT+QGPS=1 switches it on)"], 1)`.
- `NmeaLineBuffer`: lines 5 and 6 with CR LF, fed whole, byte by byte, and split inside each CR LF, give exactly those two lines; a line ending in bare LF is returned; 600 bytes of `A` with no LF, then `\n` + line 5 + `\r\n`, gives only line 5; bytes `FF FE` then `\n` give a line that `parse` rejects.
- `parseGps`: `[]` → 10, `["30"]` → 30, `["600"]` → 600; `nil` for `["0"]`, `["601"]`, `["x"]`, `["10", "20"]`, `["-5"]`.

Add to the `Makefile`: `build/nmea-tests: app/Nmea.swift tests/app/NmeaTests.swift` (same recipe as `build/at-tests`), listed in `app-test`'s prerequisites and run by it; update the comment above `app-test`.

- [ ] **Step 2: Run them and see them fail**

Run: `make app-test`
Expected: `build/nmea-tests` fails to compile (no `app/Nmea.swift`).

- [ ] **Step 3: Write `app/Nmea.swift`** with the Interfaces and rules above.

- [ ] **Step 4: Run the tests and see them pass**

Run: `make app-test`
Expected: the four existing programs pass and `nmea-test: <n> checks passed`.

- [ ] **Step 5: Write `app/GpsCommand.swift` and the `main.swift` hook**, then build the app

Run: `make driver` (compiles every `app/*.swift` into the app)
Expected: `driver build ok`. Then `build/xcode/Debug/RMNet.app/Contents/MacOS/RMNet gps 0` prints the usage line and exits 2; `RMNet gps 1` (with the installed driver having no serial ports) prints `gps: /dev/cu.RM520N-GL-NMEA not found (...)` and exits 1. Neither touches the modem.

- [ ] **Step 6: Document** in `README.md`: a bullet for `RMNet gps [seconds]` beside the `sms` verbs (what it reads, how long it waits, its three outcomes and exit codes, that it never changes a modem setting, that GNSS must be switched on at the console, that the position is printed only to the terminal); "Make targets": `make app-test` runs five programs, naming `app/Nmea.swift` with `tests/app/NmeaTests.swift`.

- [ ] **Step 7: Commit**

```bash
git add app/Nmea.swift app/GpsCommand.swift app/main.swift tests/app/NmeaTests.swift Makefile README.md
git commit -m "feat: RMNet gps prints the position read from the NMEA port"
```

---

### Task 4: Install and check on the modem (controller, with the owner's approval)

Not for a subagent. Before it: the whole-branch review, its fix wave and the re-review are done, and every Make target passes.

- [ ] **Step 1: Ask the owner** in one question: may the build be installed (replaces `/Applications/RMNet.app`, then `AT+CFUN=1,1` drops `en33` for about 40 s; the `app-controls` session's app changes are not in this build), is a GNSS antenna attached, and may GNSS be switched on (`AT+QGPS=1`) for the test and off afterwards (`AT+QGPSEND`).
- [ ] **Step 2: Before**: `ioreg` layout (interfaces 0 to 4, who holds them), `ls /dev/cu.*`, `en33` addresses, one ping per family, `RMNet sms list | head -1`, `AT+QGPS?` and `AT+QGPSCFG="outport"` (read-only) through the console.
- [ ] **Step 3: Install**: start `scripts/driver-log.sh` in the background, run `scripts/install-driver.sh` from the worktree (it keeps the replaced app and the new one in the worktree's `build/installed/`), then `AT+CFUN=1,1` through the console, and wait for `RMNetState` up.
- [ ] **Step 4: Check**: the serial instances' registry entries and `IOTTYBaseName`; `/dev/cu.RM520N-GL-DIAG` and `/dev/cu.RM520N-GL-NMEA` exist; interfaces 2 and 3 have no kernel driver (the console's libusb client on 2); the processes (`ps`, one per instance or not); then `en33` IPv4 and IPv6, `/sbin/ping -b en33 1.1.1.1`, `/sbin/ping6 -B en33 2606:4700:4700::1111`, `/Applications/RMNet.app/Contents/MacOS/RMNet sms list | head -1`, and the console answering `AT`.
- [ ] **Step 5: NMEA**: with the owner's yes, `AT+QGPS=1`; read the port for 10 s (`RMNet gps 10`, and a raw read showing sentence types only, never coordinates in any record); `AT+QGPSEND`. Without a fix, empty sentences prove the port.
- [ ] **Step 6: DIAG**: write `00 78 F0 7E` and read the answer for 2 s (expect an HDLC frame ending `7E` starting with `00`).
- [ ] **Step 7: Re-enumeration with a port open**: a `cat` on the NMEA port running, `AT+CFUN=1,1`; the reader ends, the instances stop (log), the ports and `en33` come back; repeat the Step 4 network checks; no new crash report under `/Library/Logs/DiagnosticReports` or `~/Library/Logs/DiagnosticReports` naming the driver.
- [ ] **Step 8: Record** in `docs/driverkit-notes.md` a "Runtime findings (serial ports, <date>)" section (build version, what was seen, which `Hw*` calls came and in what order, the names, the processes, what was not seen) and replace README's **not yet shown** with what was shown; commit `docs: serial ports on the modem`.
