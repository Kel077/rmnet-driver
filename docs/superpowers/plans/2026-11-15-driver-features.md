# Driver Features Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Three driver features that Quectel's own drivers have and ours lacks or does slowly: a held uplink drain restarts as soon as the uplink is usable again (with counters that show whether the two remaining 100 ms timer waits ever happen), matching for the other Quectel QMI modems (marked untested), and opt-in USB idle suspend.

**Architecture:** `UsbIo` gains one listener callback, `on_uplink_usable`, and the driver drains on it; the driver counts the two completion-queue refusals and the ticks that found work waiting. `driver/Info.plist` gains one personality per known Quectel QMI model; the app's modem detection reads the same list. A personality key `RMNetIdleSuspendMs` (absent or 0: today's behaviour) sets the interface's and pipes' idle policies when the modem offers remote wakeup, and the driver counts the ticks it finds the port suspended. Measurements before and after on the modem decide what the counters and the suspend are worth.

**Tech Stack:** C++17, DriverKit (USBDriverKit `IOUSBHostInterface::SetIdlePolicy`, `IOUSBHostPipe::SetIdlePolicy`, `GetPortStatus`), Swift 5, POSIX `sh`.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md`; the items: `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md` ("An 'uplink usable' callback", "Two paths wait for the 100 ms timer instead of a completion"), and the original session's comparison with Quectel's `qmi_wwan_q` and its Linux driver guide (chapter 5, USB auto suspend and remote wakeup; the model table). Several APNs at once (multi-PDN) is a separate design and plan after this one.

## Global Constraints

- Branch `driver-features`, cut from `main` at `61e2941`. Tasks run one at a time, in order, in this checkout.
- With the shipped `driver/Info.plist`, the driver on the RM520N-GL (2c7c:0801, interface 4) behaves as today except: the held-drain restarts Task 1 adds, the new counters and properties, and the new log lines. The existing `RMNetDriver` personality stays byte-for-byte as it is; `RMNetIdleSuspendMs` is not added to it.
- After every task: `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test` all pass (170, 7, 11 files, 150/312/129/87, 16 and 15 at the start), and `make driver` (unsigned Xcode build of the driver and app) succeeds.
- No hardware in Tasks 1 to 3: no install, no modem reboot, no AT command, never the owner's own AT tool, no `sudo`, no script on `en33`. Never write to `build/installed/`. Never touch `<project>/worktrees/`.
- Text messages and phone numbers stored in the modem are private.
- Commit at the end of every task with the message given; no attribution lines.

## Review Focus

- `on_uplink_usable` is never raised from inside `UsbIo::send` or `send_uplink`, never while held, stopping or failed, and a drain it starts can never submit to a halted bulk OUT pipe.
- A completion-queue refusal is counted once per packet refused, not once per retry of the same packet.
- A new personality cannot take an interface that is not the modem's QMI interface (a serial, AT, ADB or DIAG port): each names its product and interface number from a cited source.
- With `RMNetIdleSuspendMs` absent or 0, no idle-policy call is made and nothing about USB changes; with it set but no remote wakeup offered, nothing changes either and the reason is published.
- The port-status sampling for the suspend counter runs only while idle suspend is on, and its failures are counted, not fatal.

---

### Task 1: The uplink-usable callback and the timer-wait counters

Items: "An 'uplink usable' callback" (a failed bulk OUT completion, the end of a bulk OUT recovery and a link down without a pause restart a held drain only on the next 100 ms tick) and, to measure first, "Two paths wait for the 100 ms timer instead of a completion: frames held for lack of `txDone` room, and receive packets the completion queue refused".

**Files:**
- Modify: `driver/usb_io.h`, `driver/usb_io.cpp`, `driver/RMNetDriver.cpp`, `driver/RMNetDriver.iig` if a declaration is needed, `README.md` (the counters' list, if it names them), `docs/driverkit-notes.md` ("Changed in code, not yet on hardware" section for this plan)

**Interfaces (produced):**
- `UsbIoListener::on_uplink_usable()`, pure virtual, comment: "A held uplink may go on: a transfer that failed without starting a recovery freed its buffer, or a bulk OUT recovery ended and the pipe is open again. Raised only while running, not held, not failed, and never from inside send or send_uplink." Raised at the end of `UsbIo::bulk_out_complete` when the transfer failed (`!ok`), nothing fatal happened, the pipe is not recovering after the recovery decision, and `phase_` is Running and not `failed_`; and at the end of `UsbIo::end_out_recovery` under the same conditions.
- `RMNetDriver` (through `UsbBridge`): on `on_uplink_usable`, if `txWaitUplink` or `txHeld`, `DrainTx()`; counts `RMNetUplinkUsable` (callbacks received).
- `RMNetDriver::ApplyCore`: after a link down, if `txWaitUplink` is still set (no pause was lifted), `DrainTx()` (the kept frames then go through `transmit` and are dropped as link down, as the comment in `CoreHost::restart` already describes).
- New published counters (same mechanism and cadence as the existing ones): `RMNetUplinkUsable`; `RMNetTxCompleteRefused` (packets the TX completion queue refused, counted once each, in `FlushTxDone`); `RMNetRxCompleteRefused` (filled receive packets the RX completion queue refused, counted once each, in `FlushRx`); `RMNetTickTxDrains` (timer ticks that called `DrainTx` because `txHeld`, `txWaitUplink` or `txDoneCount > 0`); `RMNetTickRxFlushes` (timer ticks that found `rxOutCount > 0` before their `FlushRx`).

- [ ] **Step 1: Make the change.** Keep every existing comment true (`OnBulkOutDone`'s "the timer tick restarts it instead" becomes the callback). A packet refused once and refused again on a retry counts once: count at the moment a packet first becomes refused (it is the oldest kept ones that are retried; keep a count of how many kept packets have already been counted, or count `n - done` only for packets added since the last flush — say which in a comment).
- [ ] **Step 2: Verify.** No host test can run `UsbIo` or `RMNetDriver`; write in the report, for each place `on_uplink_usable` is raised, the state that makes a drain safe there (pipe not halted, not recovering, not held), and for each counter, the line that counts it. `make driver` builds without warnings; all the test targets pass.
- [ ] **Step 3: Commit.**

```bash
git add driver README.md docs/driverkit-notes.md && git commit -m "feat: a held uplink drain restarts when the uplink is usable again, and counters show the timer waits"
```

---

### Task 2: The other Quectel QMI modems

Item: "Other Quectel QMI modems": Quectel's driver matches many models; ours matches only 2c7c:0801 interface 4.

**Files:**
- Modify: `driver/Info.plist`, `driver/RMNetDriver.cpp` (only if it assumes product 0x0801 or interface 4 anywhere), `core/` (only for a per-model limit established from a cited source), `app/Registry.swift`, `app/StatusModel.swift`, `app/main.swift` (the `status` lines that print `2c7c:0801`), `app/AtPort.swift` (only its not-attached text), `tests/app/StatusModelTests.swift`, `README.md` (a supported-models table)
- Create: `tests/scripts/test-personalities.sh`, `tests/scripts/fixtures/rmnetdriver-personality.txt` (today's `RMNetDriver` personality as `PlistBuddy -c 'Print :IOKitPersonalities:RMNetDriver'` prints it)

**Interfaces (produced):**
- One personality per model, named `RMNetDriver_<4 hex digits of idProduct>` (for example `RMNetDriver_0125`), with the same keys and values as `RMNetDriver` except `idProduct` and `bInterfaceNumber`. The model list comes from the Quectel (vendor 0x2c7c) entries of the Linux kernel's `drivers/net/usb/qmi_wwan.c` device table (fetch it from a public source such as `https://raw.githubusercontent.com/torvalds/linux/master/drivers/net/usb/qmi_wwan.c`; if the network is unavailable, report NEEDS_CONTEXT): every entry that names a fixed QMI interface number for a product other than 0x0801, with the model names from its comment. Entries matched only by class (`QMI_MATCH_FF_FF_FF` without an interface number) are listed in the README as not matched, with the reason.
- `StatusModel.swift`: `struct QuectelModel { let product: Int; let qmiInterface: Int; let names: String; let tested: Bool }` and `let quectelModels: [QuectelModel]` with the same list (0x0801, interface 4, "RM520N-GL", tested: true; the rest tested: false); `func quectelModel(product: Int) -> QuectelModel?`. `Registry.swift` finds the modem by vendor 0x2c7c and any product in the list; `status` prints the found `vid:pid`, the model names and "untested" for an untested one. SMS (`AtPort`) stays on 0x0801 only; its not-attached text names the RM520N-GL.
- Core: change only if a cited source states a per-model limit that Core's Set Data Format request or `data_format_usable` would get wrong; otherwise none, and the report says what was checked.
- `tests/scripts/test-personalities.sh`, run by `make script-test`: `plutil -lint driver/Info.plist`; the `RMNetDriver` personality prints exactly as the fixture; every personality has `idVendor` 11388, a distinct (`idProduct`, `bInterfaceNumber`) pair, `IOUserClass` RMNetDriver, `IOProviderClass` IOUSBHostInterface, `bConfigurationValue` 1, `RMNetProfile` 1, `RMNetFlowControl` 1.

- [ ] **Step 1: Write the failing tests:** the personality test; app checks for `quectelModel(product: 0x0801)` (interface 4, tested) and for one other listed product (its interface, untested), and nil for an unknown product.
- [ ] **Step 2: Run `make script-test` and `make app-test`** and see them fail.
- [ ] **Step 3: Implement**, with each model's source line cited in a comment next to the list in `StatusModel.swift` and in the README table, marked untested.
- [ ] **Step 4: Verify** every target and `make driver`.
- [ ] **Step 5: Commit.**

```bash
git add driver/Info.plist app tests README.md && git add core 2>/dev/null; git commit -m "feat: the driver matches the other Quectel QMI modems (untested), and the app recognises them"
```

---

### Task 3: Opt-in USB idle suspend

Item: "USB power saving when idle" (Quectel's Linux driver guide, chapter 5: USB auto suspend and remote wakeup). Ours keeps 32 bulk reads posted, so the link never idles.

**Files:**
- Modify: `driver/RMNetDriver.cpp`, `driver/usb_io.h`, `driver/usb_io.cpp`, `README.md` (the personality keys), `docs/driverkit-notes.md`

**Interfaces (produced):**
- Personality key `RMNetIdleSuspendMs` (integer, milliseconds; absent or 0 means off, today's behaviour; read like `RMNetProfile` and `RMNetFlowControl`; values above 60000 are taken as 60000).
- When on: the driver reads the configuration descriptor's `bmAttributes` (`kIOUSBConfigurationDescriptorAttributeRemoteWakeCapable`). Without remote wakeup, idle suspend is refused: nothing is called, the log says why. With it, `UsbIo` calls `SetIdlePolicy(value)` on the interface and `SetIdlePolicy(value)` on the bulk IN, bulk OUT and interrupt pipes after they are opened (and again after a resume, if the policies do not survive one: check the header comments and say what you found), each result logged.
- Published: `RMNetIdleSuspendMs` (the value in force, 0 when off or refused), `RMNetRemoteWakeup` (0 or 1, read whether or not suspend is on), `RMNetIdleSuspend` (text: `off`, `on`, `refused: no remote wakeup`, or `failed: <call> 0x<code>`), `RMNetSuspendedTicks` (timer ticks whose `GetPortStatus` on the interface showed `kIOUSBHostPortStatusSuspended`; sampled only while idle suspend is on), `RMNetPortStatusFailures` (failed `GetPortStatus` calls).
- With the key absent or 0: no `SetIdlePolicy` and no `GetPortStatus` call is made.

- [ ] **Step 1: Make the change**, keeping the USB calls in `UsbIo` and the decision (key, descriptor) in the driver; the decision that maps (key, remote-wakeup bit, call results) to the published text is a small pure function in `driver/usb_port.h` or a new DriverKit-free header, with host tests in `tests/driver/` (`make driver-test`): off for 0, clamped above 60000, refused without remote wakeup, the failed call named.
- [ ] **Step 2: Verify** every target and `make driver`.
- [ ] **Step 3: Commit.**

```bash
git add driver tests/driver Makefile README.md docs/driverkit-notes.md && git commit -m "feat: opt-in USB idle suspend when the modem offers remote wakeup, with its state and suspended time published"
```

---

### Task 4: On the modem, before and after (controller)

**Files:** Modify: `docs/driverkit-notes.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`, `README.md`

- [ ] **Step 1 (before, on the build `main` installed, recorded with its version):** under the modem lock, with the cell and signal recorded: `scripts/measure.sh en33 up` with a ping every 0.2 s alongside; `scripts/measure.sh en33 both` once; 60 s idle with the modem's `IOPowerManagement` `CurrentPowerState` sampled each second (`ioreg -p IOUSB`), then the round trip of the first ping after the idle minute against the next nine.
- [ ] **Step 2:** merge the then-current `main` into `driver-features` (retest every target), install with `scripts/install-driver.sh`, reload with `AT+CFUN=1,1`; check status, both families, pings, `sms list`, no crash; the same measurements as Step 1, and the new counters before and after each.
- [ ] **Step 3:** a build with `RMNetIdleSuspendMs` 2000 in the working tree only (never committed): install, reload; `RMNetRemoteWakeup`, `RMNetIdleSuspend`; the idle minute (power state, `RMNetSuspendedTicks`), the first-ping round trip after it, one `scripts/measure.sh en33 up` and one `down`. Then reinstall the committed build and check it.
- [ ] **Step 4:** record every figure, the data used, and a recommendation on idle suspend's default (it stays off in this plan); mark the follow-up items; commit.

```bash
git add -A docs README.md && git commit -m "docs: the driver features on the modem, before and after"
```
