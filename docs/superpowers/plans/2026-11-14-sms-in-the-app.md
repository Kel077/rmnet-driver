# SMS in the RMNet App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The RMNet app reads, deletes and sends text messages through the modem: in its window and from the command line.

**Architecture:** The modem has two AT ports. The owner's web console holds USB interface 2; interface 3 is unused, and a throwaway test showed that a program on the Mac can open it with IOUSBHost and exchange AT commands while the driver (interface 4) and the console keep working. The app talks to interface 3 in PDU mode, opening the port for each operation and closing it after. Everything about the message format is pure Swift with tests; the driver, Core and the modem's settings are not touched.

**Tech Stack:** Swift 5 (Foundation, IOKit, IOUSBHost, SwiftUI). Message formats from 3GPP TS 23.040 and TS 23.038 and AT commands from TS 27.005; no code from other projects.

**Spec:** The owner's request of 2026-11-14 ("Get sms working too") and their choices in the question dialog: SMS built into RMNet (window and command line), receive and send, messages stay in the modem until deleted, no background notifications in the first version. The app's place in the project: `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md` (goal 6).

## Global Constraints

- Branch `sms`, cut from `main` at `ed7b5f4`. Only `app/`, `tests/app/`, the `Makefile`, `README.md` and documents change. Nothing under `driver/`, `core/`, `tests/*.cpp` or `scripts/`.
- The modem: USB `2c7c:0801`; the AT port is the interface with `bInterfaceNumber` 3 (vendor class `0xff`, one bulk IN and one bulk OUT endpoint, found from its descriptors; on this modem `0x86` and `0x04`). Never interface 2 (the owner's console) or 4 (the driver).
- Nothing lasting is changed on the modem: no `AT&W`, no `AT+CPMS=`, no `AT+CNMI=`, no `AT+CSCA=`, no `ATE`. The port echoes commands; the echo is skipped, not switched off. Messages are read and sent in PDU mode (`AT+CMGF?` is 0 on this modem; if it reads 1 the service sends `AT+CMGF=0`, which is not saved).
- Message text and phone numbers are never written to a log (`os_log`, `NSLog`, `print` outside the `sms` verbs' own output) or to disk.
- The existing verbs (`activate`, `deactivate`, `status`, `status --json`) print exactly what they print today; scripts read them.
- Swift only uses the system frameworks named above. All modem I/O runs off the main thread; a command that does not answer ends by its timeout.
- Implementers do not install anything and do not send or delete messages. Sending costs the owner a carrier fee: only the controller sends, in Task 5, after the owner has said yes. Task 2 alone may open interface 3, for the read-only commands it lists.
- Commit at the end of every task, with the message given.

## Review Focus

- A stored entry that is malformed or of a kind the app does not show (truncated hex, an odd number of hex digits, a status report, an unknown alphabet) never crashes: it is listed as not readable, with its index, so it can still be deleted.
- Multi-part messages: parts that arrive out of order, twice, or not at all, and two senders using the same reference number, assemble correctly; deleting a message deletes every stored part of it.
- Sending: one character outside the GSM alphabet switches the whole message to UCS-2; extension characters count as two; an escape pair or a surrogate pair is never split across parts; when a part fails the rest is not sent and the report says how many went out.
- The AT port: the modem absent, the interface held by another program, a command that never answers, and a send prompt that never comes each end in a plain message and a closed port. The port is never left open after a verb or when the window goes away.
- Privacy: nothing with message text or numbers reaches a log or a file.

---

### Task 1: The message model: PDUs, alphabets, multi-part assembly, AT text (pure Swift)

**Files:**
- Create: `app/SmsModel.swift`, `tests/app/SmsModelTests.swift`
- Modify: `Makefile` (`app-test` also builds and runs `build/sms-tests` from the two new files, in the way it builds `build/app-tests`)

**Interfaces:**
- Consumes: nothing. `app/SmsModel.swift` imports Foundation only.
- Produces:

```swift
enum SmsStatus: Int { case unread = 0, read = 1, unsent = 2, sent = 3 }
struct StoredPdu: Equatable { let index: Int; let status: SmsStatus; let hex: String }
struct SmsConcat: Equatable { let reference: Int; let total: Int; let sequence: Int }
struct SmsPart: Equatable {          // one stored entry, decoded or not
    let index: Int; let status: SmsStatus
    let sender: String               // "" when not readable
    let timestamp: Date?             // the service centre's time, nil when absent or invalid
    let text: String                 // "" when not readable
    let concat: SmsConcat?
    let readable: Bool               // false: not an SMS-DELIVER, or malformed
}
struct SmsMessage: Equatable {
    let indices: [Int]               // every stored index of the message, ascending
    let unread: Bool                 // any part was unread when listed
    let sender: String; let timestamp: Date?; let text: String
    let missingParts: Int            // 0 when complete
    let readable: Bool
}
enum SmsEncoding { case gsm7, ucs2 }
struct SubmitPdu: Equatable { let hex: String; let tpduLength: Int }  // tpduLength: octets after the SMSC field (what AT+CMGS takes)
struct SmsFailure: Error, Equatable { let message: String }           // a sentence for the owner
protocol SmsServing {
    func list() -> Result<[SmsMessage], SmsFailure>
    func delete(indices: [Int]) -> Result<Int, SmsFailure>            // stored entries deleted
    func send(to number: String, text: String) -> Result<Int, SmsFailure>  // parts sent
}

func parseListing(_ lines: [String]) -> [StoredPdu]       // the lines AT+CMGL=4 answers: "+CMGL: <index>,<stat>,[<alpha>],<length>" then a hex line
func decodePart(_ stored: StoredPdu) -> SmsPart           // never fails: readable false instead
func assemble(_ parts: [SmsPart]) -> [SmsMessage]         // newest first; entries without a time last, by index
func chooseEncoding(_ text: String) -> SmsEncoding
func partCount(_ text: String) -> Int                     // parts the text needs; 0 for empty text
func validNumber(_ number: String) -> Bool                // optional leading "+", then 3 to 20 digits
func encodeSubmit(to number: String, text: String, reference: UInt8) -> Result<[SubmitPdu], SmsFailure>
func parseSendReference(_ lines: [String]) -> Int?        // from "+CMGS: <mr>"
func parseStorage(_ lines: [String]) -> (used: Int, total: Int)?  // from "+CPMS: "ME",0,255,..." (the first pair)
```

  - `decodePart` handles SMS-DELIVER (TP-MTI 0): the service-centre field; the sender (international with a leading "+", national or unknown as digits, alphanumeric type `0xD0` unpacked from 7 bits); the alphabet from the data coding scheme (general groups `00xx` and the class group `1111`: GSM 7-bit, 8-bit shown as Latin-1, UCS-2 as UTF-16 big-endian with surrogate pairs); the service centre's time with its quarter-hour zone and sign; a user data header with the 8-bit (`0x00`) or 16-bit (`0x08`) concatenation element, skipping others, and the fill bits after it in 7-bit text; the GSM default alphabet and its extension table (escape `0x1B`). Anything else is `readable: false`.
  - `assemble` groups parts by sender, reference and total; a part without a concatenation element is a message by itself; a duplicate sequence number keeps the lower index for the text and still lists both indices; missing parts leave "[...]" in their place in the text and are counted.
  - `encodeSubmit` builds SMS-SUBMIT with the stored service centre (`00`), no validity period, no status report, message reference `00`, the number as international (`0x91`) when it starts with "+" and as unknown/national (`0x81`) otherwise. GSM 7-bit: one part up to 160 septets, else parts of at most 153 with the 8-bit concatenation element. UCS-2: one part up to 70 UTF-16 units, else parts of at most 67. At most 10 parts; more is a failure that says the message is too long. An invalid number or empty text is a failure.
  - The test binary follows `tests/app/StatusModelTests.swift` (its own `@main`, a `check` helper, a count at the end, exit 1 on any failure).

- [ ] **Step 1: Write the failing checks** in `tests/app/SmsModelTests.swift`. They must include:
  - The classic vector: `07917283010010F5040BC87238880900F10000993092516195800AE8329BFD4697D9EC37` decodes to sender `27838890001` (its address type is `0xC8`, not international, so there is no "+"), text `hellohello`, time 1999-03-29 15:16:59 at UTC+2 (that is 13:16:59 UTC), no concatenation.
  - `parseListing` on `["+CMGL: 3,0,,29", "<that hex>", "+CMGL: 7,1,,24", "<another hex>"]` gives indices 3 (unread) and 7 (read); a `+CMGL` line with no hex line after it is dropped; stray lines are ignored.
  - Vectors you build by hand from the specifications, each with the derivation in a comment so a reviewer can check it byte by byte: a UCS-2 message in Chinese; a sender of alphanumeric type; a national-number sender such as `10086`; a 7-bit message with a user data header (fill bits); extension characters (`€`, `[`, `]`, `{`, `}`, `\`, `~`, `^`, `|`); a UCS-2 text containing an emoji (a surrogate pair); a time zone of +8 hours (China) and a negative zone.
  - Not readable, and no crash, for: empty hex, an odd number of hex digits, hex cut short at every length of a valid PDU (a loop over all prefixes), a status report (TP-MTI 2), a reserved alphabet.
  - `assemble`: three parts in the order 3, 1, 2; a duplicate part; a missing middle part (`missingParts` 1, "[...]" in the text); two senders with the same reference and total kept apart; newest first.
  - `chooseEncoding` and `partCount`: 160 GSM characters is 1 part and 161 is 2; `€` counts as two septets (a 160-character text containing one `€` is 2 parts); 70 Chinese characters is 1 part and 71 is 2; an escape pair at a part boundary and a surrogate pair at a part boundary move whole to the next part.
  - `encodeSubmit`: `hellohello` to `+27838890001` gives exactly `0001000B917238880900F100000AE8329BFD4697D9EC37` with `tpduLength` 22; every encoded text, single and multi-part, GSM and UCS-2, decodes back to the same text when its SUBMIT user data is read by the decoder's alphabet routines (a round trip over at least 200 generated texts with a fixed seed); a number without "+" uses `0x81`; 11 parts is a failure; an invalid number is a failure.
  - `validNumber`, `parseSendReference`, `parseStorage` on good and bad input.
- [ ] **Step 2: Run `make app-test`.** Expected: `build/sms-tests` does not build.
- [ ] **Step 3: Implement `app/SmsModel.swift`.**
- [ ] **Step 4: Run `make app-test`.** Expected: both test programs pass (131 checks in the first, as before).
- [ ] **Step 5: Commit.**

```bash
git add app/SmsModel.swift tests/app/SmsModelTests.swift Makefile && git commit -m "feat: the SMS message model: PDUs, alphabets, multi-part assembly, with checks"
```

---

### Task 2: The AT port over USB interface 3

**Files:**
- Create: `app/AtPort.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:

```swift
enum AtError: Error, Equatable {
    case modemNotAttached      // no 2c7c:0801 on USB
    case noAtInterface         // the modem is there but has no interface 3 with two bulk endpoints
    case busy                  // another program holds the interface
    case io(Int32)             // an IOKit status from a transfer or the open
    case timeout               // no final result (or no prompt) in time
    case modem(String)         // the modem's own error line: "ERROR", "+CME ERROR: 10", "+CMS ERROR: 500"
}
final class AtPort {
    static func open() -> Result<AtPort, AtError>
    // Sends the line and returns the lines before the final "OK", without the echo and without empty lines.
    func command(_ line: String, timeout: TimeInterval = 3) -> Result<[String], AtError>
    // For AT+CMGS: sends `line`, waits for the "> " prompt, sends `payload` followed by Ctrl-Z (0x1A),
    // then returns the lines before the final "OK". If the prompt does not come, sends ESC (0x1B) and fails with .timeout.
    func send(_ line: String, afterPrompt payload: String, timeout: TimeInterval) -> Result<[String], AtError>
    func close()                // safe to call twice; deinit closes
}
```

  - Calls are synchronous and must not be made on the main thread; the class does not start threads of its own. Before each command it reads away whatever the modem sent unasked. Input is split on CR and LF; a final result is a line that is exactly `OK`, `ERROR`, or starts with `+CME ERROR:` or `+CMS ERROR:`.
  - In Swift the synchronous pipe call is `__sendIORequest(with:bytesTransferred:completionTimeout:)` (the header marks it refined for Swift). The old user-space harness, `harness/usb_transport.mm`, shows how this project finds and opens an interface with IOUSBHost.

- [ ] **Step 1: Implement `AtPort`.**
- [ ] **Step 2: Try it on the modem, read-only.** Build a scratch program (outside the repository) from `app/AtPort.swift` and a few lines of `main`, and run only these commands through it: `AT`, `ATI`, `AT+CPMS?`, `AT+CMGF?`, `AT+CMGL=4`. Expected: each returns its lines without the echo (`AT+CPMS?` gives one line starting `+CPMS: "ME"`). Also show: a command that cannot answer in time (`AT+COPS=?` with a timeout of 0.2 s is a search that takes many seconds: expect `.timeout`, then read-only `AT` works again after about 30 s or once the search has ended; if you would rather not start a search, use a 1 ms timeout on `ATI`); `open()` twice at once (the second is `.busy`, or say what it is); and that afterwards the driver is still up (`/Applications/RMNet.app/Contents/MacOS/RMNet status` shows `RMNetState = up`) and the owner's console still answers (`curl -s --noproxy '*' -X POST --data-binary 'AT' http://127.0.0.1:8730/at`).
- [ ] **Step 3: Run `make driver`** (the app target must build with the new file; no warning from `app/`). Commit.

```bash
git add app/AtPort.swift && git commit -m "feat: an AT port over the modem's spare USB interface"
```

---

### Task 3: The SMS service and the `sms` verbs

**Files:**
- Create: `app/SmsService.swift`
- Modify: `app/main.swift`, `README.md` (the app section: the three verbs)

**Interfaces:**
- Consumes: Task 1's model and `SmsServing`; Task 2's `AtPort` and `AtError`.
- Produces:
  - `final class SmsService: SmsServing` with an initializer taking no arguments. Each call opens the port, works, and closes it, also on failure. `list`: `AT+CMGF?` (and `AT+CMGF=0` if it reads 1), `AT+CMGL=4`, then the model. `delete`: `AT+CMGD=<index>` for each index, stopping at the first failure. `send`: checks the number and text with the model, then for each part `AT+CMGS=<tpduLength>` with the hex after the prompt, 60 s timeout, expecting `+CMGS:`; stops at the first failure with a message that says how many parts were sent. The concatenation reference is a random byte per message.
  - `func describe(_ error: AtError) -> String`: one sentence for each case (the modem is not attached; the modem has no spare AT port; another program is using the modem's spare AT port; the modem did not answer; the modem refused, with its error line; an I/O error with its code).
  - Verbs, with exit 0 on success, 1 on failure, 2 on wrong usage:
    - `RMNet sms list`: first line `sms: no messages` or `sms: <n> message(s)`; then for each message a line `[<indices joined by ",">] <unread|read> <sender> <yyyy-MM-dd HH:mm:ss in local time, or "no time">` (followed by ` (<k> part(s) missing)` when incomplete, or the line `[<indices>] not readable` for an unreadable entry), then the text, each of its lines indented by two spaces.
    - `RMNet sms list --json`: one JSON array; each element has `indices`, `unread`, `sender`, `time` (ISO 8601 or null), `text`, `missingParts`, `readable`.
    - `RMNet sms send <number> <text>` (the text is every remaining argument joined by spaces): `sms: sent to <number> in <n> part(s)`.
    - `RMNet sms delete <index> [<index> ...]`: `sms: deleted <n> stored part(s)`.
    - A failure prints `sms: <sentence>`.
  - The usage line becomes `usage: RMNet activate | deactivate | status [--json] | sms list [--json] | sms send <number> <text> | sms delete <index>...`.

- [ ] **Step 1: Implement the service and the verbs.**
- [ ] **Step 2: Run `make driver` and `make app-test`.** Then, from the unsigned build (`build/xcode/Debug/RMNet.app/Contents/MacOS/RMNet`), run `sms list` and `sms list --json` (read-only; the store is empty today, so expect `sms: no messages` and `[]`), `sms` with wrong usage (exit 2), and `status` (unchanged output). Do NOT run `sms send` or `sms delete`.
- [ ] **Step 3: README, then commit.**

```bash
git add app/SmsService.swift app/main.swift README.md && git commit -m "feat: the sms verbs: list, send, delete"
```

---

### Task 4: Messages in the window

**Files:**
- Create: `app/SmsView.swift`
- Modify: `app/StatusView.swift` (the window gets two tabs), `app/SmsModel.swift` and `tests/app/SmsModelTests.swift` (pure helpers for the view), `README.md`

**Interfaces:**
- Consumes: `SmsServing`, `SmsService`, the model.
- Produces:
  - The window has two tabs: `Driver` (everything it shows today, unchanged) and `Messages`.
  - `Messages`: a list, newest first, each row with the sender, the time, the text, a mark for unread, and "part missing" or "not readable" where that applies; a `Delete` button for the selected message, with a confirmation; `Refresh`; below, a `To` field, a text field, a line saying how many parts the text needs and in which alphabet (from the model), and `Send`, enabled only for a valid number and a non-empty text of at most 10 parts; one status line for the last result or failure. The list loads when the tab appears and every 15 s while it is shown; nothing touches the modem while the `Driver` tab is shown. Every call to the service runs off the main thread, one at a time; while one runs the buttons are disabled.
  - Pure helpers in the model, with checks: `func composeNote(_ text: String) -> String` (for example "1 part, GSM alphabet", "3 parts, Unicode", "too long: 12 parts, at most 10", "" for empty text), `func canSend(number: String, text: String) -> Bool`, `func rowTitle(_ m: SmsMessage, now: Date) -> String`.
  - The view model takes any `SmsServing`, so it can be driven by a fake.

- [ ] **Step 1: Write the failing checks** for the three helpers.
- [ ] **Step 2: Implement the helpers, the view model and the view.**
- [ ] **Step 3: Run `make app-test` and `make driver`.** Do not open the window (the controller prepares that for the owner).
- [ ] **Step 4: README, then commit.**

```bash
git add app/SmsView.swift app/StatusView.swift app/SmsModel.swift tests/app/SmsModelTests.swift README.md && git commit -m "feat: a Messages tab in the window"
```

---

### Task 5: On the modem (controller)

**Files:**
- Modify: `docs/driverkit-notes.md` (a section for the app's SMS), `README.md`, `docs/superpowers/plans/2026-11-13-core-and-harness-followups.md`

- [ ] **Step 1:** After the final review and its fix wave: from the unsigned build, `sms list` (empty store), wrong usage, `status` unchanged; the driver and the owner's console still work.
- [ ] **Step 2:** Ask the owner for permission to send test messages from the SIM to its own number (each part costs the carrier's fee), and which number. With it: one short Latin message, one Chinese message, one long message of three parts; `sms list` shows each as received, with the right text, sender and time; `sms delete` removes them; the store is empty again.
- [ ] **Step 3:** `scripts/install-driver.sh` and one modem reboot, so `/Applications/RMNet.app` carries SMS and the running driver matches the installed one; the usual checks.
- [ ] **Step 4:** Owner step, prepared only: open RMNet, look at the `Messages` tab.
- [ ] **Step 5:** Record the results and commit.

```bash
git add -A && git commit -m "docs: SMS in the app, on the modem"
```
