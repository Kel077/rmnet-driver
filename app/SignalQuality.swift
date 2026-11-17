// How good the modem's signal is, as the window draws it: bars (0…4) and a word from a leg's RAT, RSRP (RSCP
// for WCDMA) and SINR; the leg that stands for the connection; the technology for its badge; the bands; the
// ranges of the three metrics and the quality zones the gauges and charts shade; and whether a series rises
// or falls, for the charts' accessibility summaries. Foundation only (with ModemNetwork.swift's types), so
// `make app-test` tests it (tests/app/SignalQualityTests.swift).
import Foundation

/// WCDMA's RSCP is on its own scale; every other RAT (LTE, NR5G-SA, NR5G-NSA, "NR" in the signal history)
/// is on the LTE/NR one.
private func isWcdma(_ rat: String) -> Bool {
    rat == "WCDMA"
}

/// The bars, 0…4. LTE and NR: RSRP ≥ −80 dBm → 4, ≥ −90 → 3, ≥ −100 → 2, ≥ −110 → 1, else 0; then the SINR caps
/// it: under 0 dB at most 1, under 5 at most 2, under 13 at most 3 (no SINR caps nothing). WCDMA, with the RSCP in
/// `rsrp`: ≥ −75 → 4, ≥ −85 → 3, ≥ −95 → 2, ≥ −105 → 1, else 0, with no cap. No RSRP: 0.
func signalLevel(rat: String, rsrp: Int?, sinr: Double?) -> Int {
    guard let rsrp else { return 0 }
    let steps = isWcdma(rat) ? [-75, -85, -95, -105] : [-80, -90, -100, -110]
    var level = 0
    for (i, step) in steps.enumerated() where rsrp >= step {
        level = 4 - i
        break
    }
    guard !isWcdma(rat), let sinr else { return level }
    if sinr < 0 { return min(level, 1) }
    if sinr < 5 { return min(level, 2) }
    if sinr < 13 { return min(level, 3) }
    return level
}

/// The bars in a word: No signal, Poor, Fair, Good, Excellent (a level outside 0…4 is clamped).
func signalWord(_ level: Int) -> String {
    ["No signal", "Poor", "Fair", "Good", "Excellent"][max(0, min(4, level))]
}

/// The leg whose signal stands for the connection: the 5G SA leg; for EN-DC the NR leg when it has an RSRP, else
/// the LTE leg; otherwise the first leg. nil with no leg.
func servingLeg(_ legs: [CellLeg]) -> CellLeg? {
    if let sa = legs.first(where: { $0.rat == "NR5G-SA" }) { return sa }
    if let nr = legs.first(where: { $0.rat == "NR5G-NSA" }) {
        if nr.rsrp != nil { return nr }
        if let lte = legs.first(where: { $0.rat == "LTE" }) { return lte }
        return nr
    }
    return legs.first
}

/// The connection's bars: the serving leg's; 0 with no leg (searching, nothing read) or with the radio off.
func signalLevel(_ info: NetworkInfo) -> Int {
    guard info.radio != .airplane, let leg = servingLeg(info.serving?.cells ?? []) else { return 0 }
    return signalLevel(rat: leg.rat, rsrp: leg.rsrp, sinr: leg.sinr)
}

/// The technology as the badge shows it: "5G SA", "5G NSA", "LTE" (also with a 5G core), "3G" for WCDMA; nil
/// when there is none to show (radio off, searching, limited service, unknown, a RAT not named here).
func techBadgeText(_ info: NetworkInfo) -> String? {
    switch technologyLabel(info) {
    case "5G SA": return "5G SA"
    case "5G NSA": return "5G NSA"
    case "LTE", "LTE (5G core)": return "LTE"
    case "WCDMA": return "3G"
    default: return nil
    }
}

/// The bands in use: the carriers (primary first), then any leg's band they do not list, joined with " + "
/// ("n41", "B3 + B41", "B3 + n78"); nil when none is known.
func bandText(_ info: NetworkInfo) -> String? {
    var bands = info.carriers
    for leg in info.serving?.cells ?? [] {
        if let b = leg.band, !bands.contains(b) { bands.append(b) }
    }
    return bands.isEmpty ? nil : bands.joined(separator: " + ")
}

// MARK: - The metrics' ranges and zones

/// The three metrics a leg reports. For WCDMA, `rsrp` is the RSCP.
enum SignalMetric: String, CaseIterable {
    case rsrp, rsrq, sinr

    /// Its name: RSRP (RSCP for WCDMA), RSRQ, SINR.
    func title(rat: String) -> String {
        switch self {
        case .rsrp: return isWcdma(rat) ? "RSCP" : "RSRP"
        case .rsrq: return "RSRQ"
        case .sinr: return "SINR"
        }
    }

    var unit: String { self == .rsrp ? "dBm" : "dB" }

    /// The gauge's range: RSRP −140…−44 dBm (RSCP −120…−25), RSRQ −20…−3 dB, SINR −10…30 dB.
    func range(rat: String) -> ClosedRange<Double> {
        switch self {
        case .rsrp: return isWcdma(rat) ? -120...(-25) : -140...(-44)
        case .rsrq: return -20...(-3)
        case .sinr: return -10...30
        }
    }

    /// Where excellent, good and fair begin (below the last: poor). RSRP and SINR as the bars count them
    /// (signalLevel); RSRQ by the usual LTE reading (≥ −10 excellent, ≥ −15 good, ≥ −20 fair, below: cell edge).
    fileprivate func steps(rat: String) -> [Double] {
        switch self {
        case .rsrp: return isWcdma(rat) ? [-75, -85, -95] : [-80, -90, -100]
        case .rsrq: return [-10, -15, -20]
        case .sinr: return [13, 5, 0]
        }
    }
}

/// A band of a metric's range with one quality: 1 poor, 2 fair, 3 good, 4 excellent (signalWord's words).
struct QualityZone: Equatable {
    let level: Int
    let lower: Double
    let upper: Double
}

/// The metric's zones within its range, poor first: each clipped to the range, and left out when nothing of it
/// is in the range (RSRQ's poor lies below −20).
func qualityZones(_ metric: SignalMetric, rat: String) -> [QualityZone] {
    let range = metric.range(rat: rat)
    let s = metric.steps(rat: rat)
    let bounds: [(level: Int, lower: Double, upper: Double)] = [
        (1, -Double.infinity, s[2]), (2, s[2], s[1]), (3, s[1], s[0]), (4, s[0], Double.infinity),
    ]
    return bounds.compactMap { b in
        let lower = max(b.lower, range.lowerBound)
        let upper = min(b.upper, range.upperBound)
        return lower < upper ? QualityZone(level: b.level, lower: lower, upper: upper) : nil
    }
}

/// The quality (1 poor … 4 excellent) of one value of the metric; nil with no value.
func metricQuality(_ metric: SignalMetric, _ value: Double?, rat: String) -> Int? {
    guard let value else { return nil }
    let s = metric.steps(rat: rat)
    if value >= s[0] { return 4 }
    if value >= s[1] { return 3 }
    if value >= s[2] { return 2 }
    return 1
}

/// "rising", "falling" or "steady": the last value against the mean of up to ten values before it, with
/// `tolerance` either way counted as steady. nil with fewer than two values.
func trendWord(_ values: [Double], tolerance: Double) -> String? {
    guard values.count >= 2, let last = values.last else { return nil }
    let before = values.dropLast().suffix(10)
    let mean = before.reduce(0, +) / Double(before.count)
    if last - mean > tolerance { return "rising" }
    if mean - last > tolerance { return "falling" }
    return "steady"
}
