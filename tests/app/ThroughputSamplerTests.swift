// Tests for app/ThroughputSampler.swift: download and upload rates from two reads of the driver's byte counters,
// a counter that goes down (a driver restart) or a gap starting a new series, a missing counter adding nothing,
// the 120-point cap, the current rates and the session totals, the counters read from the driver's registry
// properties, and a rate in words. Driven by a fake counter reader and a fake clock. Built with swiftc by `make app-test`
// from app/ThroughputSampler.swift and this file; no AppKit, no registry.
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

let start = Date(timeIntervalSince1970: 1_800_000_000)

/// A sampler on counters and a clock the test sets before each sample.
final class Rig {
    var counters: (rx: UInt64, tx: UInt64)? = nil
    var clock = start
    var reads = 0
    lazy var sampler = ThroughputSampler(read: { [unowned self] in self.reads += 1; return self.counters },
                                         now: { [unowned self] in self.clock })

    /// Sets the counters and the time `seconds` after the start, and samples.
    func sample(at seconds: Double, _ counters: (rx: UInt64, tx: UInt64)?) {
        clock = start.addingTimeInterval(seconds)
        self.counters = counters
        sampler.sample()
    }
}

@main
struct ThroughputSamplerTests {
    static func main() {
        rates()
        resets()
        missing()
        gaps()
        cap()
        counters()
        rateWords()
        print("throughput sampler: \(checks) checks passed")
    }

    // The first read is the baseline (no point, no rate); each read after it adds a point: the bytes moved since
    // the read before, in bits per second over the time between them.
    static func rates() {
        let rig = Rig()
        let s = rig.sampler
        check(s.points.isEmpty && s.current == nil && s.sessionRx == nil && s.sessionTx == nil && rig.reads == 0,
              "rates: nothing is known, and nothing read, before the first sample")
        rig.sample(at: 0, (rx: 5_000_000, tx: 1_000_000))
        check(rig.reads == 1 && s.points.isEmpty && s.current == nil, "rates: the first read is only the baseline")
        check(s.sessionRx == 5_000_000 && s.sessionTx == 1_000_000, "rates: the session totals are the driver's counters")

        rig.sample(at: 1, (rx: 6_000_000, tx: 1_125_000))
        equal(s.points, [ThroughputPoint(at: start.addingTimeInterval(1), downBitsPerSecond: 8_000_000,
                                         upBitsPerSecond: 1_000_000, series: 0)], "rates: 1 MB down and 125 kB up in 1 s")
        equal(s.current, s.points.last, "rates: the current rates are the newest point")
        check(s.sessionRx == 6_000_000 && s.sessionTx == 1_125_000, "rates: the totals follow the counters")

        rig.sample(at: 1.5, (rx: 6_500_000, tx: 1_125_000))
        equal(s.points.last, ThroughputPoint(at: start.addingTimeInterval(1.5), downBitsPerSecond: 8_000_000,
                                             upBitsPerSecond: 0, series: 0), "rates: over half a second; nothing up is 0")
        rig.sample(at: 3.5, (rx: 6_500_000, tx: 1_125_000))
        equal(s.points.last?.downBitsPerSecond, 0, "rates: no traffic is a rate of 0, not a missing point")
        equal(s.points.count, 3, "rates: one point a read after the first")
    }

    // A counter that goes down (download or upload), as after a driver restart, gives no negative rate: the read
    // becomes the baseline of a new series, and the rates are unknown until the next read.
    static func resets() {
        let rig = Rig()
        let s = rig.sampler
        rig.sample(at: 0, (rx: 9_000_000, tx: 900_000))
        rig.sample(at: 1, (rx: 10_000_000, tx: 1_000_000))
        rig.sample(at: 2, (rx: 1_000, tx: 1_100_000))
        equal(s.points.count, 1, "reset: a download counter that went down adds no point")
        check(s.current == nil, "reset: no current rate after a reset")
        check(s.sessionRx == 1_000 && s.sessionTx == 1_100_000, "reset: the totals are the new counters")
        rig.sample(at: 3, (rx: 126_000, tx: 1_100_000))
        equal(s.points.last, ThroughputPoint(at: start.addingTimeInterval(3), downBitsPerSecond: 1_000_000,
                                             upBitsPerSecond: 0, series: 1), "reset: the next read starts series 1")
        check(s.points.allSatisfy { $0.downBitsPerSecond >= 0 && $0.upBitsPerSecond >= 0 }, "reset: no negative rate")
        rig.sample(at: 4, (rx: 226_000, tx: 50))
        check(s.points.count == 2 && s.current == nil, "reset: an upload counter that went down starts a series too")
        rig.sample(at: 5, (rx: 226_000, tx: 1_050))
        equal(s.points.last?.series, 2, "reset: series 2")
        equal(s.points.last?.upBitsPerSecond, 8_000, "reset: from the new baseline")
    }

    // A read with no counters (the driver not attached) adds nothing and makes the rates and totals unknown; the
    // next good read is a new baseline.
    static func missing() {
        let rig = Rig()
        let s = rig.sampler
        rig.sample(at: 0, (rx: 1_000, tx: 1_000))
        rig.sample(at: 1, (rx: 2_000, tx: 2_000))
        rig.sample(at: 2, nil)
        check(s.points.count == 1 && s.current == nil && s.sessionRx == nil && s.sessionTx == nil,
              "missing: no point, no rate, no totals")
        rig.sample(at: 3, (rx: 3_000, tx: 3_000))
        check(s.points.count == 1 && s.current == nil && s.sessionRx == 3_000, "missing: the next read is a baseline only")
        rig.sample(at: 4, (rx: 4_000, tx: 3_500))
        equal(s.points.last, ThroughputPoint(at: start.addingTimeInterval(4), downBitsPerSecond: 8_000,
                                             upBitsPerSecond: 4_000, series: 1), "missing: then a point in a new series")
        let fresh = Rig()
        fresh.sample(at: 0, nil)
        check(fresh.sampler.points.isEmpty && fresh.sampler.current == nil && fresh.sampler.sessionRx == nil,
              "missing: nothing from a first read that finds no counters")
    }

    // Reads more than 5 s apart (the screen was away, the window hidden) are not averaged over the gap: the later
    // one starts a new series. A clock that went back gives no point either.
    static func gaps() {
        let rig = Rig()
        let s = rig.sampler
        rig.sample(at: 0, (rx: 0, tx: 0))
        rig.sample(at: 5, (rx: 5_000, tx: 0))
        equal(s.points.count, 1, "gap: 5 s apart still adds a point")
        rig.sample(at: 65, (rx: 900_000, tx: 0))
        check(s.points.count == 1 && s.current == nil, "gap: a minute later adds no point")
        rig.sample(at: 66, (rx: 901_000, tx: 0))
        equal(s.points.last?.series, 1, "gap: the read after it is in a new series")
        equal(s.points.last?.downBitsPerSecond, 8_000, "gap: from the read after the gap")
        rig.sample(at: 60, (rx: 902_000, tx: 0))
        check(s.points.count == 2 && s.current == nil, "gap: a clock set back adds no point")
        rig.sample(at: 60, (rx: 903_000, tx: 0))
        check(s.points.count == 2, "gap: no point for no time")
        rig.sample(at: 61, (rx: 904_000, tx: 0))
        equal(s.points.last?.downBitsPerSecond, 8_000, "gap: rates again after the clock moves on")
    }

    // The last 120 points are kept, oldest dropped first.
    static func cap() {
        let rig = Rig()
        let s = rig.sampler
        equal(ThroughputSampler.capacity, 120, "cap: 120 points")
        for i in 0...130 {
            rig.sample(at: Double(i), (rx: UInt64(i) * 1_000, tx: 0))
        }
        equal(s.points.count, 120, "cap: 130 points keep 120")
        equal(s.points.first?.at, start.addingTimeInterval(11), "cap: the oldest are dropped")
        equal(s.points.last?.at, start.addingTimeInterval(130), "cap: the newest is kept")
        equal(s.current, s.points.last, "cap: current is the newest")
    }

    // RMNetRxBytes and RMNetTxBytes as unsigned decimal numbers; nil when either is missing or not a number.
    static func counters() {
        let good = driverByteCounters(["RMNetRxBytes": "123456", "RMNetTxBytes": "789", "RMNetState": "up"])
        check(good?.rx == 123_456 && good?.tx == 789, "counters: both read")
        let top = driverByteCounters(["RMNetRxBytes": "18446744073709551615", "RMNetTxBytes": "0"])
        check(top?.rx == UInt64.max && top?.tx == 0, "counters: the whole 64-bit range")
        check(driverByteCounters(nil) == nil, "counters: none without the driver")
        check(driverByteCounters(["RMNetRxBytes": "1"]) == nil, "counters: none with one missing")
        check(driverByteCounters(["RMNetRxBytes": "1", "RMNetTxBytes": "x"]) == nil, "counters: none when not a number")
        check(driverByteCounters(["RMNetRxBytes": "-1", "RMNetTxBytes": "1"]) == nil, "counters: none when negative")
        check(driverByteCounters(["RMNetRxBytes": "", "RMNetTxBytes": "1"]) == nil, "counters: none when empty")
    }

    // A rate in words: whole bits a second, then kbit/s, Mbit/s, Gbit/s with one decimal under 10 (no ".0") and
    // none from 10; a value that rounds to 1000 takes the next unit.
    static func rateWords() {
        let cases: [(Double, String)] = [
            (0, "0 bit/s"), (-5, "0 bit/s"), (.nan, "0 bit/s"), (.infinity, "0 bit/s"), (950, "950 bit/s"),
            (999.6, "1 kbit/s"), (8_500, "8.5 kbit/s"), (10_000, "10 kbit/s"), (850_000, "850 kbit/s"),
            (999_700, "1 Mbit/s"), (1_234_567, "1.2 Mbit/s"), (8_000_000, "8 Mbit/s"), (12_345_678, "12 Mbit/s"),
            (190_000_000, "190 Mbit/s"), (2_500_000_000, "2.5 Gbit/s"), (5e12, "5000 Gbit/s"),
        ]
        for (bps, words) in cases {
            equal(bitRateText(bps), words, "rate words: \(bps)")
        }
    }
}
