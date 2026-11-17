// DesignKit's charts (Apple's Charts framework): the live throughput (download and upload over the last two
// minutes), the signal history (a metric per leg over the last ten minutes, its quality zones shaded behind, a
// rule at each technology or band change), a sparkline, and a capacity gauge. Each has an accessibility summary
// (the latest value and its trend) and a placeholder line instead of an empty axis.
import Charts
import SwiftUI

// MARK: - Throughput

/// Download (blue) and upload (teal) rates as two overlapping areas over the last `window` seconds; the points
/// of different series (ThroughputSampler: after a driver restart or a gap) are not joined. "Collecting…" until
/// the first point.
struct ThroughputChart: View {
    let points: [ThroughputPoint]
    var window: TimeInterval = 120
    var height: CGFloat = 140

    var body: some View {
        if let last = points.last {
            let shown = points.filter { $0.at >= last.at.addingTimeInterval(-window) }
            let top = shown.map { max($0.downBitsPerSecond, $0.upBitsPerSecond) }.max() ?? 0
            Chart {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, p in
                    AreaMark(x: .value("Time", p.at), y: .value("Rate", p.downBitsPerSecond),
                             series: .value("Series", "Download \(p.series)"), stacking: .unstacked)
                        .foregroundStyle(by: .value("Direction", "Download"))
                        .opacity(0.25)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.at), y: .value("Rate", p.downBitsPerSecond),
                             series: .value("Series", "Download line \(p.series)"))
                        .foregroundStyle(by: .value("Direction", "Download"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    AreaMark(x: .value("Time", p.at), y: .value("Rate", p.upBitsPerSecond),
                             series: .value("Series", "Upload \(p.series)"), stacking: .unstacked)
                        .foregroundStyle(by: .value("Direction", "Upload"))
                        .opacity(0.25)
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", p.at), y: .value("Rate", p.upBitsPerSecond),
                             series: .value("Series", "Upload line \(p.series)"))
                        .foregroundStyle(by: .value("Direction", "Upload"))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(["Download": Color.blue, "Upload": Color.teal])
            .chartXScale(domain: last.at.addingTimeInterval(-window)...last.at)
            .chartYScale(domain: 0...max(top * 1.15, 8_000))
            .chartXAxis {
                AxisMarks(values: .stride(by: .second, count: Int(window / 4))) { _ in
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(verbatim: bitRateText(v)) }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .leading, spacing: Spacing.s)
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Throughput over the last \(Int(window / 60)) minutes"))
            .accessibilityValue(Text(verbatim: throughputSummary(shown)))
        } else {
            ChartPlaceholder(text: "Collecting…", height: height)
                .accessibilityLabel(Text("Throughput: collecting"))
        }
    }
}

/// "Download 12 Mbit/s, rising; upload 1.2 Mbit/s, steady".
private func throughputSummary(_ points: [ThroughputPoint]) -> String {
    guard let last = points.last else { return "collecting" }
    let down = points.map { $0.downBitsPerSecond }
    let up = points.map { $0.upBitsPerSecond }
    func trend(_ v: [Double]) -> String {
        trendWord(v, tolerance: max(50_000, (v.last ?? 0) * 0.2)).map { ", \($0)" } ?? ""
    }
    return "Download \(bitRateText(last.downBitsPerSecond))\(trend(down)); "
        + "upload \(bitRateText(last.upBitsPerSecond))\(trend(up))"
}

/// The current download and upload rates as large numbers (arrows down and up); "—" before the first rate.
struct ThroughputRates: View {
    let current: ThroughputPoint?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xl) {
            rate("arrow.down", "Download", current?.downBitsPerSecond, .blue)
            rate("arrow.up", "Upload", current?.upBitsPerSecond, .teal)
        }
    }

    private func rate(_ symbol: String, _ name: String, _ bps: Double?, _ tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .fontWeight(.semibold)
            Text(verbatim: bps.map(bitRateText) ?? "—")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: name))
        .accessibilityValue(Text(verbatim: bps.map(bitRateText) ?? "not known"))
    }
}

// MARK: - Signal history

/// One metric of the signal history over the last `window` seconds: a line per leg (NR blue, LTE teal, WCDMA
/// gray), its quality zones (SignalQuality.swift) shaded behind, and a dashed rule where the technology or the
/// band changed, labelled with the new one. "Collecting…" before two reads in the window, "No signal data" when every
/// value is unknown.
struct SignalHistoryChart: View {
    let samples: [SignalSample]
    let metric: SignalMetric
    var window: TimeInterval = 600
    var height: CGFloat = 140

    /// NR blue, LTE teal, WCDMA gray; another RAT gray too.
    private static func legColor(_ leg: String) -> Color {
        switch leg {
        case "NR": return .blue
        case "LTE": return .teal
        default: return .gray
        }
    }

    var body: some View {
        let latest = samples.last?.at ?? Date()
        let shown = samples.filter { $0.at >= latest.addingTimeInterval(-window) }
        let reads = Set(shown.map { $0.at }).count   // the reads in the window, not every one kept
        let points = signalPoints(shown, metric)
        if reads < 2 {
            ChartPlaceholder(text: "Collecting…", height: height)
                .accessibilityLabel(Text(verbatim: "\(metric.title(rat: "LTE")) history: collecting"))
        } else if points.isEmpty {
            ChartPlaceholder(text: "No signal data", height: height)
                .accessibilityLabel(Text(verbatim: "\(metric.title(rat: "LTE")) history: no signal data"))
        } else {
            let rat = points.last?.leg ?? "LTE"
            let domain = chartDomain(points.map { $0.value }, metric.range(rat: rat),
                                     minimumSpan: metric == .rsrp ? 24 : 12)
            let zones = zonesClipped(qualityZones(metric, rat: rat), to: domain)
            let legs = ["NR", "LTE", "WCDMA"].filter { leg in points.contains { $0.leg == leg } }
                + Set(points.map { $0.leg }).subtracting(["NR", "LTE", "WCDMA"]).sorted()
            let changes = signalChanges(shown)
            Chart {
                ForEach(zones, id: \.level) { z in
                    RectangleMark(xStart: .value("From", latest.addingTimeInterval(-window)),
                                  xEnd: .value("To", latest),
                                  yStart: .value("Low", z.lower), yEnd: .value("High", z.upper))
                        .foregroundStyle(zoneFill(z.level))
                }
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    RuleMark(x: .value("Change", change.at))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top, alignment: .leading, spacing: 2,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            Text(verbatim: change.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Time", p.at), y: .value(metric.title(rat: p.leg), p.value),
                             series: .value("Series", p.series))
                        .foregroundStyle(by: .value("Leg", p.leg))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }
            .chartForegroundStyleScale(domain: legs, range: legs.map(SignalHistoryChart.legColor))
            .chartXScale(domain: latest.addingTimeInterval(-window)...latest)
            .chartYScale(domain: domain)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute, count: 2)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(verbatim: "\(Int(v))") }
                    }
                }
            }
            .chartLegend(legs.count > 1 ? .visible : .hidden)
            .chartLegend(position: .bottom, alignment: .trailing)
            .frame(height: height)
            // Room above the plot for the changes' labels, which are drawn there.
            .padding(.top, changes.isEmpty ? 0 : 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "\(metric.title(rat: rat)) over the last \(Int(window / 60)) minutes"))
            .accessibilityValue(Text(verbatim: signalSummary(points, metric)))
        }
    }
}

/// A sample's value of `metric`.
private func metricValue(_ s: SignalSample, _ metric: SignalMetric) -> Double? {
    switch metric {
    case .rsrp: return s.rsrp.map(Double.init)
    case .rsrq: return s.rsrq.map(Double.init)
    case .sinr: return s.sinr
    }
}

private struct SignalPoint {
    let at: Date
    let leg: String
    let value: Double
    let series: String   // the leg, numbered again after a gap of more than three 5 s turns, so it is not joined
}

/// The known values of `metric`, a line per leg, broken where a leg was missing for more than 15 s.
private func signalPoints(_ samples: [SignalSample], _ metric: SignalMetric) -> [SignalPoint] {
    var lastSeen: [String: Date] = [:]
    var runs: [String: Int] = [:]
    var points: [SignalPoint] = []
    for s in samples {
        guard let v = metricValue(s, metric) else {
            runs[s.leg, default: 0] += 1
            continue
        }
        if let seen = lastSeen[s.leg], s.at.timeIntervalSince(seen) > 15 { runs[s.leg, default: 0] += 1 }
        lastSeen[s.leg] = s.at
        points.append(SignalPoint(at: s.at, leg: s.leg, value: v, series: "\(s.leg) \(runs[s.leg, default: 0])"))
    }
    return points
}

/// The reads where the technology or the bands differ from the read before, with the new one's words: the
/// technology when it changed ("5G NSA"), else the bands ("n78", "B3 + n78").
private func signalChanges(_ samples: [SignalSample]) -> [(at: Date, label: String)] {
    var changes: [(at: Date, label: String)] = []
    var previous: (technology: String?, bands: [String])? = nil
    var i = 0
    while i < samples.count {
        let at = samples[i].at
        var j = i
        var bands: [String] = []
        while j < samples.count && samples[j].at == at {
            if let b = samples[j].band { bands.append(b) }
            j += 1
        }
        let technology = samples[i].technology
        if let p = previous {
            if p.technology != technology {
                changes.append((at, technology ?? "—"))
            } else if p.bands != bands {
                changes.append((at, bands.isEmpty ? "—" : bands.joined(separator: " + ")))
            }
        }
        previous = (technology, bands)
        i = j
    }
    return changes
}

/// "RSRP −86 dBm, good, steady" for the newest value of the serving leg (NR before LTE, as servingLeg).
private func signalSummary(_ points: [SignalPoint], _ metric: SignalMetric) -> String {
    guard let lastAt = points.last?.at else { return "no signal data" }
    let newest = points.filter { $0.at == lastAt }
    guard let p = newest.first(where: { $0.leg == "NR" }) ?? newest.first else { return "no signal data" }
    let values = points.filter { $0.leg == p.leg }.map { $0.value }
    let quality = metricQuality(metric, p.value, rat: p.leg).map { ", \(signalWord($0).lowercased())" } ?? ""
    let trend = trendWord(values, tolerance: 2).map { ", \($0)" } ?? ""
    return "\(metric.title(rat: p.leg)) \(Int(p.value.rounded())) \(metric.unit)\(quality)\(trend)"
}

/// The values' span, padded, at least `minimumSpan` wide, within `range` as far as the values allow (a value
/// outside the range stays in view, so the plot needs no clipping).
private func chartDomain(_ values: [Double], _ range: ClosedRange<Double>, minimumSpan: Double) -> ClosedRange<Double> {
    guard let lo = values.min(), let hi = values.max() else { return range }
    var lower = lo - 4
    var upper = hi + 4
    if upper - lower < minimumSpan {
        let mid = (lower + upper) / 2
        lower = mid - minimumSpan / 2
        upper = mid + minimumSpan / 2
    }
    let floor = min(range.lowerBound, lo)
    let ceiling = max(range.upperBound, hi)
    if lower < floor {
        upper = min(ceiling, upper + (floor - lower))
        lower = floor
    }
    if upper > ceiling {
        lower = max(floor, lower - (upper - ceiling))
        upper = ceiling
    }
    return lower...upper
}

private func zonesClipped(_ zones: [QualityZone], to domain: ClosedRange<Double>) -> [QualityZone] {
    zones.compactMap { z in
        let lower = max(z.lower, domain.lowerBound)
        let upper = min(z.upper, domain.upperBound)
        return lower < upper ? QualityZone(level: z.level, lower: lower, upper: upper) : nil
    }
}

// MARK: - Sparkline

/// A small line of `values` (oldest first) with no axes, its quality zones shaded behind; for the Overview's RSRP
/// over the last ten minutes. "Collecting…" with fewer than two values. VoiceOver reads `label`, the latest value
/// with `unit`, and the trend.
struct Sparkline: View {
    let values: [Double]
    var zones: [QualityZone] = []
    var label = "Trend"
    var unit = ""
    var height: CGFloat = 36

    var body: some View {
        if values.count < 2 {
            Text("Collecting…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        } else {
            let range = zones.isEmpty ? (values.min()! ... values.max()!)
                : (zones.first!.lower ... zones.last!.upper)
            let domain = chartDomain(values, range, minimumSpan: 16)
            Chart {
                ForEach(zonesClipped(zones, to: domain), id: \.level) { z in
                    RectangleMark(xStart: .value("From", 0), xEnd: .value("To", values.count - 1),
                                  yStart: .value("Low", z.lower), yEnd: .value("High", z.upper))
                        .foregroundStyle(zoneFill(z.level))
                }
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("Sample", i), y: .value("Value", v))
                        .foregroundStyle(Color.primary.opacity(0.8))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: 0...(values.count - 1))
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { $0.clipped() }
            .frame(height: height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: "\(Int(values.last!.rounded())) \(unit)"
                                     + (trendWord(values, tolerance: 2).map { ", \($0)" } ?? "")))
        }
    }
}

// MARK: - Capacity

/// How full a store is (the SIM's message store: "12 of 255"), as a capacity bar: orange from 75 %, red from 90 %.
/// "—" when either number is not known.
struct CapacityGauge: View {
    let used: Int?
    let total: Int?
    var label = "Stored"

    var body: some View {
        if let used, let total, total > 0 {
            let fraction = Double(min(max(used, 0), total)) / Double(total)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: label)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.s)
                    Text(verbatim: "\(used) of \(total)")
                        .monospacedDigit()
                }
                Gauge(value: fraction) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(fraction >= 0.9 ? Color.red : fraction >= 0.75 ? Color.orange : Color.blue)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: "\(used) of \(total)"))
        } else {
            HStack {
                Text(verbatim: label)
                Spacer()
                Text(verbatim: "—")
            }
            .foregroundStyle(.secondary)
        }
    }
}
