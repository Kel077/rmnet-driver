# Bands in the Window, and a Menu Bar Status Item

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the window's Network tab shows and changes the modem's allowed bands (what `RMNet bands` does on the command line), and RMNet gets a menu bar item that shows at a glance whether the modem's connection is up, with details one click away.

**Owner's words (2026-11-16):** picked "Window: bands + status" from the coordinator's proposal. The coordinator's reading, recorded as rulings: "status" is a menu bar status item; the app keeps running in the menu bar after its window is closed (otherwise the item would only exist while the window is open); the item asks the modem's AT port only when its panel is opened, never on a timer, so it never competes with `RMNet` commands for the port.

**Architecture:**
- Bands: `ModemController` gains bands state and two actions over the existing `ModemServing.bands()` / `setBands(_:to:)` (app/ModemService.swift); `NetworkTab` (app/ModemView.swift) gets a Bands section and a sheet to choose bands.
- Menu bar: a `MenuBarExtra` scene (window style) in `RMNetApp` (app/StatusView.swift); a small model polls the driver's registry properties every 5 s (no AT port) for the icon, and reads the network over the AT port once each time the panel opens.

**Tech Stack:** Swift, SwiftUI (`MenuBarExtra`, macOS 13+; the project targets macOS 27), `swiftc` tests through `make app-test`.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (goal 6: "A small app installs and removes the driver and shows its status") and the owner's choice above.

## Global Constraints

- Branch `window-bands-menu`, cut from `main` at `3dafdb7` plus this plan. Task 1 in `<project>/worktrees/wb-bands` (branch `wb-bands`), Task 2 in `<project>/worktrees/wb-menu` (branch `wb-menu`), in parallel. Task 1 owns `app/ModemController.swift`, `app/ModemView.swift`, `tests/app/ModemControllerTests.swift`, and in the docs the Network-tab lines. Task 2 owns `app/StatusView.swift`, new files `app/MenuBarStatus.swift` (model) and `app/MenuBarView.swift` (view), a new test file and its Makefile target, and in the docs a new menu bar paragraph. Neither edits the other's files; `app/ModemService.swift` and `app/ModemSettings.swift` are read, not changed, unless a task's brief says so.
- No hardware: no AT command to the real modem, never the installed app or a built RMNet against it, never `at.py`, no install, no `sudo`; never touch `build/installed/` or `/Applications`.
- Text messages and phone numbers are private.
- Each task renders its new view offscreen to a PNG (SwiftUI `ImageRenderer`, from a throwaway harness that is not committed) at the path given in its brief, light and dark, so the coordinator can look at it; the session cannot screenshot the real screen.
- After every task: `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test` pass and `make driver` (unsigned) succeeds.
- Commit with the message given; no attribution lines.

## Review Focus

- Changing bands from the window can never send an empty or unsupported list, says before applying that the modem may drop the connection for a few seconds, and leaves the Bands section showing what the modem reports afterwards (read back), including after a failure.
- A bands change counts as a change for the existing quit gate and for the controls that are disabled while something runs (one call to the modem at a time).
- The menu bar item never opens the AT port except when its panel is opened, and then at most once per opening (and not more often than every 10 s); a busy port is shown as such, not as an error that hides the connection state.
- Closing the window leaves RMNet running in the menu bar; "Quit RMNet" quits through the existing quit gate (a running SMS send or modem change still delays the quit as today).
- The icon's state comes from the driver's registry properties only, and is right when the driver is absent, waiting for approval, attached but down, and up. **Note (2026-11-16, final review):** "only" is not what was built, nor can it be: the registry cannot tell waiting for approval from no driver. The icon comes from the registry plus the system's extension listing, which is asked for those two states (no driver in the registry: waiting for approval or no driver) and while the panel is open; with the driver attached the registry alone decides.

---

### Task 1: Bands on the Network tab

**Files:**
- Modify: `app/ModemController.swift`, `app/ModemView.swift`
- Test: `tests/app/ModemControllerTests.swift` (the fake `ModemServing` there already has `bands`/`setBands` stubs)
- Docs: `README.md` (the Network tab line in the window section), `docs/reference.md` (the window's Network tab bullet)

**Interfaces:**
- Consumes: `ModemServing.bands() -> Result<[BandSet], ModemFailure>`, `setBands(_ rat: BandRat, to: [Int]) -> Result<BandChange, ModemFailure>`, `BandRat` (`lte`, `nsa`, `sa`, `displayName`), `BandSet` (`rat`, `allowed`, `supported`), `bandsProblem` (app/ModemSettings.swift).
- Produces on `ModemController`: `@Published private(set) var bands: [BandSet]?` and `bandsFailure: String?` (read with the Network tab's network read, same cadence and gating: only while the Network tab is shown and the window visible); `func changeBands(_ rat: BandRat, to: [Int])`; `func resetBands(_ rat: BandRat)`; `func resetAllBands()`; a new `ModemActivity.bands`, with `running`, `result`, `resultIsFailure` and the quit notice working as for `mode`. After any change (success or failure) the bands are read again.

What the Network tab shows (a "Bands" group below the existing network information):
- One row per RAT: `LTE`, `5G NSA`, `5G SA`; the summary as the CLI prints it (`all 31 supported bands allowed`, or `2 of 31 supported bands allowed: 3, 41`); a `Change…` button; a `Reset` button, enabled only when not all supported bands are allowed. A `Reset all` button under the rows, enabled when any RAT is locked. All disabled while anything runs.
- `Change…` opens a sheet titled `<RAT> bands`: a grid of checkboxes, one per supported band (labelled `B3` for LTE, `n41` for 5G), checked for allowed ones; `Select all` and `Clear` buttons; the line `The modem may re-select a cell and drop the connection for a few seconds.`; `Apply` (default button) disabled when nothing is checked or the selection equals the allowed list; `Cancel`. While the sheet is open, the tab's periodic reads pause as they do for the existing confirmation dialogs (`setConfirming`).
- While bands are unknown: `Bands: not read yet` or the failure line.

- [ ] **Step 1: Failing controller tests** with the fake service: bands read alongside the network read (and only then); `changeBands(.sa, [41])` calls `setBands(.sa, [41])` once, sets `running == .bands`, then reads bands again, result line `5G SA bands set to 41`; a failure gives `resultIsFailure` and still re-reads; `resetBands(.lte)` calls `setBands(.lte, supported)`; `resetAllBands()` runs lte, nsa, sa in order and stops at the first failure; nothing else can start while `.bands` runs; a quit while `.bands` runs waits (as for `mode`).
- [ ] **Step 2: Run** `make app-test` → FAIL.
- [ ] **Step 3: Implement** the controller and the view.
- [ ] **Step 4: Render** `NetworkTab` with a fake controller showing all-allowed bands and a locked 5G SA (allowed `[41]`), and the open sheet for 5G SA, light and dark, to `<scratchpad>/renders/network-bands-{light,dark}.png` and `<scratchpad>/renders/bands-sheet-{light,dark}.png` (the coordinator gives the scratchpad path).
- [ ] **Step 5: Docs:** the Network tab line and bullet.
- [ ] **Step 6: All five targets and `make driver`; commit:** `app: the Network tab shows the allowed bands and changes or resets them`

### Task 2: The menu bar item

**Files:**
- Create: `app/MenuBarStatus.swift` (model, no SwiftUI), `app/MenuBarView.swift` (the label and panel), `tests/app/MenuBarStatusTests.swift`
- Modify: `app/StatusView.swift` (add the `MenuBarExtra` scene; `applicationShouldTerminateAfterLastWindowClosed` returns false), `Makefile` (a `menubar-tests` program in `app-test`)
- Docs: `README.md` (a short "Menu bar" paragraph in the window section), `docs/reference.md` (one bullet)

**Interfaces:**
- Consumes: the registry readers the Driver tab already uses (app/Registry.swift, app/StatusModel.swift: the driver's properties such as `RMNetState`, `RMNetIPv4`, `RMNetIPv6`, and the extension listing for "waiting for approval"); `ModemServing.networkInfo()` and `NetworkInfo` (technology, band, operator, signal) for the panel.
- Produces: `final class MenuBarStatus: ObservableObject` with injected sources (`properties: () -> DriverProperties?`, `listing: () -> …`, `network: () -> Result<NetworkInfo, ModemFailure>`, a clock and a queue), publishing `icon: MenuBarIcon` (`.up`, `.down`, `.noDriver`, `.waitingForApproval`), `headline: String`, `addressLines: [String]`, `networkLines: [String]`, `networkAt: Date?`, `networkNote: String?` (busy / failed / not attached). Methods: `poll()` (every 5 s from a timer; registry only), `panelOpened()` (one network read unless one finished less than 10 s ago).

What it shows:
- The label: SF Symbols `antenna.radiowaves.left.and.right` for up, `antenna.radiowaves.left.and.right.slash` for every other state, with accessibility labels `RMNet: connected` / `RMNet: not connected` / `RMNet: no driver` / `RMNet: waiting for approval`.
- The panel (window style, about 280 pt wide): the headline (the Driver tab's headline wording), the IPv4 and IPv6 addresses when up, then the network lines from the AT read (`5G SA, band n41`, `CHINA MOBILE`-style operator line as `RMNet network` prints it, `RSRP -86 dBm, SINR 10 dB`), with `as of <time>`; while reading: `Reading the modem…`; when the port is busy: `The modem's AT port is busy; open the panel again in a moment.`; then `Open RMNet` (opens or brings forward the window: `openWindow(id: "status")` and activate) and `Quit RMNet` (`NSApp.terminate`, which goes through the existing quit gate).

- [ ] **Step 1: Failing model tests:** icon for each state (no properties → `.noDriver`; listing says waiting → `.waitingForApproval`; `RMNetState` up → `.up`; anything else → `.down`); `poll()` never calls `network`; `panelOpened()` calls `network` once, and not again within 10 s, and again after 10 s; busy, failure and not-attached notes; address lines only when up.
- [ ] **Step 2: Run** `make app-test` → FAIL.
- [ ] **Step 3: Implement** the model, the view, the scene and the lifecycle change. Closing the window must leave the app running with the item; reopening from `Open RMNet` must restore the window with its tabs working.
- [ ] **Step 4: Render** the panel for up (with network lines) and down, light and dark, to `<scratchpad>/renders/menubar-{up,down}-{light,dark}.png`.
- [ ] **Step 5: Docs.**
- [ ] **Step 6: All five targets and `make driver`; commit:** `app: a menu bar item shows whether the connection is up, with details and the window one click away; RMNet stays in the menu bar when its window closes`

---

## After the tasks (coordinator)

Look at the renders. Install; start the app (`open /Applications/RMNet.app`); check from the shell that it keeps running and that the process's AT port use is quiet (no `RMNet` CLI call is refused as busy over a minute of `RMNet at AT+CSQ` every 5 s with the app open and its panel closed). **Note (2026-11-16, final review):** the check must name the RMNet window's state: closed, or open on the `Driver` tab. With the `Network` tab shown in a visible window the tab reads the port every 5 s (the `Messages` and `SIM & APN` tabs read it too, less often), and a verb may then be refused as busy by design: the window and the verbs share the port. Bands: through the CLI on hardware already proven; the window path is covered by the controller tests and renders. Ask the owner to look at the menu bar item and the Network tab's Bands section, since this session cannot see the screen. Record in `docs/status.md`; land on `main`.
