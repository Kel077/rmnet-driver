// The IMEI history: one entry for each change of the modem's IMEI made with RMNet (the SIM & Data screen's Change…,
// `RMNet imei set`), and for a change made otherwise that was recorded afterwards. Each entry has the time, the
// IMEI before and after, where the change came from, whether it succeeded, the module (its USB serial number, which
// an IMEI change does not touch, so that the history of a module plugged into several Macs can be told apart) and the
// sentence RMNet showed.
//
// The history is kept on this Mac only, in ~/Library/Application Support/RMNet/imei-history.jsonl: one JSON object a
// line, appended (never rewritten), readable by the owner only. A line that cannot be read is skipped and counted.
// Foundation only, so `make app-test` builds it (tests/app/ImeiHistoryTests.swift); nothing here talks to the modem.
import Foundation

/// Where a change came from: the window, the `imei set` verb, or another tool (recorded afterwards).
enum ImeiChangeSource: String, Codable, CaseIterable {
    case app, cli, other

    var words: String {
        switch self {
        case .app: return "RMNet window"
        case .cli: return "RMNet imei set"
        case .other: return "Another tool"
        }
    }
}

enum ImeiChangeResult: String, Codable {
    case succeeded, failed
}

struct ImeiHistoryEntry: Equatable {
    var time: Date
    var before: String?          // nil: not known
    var after: String            // the IMEI asked for
    var source: ImeiChangeSource
    var result: ImeiChangeResult
    var restart: Bool?           // the modem was to restart at once (nil: not known)
    var module: String?          // the module's USB serial number (nil: not known)
    var message: String?         // the sentence RMNet showed for the change
    var note: String?            // for an entry recorded afterwards: how it was made
}

/// The history as read: its entries in the order they were written, and how many lines could not be read.
struct ImeiHistory: Equatable {
    var entries: [ImeiHistoryEntry]
    var skippedLines: Int

    /// Newest first (an entry recorded afterwards goes where its time puts it); equal times keep the order written.
    var newestFirst: [ImeiHistoryEntry] {
        entries.enumerated().sorted { a, b in
            a.element.time != b.element.time ? a.element.time > b.element.time : a.offset > b.offset
        }.map { $0.element }
    }
}

// MARK: - One line of the file

/// "2026-11-22T02:57:14-05:00": the time with the Mac's offset at the time, to the second.
private func isoFormatter() -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    f.formatOptions = [.withInternetDateTime]
    return f
}

private func isoParser(_ text: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    if let d = f.date(from: text) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: text)
}

func imeiHistoryTimeText(_ date: Date) -> String { isoFormatter().string(from: date) }

/// The entry as a JSON object: every key is always there, a value not known is null.
func imeiHistoryObject(_ e: ImeiHistoryEntry) -> [String: Any] {
    func orNull<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }
    return ["time": imeiHistoryTimeText(e.time), "before": orNull(e.before), "after": e.after,
            "source": e.source.rawValue, "result": e.result.rawValue, "restart": orNull(e.restart),
            "module": orNull(e.module), "message": orNull(e.message), "note": orNull(e.note)]
}

/// One line of the file (no newline), keys sorted.
func imeiHistoryLine(_ e: ImeiHistoryEntry) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: imeiHistoryObject(e), options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// A line read back; nil when it is not an entry (not JSON, no valid time, no `after`, an unknown source or result).
func imeiHistoryEntry(line: String) -> ImeiHistoryEntry? {
    guard let data = line.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let time = (o["time"] as? String).flatMap(isoParser),
          let after = o["after"] as? String,
          let source = (o["source"] as? String).flatMap(ImeiChangeSource.init(rawValue:)),
          let result = (o["result"] as? String).flatMap(ImeiChangeResult.init(rawValue:)) else { return nil }
    return ImeiHistoryEntry(time: time, before: o["before"] as? String, after: after, source: source, result: result,
                            restart: o["restart"] as? Bool, module: o["module"] as? String,
                            message: o["message"] as? String, note: o["note"] as? String)
}

/// The file's text read back: blank lines ignored, any other line that is not an entry skipped and counted.
func parseImeiHistory(_ text: String) -> ImeiHistory {
    var entries: [ImeiHistoryEntry] = []
    var skipped = 0
    for raw in text.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if let e = imeiHistoryEntry(line: line) { entries.append(e) } else { skipped += 1 }
    }
    return ImeiHistory(entries: entries, skippedLines: skipped)
}

// MARK: - The file

/// Where the history is kept and how it is read and added to. The app and the verbs use ImeiHistoryFile; the tests
/// use a file of their own.
protocol ImeiHistoryKeeping {
    /// The file's path, as shown to the owner.
    var location: String { get }
    /// The history; no file yet is an empty history. A failure is a sentence.
    func load() -> Result<ImeiHistory, ModemFailure>
    /// Adds one entry at the end; nil on success, else why not.
    func append(_ entry: ImeiHistoryEntry) -> String?
}

final class ImeiHistoryFile: ImeiHistoryKeeping {
    let url: URL

    init(url: URL) { self.url = url }

    /// ~/Library/Application Support/RMNet/imei-history.jsonl, for the window and the verbs alike (the app is not
    /// sandboxed, so both see the same file).
    static var standard: ImeiHistoryFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ImeiHistoryFile(url: base.appendingPathComponent("RMNet/imei-history.jsonl"))
    }

    var location: String { url.path }

    func load() -> Result<ImeiHistory, ModemFailure> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .success(ImeiHistory(entries: [], skippedLines: 0)) }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            return .success(parseImeiHistory(text))
        } catch {
            return .failure(ModemFailure(message: "The IMEI history could not be read (\(url.path))."))
        }
    }

    /// One write(2) of the line and its newline to the file opened for appending (created owner-only, its folder
    /// too), so a change recorded by the window and one by a verb at the same moment do not mix their lines.
    func append(_ entry: ImeiHistoryEntry) -> String? {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return "The IMEI history's folder could not be made (\(folder.path))."
        }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return "The IMEI history could not be opened (\(url.path))." }
        defer { close(fd) }
        let bytes = Array((imeiHistoryLine(entry) + "\n").utf8)
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return written == bytes.count ? nil : "The IMEI history could not be written (\(url.path))."
    }
}

/// What a change needs to record itself: the file, the attached module's serial number and the clock.
struct ImeiHistoryRecorder {
    let keeper: ImeiHistoryKeeping
    let module: () -> String?
    var now: () -> Date = { Date() }
}

// MARK: - Entries from changes

/// The entry for a change asked for (`after`), from the IMEI known before it and the service's answer; nil when the
/// modem already had that IMEI (nothing was written). A failure is recorded as failed with its sentence: it may
/// still have changed the IMEI (the sentence then says so).
func imeiHistoryEntry(after: String, before: String?, restart: Bool, outcome: Result<ImeiChange, ModemFailure>,
                      source: ImeiChangeSource, module: String?, at time: Date) -> ImeiHistoryEntry? {
    switch outcome {
    case .success(.unchanged):
        return nil
    case .success(let change):
        let was: String
        switch change {
        case .rebooting(let b, _), .setTakesEffectAfterRestart(let b, _): was = b
        case .unchanged(let b): was = b
        }
        return ImeiHistoryEntry(time: time, before: was, after: after, source: source, result: .succeeded,
                                restart: restart, module: module, message: imeiSentence(change), note: nil)
    case .failure(let failure):
        return ImeiHistoryEntry(time: time, before: before, after: after, source: source, result: .failed,
                                restart: restart, module: module, message: failure.message, note: nil)
    }
}

// MARK: - What `RMNet imei history` prints

private let localTimeText: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.calendar = Calendar(identifier: .gregorian)
    f.timeZone = .current
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

/// `imei history`: a headline, then each entry newest first on one line (time in the Mac's time zone, before and
/// after, the result, where it came from, the module), its sentence or note indented below; then where it is kept.
func imeiHistoryLines(_ history: ImeiHistory, location: String) -> [String] {
    var lines: [String] = []
    let n = history.entries.count
    if n == 0 {
        lines.append("imei: no IMEI changes recorded on this Mac")
    } else {
        lines.append("imei: \(n) IMEI change\(n == 1 ? "" : "s") recorded on this Mac, newest first")
    }
    for e in history.newestFirst {
        var parts = ["\(localTimeText.string(from: e.time))", "\(e.before ?? "unknown") -> \(e.after)",
                     e.result.rawValue, e.source.rawValue]
        if let m = e.module { parts.append("module \(m)") }
        lines.append(parts.joined(separator: "  "))
        for text in [e.note, e.message].compactMap({ $0 }) where !text.isEmpty {
            lines.append("  \(text)")
        }
    }
    if history.skippedLines > 0 {
        lines.append("imei: \(history.skippedLines) line\(history.skippedLines == 1 ? "" : "s") of the history could not be read and \(history.skippedLines == 1 ? "was" : "were") skipped")
    }
    lines.append("imei: kept in \(location)")
    return lines
}

/// `imei history --json`: `path`, `skippedLines` and `entries` (newest first; each with every key, null when not
/// known).
func imeiHistoryJSON(_ history: ImeiHistory, location: String) -> [String: Any] {
    ["path": location, "skippedLines": history.skippedLines, "entries": history.newestFirst.map(imeiHistoryObject)]
}

// MARK: - What the SIM & Data screen shows

/// A row of the screen's history: the change in words, and whether Change Back… is offered for it (a change that
/// succeeded, on the module attached (or one not known on either side), whose IMEI before is known and is not the
/// one the modem has now).
struct ImeiHistoryRow: Equatable {
    let entry: ImeiHistoryEntry
    let otherModule: Bool        // made on another module than the one attached
    let canChangeBack: Bool
}

func imeiHistoryRows(_ history: ImeiHistory, currentImei: String?, currentModule: String?) -> [ImeiHistoryRow] {
    history.newestFirst.map { e in
        let other = currentModule != nil && e.module != nil && e.module != currentModule
        let back = !other && e.result == .succeeded && e.before.map { imeiProblem($0) == nil && $0 != currentImei } == true
        return ImeiHistoryRow(entry: e, otherModule: other, canChangeBack: back)
    }
}
