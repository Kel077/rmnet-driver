// Tests for app/ImeiHistory.swift: an entry's line and its reading back (also a line that is not one), the file in a
// temporary folder (no file, appending, its permissions, a broken line among good ones), the entries made from the
// service's outcomes, the order newest first, what `RMNet imei history` prints with and without --json, and the SIM &
// Data screen's rows (which offer Change Back…). Built with swiftc by `make app-test` from app/ModemNetwork.swift,
// app/ModemSettings.swift, app/ImeiHistory.swift and this file; no AppKit, no modem. The IMEIs are made-up numbers
// with a valid check digit (000000000000000, 123456789012347), never a real modem's.
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

func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) {
    check(got == want, name, "got \(got)\nwant \(want)")
}

let zeros = "000000000000000"
let counting = "123456789012347"
let t0 = Date(timeIntervalSince1970: 1_795_000_000)   // a fixed time

func entry(_ before: String?, _ after: String, at offset: TimeInterval = 0, source: ImeiChangeSource = .app,
           result: ImeiChangeResult = .succeeded, module: String? = "f00dcafe") -> ImeiHistoryEntry {
    ImeiHistoryEntry(time: t0.addingTimeInterval(offset), before: before, after: after, source: source, result: result,
                     restart: true, module: module, message: "IMEI set to \(after); the modem is restarting.", note: nil)
}

func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("rmnet-imei-history-tests-\(getpid())-\(UUID().uuidString)")
        .appendingPathComponent("nested/imei-history.jsonl")
}

@main
struct ImeiHistoryTests {
    static func main() {
        check(imeiProblem(zeros) == nil && imeiProblem(counting) == nil, "the made-up IMEIs have valid check digits")
        lines()
        file()
        entriesFromOutcomes()
        order()
        printed()
        screenRows()
        print("ImeiHistory: \(checks) checks passed")
    }

    // An entry's line has every key (null when not known), sorted; read back it is the same entry.
    static func lines() {
        let e = entry(zeros, counting)
        let line = imeiHistoryLine(e)
        check(!line.contains("\n"), "line: one line")
        check(line.hasPrefix("{\"after\":\"\(counting)\",\"before\":\"\(zeros)\""), "line: keys sorted", line)
        equal(imeiHistoryEntry(line: line), e, "line: read back")

        var unknown = e
        unknown.before = nil
        unknown.module = nil
        unknown.restart = nil
        unknown.message = nil
        let nullLine = imeiHistoryLine(unknown)
        check(nullLine.contains("\"before\":null") && nullLine.contains("\"module\":null")
              && nullLine.contains("\"note\":null"), "line: a value not known is null", nullLine)
        equal(imeiHistoryEntry(line: nullLine), unknown, "line: nulls read back as nil")

        // The time keeps its offset; another offset reads as the same instant.
        let written = imeiHistoryTimeText(t0)
        check(written.count == 25 || written.hasSuffix("Z"), "time: ISO 8601 to the second with an offset", written)
        let other = "{\"after\":\"\(counting)\",\"before\":null,\"module\":null,\"result\":\"succeeded\",\"source\":\"other\","
            + "\"time\":\"2026-11-22T02:57:14-05:00\",\"note\":\"recorded afterwards\"}"
        let read = imeiHistoryEntry(line: other)
        equal(read?.time, ISO8601DateFormatter().date(from: "2026-11-22T07:57:14Z"), "time: an offset read back")
        equal(read?.source, .other, "line: source other")
        equal(read?.note, "recorded afterwards", "line: note")

        // Not entries.
        for bad in ["", "not json", "[]", "{\"after\":\"\(counting)\"}",
                    "{\"after\":\"\(counting)\",\"result\":\"succeeded\",\"source\":\"app\",\"time\":\"yesterday\"}",
                    "{\"after\":\"\(counting)\",\"result\":\"maybe\",\"source\":\"app\",\"time\":\"2026-11-22T02:57:14Z\"}",
                    "{\"after\":\"\(counting)\",\"result\":\"failed\",\"source\":\"phone\",\"time\":\"2026-11-22T02:57:14Z\"}",
                    "{\"after\":15,\"result\":\"failed\",\"source\":\"app\",\"time\":\"2026-11-22T02:57:14Z\"}"] {
            check(imeiHistoryEntry(line: bad) == nil, "line: not an entry: \(bad)")
        }

        let text = imeiHistoryLine(entry(zeros, counting)) + "\n\n  \nbroken line\n" + imeiHistoryLine(entry(counting, zeros, at: 60)) + "\n"
        let h = parseImeiHistory(text)
        equal(h.entries.count, 2, "parse: two entries")
        equal(h.skippedLines, 1, "parse: the broken line skipped and counted, blank lines ignored")
    }

    // The file: none yet is an empty history; appending makes the folder and the file (owner only), adds a line each.
    static func file() {
        let url = temporaryFile()
        let keeper = ImeiHistoryFile(url: url)
        equal(keeper.location, url.path, "file: location")
        equal(try? keeper.load().get(), ImeiHistory(entries: [], skippedLines: 0), "file: no file is an empty history")

        let first = entry(zeros, counting)
        let second = entry(counting, zeros, at: 3600, source: .cli, result: .failed)
        check(keeper.append(first) == nil, "file: first append")
        check(keeper.append(second) == nil, "file: second append")
        equal(try? keeper.load().get().entries, [first, second], "file: both entries, in the order written")

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        equal((attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600, "file: owner only")
        let folder = try? FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        equal((folder?[.posixPermissions] as? NSNumber)?.intValue, 0o700, "file: its folder owner only")

        // A line broken by hand does not lose the others.
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write("{\"half\":\n".data(using: .utf8)!)
            handle.closeFile()
        }
        let third = entry(nil, zeros, at: 7200, source: .other)
        check(keeper.append(third) == nil, "file: append after a broken line")
        let h = try? keeper.load().get()
        equal(h?.entries, [first, second, third], "file: entries around a broken line")
        equal(h?.skippedLines, 1, "file: the broken line counted")

        // A file that cannot be written says so.
        let blocked = ImeiHistoryFile(url: URL(fileURLWithPath: "/dev/null/imei-history.jsonl"))
        check(blocked.append(first) != nil, "file: a folder that cannot be made is a sentence")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent())
    }

    // The service's outcome as an entry: nothing for an IMEI already set; the before from the service on success,
    // the one known before on failure.
    static func entriesFromOutcomes() {
        check(imeiHistoryEntry(after: counting, before: counting, restart: true, outcome: .success(.unchanged(counting)),
                               source: .app, module: nil, at: t0) == nil, "outcome: unchanged is not recorded")

        let restarted = imeiHistoryEntry(after: counting, before: nil, restart: true,
                                         outcome: .success(.rebooting(before: zeros, after: counting)),
                                         source: .cli, module: "f00dcafe", at: t0)
        equal(restarted, ImeiHistoryEntry(time: t0, before: zeros, after: counting, source: .cli, result: .succeeded,
                                          restart: true, module: "f00dcafe",
                                          message: "IMEI set to \(counting); the modem is restarting.", note: nil),
              "outcome: restarting")

        let later = imeiHistoryEntry(after: counting, before: zeros, restart: false,
                                     outcome: .success(.setTakesEffectAfterRestart(before: zeros, after: counting)),
                                     source: .app, module: nil, at: t0)
        equal(later?.result, .succeeded, "outcome: after the next restart succeeded")
        equal(later?.restart, false, "outcome: no restart asked")
        check(later?.message?.contains("next restart") == true, "outcome: its sentence")

        let failed = imeiHistoryEntry(after: counting, before: zeros, restart: true,
                                      outcome: .failure(ModemFailure(message: "The IMEI was not changed. ERROR")),
                                      source: .app, module: "f00dcafe", at: t0)
        equal(failed?.result, .failed, "outcome: failure recorded as failed")
        equal(failed?.before, zeros, "outcome: a failure keeps the IMEI known before")
        equal(failed?.message, "The IMEI was not changed. ERROR", "outcome: a failure's sentence")
    }

    // Newest first by time; an entry recorded afterwards goes where its time puts it; equal times newest written first.
    static func order() {
        let old = entry(zeros, counting, at: 0, source: .other)
        let new = entry(counting, zeros, at: 100)
        let backfilled = entry(nil, zeros, at: 50, source: .other)
        let same = entry(zeros, counting, at: 100, source: .cli)
        let h = ImeiHistory(entries: [old, new, backfilled, same], skippedLines: 0)
        equal(h.newestFirst, [same, new, backfilled, old], "order: newest first")
    }

    // What `imei history` prints.
    static func printed() {
        let none = imeiHistoryLines(ImeiHistory(entries: [], skippedLines: 0), location: "/tmp/h.jsonl")
        equal(none, ["imei: no IMEI changes recorded on this Mac", "imei: kept in /tmp/h.jsonl"], "print: empty")

        var other = entry(zeros, counting, at: 0, source: .other, module: "f00dcafe")
        other.message = nil
        other.note = "Sent as AT+EGMR=1,7 by another tool; recorded afterwards."
        var failed = entry(counting, zeros, at: 60, result: .failed, module: nil)
        failed.message = "The IMEI was not changed. ERROR"
        let lines = imeiHistoryLines(ImeiHistory(entries: [other, failed], skippedLines: 2), location: "/tmp/h.jsonl")
        equal(lines.count, 7, "print: headline, two entries with a line each, skipped, location")
        equal(lines[0], "imei: 2 IMEI changes recorded on this Mac, newest first", "print: headline")
        check(lines[1].hasSuffix("  \(counting) -> \(zeros)  failed  app"), "print: newest first, no module", lines[1])
        equal(lines[2], "  The IMEI was not changed. ERROR", "print: its sentence indented")
        check(lines[3].hasSuffix("  \(zeros) -> \(counting)  succeeded  other  module f00dcafe"), "print: module", lines[3])
        equal(lines[4], "  Sent as AT+EGMR=1,7 by another tool; recorded afterwards.", "print: note")
        equal(lines[5], "imei: 2 lines of the history could not be read and were skipped", "print: skipped")
        equal(lines[6], "imei: kept in /tmp/h.jsonl", "print: location")
        let one = imeiHistoryLines(ImeiHistory(entries: [other], skippedLines: 1), location: "x")
        equal(one[0], "imei: 1 IMEI change recorded on this Mac, newest first", "print: one change")
        equal(one[3], "imei: 1 line of the history could not be read and was skipped", "print: one skipped")

        let json = imeiHistoryJSON(ImeiHistory(entries: [other, failed], skippedLines: 2), location: "/tmp/h.jsonl")
        check(JSONSerialization.isValidJSONObject(json), "json: valid")
        equal(json["path"] as? String, "/tmp/h.jsonl", "json: path")
        equal(json["skippedLines"] as? Int, 2, "json: skippedLines")
        let entries = json["entries"] as? [[String: Any]] ?? []
        equal(entries.count, 2, "json: entries")
        equal(entries.first?["after"] as? String, zeros, "json: newest first")
        equal(Set(entries.first?.keys.map { $0 } ?? []),
              ["time", "before", "after", "source", "result", "restart", "module", "message", "note"], "json: every key")
        check(entries.first?["module"] is NSNull, "json: unknown module is null")
    }

    // The screen's rows: Change Back… only for a change that succeeded on the attached module, back to a valid IMEI
    // other than the current one.
    static func screenRows() {
        let mine = entry(zeros, counting, at: 0, module: "f00dcafe")
        let elsewhere = entry(zeros, counting, at: 10, module: "0badbeef")
        let failed = entry(zeros, counting, at: 20, result: .failed, module: "f00dcafe")
        let unknownBefore = entry(nil, counting, at: 30, module: "f00dcafe")
        let noModule = entry(zeros, counting, at: 40, module: nil)
        let h = ImeiHistory(entries: [mine, elsewhere, failed, unknownBefore, noModule], skippedLines: 0)

        let rows = imeiHistoryRows(h, currentImei: counting, currentModule: "f00dcafe")
        equal(rows.map { $0.entry }, h.newestFirst, "rows: newest first")
        equal(rows.map { $0.canChangeBack }, [true, false, false, false, true], "rows: change back offered")
        equal(rows.map { $0.otherModule }, [false, false, false, true, false], "rows: other module")

        let backNow = imeiHistoryRows(h, currentImei: zeros, currentModule: "f00dcafe")
        check(backNow.allSatisfy { !$0.canChangeBack }, "rows: not back to the IMEI the modem has now")
        let noneAttached = imeiHistoryRows(h, currentImei: counting, currentModule: nil)
        check(noneAttached.allSatisfy { !$0.otherModule }, "rows: no module attached, none is another")
    }
}
