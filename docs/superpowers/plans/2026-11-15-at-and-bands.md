# RMNet at and RMNet bands

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** two app features for people who use this modem daily: `RMNet at` sends one AT command to the modem and prints the answer (macOS gives the modem's AT ports no device, so today a builder has no AT terminal at all), and `RMNet bands` shows which LTE and 5G bands the modem may use and lets the user lock or reset them.

**Owner's words (2026-11-15):** "keep cleaning up and improving to add more features." The features are the coordinator's choice (recorded as a ruling): both run over the app's existing user-space AT port (`app/AtPort.swift`, USB interface 3), touch neither the driver nor the data path, and cost no mobile data. The final review of the open-source cleanup recommended `RMNet at` so that the README's AT commands (`AT+QGPS=1`, `AT+CFUN=1,1`, the USB-mode fallback) are usable.

**What the modem answers (read on the owner's RM520N-GL, 2026-11-15, console, read-only):**
- `AT+QNWPREFCFG="ue_capability_band"` → lines `+QNWPREFCFG: "gw_band",1:2:4:5:8:19`, `+QNWPREFCFG: "lte_band",1:2:3:…:71`, `+QNWPREFCFG: "nsa_nr5g_band",1:2:3:…:79`, `+QNWPREFCFG: "nr5g_band",1:2:3:…:79`, `+QNWPREFCFG: "nrdc_nr5g_band",0`, then `OK`.
- `AT+QNWPREFCFG="lte_band"` → `+QNWPREFCFG: "lte_band",1:2:3:4:5:7:8:12:13:14:17:18:19:20:25:26:28:29:30:32:34:38:39:40:41:42:43:46:48:66:71`; `"nsa_nr5g_band"` and `"nr5g_band"` → `1:2:3:5:7:8:12:13:14:18:20:25:26:28:29:30:38:40:41:48:66:70:71:75:76:77:78:79` (today every supported band is allowed).
- Writing is `AT+QNWPREFCFG="<key>",<b1>:<b2>:…` (Quectel's manual); the modem re-selects a cell after a change, so the connection can drop for a few seconds.

**Architecture:** each feature is a pair of methods on `ModemServing`/`ModemService` (in the style of `usbMode`/`setUsbMode`), a verb in `app/ModemCli.swift`, tests against the scripted port and the fake service, and its lines in `README.md`'s verb table and `docs/reference.md`.

**Tech Stack:** Swift (`swiftc` through `make app-test`).

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` and the owner's words above. The design's first-version non-goal "Band, mode, SIM or signal tools" was lifted by the modem-controls stage (`mode`, `network`, `sim`, `apn` exist); band locking extends that.

## Global Constraints

- Branch `at-and-bands`, cut from `main` after the open-source cleanup lands. Task 1 in worktree `<project>/worktrees/fx-at` (branch `fx-at`); Task 2 after Task 1 merges, in `<project>/worktrees/fx-bands` (branch `fx-bands`): both edit `app/ModemSettings.swift`, `app/ModemService.swift`, `app/ModemCli.swift`, so they run one after the other.
- No hardware in either task: no AT command sent to the real modem, never the installed app against it, no install, no `sudo`; never touch `build/installed/` or `/Applications`.
- Text messages and phone numbers in the modem are private: `RMNet at` prints what the user asked for to their terminal and never logs it; tests use synthetic numbers only.
- After every task: `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test` pass and `make driver` (unsigned) succeeds.
- Commit at the end of each task with the message given; no attribution lines.

## Review Focus

- `RMNet at` sends exactly the one line the user gave, never a second one, and refuses anything that is not a single printable `AT…` line (a CR, LF or Ctrl-Z inside could send a second command or an SMS body).
- `RMNet at` refuses the commands that need a second stage (`AT+CMGS`, `AT+CMGW`: an SMS body after a `>` prompt) and points to `RMNet sms send`.
- `RMNet bands set` never writes a band the modem does not list as supported, never writes an empty list, and reads the list back before saying it worked.
- `RMNet bands reset` restores exactly the supported list from `ue_capability_band`, for one RAT or all three.
- Answers that do not parse (a missing line, a key the modem did not echo) are failures that say nothing was changed, never a silent success.

---

### Task 1: `RMNet at <command>`

**Files:**
- Modify: `app/ModemSettings.swift` (protocol), `app/ModemService.swift`, `app/ModemCli.swift` (verb, usage), `app/main.swift` (usage comment), the three test fakes that implement `ModemServing`
- Test: `tests/app/ModemServiceTests.swift`, `tests/app/ModemCliTests.swift`
- Docs: `README.md` (verb table row; replace "any AT terminal" wording with `RMNet at` where it now applies), `docs/reference.md` (one bullet)

**Interfaces:**
- Produces on `ModemServing`: `func at(_ line: String, timeout: TimeInterval) -> Result<[String], ModemFailure>`: sends `line` as is through the port; on the modem's final `OK` returns the answer lines (without echo and without `OK`); a modem error line (`ERROR`, `+CME ERROR: …`, `+CMS ERROR: …`) is a failure whose text is that line; a timeout or I/O error is a failure saying so.
- Produces the verb `RMNet at [--timeout <seconds>] <command…>`: the words after the options are joined with single spaces into one line. Refused (exit 2, nothing sent, one line on stderr starting `at: `): an empty command; a command that does not start with `AT` (any case); any character outside printable ASCII (0x20–0x7E), which excludes CR, LF and Ctrl-Z; longer than 512 characters; `AT+CMGS` or `AT+CMGW` at the start (any case): `at: AT+CMGS needs a message body; use RMNet sms send`. `--timeout` is an integer 1 to 300, default 10.
- Output: each answer line on stdout, then `OK`; on a modem error the error line on stdout and exit 1; on a timeout `at: no answer in <n> s` on stderr, exit 1; any other failure its text on stderr, exit 1. Nothing is logged. Not in `changesModem` (Ctrl-C works).

- [ ] **Step 1: Write the failing tests.** Service: `at("ATI", timeout: 10)` with the scripted port answering `Quectel`, `RM520N-GL`, `Revision: X`, `OK` → those three lines, and the port saw exactly `ATI` with timeout 10; an `ERROR` answer → failure with text `ERROR`; `+CME ERROR: 10` → failure with that text; a timeout → failure. CLI: parsing (`at ATI`; `at AT+CSQ`; `at --timeout 60 AT+COPS=?`; `at AT+QCFG="usbnet"` joined from words; rejects `at`, `at --timeout 0 ATI`, `at --timeout 301 ATI`, `at hello`, a command with `\r` or `\u{1A}` inside, 513 characters, `at at+cmgs="123"`); the printed lines and exit codes above against the fake service; the fake records that nothing was sent for every refusal.
- [ ] **Step 2: Run** `make app-test`. Expected: FAIL.
- [ ] **Step 3: Implement**, following `usbmode`'s structure.
- [ ] **Step 4: Docs:** README verb table row `RMNet at [--timeout <s>] <command>` — send one AT command and print the answer; the README's "AT terminal" wording points to it (for `AT+QGPS=1`, `AT+CFUN=1,1`, and the USB-mode fallback, noting that `RMNet at` too needs the modem on product ID 0x0801); `docs/reference.md`: one bullet.
- [ ] **Step 5: Run all five targets and `make driver`; commit:** `app: RMNet at sends one AT command to the modem and prints the answer`

### Task 2: `RMNet bands`

**Files:**
- Modify: `app/ModemSettings.swift` (types, protocol), `app/ModemService.swift`, `app/ModemCli.swift`, `app/main.swift` (usage comment), the test fakes
- Test: `tests/app/ModemServiceTests.swift`, `tests/app/ModemCliTests.swift`
- Docs: `README.md` (verb table row), `docs/reference.md` (a short paragraph)

**Interfaces:**
- Produces: `enum BandRat: String, CaseIterable { case lte, nsa, sa }` with modem keys `lte_band`, `nsa_nr5g_band`, `nr5g_band` and display names `LTE`, `5G NSA`, `5G SA`; `struct BandSet { let rat: BandRat; let allowed: [Int]; let supported: [Int] }` (sorted, unique).
- Produces on `ModemServing`: `func bands() -> Result<[BandSet], ModemFailure>` (one `AT+QNWPREFCFG="ue_capability_band"` read plus one `AT+QNWPREFCFG="<key>"` read per RAT; the three in `BandRat.allCases` order); `func setBands(_ rat: BandRat, to bands: [Int]) -> Result<BandChange, ModemFailure>` where `BandChange` holds `before` and `after` lists: reads the supported and allowed lists first; refuses (failure, nothing written) an empty list or any band not supported (the failure names them); if the allowed list already equals the request, returns without writing; otherwise writes `AT+QNWPREFCFG="<key>",<b1>:<b2>:…` (sorted, unique), reads back, and fails if the read-back differs as a set (saying what the modem now reports and what it was). `reset` is `setBands(rat, to: supported)`.
- Parsing: a line `+QNWPREFCFG: "<key>",<list>` where `<list>` is numbers joined by `:`; `0` alone (as for `nrdc_nr5g_band`) means none. A missing key or an unparsable list is a failure saying the modem did not report it.
- Produces the verbs:
  - `RMNet bands [--json]` prints one line per RAT: `LTE: all 31 supported bands allowed` or `LTE: 2 of 31 supported bands allowed: 3, 41`, then, indented, `supported: 1, 2, 3, …`. `--json`: `[{"rat":"lte","allowed":[…],"supported":[…]}, …]`.
  - `RMNet bands set lte|nsa|sa <bands>`: `<bands>` is one argument of numbers separated by `,` or `:`, each optionally prefixed `b`/`B` (LTE) or `n`/`N` (5G), for example `3,41` or `n41:n78`. Before writing it prints `<RAT> bands: <list> (was <before or "all supported">); the modem may re-select a cell and drop the connection for a few seconds`. After: `<RAT> bands set to <list>`; unchanged: `<RAT> bands: already <list>; nothing changed`. No prompt (as `mode`).
  - `RMNet bands reset [lte|nsa|sa]`: without a RAT, all three, one after another, each reported; stops at the first failure.
  - Exit codes as the other modem verbs: 0, 1 after a failure, 2 on wrong usage. These verbs change the modem: add `set` and `reset` to `changesModem`.

- [ ] **Step 1: Write the failing tests.** Service, with the answers above as fixtures: `bands()` parses all three RATs and the capability lines (including `nrdc_nr5g_band",0` ignored); `setBands(.sa, [41])` sends exactly the capability read, the `nr5g_band` read, `AT+QNWPREFCFG="nr5g_band",41`, the read-back, in that order; a request equal to the allowed list sends no write; band 99 (unsupported) or `[]` → failure, no write; a read-back that differs → failure naming both lists; a missing key → failure. CLI: parsing (`bands`, `bands --json`, `bands set sa n41`, `bands set lte 3,41`, `bands set nsa 41:78`, `bands reset`, `bands reset lte`; rejects `bands set`, `bands set sa`, `bands set xx 41`, `bands set sa n41,abc`, `bands reset foo`, extra words); printed lines; `--json`; reset of all three stops at the first failure.
- [ ] **Step 2: Run** `make app-test`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Docs:** README verb table row; `docs/reference.md`: what locking does, that `reset` undoes it, that locking to bands with no cell nearby leaves that RAT with no service until reset (the AT port still works, so `RMNet bands reset` always can).
- [ ] **Step 5: Run all five targets and `make driver`; commit:** `app: RMNet bands shows the LTE and 5G bands the modem may use, and locks or resets them`

---

## After the tasks (coordinator, on the modem)

Install, `AT+CFUN=1,1`, then: `RMNet at ATI` (model and revision), `RMNet at AT+CSQ`, `RMNet at 'AT+CMGS="1"'` refused; `RMNet bands`; lock 5G SA to the band `RMNet network` shows in use, check `RMNet network` and pings, `RMNet bands reset sa`, check again; `configd` steady. Pings only. Record in `docs/status.md` and the notes; land on `main`.
