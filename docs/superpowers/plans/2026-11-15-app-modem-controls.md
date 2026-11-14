# Modem Controls in the RMNet App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The RMNet app shows the modem's network, signal and SIM state and changes its radio, network mode, data profile (APN and authentication) and SIM PIN: in two new window tabs and through new command-line verbs.

**Architecture:** Everything goes over the modem's spare AT port (USB interface 3) through the existing `AtPort`, exactly as the SMS feature does: a service opens the port for each operation and closes it after. The reading of AT answers, the summaries, the checks of what the owner typed and the AT lines that change the modem are pure Swift with tests; the service's sequences (above all "radio off, change, radio on again") are tested against a scripted fake port; the window's controller is tested with a fake service. The driver, Core and the scripts are not touched.

**Tech Stack:** Swift 5 (Foundation, IOKit, IOUSBHost, SwiftUI, AppKit). AT commands from Quectel's "RG520N&RG525F&RG5x0F&RM5x0N&RM521F Series AT Commands Manual V1.0" (in `~/personal/RM520N-GL/RM520N-GL/Documents/`, called "the manual" below) and 3GPP TS 27.007; `AT+QICSGP`, which the manual does not cover, from the modem's own test answer (below).

**Spec:** The owner's request of 2026-11-15, relayed by the controlling session: after comparing with Quectel's official drivers (Linux `qmi_wwan_q` + `quectel-CM`, Windows), the app lacks their control features: signal/operator/network info, radio on/off, network-mode preference, APN/user/password/authentication (`quectel-CM -s`) and SIM PIN entry (`quectel-CM -p`); "all should come". The five features, their candidate commands and the rules (never send a PIN while testing, ask before changing the modem, put every change back, never log a password or PIN) are the task brief, summarised in the Global Constraints. The app's place in the project: `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (goal 6); the SMS plan `docs/superpowers/plans/2026-11-14-sms-in-the-app.md` set the pattern this plan follows.

## What the modem answered (read only, 2026-11-15 03:40, firmware `RM520NGLAAR03A04M4G_01.204.01.204`)

These are the exact lines, used as test fixtures. `AT+CMEE?` is `+CMEE: 1` (numeric `+CME ERROR: <n>`). Every command answered in about 60 ms.

```
AT+CFUN?                      +CFUN: 1                     (AT+CFUN=? gives +CFUN: (0,1,4),(0,1))
AT+COPS?                      +COPS: 0,0,"CHINA MOBILE",11
AT+QSPN                       +QSPN: "4E2D56FD79FB52A8","4E2D56FD79FB52A8","0043004D00430043",1,"46000"
AT+C5GREG?                    +C5GREG: 0,1
AT+CEREG?                     +CEREG: 0,0
AT+CGREG?                     +CGREG: 0,0
AT+CREG?                      +CREG: 0,0
AT+QENG="servingcell"         +QENG: "servingcell","NOCONN","NR5G-SA","TDD",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,8,1,-
AT+QCAINFO                    +QCAINFO: "PCC",504990,12,"NR5G BAND 41",32
                              +QCAINFO: "SCC",155770,3,"NR5G BAND 28",1,6,0,-,-
AT+QNWPREFCFG="mode_pref"     +QNWPREFCFG: "mode_pref",AUTO
AT+QNWPREFCFG="nr5g_disable_mode"   +QNWPREFCFG: "nr5g_disable_mode",0
AT+CGDCONT?                   +CGDCONT: 1,"IPV4V6","","0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0",0,0,0,0,,,,,,,,,,"",,,,0
                              +CGDCONT: 2,"IPV4V6","ims","0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0",0,0,0,0,,,,,,,,,,"",,,,0
                              +CGDCONT: 3,"IPV4V6","CMNET","0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0",0,0,0,0,,,,,,,,,,"",,,,0
                              +CGDCONT: 4,"IPV4V6","CMWAP", ... (same shape)
                              +CGDCONT: 5,"IPV4V6","SOS","0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0",0,0,0,1,,,,,,,,,,"",,,,0
AT+QICSGP=?                   +QICSGP: (1-16),(1-3),<APN>,<username>,<password>,(0-3)
AT+QICSGP=1                   +QICSGP: 3,"","","",0
AT+QICSGP=3                   +QICSGP: 3,"CMNET","","",0
AT+CGAUTH? / AT+CGAUTH=?      ERROR            (not supported: authentication goes through AT+QICSGP)
AT+CPIN?                      +CPIN: READY
AT+QPINC?                     +QPINC: "SC",3,10
                              +QPINC: "P2",3,10
AT+CLCK="SC",2                +CLCK: 0         (PIN lock off; mode 2 only queries)
```

The driver dials with only the profile number (`core/src/qmi_msgs.cpp`, TLV 0x31 "Profile Index 3GPP"); `AT+QICSGP` and `AT+CGDCONT` show the same profiles (both say profile 1 has an empty APN and profile 3 `CMNET`), so a profile changed with `AT+QICSGP` is what the driver's next call uses. `RMNetProfile` in the registry is `1` today.

The commands chosen, and their meaning, from the manual:
- `AT+QENG="servingcell"` (5.20). SA: `"servingcell",<state>,"NR5G-SA",<duplex>,<MCC>,<MNC>,<cellID>,<PCID>,<TAC>,<ARFCN>,<band>,<NR_DL_bandwidth>,<RSRP>,<RSRQ>,<SINR>,<scs>,<srxlev>`. EN-DC (NSA): three lines, `"servingcell",<state>`, then `"LTE",<is_tdd>,<MCC>,<MNC>,<cellID>,<PCID>,<earfcn>,<freq_band_ind>,<UL_bandwidth>,<DL_bandwidth>,<TAC>,<RSRP>,<RSRQ>,<RSSI>,<SINR>,<CQI>,<tx_power>,<srxlev>`, then `"NR5G-NSA",<MCC>,<MNC>,<PCID>,<RSRP>,<SINR>,<RSRQ>,<ARFCN>,<band>,<NR_DL_bandwidth>,<scs>` (note SINR before RSRQ). LTE: one line `"servingcell",<state>,"LTE",` then the LTE fields. WCDMA: `"servingcell",<state>,"WCDMA",<MCC>,<MNC>,<LAC>,<cellID>,<uarfcn>,<PSC>,<RAC>,<RSCP>,<ecio>,...`. `<state>`: `SEARCH`, `LIMSRV`, `NOCONN`, `CONNECT`. LTE `<SINR>` is a raw value: dB = raw × 2 − 20 (manual: "Y = (1/5) × X × 10 − 20"); NR SINR is in dB. `-` means no value. NR DL bandwidth codes 0…16 = 5, 10, 15, 20, 25, 30, 40, 50, 60, 70, 80, 90, 100, 200, 400, 35, 45 MHz; LTE codes 0…5 = 1.4, 3, 5, 10, 15, 20 MHz.
- `AT+C5GREG?`, `AT+CEREG?`, `AT+CGREG?`, `AT+CREG?` (5.2–5.5): `<n>,<stat>[,…]`; stat 0 not registered, 1 home, 2 searching, 3 denied, 4 unknown, 5 roaming, 8 emergency only. On 5G SA only `C5GREG` is registered.
- `AT+COPS?` (5.1): `<mode>[,<format>,<oper>[,<AcT>]]`; AcT 2/4/5/6 UTRAN, 7 E-UTRAN, 10 E-UTRAN on 5GC, 11 NR on 5GC (SA), 12 NG-RAN, 13 EN-DC.
- `AT+QSPN` (5.19): `<FNN>,<SNN>,<SPN>,<alphabet>,<RPLMN>`; alphabet 1 means the names are UCS-2 in hex (above: 中国移动, CMCC). Plain `OK` when not registered.
- `AT+QNWPREFCFG="mode_pref"[,<mode>]` (5.24.5): `AUTO` or RATs joined by `:` from `WCDMA`, `LTE`, `NR5G`; written to NVM, effective at once. `"nr5g_disable_mode"` (5.24.13): 0 none, 1 SA disabled, 2 NSA disabled (shown, never changed).
- `AT+CFUN=<fun>` (2.22): 0 minimum, 1 full, 4 RF off ("airplane"); answer within 15 s.
- `AT+QICSGP=<id>[,<type>,"<APN>","<user>","<password>",<auth>]`: id 1–16; type 1 IPV4, 2 IPV6, 3 IPV4V6; auth 0 none, 1 PAP, 2 CHAP, 3 PAP or CHAP. Kept by the modem.
- `AT+CPIN?` / `AT+CPIN="<pin>"` (4.4), `AT+QPINC?` (4.11, `"SC",<pin left>,<puk left>`), `AT+CLCK="SC",2` (4.3). CPIN states: `READY`, `SIM PIN`, `SIM PUK`, `SIM PIN2`, `SIM PUK2`, `PH-…`; `+CME ERROR: 10` no SIM, `13` SIM failure, `14` SIM busy.

## Global Constraints

- Branch `app-controls` in the worktree `~/personal/RM520N-GL/worktrees/app-controls`, cut from `main` at `c226454`. Never touch `~/personal/RM520N-GL/rmnet-driver` (another session's checkout) or `~/personal/RM520N-GL/worktrees/serial-ports`. Nothing is pushed; commit messages carry no attribution lines.
- Only `app/`, `tests/app/`, the `Makefile`, `README.md` and documents change. Nothing under `driver/`, `core/`, `tests/*.cpp`, `harness/` or `scripts/`.
- New code goes in new files. Existing files get only minimal hooks: `app/StatusView.swift` (the window's tabs and the app delegate) and `app/main.swift` (dispatch and usage). Another session is editing `app/ExtensionManager.swift`, `app/StatusModel.swift` and `app/StatusView.swift`; do not reformat or move anything there.
- AT port: interface 3 only, through `AtPort` (`app/AtPort.swift`, unchanged). Never interface 2 (the owner's console `webui.py`) or 4 (the driver). Never run `~/personal/RM520N-GL/at.py`.
- Implementers send only these read-only commands to the modem, and only in the tasks that say so: `AT+CFUN?`, `AT+COPS?`, `AT+QSPN`, `AT+C5GREG?`, `AT+CEREG?`, `AT+CGREG?`, `AT+CREG?`, `AT+QENG="servingcell"`, `AT+QCAINFO`, `AT+QNWPREFCFG="mode_pref"`, `AT+QNWPREFCFG="nr5g_disable_mode"`, `AT+CGDCONT?`, `AT+QICSGP=<id>`, `AT+CPIN?`, `AT+QPINC?`, `AT+CLCK="SC",2`. Never `AT+COPS=?` (a network scan), never any command that changes the modem. Only the controller changes the modem, in Task 7, after the owner's yes, and puts each change back.
- **Never send a PIN or PUK to the modem**, in any task: wrong attempts lock the SIM. PIN entry is tested with the fake port and the fake service only. RMNet never enters a PUK.
- A password or PIN is never written to a log, to standard output (other than nothing: it is never printed), to disk or to the pasteboard, and never appears in a `String(describing:)`, `String(reflecting:)` or `dump` of any value. Message texts and phone numbers rules from the SMS feature still hold.
- The existing verbs (`activate`, `deactivate`, `status`, `status --json`, `sms …`) print exactly what they print today; scripts read them.
- All modem I/O runs off the main thread. Commands that only read use a 3 s timeout; `AT+CFUN=` 20 s; `AT+QICSGP=` and `AT+QNWPREFCFG=` writes 5 s; `AT+CPIN="…"` 10 s.
- No uncapped network transfer, no `networkQuality`: the SIM is metered. These features move no data of their own.
- Do not run `scripts/install-driver.sh` and do not touch `/Applications/RMNet.app` or `build/installed/` in the main checkout. App builds are unsigned, from this worktree (`make driver`).
- `make test`, `make check-driverkit` and `make app-test` stay green; each task's new test program is added to `app-test`.
- Commit at the end of every task, with the message given.

## Review Focus

- **The radio left off.** A redial (radio off, change, radio on) whose change, read-back or own port fails in the middle must still switch the radio back on, opening a new port if the old one closed itself, and must say plainly if it could not ("The radio is still off. Run `RMNet radio on`…"). A redial is never started when the radio was not on to begin with. Tests: Task 3.
- **A PIN sent when the owner did not see the attempts left.** The service re-reads `AT+CPIN?` and `AT+QPINC?` and sends nothing unless the SIM still asks for its PIN and the attempts left equal what the owner was shown and are at least 1; at 1 the CLI needs `--last-attempt` and the window's confirmation says it is the last one; a timeout after sending says it is not known whether the PIN was taken. Tests: Tasks 2, 3, 4, 5.
- **Secrets leaking through string conversion.** `ProfileSettings` holds a password: interpolation, `String(reflecting:)`, `dump`, the JSON and every printed line show only whether one is set. Tests: Tasks 2 and 4.
- **Odd modem answers.** Missing fields, `-` in place of a number, extra fields, quoted commas in an APN or user name, a `+CME ERROR` for one query among several, `AT+QSPN` answering bare `OK`, the radio off (`AT+QENG` answering `"servingcell","SEARCH"` or an error): the read still succeeds with what it could read, never crashes and never invents a value. Tests: Tasks 1 and 2.
- **What the owner types.** An APN with spaces, quotes or non-ASCII; a user name or password with `"`; a PIN with letters or of the wrong length; a mode such as `lte:lte`, `auto:lte` or `5g`: each refused with a sentence before the port opens. Tests: Tasks 2 and 4.

---

### Task 1: The network model: reading signal, operator, registration and cell (pure Swift)

**Files:**
- Create: `app/ModemNetwork.swift`, `tests/app/ModemNetworkTests.swift`
- Modify: `Makefile` (`app-test` also builds and runs `build/modemnet-tests` from those two files, the way it builds `build/app-tests`)

**Interfaces:**
- Consumes: nothing. Imports Foundation only. Must not clash with names already in `app/` (for example `ModemState`, `TableRow` and `displaySafe` exist): keep helpers `private`/`fileprivate`.
- Produces:

```swift
enum RadioState: Equatable { case on, airplane, minimum, other(Int) }        // AT+CFUN 1, 4, 0, other
enum RegistrationStatus: Equatable { case home, roaming, searching, denied, emergencyOnly, notRegistered, unknown }
struct Registration: Equatable { let status: RegistrationStatus; let domain: String }   // domain "5GS", "EPS", "PS", "CS"
struct CellLeg: Equatable {
    let rat: String                 // "NR5G-SA", "NR5G-NSA", "LTE", "WCDMA"
    let duplex: String?             // "TDD"/"FDD"
    let mcc: String?; let mnc: String?          // as the modem gave them ("00" stays "00")
    let cellID: String?; let pci: Int?; let tac: String?   // WCDMA: tac = LAC, pci = PSC
    let channel: Int?               // ARFCN, EARFCN or UARFCN
    let band: String?               // "n41", "B3"; nil for WCDMA
    let bandwidthMHz: Double?       // downlink
    let rsrp: Int?; let rsrq: Int?; let sinr: Double?    // dBm, dB, dB (LTE SINR converted); WCDMA: rsrp = RSCP
}
struct ServingCell: Equatable { let state: String; let cells: [CellLeg] }   // state as given: "NOCONN", …
struct NetworkInfo: Equatable {
    var radio: RadioState? = nil
    var registration: Registration? = nil
    var operatorName: String? = nil      // AT+COPS? <oper>, display-safe
    var networkName: String? = nil       // AT+QSPN <FNN>, decoded, display-safe
    var plmn: String? = nil              // AT+QSPN <RPLMN>, else MCC+MNC of the first leg
    var accessTechnology: Int? = nil     // AT+COPS? <AcT>
    var serving: ServingCell? = nil
    var carriers: [String] = []          // AT+QCAINFO bands, primary first
    var mode: String? = nil              // mode_pref exactly as the modem gave it ("AUTO", "LTE:NR5G")
    var nr5gDisable: Int? = nil
}

func atFields(_ line: String, prefix: String) -> [String]?   // the fields after "<prefix>:", split on commas outside quotes, quotes removed, each trimmed; nil if the line does not start with the prefix
func parseRadio(_ lines: [String]) -> RadioState?
func parseRegistrationStat(_ lines: [String], prefix: String) -> Int?      // prefix "+C5GREG" etc.; the <stat> of the read answer
func summarizeRegistration(fiveG: Int?, eps: Int?, ps: Int?, cs: Int?) -> Registration?
func parseOperator(_ lines: [String]) -> (name: String?, accessTechnology: Int?)
func parseServiceProvider(_ lines: [String]) -> (fullName: String?, plmn: String?)
func parseServingCell(_ lines: [String]) -> ServingCell?
func parseCarriers(_ lines: [String]) -> [String]
func parseModePreference(_ lines: [String]) -> String?
func parseNr5gDisable(_ lines: [String]) -> Int?
func technologyLabel(_ info: NetworkInfo) -> String
func registrationWords(_ r: Registration?) -> String
func modeWords(_ mode: String) -> String
func networkRows(_ info: NetworkInfo) -> [(label: String, value: String)]   // the window's rows and the CLI's lines
func networkJSON(_ info: NetworkInfo) -> [String: Any]
```

Rules the tests pin:
- `atFields`: `+QSPN: "a,b",1` gives `["a,b", "1"]`; empty fields stay `""`; a line with another prefix gives nil.
- `summarizeRegistration`: domains in the order 5GS, EPS, PS, CS. The first whose stat is 1 or 5 gives `.home`/`.roaming` with that domain; otherwise the first with 2 gives `.searching`; otherwise any 3 `.denied`, any 8 `.emergencyOnly`; otherwise `.notRegistered` with domain `""` if any was read (0 or 4 count as read), nil if all four are nil.
- `parseServiceProvider`: alphabet 1 decodes `<FNN>` as UCS-2 big-endian hex; hex that is not valid UCS-2 (odd length, not hex) is kept as given; empty name gives nil; a bare `OK` (no line) gives `(nil, nil)`.
- Every text that came from the network (`operatorName`, `networkName`) has control characters and the bidirectional controls (U+202A–U+202E, U+2066–U+2069, U+200E, U+200F) replaced by U+FFFD.
- `parseServingCell`: a field that is `-`, empty or not a number becomes nil; a line with fewer fields than the format leaves the missing ones nil; extra fields are ignored; `"servingcell","SEARCH"` alone gives `ServingCell(state: "SEARCH", cells: [])`; no `+QENG:` line gives nil. Bands: NR `41` gives `"n41"`, LTE `3` gives `"B3"`.
- `parseCarriers`: `"NR5G BAND 41"` → `"n41"`, `"LTE BAND 3"` → `"B3"`, another text kept as given; PCC first, then SCC lines in order.
- `technologyLabel`: a `NR5G-SA` leg → `"5G SA"`; a `NR5G-NSA` leg → `"5G NSA"`; `LTE` alone → `"LTE"`; `WCDMA` → `"WCDMA"`; no legs with state `SEARCH` → `"searching"`, `LIMSRV` → `"limited service"`; no serving cell: from `accessTechnology` (11 or 12 `"5G SA"`, 13 `"5G NSA"`, 7 `"LTE"`, 10 `"LTE (5G core)"`, 2/4/5/6 `"WCDMA"`), else `"unknown"`; radio `.airplane` → `"none (radio off)"` whatever else was read.
- `modeWords`: `AUTO` "automatic (5G, LTE and WCDMA)", `NR5G` "5G only", `LTE` "LTE only", `LTE:NR5G` "5G and LTE", `WCDMA` "WCDMA only", anything else its RATs joined with " and ".

- [ ] **Step 1: Write the failing tests** in `tests/app/ModemNetworkTests.swift`, in the style of `tests/app/StatusModelTests.swift` (`check(_:_:_:)`, `@main struct ModemNetworkTests`, prints `modem network: <n> checks passed`). They must include, with the fixtures above:

```swift
let sa = ["+QENG: \"servingcell\",\"NOCONN\",\"NR5G-SA\",\"TDD\",460,00,123456789,32,1A2B3C,504990,41,12,-95,-10,8,1,-"]
let cell = parseServingCell(sa)!
check(cell.state == "NOCONN" && cell.cells.count == 1, "SA: one leg")
check(cell.cells[0] == CellLeg(rat: "NR5G-SA", duplex: "TDD", mcc: "460", mnc: "00", cellID: "123456789", pci: 32,
      tac: "1A2B3C", channel: 504990, band: "n41", bandwidthMHz: 100, rsrp: -95, rsrq: -10, sinr: 8), "SA leg")
let endc = ["+QENG: \"servingcell\",\"CONNECT\"",
            "+QENG: \"LTE\",\"FDD\",460,00,1C2D3E4,128,1300,3,5,3,2B3C,-98,-11,-68,14,8,230,52",
            "+QENG: \"NR5G-NSA\",460,00,513,-90,15,-11,627264,78,12,1"]
// LTE leg: band "B3", channel 1300, bandwidthMHz 10, rsrp -98, rsrq -11, sinr 8 (14 × 2 − 20); NR leg: pci 513, rsrp -90, sinr 15, rsrq -11, band "n78", bandwidthMHz 100
check(parseServingCell(["+QENG: \"servingcell\",\"SEARCH\""]) == ServingCell(state: "SEARCH", cells: []), "searching")
check(parseServiceProvider(["+QSPN: \"4E2D56FD79FB52A8\",\"4E2D56FD79FB52A8\",\"0043004D00430043\",1,\"46000\""]) == ("中国移动", "46000") ...)
check(parseCarriers(["+QCAINFO: \"PCC\",504990,12,\"NR5G BAND 41\",32", "+QCAINFO: \"SCC\",155770,3,\"NR5G BAND 28\",1,6,0,-,-"]) == ["n41", "n28"], "carriers")
check(summarizeRegistration(fiveG: 1, eps: 0, ps: 0, cs: 0) == Registration(status: .home, domain: "5GS"), "SA home")
check(summarizeRegistration(fiveG: nil, eps: 5, ps: nil, cs: 1) == Registration(status: .roaming, domain: "EPS"), "roaming")
```

plus: `parseRadio` for 1, 4, 0, 7; `parseOperator(["+COPS: 0,0,\"CHINA MOBILE\",11"])` and `["+COPS: 0"]`; a QSPN with alphabet 0; an operator name containing U+202E becomes U+FFFD; a truncated SA line (only up to `<PCID>`); a WCDMA line; `parseModePreference` and `parseNr5gDisable` on the fixtures; every `technologyLabel` case; and `networkRows` for the SA fixture (all reads above combined, radio on) giving exactly these rows, in this order:

```
Registration   registered, home network (5GS)
Operator       CHINA MOBILE (中国移动), PLMN 46000
Technology     5G SA (TDD)
Band           n41 + n28 (carrier aggregation)
Signal         RSRP -95 dBm, RSRQ -10 dB, SINR 8 dB
Cell           PCI 32, cell ID 123456789, TAC 1A2B3C
Channel        ARFCN 504990, 100 MHz
Connection     idle
Radio          on
Network mode   automatic (5G, LTE and WCDMA)
```

For the EN-DC fixture the rows are `Technology 5G NSA (LTE FDD + 5G)`, `Band B3 + n78`, then `Signal (LTE)`, `Signal (5G)`, `Cell (LTE)`, `Cell (5G)`, `Channel (LTE)`, `Channel (5G)` in that order (`Cell (5G)` is `PCI 513`; a value that is nil is left out of its row, and a row with no value is left out). `Connection`: `NOCONN` "idle", `CONNECT` "connected", `SEARCH` "searching", `LIMSRV` "limited service", other as given. `Radio`: "on", "off (airplane mode)", "minimum functionality", "AT+CFUN <n>". Registration words: "registered, home network (5GS)", "registered, roaming (EPS)", "searching", "registration denied", "emergency services only", "not registered", "unknown"; nil gives "unknown". `Operator` leaves out the parenthesis when the network name is nil or equals the operator name ignoring case, and `, PLMN …` when there is no PLMN. When `nr5gDisable` is 1 or 2 the mode row ends with "; 5G SA is disabled" or "; 5G NSA is disabled".

`networkJSON` for the SA fixture (checked key by key after a `JSONSerialization` round trip): `radio` "on" (others "airplane", "minimum", "cfun <n>"), `registration` {`status` "home" (others "roaming", "searching", "denied", "emergency", "not registered", "unknown"), `domain` "5GS"}, `roaming` false, `operator` "CHINA MOBILE", `networkName` "中国移动", `plmn` "46000", `technology` "5G SA", `state` "NOCONN", `cells` [{`rat`, `duplex`, `mcc`, `mnc`, `cellId`, `pci`, `tac`, `channel`, `band`, `bandwidthMHz`, `rsrp`, `rsrq`, `sinr`}], `carriers` ["n41","n28"], `mode` "AUTO", `nr5gDisableMode` 0. Every absent value is JSON null (`NSNull`), never left out.

- [ ] **Step 2: Add the Makefile target and run it to see it fail**

Run: `make app-test`
Expected: the build of `build/modemnet-tests` fails (the functions do not exist).

- [ ] **Step 3: Implement `app/ModemNetwork.swift`** with the interfaces above. Fields are taken by position after `atFields`; nothing is force-unwrapped or indexed without a bounds check.

- [ ] **Step 4: Run the tests**

Run: `make app-test`
Expected: every program passes, the last line `modem network: <n> checks passed`.

- [ ] **Step 5: Commit**

```bash
git add app/ModemNetwork.swift tests/app/ModemNetworkTests.swift Makefile
git commit -m "app: read the modem's network, signal and cell from its AT answers"
```

---

### Task 2: The settings model: radio, network mode, data profiles, SIM and the service's interface (pure Swift)

**Files:**
- Create: `app/ModemSettings.swift`, `tests/app/ModemSettingsTests.swift`
- Modify: `Makefile` (`app-test` also builds and runs `build/modemset-tests` from `app/ModemNetwork.swift`, `app/ModemSettings.swift` and the test file)

**Interfaces:**
- Consumes: Task 1's `NetworkInfo`, `Registration`, `atFields`.
- Produces:

```swift
struct ModemFailure: Error, Equatable { let message: String }      // a sentence for the owner
enum PdpType: Int, CaseIterable { case ipv4 = 1, ipv6 = 2, ipv4v6 = 3 }       // AT+QICSGP <context_type>
enum AuthMethod: Int, CaseIterable { case none = 0, pap = 1, chap = 2, papOrChap = 3 }
struct ProfileSettings: Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var type: PdpType; var apn: String; var user: String
    var password: String            // in memory only: never printed, logged or stored
    var auth: AuthMethod
}
struct DataProfile: Equatable { let id: Int; let pdpType: String; let apn: String; let settings: ProfileSettings? }  // from AT+CGDCONT?; settings from AT+QICSGP=<id> (nil above 16 or unread)
enum SimState: Equatable { case ready, pin, puk, pin2, puk2, notInserted, failure, busy, other(String) }
struct SimInfo: Equatable { let state: SimState; let pinLock: Bool?; let pinAttempts: Int?; let pukAttempts: Int? }
struct RadioChange: Equatable { let on: Bool; let registration: Registration?; let secondsToRegister: Int? }
struct ModeChange: Equatable { let before: String; let after: String }
enum RedialResult: Equatable { case notAsked, radioWasOff, done(RadioChange), radioLeftOff(String) }
struct ProfileChange: Equatable { let id: Int; let before: ProfileSettings; let after: ProfileSettings; let redial: RedialResult }
struct PinOutcome: Equatable { let accepted: Bool; let sim: SimInfo? }

protocol ModemServing {
    func networkInfo() -> Result<NetworkInfo, ModemFailure>
    func setRadio(on: Bool) -> Result<RadioChange, ModemFailure>
    func setMode(_ mode: String) -> Result<ModeChange, ModemFailure>          // a canonicalMode value
    func profiles() -> Result<[DataProfile], ModemFailure>
    func setProfile(_ id: Int, to settings: ProfileSettings, redial: Bool) -> Result<ProfileChange, ModemFailure>
    func sim() -> Result<SimInfo, ModemFailure>
    func enterPin(_ pin: String, shownAttempts: Int) -> Result<PinOutcome, ModemFailure>
}

let networkModeChoices = ["AUTO", "LTE:NR5G", "NR5G", "LTE"]       // what the window offers, in this order
func canonicalMode(_ argument: String) -> String?
func parseProfiles(_ lines: [String]) -> [(id: Int, pdpType: String, apn: String)]   // AT+CGDCONT?
func parseProfileSettings(_ lines: [String]) -> ProfileSettings?                       // AT+QICSGP=<id>
func profileCommand(_ id: Int, _ s: ProfileSettings) -> String      // AT+QICSGP=<id>,<type>,"<apn>","<user>","<password>",<auth>
func modeCommand(_ mode: String) -> String                          // AT+QNWPREFCFG="mode_pref",<mode>
func pinCommand(_ pin: String) -> String                            // AT+CPIN="<pin>"
func profileProblem(_ id: Int, _ s: ProfileSettings) -> String?     // nil when it can be sent; else the sentence
func pinProblem(_ pin: String) -> String?
func parseSimState(_ lines: [String]) -> SimState?                  // the answer to AT+CPIN?
func simState(fromError line: String) -> SimState                   // its error line instead ("+CME ERROR: 10")
func parsePinAttempts(_ lines: [String]) -> (pin: Int?, puk: Int?)  // the "SC" line of AT+QPINC?
func parsePinLock(_ lines: [String]) -> Bool?                       // AT+CLCK="SC",2
func profileWords(_ s: ProfileSettings) -> String
func profileRestoreArguments(_ s: ProfileSettings) -> String        // the `RMNet apn set` options that put s back
func simRows(_ sim: SimInfo) -> [(label: String, value: String)]
func simJSON(_ sim: SimInfo) -> [String: Any]
func profilesJSON(_ profiles: [DataProfile], driverProfile: Int) -> [String: Any]
func radioOffQuestion() -> (title: String, message: String)
func modeQuestion(from: String?, to: String) -> (title: String, message: String)
func profileQuestion(id: Int, before: ProfileSettings?, after: ProfileSettings) -> (title: String, message: String)
func pinQuestion(attempts: Int) -> (title: String, message: String)
func radioSentence(_ c: RadioChange) -> String
func modeSentence(_ c: ModeChange) -> String
func profileSentence(_ c: ProfileChange) -> String
func pinSentence(_ o: PinOutcome) -> String
```

Rules the tests pin:
- `canonicalMode`: case-insensitive; `auto` → `AUTO`; otherwise RATs from `wcdma`, `lte`, `nr5g` joined by `:`, each at most once, returned in the order WCDMA, LTE, NR5G (`nr5g:lte` → `LTE:NR5G`). nil for empty, unknown names (`5g`, `nr`), repeats (`lte:lte`), `auto` with others, empty pieces (`lte:`).
- `parseProfileSettings(["+QICSGP: 3,\"\",\"\",\"\",0"])` is `ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none)`; quoted commas stay in their field; a type or auth out of range gives nil.
- `profileCommand(1, ProfileSettings(type: .ipv4v6, apn: "cmnet", user: "u", password: "p", auth: .chap))` is exactly `AT+QICSGP=1,3,"cmnet","u","p",2`.
- `profileProblem`: id outside 1…16 → "Profile <id> cannot be changed by RMNet: AT+QICSGP takes profiles 1 to 16."; APN longer than 100 characters, or with a character other than ASCII letters, digits, `.`, `-`, `_`, or starting or ending with `.` → a sentence naming the APN rule; user or password longer than 127 characters or with a character outside printable ASCII (0x20–0x7E) or a `"` → a sentence naming the field (never quoting the password). An empty APN is allowed (the network chooses).
- `pinProblem`: 4 to 8 ASCII digits, else "A PIN is 4 to 8 digits."
- `parseSimState`: `+CPIN: READY` `.ready`, `SIM PIN` `.pin`, `SIM PUK` `.puk`, `SIM PIN2` `.pin2`, `SIM PUK2` `.puk2`, other text `.other(text)`; no `+CPIN:` line nil. `simState(fromError:)`: `+CME ERROR: 10` `.notInserted`, `13` `.failure`, `14` `.busy`, any other line `.other(line)`.
- Redaction: for `let s = ProfileSettings(type: .ipv4v6, apn: "a", user: "u", password: "hunter2-secret", auth: .pap)`, none of `"\(s)"`, `String(describing: s)`, `String(reflecting: s)`, the output of `dump(s, to: &text)`, `"\(DataProfile(id: 1, pdpType: "IPV4V6", apn: "a", settings: s))"`, `profileWords(s)`, `profileRestoreArguments(s)`, any `profileQuestion`/`profileSentence` text, or the JSON from `profilesJSON` contains `hunter2-secret`. The same for a `ProfileChange` holding it in `before` and `after`.
- `profileWords`: e.g. `IPV4V6, APN "cmnet", PAP, user "u", password set`; empty APN reads `APN "" (the network chooses)`; no auth reads `no authentication`; empty user and password are left out.
- `profileRestoreArguments(ProfileSettings(type: .ipv4v6, apn: "", user: "", password: "", auth: .none))` is `--apn '' --type ipv4v6 --user '' --auth none`; with a password set it ends ` --password` (the owner types the old one at the prompt). Values are single-quoted for the shell (`'` inside as `'\''`).
- `profilesJSON(…, driverProfile: 1)`: `{"driverProfile": 1, "profiles": [{"id", "pdpType", "apn", "auth" ("none", "pap", "chap", "pap-or-chap" or null), "user" (or null), "passwordSet" (bool or null), "driver" (bool)}]}`.
- `simRows(SimInfo(state: .ready, pinLock: false, pinAttempts: 3, pukAttempts: 10))` is `[("SIM", "ready"), ("PIN lock", "off"), ("Attempts left", "PIN 3, PUK 10")]`; states read "ready", "asks for its PIN", "blocked: needs its PUK from the carrier", "asks for PIN2", "asks for PUK2", "not inserted", "SIM failure", "busy", or the text. `simJSON`: `state` ("ready", "pin", "puk", "pin2", "puk2", "not inserted", "failure", "busy", or the text), `pinLock`, `pinAttempts`, `pukAttempts`, nulls where unknown.
- `pinQuestion(attempts: 3).message` contains "3 attempts left" and "a wrong PIN uses one"; `pinQuestion(attempts: 1).message` contains "This is the last attempt" and "PUK".
- `profileQuestion` message contains "A wrong APN breaks the connection." and says the radio is switched off and on again (a redial), and whether the password changes ("password: unchanged" / "password: changed"), never its value.
- `modeQuestion(from: "AUTO", to: "LTE")` says the setting is kept by the modem and how to put it back ("Put back" in the window, `RMNet mode auto`).
- `radioSentence`: off → "The radio is off. The driver's connection is down until the radio is switched on again."; on and registered after n seconds → "The radio is on; registered (<registration words>) after <n> s."; on and not registered within the wait → "The radio is on, but the modem has not registered yet (<words>)."
- `profileSentence` for `.radioLeftOff(why)` begins "The profile was changed, but the radio is still off: " and ends "Run `RMNet radio on`, or press Radio On in the window."; for `.radioWasOff` it says the new settings are used when the radio is switched on.
- `pinSentence(PinOutcome(accepted: false, sim: SimInfo(state: .pin, pinLock: true, pinAttempts: 2, pukAttempts: 10)))` is "The SIM refused the PIN. 2 attempts left."; with `.puk` it says the SIM is blocked and needs its PUK from the carrier, and that RMNet does not enter PUKs.

- [ ] **Step 1: Write the failing tests** in `tests/app/ModemSettingsTests.swift` (same style; prints `modem settings: <n> checks passed`) covering every rule above, including each `canonicalMode` refusal and each redaction form.

- [ ] **Step 2: Add the Makefile target; run `make app-test`**
Expected: the build of `build/modemset-tests` fails.

- [ ] **Step 3: Implement `app/ModemSettings.swift`.** `ProfileSettings.description` and `debugDescription` are `profileWords(self)`; `customMirror` has `type`, `apn`, `user`, `passwordSet`, `auth` and no password.

- [ ] **Step 4: Run `make app-test`**
Expected: every program passes, including `modem settings: <n> checks passed`.

- [ ] **Step 5: Commit**

```bash
git add app/ModemSettings.swift tests/app/ModemSettingsTests.swift Makefile
git commit -m "app: the modem settings model: radio, network mode, data profiles, SIM, and their checks"
```

---

### Task 3: The modem service: the AT sequences over interface 3

**Files:**
- Create: `app/ModemService.swift`, `tests/app/ModemServiceTests.swift`
- Modify: `Makefile` (`app-test` also builds and runs `build/modemsvc-tests` from `app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/ModemNetwork.swift app/ModemSettings.swift app/ModemService.swift tests/app/ModemServiceTests.swift`; `SmsService.swift` brings `describe(_: AtError)`)

**Interfaces:**
- Consumes: Tasks 1 and 2; `AtPort`, `AtError` (`app/AtPort.swift`); `describe(_ error: AtError) -> String` (`app/SmsService.swift`).
- Produces:

```swift
protocol AtCommanding: AnyObject {
    func command(_ line: String, timeout: TimeInterval) -> Result<[String], AtError>
    func close()
}
extension AtPort: AtCommanding {}

final class ModemService: ModemServing {
    init(open: @escaping () -> Result<AtCommanding, AtError> = { AtPort.open().map { $0 as AtCommanding } },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         now: @escaping () -> Date = { Date() })
}
func readSecret(prompt: String) -> String?   // readpassphrase(3) from /dev/tty, no echo (RPP_REQUIRE_TTY); nil without a terminal
```

Behaviour (each call opens a port, works, closes it, also on failure; a timeout or I/O error ends the call, since the port then closed itself):
- `networkInfo()`: the eleven read commands in the order of the fixtures list (`AT+CFUN?` … `"nr5g_disable_mode"`), 3 s each. A `.modem` error on one of them leaves its part empty and goes on; a timeout or I/O error fails the call with `describe(error)`.
- `setRadio(on:)`: `AT+CFUN=4` or `AT+CFUN=1` (20 s). After `on`, reads the four registration commands every 1 s (by `sleep`, timed by `now`) until registered or 30 s have passed; `RadioChange.secondsToRegister` is the whole seconds from the `AT+CFUN=1` answer to the first registered read, nil if none. For `off`, `registration` and `secondsToRegister` are nil.
- `setMode(_:)`: refuses a value `canonicalMode` would not return (nothing opened); reads the mode, sends `modeCommand` (5 s), reads it again; the read-back must equal the value sent, else failure "The modem answered OK but now reports <x>."
- `profiles()`: `AT+CGDCONT?`, then `AT+QICSGP=<id>` for each id 1…16 listed; a `.modem` error on one leaves its `settings` nil.
- `setProfile(_:to:redial:)`: checks `profileProblem` first (nothing opened). Reads `AT+QICSGP=<id>` (the `before`). With `redial` true it reads `AT+CFUN?`: if the radio is on, it sends `AT+CFUN=4`, sleeps 1 s, sends `profileCommand` (5 s), reads it back, then **always** sends `AT+CFUN=1` and waits for registration as `setRadio(on: true)` does; if the radio is not on, it only sends and reads back (`.radioWasOff`). With `redial` false, only the change and read-back (`.notAsked`). The read-back must equal the settings sent (password compared in memory), else a failure saying what the modem reports (without the password). If `AT+CFUN=1` cannot be sent on the current port (it closed itself after a timeout or I/O error), the service opens a new port once and tries again; if that fails too, the result is `.radioLeftOff(<why>)` when the change itself succeeded, or a failure whose sentence says the radio is still off and to run `RMNet radio on`. A refused `AT+CFUN=4` changes nothing: failure "…Nothing was changed."
- `sim()`: `AT+CPIN?` (an error line is a state, not a failure: `simState(fromError: line)`; an answer without a `+CPIN:` line fails the call), `AT+QPINC?`, `AT+CLCK="SC",2`; the last two may fail (nil values).
- `enterPin(_:shownAttempts:)`: checks `pinProblem` (nothing opened). Reads `AT+CPIN?` and `AT+QPINC?`; sends nothing and fails unless the state is `.pin` ("The SIM does not ask for a PIN (<state words>). Nothing was sent.") and the PIN attempts left are known, at least 1 and equal to `shownAttempts` ("The attempts left changed to <n> since they were shown. Nothing was sent; check and enter the PIN again."). Then `pinCommand(pin)` (10 s): OK → `accepted` true; a `.modem` error → `accepted` false; then reads `sim()`'s three commands for `PinOutcome.sim`. A timeout or I/O error after sending fails with "It is not known whether the SIM took the PIN. Check the attempts left (RMNet sim) before entering it again." The PIN is never put in a failure or anywhere else.

- [ ] **Step 1: Write the failing tests** in `tests/app/ModemServiceTests.swift` (prints `modem service: <n> checks passed`) with a `ScriptedPort: AtCommanding` that answers from a queue of `(expected line, Result<[String], AtError>)` and records every line it was sent, and an opener that counts opens (each test checks every opened port was closed). `sleep` adds to a fake clock that `now` reads. Tests:
  - `networkInfo` with the fixtures returns the SA `NetworkInfo`; with `+CME ERROR: 3` for `AT+QCAINFO` it still succeeds with `carriers == []`; a `.timeout` on `AT+COPS?` fails and sends nothing after it.
  - `setProfile(1, to: s, redial: true)` with the radio on sends exactly `AT+QICSGP=1`, `AT+CFUN?`, `AT+CFUN=4`, `AT+QICSGP=1,3,"cmnet","","",0`, `AT+QICSGP=1`, `AT+CFUN=1`, then registration reads; `before` and `after` are right, `redial` is `.done` with `secondsToRegister` from the fake clock.
  - The same with the change refused (`+CME ERROR: 3`): `AT+CFUN=1` is still sent and the failure says the radio was switched back on and nothing changed.
  - The same with a `.timeout` on the change: the port closed, a second port is opened, `AT+CFUN=1` is sent on it.
  - The same with `AT+CFUN=1` failing on both ports: the result names the radio still off.
  - Radio off at the start (`+CFUN: 4`): no `AT+CFUN=` is sent; `redial` is `.radioWasOff`.
  - `AT+CFUN=4` refused: no `AT+QICSGP=1,…` is sent; failure ends "Nothing was changed."
  - Read-back different (APN `x` comes back): failure.
  - `profileProblem` refusals open no port.
  - `setRadio(on: true)`: registered on the third read gives `secondsToRegister == 2`; never registered stops after 30 s of fake time.
  - `setMode("LTE")`: sends `AT+QNWPREFCFG="mode_pref"`, `AT+QNWPREFCFG="mode_pref",LTE`, `AT+QNWPREFCFG="mode_pref"`; `ModeChange(before: "AUTO", after: "LTE")`. `setMode("lte:lte")` opens no port.
  - `enterPin`: state READY → nothing sent after the reads; attempts 2 when 3 were shown → nothing sent; attempts 0 → nothing sent; `"12a4"` → no port; OK → `accepted` true and the three SIM reads follow; `+CME ERROR: 16` → `accepted` false with the new attempts; `.timeout` after sending → the "not known" failure. In every case the PIN string appears in no failure message and in no line sent except the one `AT+CPIN="…"`.

- [ ] **Step 2: Add the Makefile target; run `make app-test`** — expected: the build fails.

- [ ] **Step 3: Implement `app/ModemService.swift`.**

- [ ] **Step 4: Run `make app-test`** — expected: all programs pass.

- [ ] **Step 5: On the modem, read only.** Build a throwaway command-line program in the session's scratchpad (never in the repository) from `app/AtPort.swift app/SmsModel.swift app/SmsService.swift app/ModemNetwork.swift app/ModemSettings.swift app/ModemService.swift` and a `main.swift` that calls only `networkInfo()`, `profiles()` and `sim()` and prints `networkRows`, `profileWords` and `simRows`. Run it once. Expected: rows like the SA fixture's (values may differ), five profiles with profile 1 `IPV4V6, APN "" (the network chooses), no authentication`, and `SIM ready, PIN lock off, Attempts left PIN 3, PUK 10`. Report the output in the task report. Do not call any other method.

- [ ] **Step 6: Commit**

```bash
git add app/ModemService.swift tests/app/ModemServiceTests.swift Makefile
git commit -m "app: the modem service: reads, radio, mode, profile with redial, and PIN entry over the AT port"
```

---

### Task 4: The command-line verbs `network`, `radio`, `mode`, `apn`, `sim`

**Files:**
- Create: `app/ModemCli.swift`, `tests/app/ModemCliTests.swift`
- Modify: `app/main.swift` (dispatch and the usage line only), `Makefile` (`build/modemcli-tests` from `app/ModemNetwork.swift app/ModemSettings.swift app/ModemCli.swift tests/app/ModemCliTests.swift`), `README.md` (the verbs)

**Interfaces:**
- Consumes: Tasks 1–3 (`ModemService()`, `readSecret(prompt:)`), `readDriverProperties()` (`app/Registry.swift`).
- Produces:

```swift
enum ModemCommand: Equatable {
    case network(json: Bool)
    case radio(on: Bool?)                       // nil: show
    case mode(String?)                          // nil: show; else a canonicalMode value
    case apnShow(json: Bool)
    case apnSet(apn: String?, type: PdpType?, user: String?, askPassword: Bool, auth: AuthMethod?, redial: Bool)
    case sim(json: Bool)
    case simUnlock(lastAttempt: Bool)
    var changesModem: Bool { get }              // radio on/off, mode set, apnSet, simUnlock
}
let modemVerbs: Set<String>                     // ["network", "radio", "mode", "apn", "sim"]
func parseModem(_ words: [String]) -> ModemCommand?      // words include the verb; nil for wrong usage
func runModem(_ command: ModemCommand, service: ModemServing, driverProfile: Int?,
              readSecret: (String) -> String?, output: (String) -> Void) -> Int32   // 0 ok, 1 failure
let modemUsage: String                          // appended to main.swift's usage line
```

Usage (also the README's): `RMNet network [--json] | radio [on|off] | mode [auto|nr5g|lte|lte:nr5g|…] | apn [show] [--json] | apn set [--apn <name>] [--type ipv4|ipv6|ipv4v6] [--user <name>] [--password] [--auth none|pap|chap|pap-or-chap] [--no-redial] | sim [--json] | sim unlock [--last-attempt]`. Wrong usage prints the usage line and exits 2 without opening the port (main.swift). `apn set` with none of `--apn`, `--type`, `--user`, `--password`, `--auth` is wrong usage; an option given twice is wrong usage; a mode `canonicalMode` refuses is wrong usage. Any value after `--apn` or `--user` is taken as given (including `''`).

Output (every failure is one line `<verb>: <sentence>` and exit 1):
- `network`: one line `<label lowercased>: <value>` per `networkRows` row; `--json` prints `networkJSON` pretty-printed with sorted keys.
- `radio`: `radio: on` / `radio: off (airplane mode)` / …; `radio off` / `radio on`: `radio: <radioSentence>`.
- `mode`: `mode: <MODE> (<modeWords>)`; `mode <m>`: `mode: <modeSentence>` then `mode: to put it back: RMNet mode <before, lowercased>`.
- `apn` / `apn show`: `apn: the driver dials profile <n>` (or `apn: the driver is not attached; it dials profile 1 unless set otherwise`), then `profile <id>: <profileWords>` per profile with ` (the driver's)` on the driver's; `--json` prints `profilesJSON`.
- `apn set`: reads `profiles()` for the driver's profile (`driverProfile ?? 1`; if it is not listed or its settings could not be read: `apn: Profile <n> could not be read. Nothing was changed.`, exit 1), applies the given options over its current settings, checks `profileProblem` (exit 1 before any change), prints `apn: A wrong APN breaks the connection.`; with `--password` reads the new password by `readSecret("New password for profile <n> (empty for none): ")` (nil: `apn: --password needs a terminal to read the password.` exit 1); then `setProfile(_, to:, redial: !noRedial)`; prints `apn: <profileSentence>` and `apn: to put it back: RMNet apn set <profileRestoreArguments(before)>`.
- `sim`: `sim: <label lowercased>: <value>` per `simRows`; `--json` prints `simJSON`.
- `sim unlock`: reads `sim()`; not `.pin` → `sim: The SIM does not ask for a PIN (<words>).` exit 1 (`.puk`: the blocked sentence); attempts unknown → exit 1 `sim: The attempts left could not be read; RMNet does not send a PIN without them.`; prints `sim: The SIM asks for its PIN. <n> attempt(s) left; a wrong PIN uses one.`; at 1 without `--last-attempt` → exit 1 `sim: This is the last attempt: a wrong PIN blocks the SIM until its PUK is entered. Run again with --last-attempt to send it.`; reads the PIN by `readSecret("PIN: ")`; `pinProblem` → exit 1; `enterPin(pin, shownAttempts: n)` → `sim: <pinSentence>`, exit 0 only if accepted.

main.swift: after the `sms` block, `if let verb = verbs.first, modemVerbs.contains(verb)`: parse (usage + exit 2 on nil); if `changesModem`, ignore `SIGINT, SIGTERM, SIGHUP, SIGTSTP, SIGQUIT` as `sms send` does; run `runModem(command, service: ModemService(), driverProfile: readDriverProperties()?["RMNetProfile"].flatMap { Int($0) }, readSecret: readSecret(prompt:), output: { print($0) })` on a background queue, `fflush(stdout)`, exit with its code. The usage line gains ` | <modemUsage>`.

- [ ] **Step 1: Write the failing tests** in `tests/app/ModemCliTests.swift` (prints `modem cli: <n> checks passed`) with a fake `ModemServing` that records calls and returns set results: `parseModem` for every form above and each wrong usage (`["radio", "up"]`, `["mode", "5g"]`, `["apn", "set"]`, `["apn", "set", "--apn"]`, `["apn", "set", "--apn", "a", "--apn", "b"]`, `["sim", "unlock", "1234"]`, `["network", "--xml"]`); the exact output lines for `network` with the SA fixture and `sim` with the READY fixture; `apn set --apn cmnet` sends `setProfile(1, to: <profile 1 with apn "cmnet">, redial: true)` and prints the restore line `apn: to put it back: RMNet apn set --apn '' --type ipv4v6 --user '' --auth none`; `--no-redial` passes `redial: false`; a password read by the fake `readSecret` reaches `setProfile` and appears in no output line; `sim unlock` with 1 attempt and no `--last-attempt` never calls `readSecret` or `enterPin`; `sim unlock` with state READY never calls `readSecret`; `changesModem` true exactly for the five changing forms.

- [ ] **Step 2: Add the Makefile target; run `make app-test`** — expected: the build fails.

- [ ] **Step 3: Implement `app/ModemCli.swift` and the main.swift hook.**

- [ ] **Step 4: Run `make app-test`, then `make driver`** — expected: all programs pass; `driver build ok`.

- [ ] **Step 5: On the modem, read only**, with the unsigned build's binary `build/xcode/Debug/RMNet.app/Contents/MacOS/RMNet` (find the exact path under `build/xcode/`): run `network`, `network --json`, `radio`, `mode`, `apn`, `apn show --json`, `sim`, `sim --json` once each, and `mode 5g`, `apn set` (wrong usage: exit 2). Expected: plausible values, exit 0 (2 for the wrong usage). Paste the outputs into the task report. Run no other form.

- [ ] **Step 6: Document the verbs in `README.md`**: a new bullet after the `sms` bullet in "Driver", in the README's style: each verb, its output, its exit codes, which commands it sends, that `mode` and `apn set` change lasting modem settings and print how to put them back, that `apn set` redials (radio off, then on: the connection drops for about 10 to 30 s) unless `--no-redial` or the radio is off, that the password is read without echo and never printed, that `sim unlock` shows the attempts left first, refuses the last attempt without `--last-attempt`, and that RMNet never enters a PUK; that `RMNet radio off` leaves the modem without network until `RMNet radio on`. Also update the opening sentence of "Driver" that lists the app's verbs, and the usage comment at the top of `app/main.swift`.

- [ ] **Step 7: Commit**

```bash
git add app/ModemCli.swift tests/app/ModemCliTests.swift app/main.swift Makefile README.md
git commit -m "app: network, radio, mode, apn and sim verbs"
```

---

### Task 5: The modem controller for the window (state, timers, one call at a time, quitting)

**Files:**
- Create: `app/ModemController.swift`, `tests/app/ModemControllerTests.swift`
- Modify: `Makefile` (`build/modemui-tests` from `app/ModemNetwork.swift app/ModemSettings.swift app/ModemController.swift tests/app/ModemControllerTests.swift`)

**Interfaces:**
- Consumes: Tasks 1–2 (`ModemServing` and its types). No AppKit or SwiftUI: Combine and Foundation only, like `app/SmsController.swift`, whose structure (serial queue, results back on the main thread, `quitWhenFinished`, a separate quit-notice object) this follows; read it first.
- Produces:

```swift
enum ModemTab: Equatable { case network, simAndApn }
enum ModemActivity: Equatable { case reading, radio, mode, profile, pin }
enum ModemUndo: Equatable { case mode(String); case profile(id: Int, ProfileSettings) }
final class ModemQuitNotice: ObservableObject { @Published fileprivate(set) var line = "" }

final class ModemController: ObservableObject {
    @Published private(set) var info: NetworkInfo?
    @Published private(set) var infoAt: Date?
    @Published private(set) var infoFailure: String?
    @Published private(set) var profiles: [DataProfile]
    @Published private(set) var sim: SimInfo?
    @Published private(set) var settingsAt: Date?
    @Published private(set) var settingsFailure: String?
    @Published private(set) var running: ModemActivity?
    @Published private(set) var result: String
    @Published private(set) var resultIsFailure: Bool
    @Published private(set) var undo: ModemUndo?
    @Published var form: ProfileSettings?          // the editor's values for the driver's profile
    @Published var pickedMode: String?             // the Network tab's picker
    let quitNotice: ModemQuitNotice
    static let networkInterval: TimeInterval = 5
    static let settingsInterval: TimeInterval = 30

    init(service: ModemServing, queue: DispatchQueue, driverProfile: @escaping () -> Int?,
         replyToQuit: @escaping (Bool) -> Void, requestAttention: @escaping () -> Void)

    var profileID: Int { get }                     // driverProfile() ?? 1, read at each settings refresh
    var driverAttached: Bool { get }               // driverProfile() was not nil at the last refresh
    var formEdited: Bool { get }                   // form differs from the values it was filled from
    var applyEnabled: Bool { get }                 // not running, not quitting, form edited, profileProblem nil
    var modeChangeEnabled: Bool { get }            // not running, not quitting, pickedMode != info?.mode
    var pinEnabled: Bool { get }                   // not running, not quitting, sim?.state == .pin, pinAttempts ≥ 1
    var refreshEnabled: Bool { get }

    func setTabShown(_ tab: ModemTab?)             // nil: neither modem tab is shown
    func setWindowVisible(_ visible: Bool)
    func setConfirming(_ open: Bool)               // a confirmation is open: timer ticks skip
    func refresh()                                 // reads what the shown tab needs
    func tick()
    func setRadio(on: Bool)
    func changeMode()                              // to pickedMode
    func applyProfile()                            // form, with redial
    func putBack()                                 // undo, then undo becomes nil on success
    func revertForm()
    func enterPin(_ pin: String)                   // shownAttempts = sim!.pinAttempts!
    func quitWhenFinished() -> Bool
    func resumeAfterCancelledQuit()
}
```

Rules the tests pin:
- One call at a time on `queue`; results applied on the main thread. While the Network tab is shown and the window visible, `networkInfo()` at once and every 5 s; while the SIM & APN tab is, `profiles()` then `sim()` in one queued block at once and every 30 s; nothing while neither is shown, the window is hidden, or a confirmation is open (ticks skip). A tick while a call runs skips its turn.
- A failed read keeps the last good values and sets `infoFailure`/`settingsFailure`; a good read clears it.
- `form` is filled from the driver's profile settings when it is nil, after `applyProfile`/`putBack` finish, and on `revertForm()`; a periodic refresh never overwrites an edited form. `pickedMode` is set from `info.mode` when nil and after `changeMode`/`putBack`; a refresh never overwrites a different pick.
- `changeMode()` success: `undo = .mode(before)`, result `modeSentence`; `applyProfile()` success: `undo = .profile(id: profileID, before)` (the old password stays in memory only), result `profileSentence`, failure sentence otherwise. `putBack()` applies the undo the same way (a profile put back redials) and clears it on success. After a change, the shown tab is read again.
- `setRadio(on:)`: result `radioSentence`; no undo.
- `enterPin(pin)`: calls `enterPin(pin, shownAttempts: sim.pinAttempts)`; result `pinSentence` or the failure; the controller keeps no copy of the PIN (no stored property holds it; check with `Mirror(reflecting: controller)` that no child's value contains it after the call).
- Quitting, as `SmsController`: `quitWhenFinished()` stops the timers and new calls; returns false with nothing running; otherwise true, `quitNotice.line` is "RMNet quits when the radio has been switched back on." for `.profile` (and for `.radio`), "RMNet quits when the network mode has been changed." for `.mode`, "RMNet quits when the PIN has been checked." for `.pin`, "RMNet quits when the current request to the modem has finished." for `.reading`; when the call ends `replyToQuit(true)` after a read or a change that succeeded, and after one that failed `replyToQuit(false)`, `requestAttention()` and the controller works again. `resumeAfterCancelledQuit()` (the app delegate calls it when the Messages controller cancels the quit) makes it work again and restarts the timer if a tab is shown.

- [ ] **Step 1: Write the failing tests** in `tests/app/ModemControllerTests.swift` (prints `modem controller: <n> checks passed`), with a blocking fake service in the style of `tests/app/SmsControllerTests.swift` (calls block until released; the main run loop is pumped), covering each rule above.

- [ ] **Step 2: Add the Makefile target; run `make app-test`** — expected: the build fails.

- [ ] **Step 3: Implement `app/ModemController.swift`.**

- [ ] **Step 4: Run `make app-test`** — expected: all programs pass.

- [ ] **Step 5: Commit**

```bash
git add app/ModemController.swift tests/app/ModemControllerTests.swift Makefile
git commit -m "app: the modem controller for the window: reads while shown, one call at a time, quitting waits"
```

---

### Task 6: The Network and SIM & APN tabs

**Files:**
- Create: `app/ModemView.swift`
- Modify: `app/StatusView.swift` (hooks only: two `WindowTab` cases, two tab items, the modem quit notice, the app delegate's controller, shared queue and quit order), `README.md` (the window)

**Interfaces:**
- Consumes: Task 5's `ModemController`, Task 3's `ModemService()`, Task 2's question and word functions, `readDriverProperties()`.
- Produces: `struct NetworkTab: View`, `struct SimApnTab: View` (each `@ObservedObject var controller: ModemController`), `func driverProfileNumber() -> Int?` (`readDriverProperties()?["RMNetProfile"].flatMap { Int($0) }`), `func modemTab(_ tab: WindowTab) -> ModemTab?`.

The hooks in `app/StatusView.swift`:
- `enum WindowTab` gains `network` and `simAndApn`; the `TabView` order is Driver, Messages, Network, SIM & APN (tab titles exactly `Network` and `SIM & APN`).
- `RMNetWindow` takes `modem: ModemController` and `modemQuitNotice: ModemQuitNotice`; shows the modem's notice line above the tabs like the SMS one; calls `modem.setTabShown(modemTab(tab))` where it calls `messages.setTabShown`, `modem.setTabShown(nil)` on disappear, `modem.setWindowVisible` where it calls `messages.setWindowVisible`.
- `AppDelegate`: one `DispatchQueue(label: "io.rmnetdriver.RMNet.modem", qos: .userInitiated)` passed to both `SmsController(service:queue:…)` and `ModemController(…)`, so the window never opens the AT port twice at once. `applicationShouldTerminate`: `if modem.quitWhenFinished() { return .terminateLater }` then `messages.quitWhenFinished() ? .terminateLater : .terminateNow`. The modem's `replyToQuit`: on false, `NSApp.reply(toApplicationShouldTerminate: false)`; on true, `if !messages.quitWhenFinished() { NSApp.reply(toApplicationShouldTerminate: true) }` (otherwise the messages controller replies). The messages controller's `replyToQuit`: on false also `modem.resumeAfterCancelledQuit()` before replying.

The Network tab (refreshes as Task 5 says):
- A line "Updated HH:mm:ss" or the read failure (orange) with a note that the values below may be out of date, and `Refresh`.
- A two-column grid of `networkRows`, values selectable.
- Radio: the current radio state and a button `Radio Off…` (confirmation from `radioOffQuestion()`, destructive) or `Radio On` (no confirmation), disabled while a call runs.
- Network mode: a picker over `networkModeChoices` (plus the current value if it is another), labelled with `modeWords`, and `Change…` (confirmation from `modeQuestion`); `Put Back` (confirmation) when `undo` is a mode, labelled with the mode it restores.
- The result line of the last change (red on failure), selectable.

The SIM & APN tab (refreshes as Task 5 says):
- SIM: the `simRows`. When the state is `.pin`: a `SecureField("PIN")` held in the view's `@State`, cleared as soon as `Unlock…` is confirmed or cancelled, and `Unlock…` with the confirmation from `pinQuestion(attempts:)`. When `.puk`: the blocked sentence, no field.
- Data profiles: a table (id, type, APN, authentication, user, password set or not) with the driver's profile marked; the line "The driver dials profile <n>." (or the not-attached sentence).
- Editing the driver's profile: APN field, type picker (IPv4, IPv6, IPv4v6), authentication picker (None, PAP, CHAP, PAP or CHAP), user field, `SecureField` password (filled from the profile, so applying unchanged keeps it), the warning "A wrong APN breaks the connection. Apply switches the radio off and on again (a redial); the connection drops for about 10 to 30 seconds.", the `profileProblem` sentence in red when there is one, `Revert`, `Apply…` (confirmation from `profileQuestion`), and `Put Back…` when `undo` is a profile (confirmation naming what it restores, without the password).
- The result line of the last change.
- Text fields: no autocorrection or substitutions. Nothing typed is logged.

- [ ] **Step 1: Implement `app/ModemView.swift` and the hooks.**

- [ ] **Step 2: Build** — Run: `make app-test && make driver`. Expected: all programs pass; `driver build ok`.

- [ ] **Step 3: Look at it, read only.** Open the unsigned build (`open <path to build/xcode/…/RMNet.app>`), choose the Network tab, then the SIM & APN tab, take a screenshot of each (`screencapture -l <window id>` or `screencapture -x`, into the session scratchpad, never the repository), and quit the app with Cmd-Q. Press no button that changes the modem (`Radio Off…`, `Change…`, `Apply…`, `Unlock…`, `Put Back…`). Describe the screenshots in the report; fix layout problems (clipped text, controls off the window at the default 520×480 size; use a `ScrollView` where needed).

- [ ] **Step 4: Document the window in `README.md`**: a bullet after the `Messages` tab's, in the README's style: each tab, when it reads the modem (only while shown and visible: Network every 5 s, SIM & APN every 30 s), every control and its confirmation, Put Back, what quitting waits for, that the window and the verbs share the AT port (a verb run while the window reads waits up to 2 s for the port), and that a password or PIN is never shown, logged or stored. Update the sentence in "Driver" that names the window's tabs.

- [ ] **Step 5: Commit**

```bash
git add app/ModemView.swift app/StatusView.swift README.md
git commit -m "app: Network and SIM & APN tabs in the window"
```

---

### Task 7: On the modem (controller)

Done by the controller, not a subagent. Each change only after the owner's yes, given in the chat in answer to a question that names the change and how it is put back; each is put back right after.

**Files:**
- Modify: `docs/driverkit-notes.md` (a new section "Runtime findings (modem controls)"), `README.md` (corrections found on the modem)

- [ ] **Step 1: Read only.** With the unsigned build from the worktree: `network`, `radio`, `mode`, `apn`, `sim` and their `--json`; the window's two tabs. Record the outputs (no message text, numbers, passwords or PINs exist in them).
- [ ] **Step 2: Radio (owner's yes).** `RMNet radio off`, `RMNet network` (shows the radio off), `RMNet status` (the driver's link down), then `RMNet radio on`; record the seconds to registration and to the driver's `RMNetState = up`; three pings bound to `en33` in each family (`/sbin/ping -b en33 -c 3 223.5.5.5`, `/sbin/ping6 -I en33 -c 3 2400:3200::1`). Put back: the radio on (the last step itself).
- [ ] **Step 3: Network mode (owner's yes).** In the window: `LTE` with `Change…`; read the Network tab (technology LTE) and the driver's state; then `Put Back` to `AUTO`; read again (5G SA). Put back: `AUTO` (the step itself); check with `RMNet mode`.
- [ ] **Step 4: APN (owner's yes).** `RMNet apn set --apn cmnet` (the APN the network gives profile 1 anyway, read in `AT+CGCONTRDP=1` as `cmnet`); the redial; the driver up again; pings as above; then the printed put-back command `RMNet apn set --apn '' --type ipv4v6 --user '' --auth none`; `RMNet apn` shows profile 1 as before. Also once in the window: `Apply…` of the same change and `Put Back…`.
- [ ] **Step 5: SIM.** `RMNet sim` and the SIM & APN tab show ready, PIN lock off, attempts PIN 3, PUK 10 before and after everything. `RMNet sim unlock` with the SIM ready says no PIN is asked and sends nothing. No PIN is ever sent.
- [ ] **Step 6: Record and commit.** Write the findings (times, outputs, what each change did to the driver's link, and that each setting was put back and read back) to `docs/driverkit-notes.md`; correct `README.md` where the modem behaved otherwise; `make test && make check-driverkit && make app-test`.

```bash
git add docs/driverkit-notes.md README.md
git commit -m "docs: the modem controls on the modem"
```
