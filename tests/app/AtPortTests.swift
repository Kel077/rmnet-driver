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

        // --- the payload's echo, then the result ---------------------------------------------------
        let pdu = "0011000B916407281553F80000AA0AE8329BFD4697D9EC37"
        expect(pdu + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n", echo: pdu, .answer(["+CMGS: 7"]),
               "payload echo with Ctrl-Z, then +CMGS: 7, OK")
        expect("\r\nOK\r\n" + pdu + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n", echo: pdu, .answer(["+CMGS: 7"]),
               "a stale OK before the payload echo is discarded")
        expect("> " + pdu + "\u{1A}\r\n+CMGS: 7\r\n\r\nOK\r\n", echo: pdu, .answer(["+CMGS: 7"]),
               "payload echo on the prompt's line")
        expect(pdu + "\u{1A}\r\n+CMS ERROR: 500\r\n", echo: pdu, .modemError("+CMS ERROR: 500"),
               "payload echo, then an error")

        // --- a port that does not echo ---------------------------------------------------------------
        expect("\r\nQuectel\r\nRM520N-GL\r\n\r\nOK\r\n", echo: nil, .answer(["Quectel", "RM520N-GL"]), "no echo: answer")
        expect("\r\n+CME ERROR: 10\r\n", echo: nil, .modemError("+CME ERROR: 10"), "no echo: error")
        expect("\r\n> ", echo: nil, prompt: true, .prompt, "no echo: prompt")

        // --- learning whether the port echoes -----------------------------------------------------
        check(AtAnswerCollector.portEchoes(answerToAT: ["AT"]), "portEchoes: echo line")
        check(!AtAnswerCollector.portEchoes(answerToAT: []), "portEchoes: nothing before OK")

        print("at-test: \(checks) checks passed")
    }
}
