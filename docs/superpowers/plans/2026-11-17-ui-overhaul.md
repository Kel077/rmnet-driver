# UI Overhaul: a Modern Mac App

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** RMNet looks and feels like a modern macOS 27 app — a sidebar window with an at-a-glance Overview, cards, signal bars and badges, toolbar actions, settings-style forms, and a matching menu bar panel — instead of "a boring driver UI" of text lines and tables.

**Owner's words (2026-11-17):** "next step is to overhaul the whole ui and design good modern ui/ux for it"; "go, it needs to look like a modern app instead of a boring driver ui"; "also, there are a lot of data can be visualized rather than sitting there as a number". The owner skipped design questions, so every design choice below is the coordinator's call, to be judged by the owner on screen at the end.

**What stays:** every controller and model (`StatusController` and `StatusModel`, `SmsController`, `ModemController`, `MenuBarStatus`, `QuitGate`, `WindowVisibility`) and their tests, the CLI, the driver. The overhaul replaces views. Controller changes are allowed only in Task 0, which makes the few the new screens need.

**Tech Stack:** SwiftUI on macOS 27 (`NavigationSplitView`, `Form` with `.grouped` style, `Gauge`, SF Symbols with symbol effects, materials), Swift 5 mode, `swiftc` tests via `make app-test`.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (goal 6: the app shows its status) and the owner's words above.

## Design (coordinator's calls)

**Window:** `NavigationSplitView`, default size 920×640, minimum 760×520. Sidebar (SF Symbols): **Overview** (`antenna.radiowaves.left.and.right`), **Messages** (`message`, with the unread count as a badge), **Network** (`cellularbars`), **SIM & Data** (`simcard`), **Driver** (`puzzlepiece.extension`). The sidebar's bottom shows a compact connection pill (state dot, technology, signal bars). The selection is kept across launches (`@SceneStorage`). Each screen has a toolbar with its actions (Refresh everywhere it reads; New Message on Messages). The quit notices keep their place above the content. Result lines become an inline banner at the bottom of the screen (green check or red exclamation icon, the controller's text unchanged, dismiss button).

**Visual language (`app/DesignKit.swift`):**
- `Card { … }`: rounded rectangle (corner radius 12), `.background(.background.secondary)` (or the macOS 27 equivalent), 16 pt padding, optional title row with an SF Symbol and a trailing accessory.
- `StatusPill(state:)`: dot + text; states connected (green), connecting (yellow, pulsing symbol effect), down / not installed (gray), attention (orange: waiting for approval, not in QMI mode, SIM locked), error (red).
- `TechBadge(text:)`: capsule with the technology ("5G SA", "5G NSA", "LTE", "3G"), tinted (5G: blue, LTE: teal, 3G: gray).
- `SignalBars(level: 0...4)`: four ascending bars, filled per level, tinted by level (4–3 green, 2 yellow, 1 orange, 0 gray), with an accessibility value ("3 of 4 bars, good").
- `MetricGauge(title:value:unit:range:)`: a linear `Gauge` for RSRP / RSRQ / SINR with the number and a quality word.
- `KeyValueRow(label:value:copyable:)`: secondary label, primary value, monospaced digits; a copy button on hover when `copyable`.
- `Banner(text:isFailure:onDismiss:)`, `EmptyState(symbol:title:message:action:)`.
- Spacing scale 4/8/12/16/24; typography: `.largeTitle` for the Overview state, `.title3` for card titles, `.callout` secondary text.

**Visualizations (Swift Charts, Apple's `Charts` framework; no third-party code):** data that changes over time or has a range is drawn, not printed; a number stays only where the number itself is the point (an address, a band, a PCI).
- **Throughput:** `ThroughputSampler` (pure model, tested) reads the driver's byte counters (`RMNetRxBytes`, `RMNetTxBytes`) from the registry once a second while the Overview or the Network screen is shown and the window can be seen — registry only, never the AT port — and keeps the last 120 samples as download/upload rates (bits per second; a counter that goes down, e.g. after a driver restart, starts a new series instead of a negative rate). Drawn as a two-series area chart (download blue, upload teal) with the current rates as large numbers above it, and a session total.
- **Signal history:** `ModemController` keeps a ring buffer of the last 120 network reads' serving-cell metrics per leg (time, RSRP, RSRQ, SINR, technology, band) — about 10 minutes at the 5 s cadence. Drawn as line charts (RSRP and SINR) with the quality zones from `SignalQuality` shaded behind the line (excellent/good/fair/poor), a rule mark at a technology or band change, and a sparkline version for the Overview.
- **Ranges:** `MetricGauge` (RSRP −140…−44 dBm, RSRQ −20…−3 dB, SINR −10…30 dB) with zone colours; the SMS store as a capacity gauge; the SIM PIN/PUK attempts as small dot rows; carriers (carrier aggregation) as a horizontal row of band chips sized by bandwidth when known.
- Every chart has an accessibility summary (latest value and trend), works in light and dark, and shows an `EmptyState`-style line ("Collecting…" for the first samples, "No signal data" when unknown) rather than an empty axis.

**Signal quality (`app/SignalQuality.swift`, pure, tested):** `signalLevel(rat:rsrp:sinr:) -> Int` (0–4) and `signalWord(_ level: Int) -> String` (`No signal`, `Poor`, `Fair`, `Good`, `Excellent`). LTE/NR: RSRP ≥ −80 → 4, ≥ −90 → 3, ≥ −100 → 2, ≥ −110 → 1, else 0; then SINR caps it: < 0 dB → at most 1, < 5 → at most 2, < 13 → at most 3; nil SINR caps nothing. WCDMA (RSCP in `rsrp`): ≥ −75 → 4, ≥ −85 → 3, ≥ −95 → 2, ≥ −105 → 1. Nil RSRP → 0. The serving leg used: NR for 5G SA; for NSA the NR leg if it has RSRP, else LTE.

**Screens:**
- **Overview** (new): a hero card — `StatusPill` with the state in `.largeTitle` weight (Connected / Connecting… / Not connected / Waiting for approval / Not installed), `TechBadge`, `SignalBars` + quality word, operator (network name, else operator), band(s) (primary and carrier-aggregation list, e.g. `n41` or `B3 + B41`); addresses (IPv4, IPv6, copyable); a **live throughput chart** (last 2 minutes) with the current download/upload rates; a **signal sparkline** (RSRP over the last 10 minutes, zone-shaded); data since the driver started (`RMNetRxBytes`, `RMNetTxBytes`, `ByteCountFormatter`). Below, three small cards: **SIM** (ready / PIN required with a "Unlock…" button that goes to SIM & Data), **Messages** (unread count and "Open" → Messages), **Driver** (version and state; when something needs attention — not installed, waiting for approval, not in QMI mode, an update bundled — an orange call-to-action: Install / Open System Settings / the `RMNet usbmode set qmi` advice / Update). When the driver is not installed, the Overview is an `EmptyState` with Install as the action.
- **Messages**: a two-column layout inside the screen — list (sender, one-line preview, relative time, unread dot) and detail (sender, time, full text, Delete in the toolbar); New Message opens a sheet (To, text with the existing part counter, Send); the store use as a small meter in the list's footer (`12 of 255`). Listing failures and "not attached" show as `EmptyState`.
- **Network**: cards — **Connection** (technology badge, registration, operator, PLMN, mode), **Signal** (one `MetricGauge` per metric per leg: RSRP, RSRQ, SINR; for NSA both legs labelled LTE and NR; below them the **signal history** charts — RSRP and SINR over the last 10 minutes, zone-shaded, with band/technology changes marked), **Throughput** (the same live chart as the Overview, larger), **Cell** (band, bandwidth, channel, PCI, cell ID, TAC, carriers), **Radio & Mode** (a toggle for the radio with the existing confirmation, the mode picker and Change…), **Bands** (per RAT a row of band chips — allowed ones filled, the rest outlined, collapsed to "All 31 allowed" when all are — with Change… (the existing sheet, restyled) and Reset).
- **SIM & Data**: a grouped `Form` — **SIM** section (state, PIN lock, attempts; Unlock… when PIN is required, with the existing secure entry), **Data profile** section (APN, IP type, authentication, user, password; Apply / Revert; the put-back command shown after a change), **All profiles** in a disclosure group (the existing table).
- **Driver**: a grouped `Form` — **Status** (installed version, the app's bundled version, enabled, the modem's attachment and USB mode state from the status model), actions (Install / Update / Remove…) with the existing confirmations; approval guidance with a button opening System Settings' extensions pane (`x-apple.systempreferences:com.apple.LoginItems-Settings.extension`); **Details** disclosure with the extension entries table and the driver's `RMNet*` properties (counters) in a two-column list.
- **Menu bar panel**: a compact hero — `StatusPill`, `TechBadge`, `SignalBars` with the quality word, operator, band; the IPv4 address (copyable); the quit notices; buttons Open RMNet and Quit RMNet. Same width (280–300 pt).

**Copy:** sentence case; the controllers' result and failure texts are shown unchanged; new labels are plain English (no `RMNetState`-style names outside Driver → Details).

## Global Constraints

- Branch `ui-overhaul` from `main` at `dc6be59` plus this plan. Task 0 first, in `<project>/worktrees/ui-shell` (branch `ui-shell`); then Tasks 1–6 in parallel, each in its own worktree (`ui-overview`, `ui-messages`, `ui-network`, `ui-simdata`, `ui-driver`, `ui-menubar`), each owning only the files its brief names; Task 7 (docs) last.
- No hardware: no AT command to the real modem, never the installed app or a built RMNet against it, never `at.py`, no install, no `sudo`; never touch `build/installed/` or `/Applications`.
- Text messages and phone numbers are private: renders and tests use synthetic numbers and texts only.
- Every task renders its screen offscreen (`NSHostingView` snapshot or `ImageRenderer`, from a throwaway harness that is not committed) in light and dark, with realistic synthetic data, to `<scratchpad>/renders-ui/<task-name>/` (its own folder; never delete another task's folder).
- Controllers' public behaviour and their existing tests are unchanged except where Task 0's brief says.
- After every task: `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test` pass, `make driver` (unsigned) succeeds, and `xcrun swiftc -typecheck -swift-version 5 app/*.swift` is clean.
- Commit with the message given; no attribution lines.

## Review Focus

- Nothing the old window could do is lost: every action (install, update, remove, send, delete, radio, mode, profile apply/revert/put-back, PIN unlock, bands change/reset, refresh) is reachable, with its existing confirmation.
- The modem is read only as before: a screen reads only while it is shown and the window can be seen (the controllers' gating is reused, not bypassed), and the Overview adds at most the network read the Network screen does.
- Status is always truthful: the Overview and the menu bar never show "Connected" unless the driver's state is up; unknown values show as "—", not 0.
- Light and dark both look right; VoiceOver labels exist for the bars, badges and pills.
- No new dependencies; no web views.

---

### Task 0: Shell, shared design pieces, file split, and the controller hooks

**Files:**
- Move (no behaviour change): `StatusView` (the Driver tab) and its private helpers from `app/StatusView.swift` to `app/DriverView.swift`; `NetworkTab`, `BandsSheet` and their private helpers from `app/ModemView.swift` to `app/NetworkView.swift`; `SimApnTab`, `ProfilesTable` and helpers to `app/SimDataView.swift`; helpers both use (`ReadStatus`, `ResultLine`, `RowsGrid`, `PutBackCommand`, `Question`…) to `app/ModemViewParts.swift` (internal). `app/ModemView.swift` is deleted if empty.
- Create: `app/DesignKit.swift`, `app/Charts.swift`, `app/SignalQuality.swift`, `app/ThroughputSampler.swift`, `app/OverviewView.swift` (a placeholder screen for Task 1), `tests/app/SignalQualityTests.swift`, `tests/app/ThroughputSamplerTests.swift` (+ Makefile targets in `app-test`)
- Modify: `app/StatusView.swift` (`RMNetApp`, `RMNetWindow` → the `NavigationSplitView` shell; `AppDelegate` gains the shared driver-status controller), `app/ModemController.swift` (a `ModemTab.overview` that reads the network like `.network` and nothing else), `tests/app/ModemControllerTests.swift` (tests for `.overview`), `Makefile`

**Interfaces (produced for Tasks 1–6):**
- `enum Screen: String, CaseIterable { case overview, messages, network, simData, driver }` with `title` and `symbol`.
- `AppDelegate.driverStatus: StatusController` (moved out of the Driver view's `@StateObject`): one shared instance, polled every 2 s only while the Overview or Driver screen is shown and the window can be seen (the poll moves from the view's timer into a start/stop the shell drives).
- `ModemController.setTabShown(.overview)`: network read only, same cadence and gating as `.network`; bands not read.
- `ModemController.signalHistory: [SignalSample]` (`struct SignalSample { let at: Date; let leg: String /* "NR", "LTE", "WCDMA" */; let rsrp: Int?; let rsrq: Int?; let sinr: Double?; let technology: String?; let band: String? }`), appended on every successful network read (one sample per serving leg), capped at 120 reads, published.
- `ThroughputSampler` (`app/ThroughputSampler.swift`): `init(read: () -> (rx: UInt64, tx: UInt64)?, now: () -> Date)`, `sample()`, published `points: [ThroughputPoint]` (`at`, `downBitsPerSecond`, `upBitsPerSecond`), `current`, `sessionRx`, `sessionTx`; `AppDelegate.throughput` drives it with a 1 s timer only while the Overview or Network screen is shown and the window can be seen. A counter reset starts a new series (no negative rate); a missing counter yields no point.
- `app/Charts.swift` (DesignKit's chart pieces): `ThroughputChart(points:)`, `SignalHistoryChart(samples:metric:)`, `Sparkline(values:zones:)`, `CapacityGauge`.
- `DesignKit` components and `signalLevel` / `signalWord` exactly as in Design above.
- The shell passes to each screen: Overview gets `driverStatus`, `modem`, `messages` and a `navigate: (Screen) -> Void`; the others get their controller(s) as today.

- [ ] **Step 1: Failing tests:** `SignalQualityTests` (each threshold edge for LTE/NR and WCDMA, every SINR cap, nil RSRP → 0, nil SINR, the NSA leg choice, the five words); `ModemControllerTests` for `.overview` (network read only; same gating) and `signalHistory` (one sample per leg per successful read, none on failure, capped at 120 reads); `ThroughputSamplerTests` (rates from two samples, a counter reset starts a new series, a missing counter adds nothing, 120-point cap, session totals). Makefile targets for the new test programs.
- [ ] **Step 2: Run** `make app-test` → FAIL.
- [ ] **Step 3: Move** the files (pure move; build and test after the move alone; commit `app: split the window's views into one file per screen` before the rest).
- [ ] **Step 4: Implement** `SignalQuality`, `DesignKit`, the shell (sidebar with the connection pill, `@SceneStorage` selection, toolbar placement, the banner slot, the quit notices), the shared `driverStatus`, `.overview`, and an Overview placeholder that shows the hero card with real data (state pill, badge, bars, operator, addresses) so the shell can be judged.
- [ ] **Step 5: Render** to `<scratchpad>/renders-ui/shell/`: the shell on each screen (existing screens inside the new shell), the placeholder Overview, and a DesignKit gallery (pills in each state, badges, bars 0–4, a gauge, a card, a banner, a throughput chart, a signal history chart, a sparkline, a capacity gauge, with synthetic series), light and dark.
- [ ] **Step 6: All gates; commit:** `app: a sidebar window with an Overview, shared design pieces and signal bars`

### Tasks 1–6: one screen each (parallel, after Task 0 lands on `ui-overhaul`)

Each task: rewrite only its file(s) to the Design above, keep every action and confirmation, use DesignKit, render light/dark with synthetic data to `<scratchpad>/renders-ui/<task>/`, pass all gates, commit. No controller changes (if one seems needed, stop and report NEEDS_CONTEXT). No docs.

- **Task 1 — Overview** (`app/OverviewView.swift`): the full Overview per Design (hero, addresses, data counters, SIM/Messages/Driver cards with attention states, the not-installed empty state). Renders: connected 5G SA with a live throughput chart and signal sparkline (synthetic series); connecting; not installed; waiting for approval; SIM PIN required. Commit `app: the Overview shows the connection at a glance`.
- **Task 2 — Messages** (`app/SmsView.swift`, and `app/PlainTextEditor.swift` only if needed): list/detail, compose sheet, store meter, empty states. Renders: a list with 4 synthetic messages (one unread) and one selected; the compose sheet; the empty and not-attached states. Commit `app: Messages as a list and a reading pane, with a compose sheet`.
- **Task 3 — Network** (`app/NetworkView.swift`): the five cards, gauges per leg, band chips, restyled bands sheet. Renders: 5G SA with 10 minutes of synthetic signal history (one band change) and a throughput chart; 5G NSA (two legs); LTE; bands with one RAT locked; the bands sheet. Commit `app: Network as cards with signal gauges and band chips`.
- **Task 4 — SIM & Data** (`app/SimDataView.swift`): grouped form, unlock flow, profile editor, profiles disclosure. Renders: SIM ready with the profile; PIN required; an edited profile with Apply enabled; after a change with the put-back command. Commit `app: SIM & Data as a settings-style form`.
- **Task 5 — Driver** (`app/DriverView.swift`): grouped form, actions, approval guidance with the System Settings button, Details disclosure. Renders: installed and current; update bundled; waiting for approval; not installed; Details expanded. Commit `app: the Driver screen as a settings-style form with details on request`.
- **Task 6 — Menu bar** (`app/MenuBarView.swift`): the compact hero panel; the label unchanged. Renders: connected; down; waiting for approval; with a quit notice. Commit `app: the menu bar panel shows the connection like the Overview`.

### Task 7: Docs (after Tasks 1–6 land)

**Files:** `README.md` (the window section: the sidebar screens and the menu bar), `docs/reference.md` (the window bullets). Plain description of each screen and where each action lives; no claims beyond the code. Commit `docs: the new window: sidebar screens, Overview, and where each action lives`.

---

## After the tasks (coordinator)

Look at every render; send obvious visual problems back to the task. Final whole-branch review. Install; the owner looks at the real window and menu bar and gives feedback; a second pass for their feedback is a new request. Record in `docs/status.md`; land on `main`.
