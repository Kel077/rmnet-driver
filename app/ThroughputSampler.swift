// The connection's throughput as the window draws it: the driver's byte counters (its RMNetRxBytes and
// RMNetTxBytes registry properties, published once a second; never the AT port) read once a second while the
// Overview or the Network screen is shown and the window can be seen (WindowPolls, ShellModel.swift), turned into
// download and upload rates over the last 120 reads. Foundation only, with the counters and the clock given as
// closures, so `make app-test` tests it (tests/app/ThroughputSamplerTests.swift).
import Combine
import Foundation

/// One rate: the bits a second moved between two reads, at the later one's time. Points of one series are drawn
/// joined; a new series begins after a counter that went down (a driver restart), a read with no counters, a gap
/// of more than `maxGap` or a clock that went back.
struct ThroughputPoint: Equatable {
    let at: Date
    let downBitsPerSecond: Double
    let upBitsPerSecond: Double
    let series: Int
}

/// RMNetRxBytes and RMNetTxBytes of the driver's registry properties (readDriverProperties), as unsigned decimal
/// numbers; nil when the driver is not attached, or either is missing or not such a number.
func driverByteCounters(_ properties: [String: String]?) -> (rx: UInt64, tx: UInt64)? {
    guard let p = properties, let rx = p["RMNetRxBytes"].flatMap({ UInt64($0) }),
          let tx = p["RMNetTxBytes"].flatMap({ UInt64($0) }) else { return nil }
    return (rx, tx)
}

/// A rate in words: "950 bit/s", "8.5 kbit/s", "850 kbit/s", "1.2 Mbit/s", "190 Mbit/s", "2.5 Gbit/s": whole bits
/// a second, then one decimal under 10 (none when it is 0) and none from 10; a value that rounds to 1000 takes the
/// next unit. Not a number, or not above 0: "0 bit/s".
func bitRateText(_ bitsPerSecond: Double) -> String {
    guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "0 bit/s" }
    let units = ["bit/s", "kbit/s", "Mbit/s", "Gbit/s"]
    var value = bitsPerSecond
    for (i, unit) in units.enumerated() {
        let rounded: Double
        let text: String
        if i > 0 && value < 9.95 {
            rounded = (value * 10).rounded() / 10
            text = rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        } else {
            rounded = value.rounded()
            text = String(Int(rounded))
        }
        if rounded < 1000 || i == units.count - 1 { return "\(text) \(unit)" }
        value /= 1000
    }
    return "0 bit/s"
}

/// The app has one, kept by the app delegate; its `sample` is called on the main thread.
final class ThroughputSampler: ObservableObject {
    static let capacity = 120

    /// The last 120 rates, oldest first.
    @Published private(set) var points: [ThroughputPoint] = []
    /// The newest rate; nil before the second read, and after a read that started a new series until the next.
    @Published private(set) var current: ThroughputPoint? = nil
    /// The bytes the driver has counted since it started (its counters at the last read); nil when that read
    /// found none.
    @Published private(set) var sessionRx: UInt64? = nil
    @Published private(set) var sessionTx: UInt64? = nil

    private let read: () -> (rx: UInt64, tx: UInt64)?
    private let now: () -> Date
    private let maxGap: TimeInterval
    private var baseline: (at: Date, rx: UInt64, tx: UInt64)? = nil   // the read the next rate is counted from
    private var series = 0
    private var seriesHasPoints = false

    /// `read`: the driver's counters now (nil: not attached). `maxGap`: reads further apart than this are not
    /// averaged over; the later one starts a new series.
    init(read: @escaping () -> (rx: UInt64, tx: UInt64)?, now: @escaping () -> Date = { Date() },
         maxGap: TimeInterval = 5) {
        self.read = read
        self.now = now
        self.maxGap = maxGap
    }

    /// Reads the counters once: a rate from the read before when both are in one series, else this read becomes
    /// the baseline of a new one.
    func sample() {
        let at = now()
        guard let counters = read() else {
            endSeries()
            baseline = nil
            sessionRx = nil
            sessionTx = nil
            return
        }
        sessionRx = counters.rx
        sessionTx = counters.tx
        defer { baseline = (at, counters.rx, counters.tx) }
        guard let base = baseline else { return }
        let seconds = at.timeIntervalSince(base.at)
        guard seconds > 0, seconds <= maxGap, counters.rx >= base.rx, counters.tx >= base.tx else {
            endSeries()
            return
        }
        let point = ThroughputPoint(at: at, downBitsPerSecond: Double(counters.rx - base.rx) * 8 / seconds,
                                    upBitsPerSecond: Double(counters.tx - base.tx) * 8 / seconds, series: series)
        seriesHasPoints = true
        var kept = points
        kept.append(point)
        if kept.count > ThroughputSampler.capacity { kept.removeFirst(kept.count - ThroughputSampler.capacity) }
        points = kept
        current = point
    }

    /// The rates are unknown until the next point, which starts a new series (when this one has any point).
    private func endSeries() {
        current = nil
        if seriesHasPoints {
            series += 1
            seriesHasPoints = false
        }
    }
}
