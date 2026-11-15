# Polish for Newcomers, and `RMNet gps` Switches GNSS On

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** remove the last places where the app or docs assume the owner's private tools, fix small inaccuracies the reviews left, and make `RMNet gps` work for a newcomer without any AT command: today it only reads, so with GNSS off (the modem's default) it prints "no NMEA sentences … AT+QGPS? on the console shows it".

**Owner's words (2026-11-16):** "keep improving the project". The items are the coordinator's choice from the open review notes (ledgers of the open-source and at-and-bands plans).

**What the modem answers (owner's RM520N-GL, 2026-11-16):** `AT+QGPS?` → `+QGPS: 0` (off) then `OK`. Quectel's manual: `AT+QGPS=1` switches GNSS on (`+CME ERROR: 504` if already on), `AT+QGPSEND` switches it off; the NMEA port (`/dev/cu.RM520N-GL-NMEA`, needs the driver) then carries sentences about once a second. A first fix outdoors can take a minute or more; whether an antenna is attached to the owner's modem is unknown (no fix has been seen).

**Architecture:** Task 1 is text and one shared-parser fix; Task 2 gives `runGps` an injectable GNSS switch backed by the existing AT port. Both are app-only: no driver change, no mobile data.

**Tech Stack:** Swift (`swiftc` through `make app-test`), POSIX `sh` (one comment).

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md`, the open-source plan's Goal (a newcomer builds and uses this with no other tool), and the owner's words above.

## Global Constraints

- Branch `polish-gps`, cut from `main` at `2326b71` plus this plan. Task 1 in worktree `<project>/worktrees/pg-polish` (branch `pg-polish`), Task 2 in `<project>/worktrees/pg-gps` (branch `pg-gps`), in parallel: Task 1 owns `app/ModemCli.swift`, `app/ModemController.swift`, `app/ModemSettings.swift`, `app/StatusModel.swift`, `app/AtPort.swift`, `scripts/soak.sh`, and in the docs only the lines named in its brief; Task 2 owns `app/GpsCommand.swift`, `app/Nmea.swift`, `app/main.swift`, the `Makefile`, and the `gps` row/paragraph of the docs.
- No hardware in either task: no AT command to the real modem, never the installed app against it, never `at.py`, no install, no `sudo`; never touch `build/installed/` or `/Applications`.
- Text messages, phone numbers and positions are private: never logged; tests use synthetic values.
- After every task: `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test` pass and `make driver` (unsigned) succeeds.
- Commit with the message given; no attribution lines.

## Review Focus

- No app output or newcomer doc tells the user to use "the console" or another tool this project does not have; where an AT command is the answer, it is given as an `RMNet at …` line.
- `RMNet gps` leaves GNSS as it found it unless `--keep-on`: switched off again only if this run switched it on, also when reading fails or is interrupted (Ctrl-C).
- If the AT port cannot be used (another program holds it, or the modem is not 2c7c:0801), `gps` still reads the NMEA port and says it could not check or switch GNSS, rather than failing outright.
- The new final result codes end an answer as an error for every verb, without changing how `OK`, `ERROR`, `+CME ERROR` and `+CMS ERROR` are handled.

---

### Task 1: Newcomer-facing text, and V.250's other final results

**Files:**
- Modify: `app/ModemCli.swift` (header comment's exit codes; the `mode` line at about :355; the `usbmode` question goes to `/dev/tty`), `app/ModemController.swift` (about :463), `app/ModemSettings.swift` (about :672), `app/StatusModel.swift` (the advice for models other than the RM520N-GL), `app/AtPort.swift` (final results), `scripts/soak.sh` (header comment)
- Test: `tests/app/ModemCliTests.swift`, `tests/app/ModemControllerTests.swift`, `tests/app/ModemSettingsTests.swift`, `tests/app/StatusModelTests.swift`, `tests/app/AtPortTests.swift`
- Docs: `README.md` (the Ctrl-C sentence only), `docs/reference.md` (line 11's app-test list; line 71's "owner's console"; the throughput-gate sentence near line 20)

**Changes:**
1. The three "set it again on the modem's console" messages (ModemCli `mode`, ModemController, ModemSettings) become `…; to put it back: RMNet at 'AT+QNWPREFCFG="mode_pref",<value>'` with the earlier value filled in when it is printable ASCII without quotes, else `…cannot be set by RMNet; set it again with RMNet at 'AT+QNWPREFCFG="mode_pref",<value>'` (literal `<value>`). Use `modeCommand` for the AT text. Update the pinned texts in tests.
2. `StatusModel` advice for other models (not 2c7c:0801): keep the two AT lines, add `(or unplug and replug the modem instead of AT+CFUN=1,1)`, and say that `RMNet at` and `RMNet usbmode` work only with the RM520N-GL. Tests pin it.
3. `AtPort`'s answer collector also ends an answer on the V.250 final results `NO CARRIER`, `BUSY`, `NO ANSWER`, `NO DIALTONE`, as a modem error whose text is that line (so `RMNet at ATA` with no call prints `NO CARRIER` and exits 1 at once). Tests in `AtPortTests` for each, and that `OK`/`ERROR`/`+CME`/`+CMS` behave as before.
4. The `usbmode` `[y/N]` question is written to `/dev/tty` when it can be opened (as the PIN prompt is), else to stdout as today; the answer is still read from stdin with the `isatty(0)` rule. Test with the injectable output the CLI already uses.
5. Comments: `ModemCli.swift`'s header lists exit codes 0, 1 and 2; `scripts/soak.sh`'s header no longer claims `--classify` reads nothing else (it reads `config.local` through `scripts/config.sh`).
6. Docs: README's Ctrl-C sentence names exactly the verbs that ignore Ctrl-C (`sms send`, and the modem verbs that change something: `radio on|off`, `mode <value>`, `apn set`, `sim unlock`, `usbmode set`, `bands set`, `bands reset`; check `changesModem` and main.swift for the true list); `docs/reference.md` line 11 lists every app-test program and verb including `at` and `bands`; line 71 says "a terminal program of your own" instead of "the owner's console"; the throughput-gate sentence near line 20 gets "(at the time of that measurement; docs/status.md has the later result)".

- [ ] **Step 1:** failing tests for changes 1 to 4.
- [ ] **Step 2:** `make app-test` → FAIL.
- [ ] **Step 3:** implement 1 to 6.
- [ ] **Step 4:** all five targets and `make driver`; commit: `app: no output points to a console the user does not have; NO CARRIER and the other V.250 final results end an AT answer; docs fixes`

### Task 2: `RMNet gps` switches GNSS on and back off

**Files:**
- Modify: `app/GpsCommand.swift`, `app/Nmea.swift` (messages), `app/main.swift` (parse `--keep-on`; usage line and comment), `Makefile` (whatever the gps test program now needs to compile)
- Test: `tests/app/GpsReadTests.swift` (and/or a new `tests/app/GpsCommandTests.swift` added to the Makefile)
- Docs: `README.md` and `docs/reference.md`: the `gps` row/paragraph only

**Interfaces:**
- Produces: `protocol GnssSwitching { func state() -> Result<Bool, String>; func switchOn() -> Result<Void, String>; func switchOff() -> Result<Void, String> }` (Bool: on). The real one sends `AT+QGPS?` (parses `+QGPS: <0|1>`), `AT+QGPS=1`, `AT+QGPSEND` over `AtPort` (open per call is fine; timeouts as the other short reads/writes). `runGps(seconds:keepOn:gnss:)` with the real switch by default.
- Behaviour of `RMNet gps [seconds] [--keep-on]`:
  1. Asks `state()`. If it fails: print `gps: could not check GNSS (<reason>); reading anyway` to stderr and read as today, switching nothing.
  2. If off: `switchOn()`; on success print `gps: GNSS switched on; a first fix outdoors can take a minute or more` to stderr; on failure print `gps: could not switch GNSS on (<reason>); reading anyway`.
  3. Read the NMEA port for `seconds` as today (the default stays as it is).
  4. If this run switched GNSS on and `--keep-on` is absent: `switchOff()` on every way out (fix, no fix, port closed, read failed, and SIGINT/SIGTERM during the read), printing `gps: GNSS switched off again` (or `gps: could not switch GNSS off (<reason>); RMNet at AT+QGPSEND does it`). With `--keep-on`: `gps: GNSS left on (RMNet at AT+QGPSEND switches it off)`.
  5. The "no NMEA sentences" message no longer mentions the console: `gps: no NMEA sentences in <n> s` plus, only when GNSS's state is unknown, `; GNSS may be off (RMNet at AT+QGPS? shows it, RMNet at AT+QGPS=1 switches it on)`.
- Exit codes unchanged (0 fix, 1 otherwise, 2 usage).

- [ ] **Step 1:** failing tests with a fake `GnssSwitching` and the existing pseudo-terminal NMEA reader: off → on → read → off (order of calls); already on → no switch calls; `--keep-on` → no off; state fails → reads anyway, message; switchOn fails → reads anyway, no off; off on a read failure and on a closed port; the new messages. SIGINT handling: if testing a real signal is impractical, structure the code so the off-path is one function called from both the normal end and the signal handler, and test that function.
- [ ] **Step 2:** `make app-test` → FAIL.
- [ ] **Step 3:** implement.
- [ ] **Step 4:** docs: the `gps` row and paragraph (switches GNSS on and off by itself; `--keep-on`; still needs the driver for the NMEA port; first fix can take minutes; an antenna is needed).
- [ ] **Step 5:** all five targets and `make driver`; commit: `app: RMNet gps switches GNSS on when it is off and back off afterwards`

---

## After the tasks (coordinator, on the modem)

Install; `RMNet at AT+QGPS?` (expect 0); `RMNet gps 20` → "GNSS switched on", sentences arrive (likely no fix: antenna unknown), "switched off again"; `RMNet at AT+QGPS?` → 0; `RMNet gps 10 --keep-on` → left on; `RMNet at AT+QGPSEND`; `RMNet at ATA` → `NO CARRIER` exit 1 at once (no call); `RMNet mode` unchanged; pings; configd. No data beyond pings. Record in `docs/status.md` and the notes; land on `main`.
