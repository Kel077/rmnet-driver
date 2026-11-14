// Tests for the answer logic of app/AtPort.swift (AtAnswerCollector): scripted byte sequences, each
// fed whole, byte by byte, and split inside every CR LF. Built with swiftc by `make app-test`; needs
// no Xcode project and no hardware (nothing here opens the port).
// Stops at the first failure, prints which check failed and exits 1.
import Foundation

var checks = 0

func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if !ok {
        print("FAIL: \(name)")
        let d = detail()
        if !d.isEmpty { print("  \(d)") }
        exit(1)
    }
}

// The ways the same bytes may arrive in transfers.
func chunkings(_ bytes: [UInt8]) -> [(String, [[UInt8]])] {
    var splitInCRLF: [[UInt8]] = [[]]
    for b in bytes {
        splitInCRLF[splitInCRLF.count - 1].append(b)
        if b == 0x0D { splitInCRLF.append([]) }  // a transfer ends between CR and LF
    }
    return [
        ("whole", [bytes]),
        ("byte by byte", bytes.map { [$0] }),
        ("split inside CR LF", splitInCRLF),
    ]
}

func outcome(_ input: String, echo: String?, prompt: Bool = false, _ chunks: [[UInt8]]) -> AtAnswerCollector.Outcome {
    var c = AtAnswerCollector(echo: echo, prompt: prompt)
    for chunk in chunks { c.feed(chunk) }
    return c.outcome
}

// Feeds `input` in every chunking and expects `want` from each.
func expect(_ input: String, echo: String?, prompt: Bool = false, _ want: AtAnswerCollector.Outcome, _ name: String) {
    for (how, chunks) in chunkings(Array(input.utf8)) {
        let got = outcome(input, echo: echo, prompt: prompt, chunks)
        check(got == want, "\(name) (\(how))", "want \(want), got \(got)")
    }
}

// The result after a payload, fed in every chunking.
func expectAfterPayload(_ input: String, payload: String, _ want: AtAnswerCollector.Outcome, _ name: String) {
    for (how, chunks) in chunkings(Array(input.utf8)) {
        var c = AtAnswerCollector(afterPayload: payload)
        for chunk in chunks { c.feed(chunk) }
        check(c.outcome == want, "\(name) (\(how))", "want \(want), got \(c.outcome)")
    }
}

// Successive answers to the echo probe's "AT", each collected without a gate (as open() does) in
// every chunking; `want` is the probe's step after each answer.
func expectProbe(_ answers: [String], _ want: [AtEchoProbe.Step], _ name: String) {
    for index in 0..<3 {
        var probe = AtEchoProbe()
        var steps: [AtEchoProbe.Step] = []
        var how = ""
        for answer in answers {
            let (h, chunks) = chunkings(Array(answer.utf8))[index]
            how = h
            var c = AtAnswerCollector(echo: nil)
            for chunk in chunks { c.feed(chunk) }
            steps.append(probe.record(c.outcome))
        }
        check(steps == want, "probe: \(name) (\(how))", "want \(want), got \(steps)")
    }
}

@main
struct AtPortTests {
    static func main() {
        // --- an echoed command and its answer -----------------------------------------------------
        expect("AT+CPMS?\r\r\n+CPMS: \"ME\",0,255,\"ME\",0,255,\"ME\",0,255\r\n+X: second\r\n\r\nOK\r\n",
               echo: "AT+CPMS?", .answer(["+CPMS: \"ME\",0,255,\"ME\",0,255,\"ME\",0,255", "+X: second"]),
               "echoed command, two-line answer")
        expect("AT\r\r\nOK\r\n", echo: "AT", .answer([]), "echoed command, empty answer")
        expect("AT+CPMS?\r\r\n+CPMS: 1\r\n", echo: "AT+CPMS?", .waiting, "no final result yet")

        // --- the echo is the gate (a late answer of an earlier command) -------------------------------
        let late = "\r\n+CMGS: 5\r\n\r\nOK\r\n"
        let listing = "AT+CMGL=4\r\r\n+CMGL: 1,0,,23\r\n0791448720003023240DD0E474D81C0EBB010000111011315214000BE474D81C0EBB5DE3771B\r\n\r\nOK\r\n"
        expect(late + listing, echo: "AT+CMGL=4",
               .answer(["+CMGL: 1,0,,23", "0791448720003023240DD0E474D81C0EBB010000111011315214000BE474D81C0EBB5DE3771B"]),
               "late +CMGS: 5 / OK before the echo neither ends nor enters the listing")
        expect(late, echo: "AT+CMGL=4", .waiting, "a late OK alone does not end the answer")
        expect("\r\n+CMS ERROR: 500\r\n" + listing.replacingOccurrences(of: "+CMGL: 1,0,,23\r\n", with: ""),
               echo: "AT+CMGL=4",
               .answer(["0791448720003023240DD0E474D81C0EBB010000111011315214000BE474D81C0EBB5DE3771B"]),
               "a late error before the echo is discarded")
        expect("\r\n+CMTI: \"ME\",0\r\nATI\r\r\nQuectel\r\nRM520N-GL\r\n\r\nOK\r\n", echo: "ATI",
               .answer(["Quectel", "RM520N-GL"]), "an unsolicited line before the echo is discarded")

        // --- final results are exact lines ---------------------------------------------------------
        expect("AT+X\r\r\n+X: OK then\r\nNO ERROR\r\nOKAY\r\n OK\r\n", echo: "AT+X",
               .answer(["+X: OK then", "NO ERROR", "OKAY"]),
               "OK or ERROR inside other text does not end the answer")
        expect("AT+CMGL=4\r\r\n+CMS ERROR: 500\r\n", echo: "AT+CMGL=4", .modemError("+CMS ERROR: 500"), "+CMS ERROR ends it")
        expect("AT+CPMS?\r\r\n+CME ERROR: 10\r\n", echo: "AT+CPMS?", .modemError("+CME ERROR: 10"), "+CME ERROR ends it")
        expect("AT+X\r\r\nERROR\r\n", echo: "AT+X", .modemError("ERROR"), "ERROR ends it")
        expect("AT\r\r\nOK\r\n+CMTI: \"ME\",1\r\n", echo: "AT", .answer([]), "bytes after the final result are ignored")

        // --- the prompt ----------------------------------------------------------------------------
        expect("AT+CMGS=23\r\r\n> ", echo: "AT+CMGS=23", prompt: true, .prompt, "prompt after the echo")
        expect("\r\n> ", echo: "AT+CMGS=23", prompt: true, .waiting, "a prompt before the echo is not taken")
        expect("\r\n> \r\nAT+CMGS=23\r\r\n> ", echo: "AT+CMGS=23", prompt: true, .prompt,
               "a stale prompt line, then the echo and the prompt")
        expect("AT+CMGS=23\r\r\n+CMS ERROR: 304\r\n", echo: "AT+CMGS=23", prompt: true,
               .modemError("+CMS ERROR: 304"), "an error instead of the prompt")
        expect("AT+CMGS=23\r\r\nOK\r\n", echo: "AT+CMGS=23", prompt: true, .waiting, "OK is not a prompt")

        // --- the result after the payload: no gate, the payload's echo skipped if it comes ---------
        let pdu = "0011000B916407281553F80000AA0AE8329BFD4697D9EC37"
        expectAfterPayload(pdu + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu, .answer(["+CMGS: 7"]),
                           "payload echoed whole with Ctrl-Z, then +CMGS: 7, OK")
        expectAfterPayload("\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu, .answer(["+CMGS: 7"]),
                           "payload not echoed at all")
        expectAfterPayload(String(pdu.prefix(20)) + "\r\n" + String(pdu.dropFirst(20)) + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n",
                           payload: pdu, .answer(["+CMGS: 7"]), "payload echo broken by a line end: the pieces are skipped")
        expectAfterPayload(String(pdu.prefix(9)) + "\r\n" + String(pdu.dropFirst(9).prefix(15)) + "\r\n"
                           + String(pdu.dropFirst(24)) + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n",
                           payload: pdu, .answer(["+CMGS: 7"]), "payload echo in three pieces")
        expectAfterPayload("\r\n+CMTI: \"ME\",0\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu,
                           .answer(["+CMTI: \"ME\",0", "+CMGS: 7"]),
                           "an unsolicited line before +CMGS: 7 is an answer line (the caller looks for +CMGS:)")
        expectAfterPayload("> " + pdu + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n", payload: pdu, .answer(["+CMGS: 7"]),
                           "payload echo on the prompt's line")
        expectAfterPayload(pdu + "\u{1A}\r\n+CMS ERROR: 500\r\n", payload: pdu, .modemError("+CMS ERROR: 500"),
                           "payload echo, then an error")
        expectAfterPayload("\r\n+CMS ERROR: 500\r\n", payload: pdu, .modemError("+CMS ERROR: 500"),
                           "no payload echo, an error")

        // --- a port that does not echo ---------------------------------------------------------------
        expect("\r\nQuectel\r\nRM520N-GL\r\n\r\nOK\r\n", echo: nil, .answer(["Quectel", "RM520N-GL"]), "no echo: answer")
        expect("\r\n+CME ERROR: 10\r\n", echo: nil, .modemError("+CME ERROR: 10"), "no echo: error")
        expect("\r\n> ", echo: nil, prompt: true, .prompt, "no echo: prompt")

        // --- learning whether the port echoes: two agreeing probes -------------------------------
        let echoAnswer = "AT\r\r\nOK\r\n"
        let silentAnswer = "\r\nOK\r\n"
        expectProbe([echoAnswer], [.probeAgain], "one echo answer does not settle")
        expectProbe([echoAnswer, echoAnswer], [.probeAgain, .settled(echoes: true)], "echo: two agreeing probes")
        expectProbe([silentAnswer, silentAnswer], [.probeAgain, .settled(echoes: false)], "no echo: two agreeing probes")
        expectProbe(["\r\n+CMGS: 5\r\n\r\nOK\r\n" + echoAnswer, echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "a late +CMGS: 5 / OK before the probe's echo does not settle on no echo")
        expectProbe(["\r\nOK\r\n" + echoAnswer, echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "a late lone OK before the probe's echo does not settle on no echo")
        expectProbe(["\r\n+CMS ERROR: 500\r\n", echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "a late +CMS ERROR: 500 before the probe makes it probe again, not fail")
        expectProbe([silentAnswer, echoAnswer, silentAnswer], [.probeAgain, .probeAgain, .probeAgain],
                    "disagreeing probes do not settle")
        expectProbe([echoAnswer, "\r\nERROR\r\n", echoAnswer, echoAnswer],
                    [.probeAgain, .probeAgain, .probeAgain, .settled(echoes: true)],
                    "an answer that does not count breaks the run")
        expectProbe(["AT\r\r\n+X: 1\r\n\r\nOK\r\n", echoAnswer], [.probeAgain, .probeAgain],
                    "an echo with more lines does not count")

        // --- the ESC open() writes first (a modem left at the "> " prompt) -------------------------
        expect("\u{1B}AT\r\r\nOK\r\n", echo: "AT", .answer([]),
               "an echoed ESC on the line of the AT echo: the echo is still found")
        expect("\u{1B}\r\nAT\r\r\nOK\r\n", echo: "AT", .answer([]),
               "an echoed ESC on a line of its own is dropped before the echo")
        expect("> \u{1B}\r\n\r\nOK\r\nAT\r\r\nOK\r\n", echo: "AT", .answer([]),
               "the prompt, the ESC and the modem's OK to it come before the echo and are discarded")
        expectProbe(["\u{1B}AT\r\r\nOK\r\n", echoAnswer], [.probeAgain, .settled(echoes: true)],
                    "an echoed ESC before the first AT echo still counts as an echo")
        expectProbe(["\u{1B}\r\nAT\r\r\nOK\r\n", echoAnswer], [.probeAgain, .settled(echoes: true)],
                    "an echoed ESC on a line of its own is dropped; the AT echo counts")
        expectProbe(["\u{1B}\r\n\r\nOK\r\n", "AT\r\r\nOK\r\n", echoAnswer],
                    [.probeAgain, .probeAgain, .settled(echoes: true)],
                    "the modem's OK to the ESC, read as a silent answer, does not settle on no echo")

        print("at-test: \(checks) checks passed")
    }
}
