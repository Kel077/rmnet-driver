# Idle Suspend That Works: Phase 1, Evidence

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** find out, safely, why USB idle suspend took `en33` away and hung macOS's `configd`, so that Phase 2 can make it work: the modem suspends when idle, `en33` stays, the Mac's networking is untouched, and traffic in either direction wakes the link.

**Background (2026-11-15, build 318.1.4, `RMNetIdleSuspendMs` 2000 in all three personalities):** the modem suspended, but `en33` left `ifconfig -l`, `ifconfig en33` stalled for minutes, and `configd` hung in a system call into `IOSkywalkFamily`; the watchdog restarted it about every minute from 09:06 to 12:31 and the whole Mac lost its network (DNS and the VPN `utun5`) until the owner pressed Remove. See `docs/driverkit-notes.md`, "Runtime findings (driver features)".

**What is known from the sources:**
- `IOUSBHostFamily.h`: idle suspend "is disabled if a driver is the power child of the IOUSBHostDevice and resides in a power state with an input power requirement that does not include `kIOPMLowPower`".
- xnu `iokit/Kernel/IOUserServer.cpp` (`sPowerStates`): every dext service gets the same four states, 0 off, 1 low (input `kIOPMLowPower`), 2 AOT, 3 on (input `kIOPMPowerOn`). `ChangePowerState(kIOServicePowerCapabilityLow)` is state 1. So a dext can allow idle suspend only from state 1; there is no "on, but fine with a suspended parent" state. `IOUserServer` does not hold back calls to a dext in state 1.
- `ioreg -p IOPower`: `RMNetDriver` and both `RMNetSerial` instances are direct power children of the modem's `IOUSBHostDevice`.
- What `IOSkywalkFamily` does when an `IOUserNetworkEthernet` service enters state 1 is undocumented. That is the question.

**Hypotheses Phase 1 separates:**
- **H1:** the networking family treats the network dext's state 1 as powered down. It takes the interface away and blocks interface calls whatever USB does. Then a network dext that is a power child of the USB device can never let it suspend, and Phase 2 is an architecture change: the network service must leave the USB device's power subtree.
- **H2:** state 1 itself is fine, but the suspended USB link is not: with the bulk and interrupt reads paused, something the family waits for never happens (for example the up to 32 receive packets `RMNetDriver` holds in `rxStock`, or an outstanding transfer). Then Phase 2 is a fix inside the driver.
- The two trials: **E1a** puts only `RMNetDriver` in state 1 with no idle policy (USB keeps running). **E1b**, only if E1a keeps `en33`, is the full idle suspend. Both are time-boxed by the driver and by an outside script.

**Architecture:** a new script, `scripts/power-trial.sh`, runs one trial without this session: it installs a kept test build, re-enumerates the modem, samples the Mac's network and the driver once a second, and always reinstalls a kept good build, even when the session that started it is gone. `scripts/install-driver.sh` gains `--build-only`, which builds and keeps a signed app without installing it. The driver gains two personality keys for experiments only, `RMNetLowPowerTrialSec` (a time box after which the driver returns itself to full power and stops asking) and `RMNetLowPowerOnly` (state 1 with no idle policy), plus a trace of every power and interface call while it asks for low power. The shipped `driver/Info.plist` sets neither key.

**Tech Stack:** C++17, DriverKit (`IOService::ChangePowerState`, `IOUSBHostInterface::SetIdlePolicy`, `IOUSBHostPipe::SetIdlePolicy`), POSIX `sh`, `perl` (for timeouts only).

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md`; the owner's words (2026-11-15): "you should fix it properly if it's device built in feature" (the modem offers remote wakeup, `RMNetRemoteWakeup` 1, and Quectel's Linux driver guide, chapter 5, turns on USB auto suspend).

## Global Constraints

- Branch `idle-suspend`, cut from `main` at `8824d57`. Task 1 is done in the worktree `~/personal/RM520N-GL/worktrees/idle-suspend-trial` on branch `idle-suspend-trial`, Task 2 in `~/personal/RM520N-GL/worktrees/idle-suspend-driver` on branch `idle-suspend-driver`; the coordinator merges both into `idle-suspend`.
- With the shipped `driver/Info.plist` the driver behaves exactly as at `8824d57`: neither new key is in any personality, no new call is made, the trace stays silent, and `make check-driverkit` passes unchanged.
- After every task: `make test`, `make driver-test`, `make check-driverkit`, `make app-test`, `make script-test` all pass, and `make driver` (unsigned Xcode build) succeeds.
- No hardware in Tasks 1 and 2: no install, no activation, no modem reboot, no AT command, never `~/personal/RM520N-GL/at.py`, no `sudo`, nothing sent on `en33`. Never write to or delete from `build/installed/` (tests use their own temporary directories). Never touch `/Applications/RMNet.app`.
- Never `ifconfig en33` (or `ifconfig` with any interface name) in the script: it can hang for minutes. Use `ifconfig -l` and `ipconfig getifaddr en33`, each under a timeout.
- Text messages and phone numbers stored in the modem are private.
- Commit at the end of every task with the message given; no attribution lines.

## Review Focus

- `power-trial.sh` reinstalls the good build on every way out after the test build was activated: the window ending, an early stop, a failed step, `SIGINT`, `SIGTERM`, `SIGHUP`. It never leaves the test build active.
- Every external command in `power-trial.sh` that could block (`ipconfig`, `ioreg`, `ping`, `systemextensionsctl`, `curl`, `RMNet activate`) runs under a timeout, so a hung network stack cannot stop the restore.
- The trial clock in the driver starts at the first successful low-power ask and ends the trial even when no timer tick ran for a while; after it ends, no further low-power ask is ever made by that instance.
- With `RMNetLowPowerOnly` set, no `SetIdlePolicy` call is made at all; without either key nothing changes.
- The trace is complete while asking: every `SetPowerState`, `setPowerState`, `SetInterfaceEnable`, `setInterfaceEnable` and `ChangePowerState` call is logged with its time since `Start`, not only the first.

---

### Task 1: The trial harness

**Files:**
- Create: `scripts/power-trial.sh`
- Modify: `scripts/install-driver.sh` (the `--build-only` option)
- Create: `tests/scripts/test-power-trial.sh`
- Modify: `Makefile` (`script-test` runs the new test)
- Modify: `README.md` (one short section, "Power trials", under the existing scripts section)

**Interfaces:**
- Produces: `scripts/install-driver.sh --build-only`: generates the project, makes the signed build with the next version exactly as today, keeps it with `keep_app` as `build/installed/RMNet-<version>.app`, prints `built build/installed/RMNet-<version>.app` as its last line, and stops: no copy to `/Applications`, no activation, no listing check beyond what keeping needs. Without the option the script is unchanged.
- Produces: `scripts/power-trial.sh --test <kept app> --good <kept app> [--window <s>] [--out <dir>] [--detach] [--dry-run]`.

Behaviour of `power-trial.sh`:
1. **Refuses** (exit 2, one line on stderr, nothing changed) unless: both apps are directories inside `build/installed/` and embed `Contents/Library/SystemExtensions/io.rmnetdriver.RMNet.driver.dext` with a `CFBundleVersion`; the two versions differ; `--window` is an integer from 10 to 180 (default 60); the modem is attached (`ioreg -p IOUSB -l` shows `"idProduct" = 2049` with `"idVendor" = 11388`); the console answers `AT` with `OK` (`POST http://127.0.0.1:8730/at`, body `AT`, `/usr/bin/curl --noproxy '*' -m 10`); and `~/personal/RM520N-GL/.modem-lock` can be taken with `mkdir` (owner file: `power-trial <pid> <ISO time> test <version>`).
2. `--out` defaults to `build/trials/<UTC stamp>-<test version>/` (`build/` is git-ignored). Everything below is written there: `run.log` (each step with a UTC time), `samples.tsv`, `dext.log`, `summary.txt`.
3. `--detach` re-runs the script itself under `nohup`, in a new session (`setsid` is absent on macOS; use `nohup` with stdin from `/dev/null` and the output to `run.log`), prints the out directory, and exits 0 at once. The detached run must survive the parent shell and the Claude session ending.
4. `--dry-run` prints each step it would take, one per line, starting `dry-run: `, and changes nothing; the refusal checks of step 1 still run, except the modem, console and lock checks, which print what they would check.
5. **Baseline:** `configd`'s PID (`pgrep -x configd`), the newest `/Library/Logs/DiagnosticReports/configd_*.spin` name, `ifconfig -l`, the active driver version from `systemextensionsctl list`.
6. **Log capture:** `/usr/bin/log stream --style compact --predicate 'senderImagePath ENDSWITH "/io.rmnetdriver.RMNet.driver" OR eventMessage BEGINSWITH "RMNet:"'` in the background to `dext.log`, killed at the end.
7. **Install the test build:** `ditto` it over `/Applications/RMNet.app` (remove first, as `install-driver.sh` does), run `/Applications/RMNet.app/Contents/MacOS/RMNet activate` under a 60 s timeout, wait (up to 60 s) until `systemextensionsctl list` shows the test version `activated enabled`, then send `AT+CFUN=1,1` through the console. From the moment `activate` is run, the restore of step 9 is armed.
8. **Observe:** wait up to 90 s for `en33` to be in `ifconfig -l`, then for `--window` seconds sample once a second, one tab-separated line each: seconds since `AT+CFUN=1,1`; `en33` in `ifconfig -l` (1/0); `ipconfig getifaddr en33` (or `-`, or `timeout`); `configd`'s PID; whether a new `configd_*.spin` appeared (1/0); `ping -c 1 -t 2 -b en33 1.1.1.1` (`ok`, `fail`, or `-` when `en33` is absent); and from `ioreg -r -n RMNetDriver -d 1 -w0` the values of `RMNetIdleSuspend`, `RMNetLastPowerFlags`, `RMNetLowPowerTrial`, `RMNetSuspendedTicks`, `RMNetState`. A header line names the columns. The window ends early, with the reason in `run.log`, at the first `configd` PID change or new spin report.
9. **Restore (always, once the test build was activated):** on the window's end, an early end, any failed step, and `INT`, `TERM`, `HUP` (a `trap`): `ditto` the good build over `/Applications/RMNet.app`, `RMNet activate` (60 s timeout), wait for the good version `activated enabled` (60 s), `AT+CFUN=1,1`, wait up to 120 s for `ipconfig getifaddr en33` to give an address, then watch `configd` for 30 s. A restore step that fails is logged and the next is still tried; `RMNet activate` is retried once after 10 s. The lock is removed last.
10. **Summary** (`summary.txt`, also printed): the test and good versions, the window asked and the window run, why it ended, the first second `en33` was absent (or `never`), the `configd` PID changes and new spin reports during the window, and the restore's result: `restored <version>, en33 <address>, configd steady 30 s`, or which restore step failed.

Timeouts: one helper, `with_timeout <seconds> <command...>`, implemented as `perl -e 'alarm shift; exec @ARGV' <seconds> <command...>`; its exit status 142 means timed out. Every `ipconfig`, `ioreg`, `ping`, `systemextensionsctl`, `curl` and `RMNet` call goes through it. Data: the samples send at most one ping a second, under 100 bytes each.

- [ ] **Step 1: Write `tests/scripts/test-power-trial.sh`**, in the style of `tests/scripts/test-install-checks.sh` (counts `passed`/`failed`, exit 1 on a failure), with stub commands on a temporary `PATH` and temporary kept-app directories (fake bundles with an `Info.plist` holding `CFBundleVersion`, read with `defaults`, which works on any plist path). Cases, at least: missing `--test` → exit 2; a test app outside `build/installed/` → exit 2 (the script takes the kept-apps directory from `RMNET_KEEP_DIR` when set, for tests, else `build/installed`); same version for test and good → exit 2; `--window 5` and `--window 181` → exit 2; a valid `--dry-run` → exit 0, prints `dry-run: ` lines in this order: lock, baseline, log stream, install test, activate, re-enumerate, observe 60 s, restore good, summary; `with_timeout 1 sleep 5` returns 142 within 3 s; the restore runs when the observe step fails (a stub `ifconfig` that exits 1, in a mode `RMNET_TRIAL_STUB=1` that the script honours only together with `RMNET_KEEP_DIR`, where `ditto`, `RMNet activate`, `curl` and `systemextensionsctl` are the stubs on `PATH`: the stub log shows the good app's `ditto` and `activate` after the test app's).
- [ ] **Step 2: Run it:** `sh tests/scripts/test-power-trial.sh`. Expected: FAIL (no script yet).
- [ ] **Step 3: Write `scripts/power-trial.sh` and `install-driver.sh --build-only`** as specified above. POSIX `sh`, `set -u`, no bashisms (`checkbashisms` is not available; keep to what `/bin/sh` on macOS runs with `sh -n`).
- [ ] **Step 4: Run** `sh -n scripts/power-trial.sh && sh tests/scripts/test-power-trial.sh`, then add the test to the `script-test` target and run `make script-test`. Expected: all pass.
- [ ] **Step 5: README**: a "Power trials" section: what the script is for (driver power experiments only), that it changes the installed driver and reboots the modem twice, that it always reinstalls the good build, how to run it detached, where the results go, and that it never needs the owner's password.
- [ ] **Step 6: Run all five targets and `make driver`; commit:** `scripts: power-trial.sh runs one driver power trial and always restores the good build; install-driver.sh --build-only`

### Task 2: Trial keys and the power trace in the drivers

**Files:**
- Modify: `driver/idle_suspend.h` (pure decisions for the new keys)
- Modify: `driver/RMNetDriver.cpp`, `driver/RMNetSerial.cpp`, and their `.iig` only if a new member function needs declaring
- Modify: `tests/driver/test_idle_suspend.cpp` (or a new `tests/driver/test_power_trial.cpp`; the Makefile builds every `tests/driver/test_*.cpp`)
- Modify: `README.md` (the idle suspend paragraph: the two experiment keys, one or two sentences), `docs/driverkit-notes.md` (a short "Phase 1 trial keys" entry)

**Interfaces:**
- Consumes: `idle_suspend_key`, `idle_suspend_wanted`, `idle_suspend_state`, `power_call`, `low_power_ask_after`, `AskLowPower`, `lowPowerDue`, `UsbIo::set_idle_policy` (all at `8824d57`).
- Produces, in `driver/idle_suspend.h`:
  - `uint32_t low_power_trial_key(IdleKeyKind kind, uint64_t value, uint32_t bits)`: seconds; absent, not an integer, negative or 0 → 0 (no time box); 1 to 300 as is; above 300 → 300. Same sign rule as `idle_suspend_key`.
  - `bool low_power_trial_over(uint64_t startMs, uint64_t nowMs, uint32_t sec)`: false when `sec` is 0 or `startMs` is 0; true once `nowMs - startMs >= sec * 1000`.
  - `bool low_power_only_key(IdleKeyKind kind, bool value)`: true only for a boolean `true` (`OSBoolean`); kind `Integer` or `NotInteger` or `Absent` → false. (Add an `IdleKeyKind::Boolean` if needed.)
- Produces: published properties `RMNetLowPowerTrial` (string: `none`, `running <sec> s`, `ended after <sec> s`) and `RMNetLowPowerOnly` (0/1), in `RMNetDriver`; `RMNetSerial` publishes `RMNetLowPowerTrial` the same way.

Behaviour:
1. `RMNetDriver` reads `RMNetLowPowerOnly` and `RMNetLowPowerTrialSec` from its own personality at `Start`, logging how each was taken (one line each, like `RMNetIdleSuspendMs: …`).
2. **Low power only:** when `RMNetLowPowerOnly` is true, the driver asks for the low power state exactly as it does with idle suspend on (`lowPower` true: `AskLowPower` on the first full tick, and again after every on state; `power_call` takes the low state as powered), but `UsbIo::set_idle_policy` is never called, whatever `RMNetIdleSuspendMs` says, and `RMNetIdleSuspend` reads `low power only`. It does not need remote wakeup.
3. **Time box:** when `RMNetLowPowerTrialSec` is above 0 and the driver asks for low power (either mode), the first ask that returns success sets `trialStartMs`. On the first full tick where `low_power_trial_over` is true (ticks run every 100 ms while anything is pending and at least every second otherwise; check the existing timer's longest gap and use the tick that is sure to come), the driver: calls `ChangePowerState(kIOServicePowerCapabilityOn)` once and logs the result; sets `lowPower` false for the rest of this instance's life (no further ask, `power_call` back to its off-mode meaning); if idle policies were set, calls `UsbIo::set_idle_policy(0)` so the device stays awake (0 removes the policy; log the result; add the 0 case to `set_idle_policy` if it refuses 0 today); and publishes `RMNetLowPowerTrial` `ended after <sec> s`. A trial that never started (no successful ask) never ends and says `running <sec> s` only once started; before that `none`.
4. **Trace:** while `lowPower` is true or a trial has run in this instance, every `SetPowerState_Impl`, `setPowerState`, `SetInterfaceEnable_Impl`, `setInterfaceEnable`, `Stop_Impl`, and every `ChangePowerState` call (low and on) is logged with `t+<ms since Start>`, the flags or state, and the driver's `asleep`/`resumePending`/`stopping`, and the `rxStock` count. The existing `LOG_FIRST` lines stay as they are for the off case.
5. **`RMNetSerial`** reads `RMNetLowPowerTrialSec` from its own personality under the same rule and, when it asks for low power (idle suspend on), applies the same time box: at its end, `ChangePowerState(kIOServicePowerCapabilityOn)` once, no further ask, `RMNetLowPowerTrial` published. Its time source is the same `CLOCK_UPTIME_RAW` milliseconds; it has no timer of its own, so schedule the end with one `DispatchAsync` block per check, or the existing re-ask path, whichever the code allows without a new timer; if neither can guarantee the end, add an `IOTimerDispatchSource` used only during a trial. `RMNetLowPowerOnly` does not apply to the serial ports.
6. Nothing changes without the keys: no new call, no new log line except the two "how the key was taken" lines (which say `no such property`), and the two new properties read `none` and 0.

- [ ] **Step 1: Write the failing host tests** for `low_power_trial_key` (absent 0; 0 → 0; −1 → 0; 1 → 1; 20 → 20; 300 → 300; 301 → 300; 8-bit 0xFF → 0, the sign rule) and `low_power_trial_over` (sec 0 → false; start 0 → false; start 1000, now 20999, sec 20 → false; now 21000 → true) and `low_power_only_key` (absent false; boolean false false; boolean true true; integer 1 false).
- [ ] **Step 2: Run** `make driver-test`. Expected: FAIL (functions not defined).
- [ ] **Step 3: Implement** the three functions in `driver/idle_suspend.h`, then the driver behaviour 1 to 6.
- [ ] **Step 4: Run** `make driver-test` (PASS) and `make driver` (builds, no new warnings).
- [ ] **Step 5: Docs:** README's idle suspend paragraph and the notes entry: the two keys, that they are for power experiments with `scripts/power-trial.sh` only, and that the shipped plist sets neither.
- [ ] **Step 6: Run all five targets and `make driver`; commit:** `driver: experiment keys RMNetLowPowerOnly and RMNetLowPowerTrialSec, and a full power trace while asking for low power`

---

## Phase 1 trials (coordinator, on the modem, after Tasks 1 and 2 land on `idle-suspend`)

Before each trial: tell the owner the Mac's network may drop for up to the trial's time box. Builds: a working-tree `driver/Info.plist` change only (never committed), `scripts/install-driver.sh --build-only`, then `scripts/power-trial.sh --detach --test <that build> --good build/installed/RMNet-318.4.36.app`.
- **E1a:** `RMNetDriver` personality only: `RMNetLowPowerOnly` true, `RMNetLowPowerTrialSec` 20. Window 60 s.
- **E1b** (only if E1a kept `en33` and `configd`): `RMNetIdleSuspendMs` 2000 and `RMNetLowPowerTrialSec` 20 in all three personalities. Window 60 s.
- Read `samples.tsv`, `dext.log` and `summary.txt`; record them in `docs/driverkit-notes.md`; decide H1 or H2; write Phase 2 into this plan.
