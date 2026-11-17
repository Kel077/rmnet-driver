// Tests for app/SignalQuality.swift: the bars (0…4) for a leg's RAT, RSRP (RSCP for WCDMA) and SINR at each
// threshold's edge, every SINR cap, the words, the leg that stands for the connection (5G SA, EN-DC), the badge's
// technology, the bands, the metrics' ranges and quality zones, and the trend word. Built with swiftc by `make
// app-test` from app/ModemNetwork.swift, app/SignalQuality.swift and this file; no AppKit, no modem.
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

func leg(_ rat: String, rsrp: Int?, sinr: Double? = nil, band: String? = nil) -> CellLeg {
    CellLeg(rat: rat, duplex: nil, mcc: "001", mnc: "01", cellID: nil, pci: 1, tac: nil, channel: nil, band: band,
            bandwidthMHz: nil, rsrp: rsrp, rsrq: -11, sinr: sinr)
}

func info(_ legs: [CellLeg], carriers: [String] = [], radio: RadioState = .on, state: String = "NOCONN",
          accessTechnology: Int? = nil) -> NetworkInfo {
    NetworkInfo(radio: radio, accessTechnology: accessTechnology, serving: ServingCell(state: state, cells: legs),
                carriers: carriers)
}

@main
struct SignalQualityTests {
    static func main() {
        lteAndNr()
        sinrCaps()
        wcdma()
        noRsrp()
        words()
        servingLegs()
        connectionLevel()
        captions()
        badges()
        bands()
        metrics()
        trends()
        print("signal quality: \(checks) checks passed")
    }

    // RSRP ≥ −80 → 4, ≥ −90 → 3, ≥ −100 → 2, ≥ −110 → 1, else 0, for every LTE and NR name, with no SINR.
    static func lteAndNr() {
        let edges: [(rsrp: Int, level: Int)] = [(-44, 4), (-80, 4), (-81, 3), (-90, 3), (-91, 2), (-100, 2), (-101, 1),
                                                (-110, 1), (-111, 0), (-140, 0)]
        for rat in ["LTE", "NR5G-SA", "NR5G-NSA", "NR"] {
            for e in edges {
                equal(signalLevel(rat: rat, rsrp: e.rsrp, sinr: nil), e.level, "LTE/NR: \(rat) RSRP \(e.rsrp) dBm")
            }
        }
    }

    // SINR < 0 → at most 1, < 5 → at most 2, < 13 → at most 3; a cap never raises the level; nil caps nothing.
    static func sinrCaps() {
        let caps: [(sinr: Double?, level: Int)] = [(-10, 1), (-0.5, 1), (0, 2), (4.9, 2), (5, 3), (12.9, 3), (13, 4),
                                                   (30, 4), (nil, 4)]
        for rat in ["LTE", "NR5G-SA", "NR"] {
            for c in caps {
                equal(signalLevel(rat: rat, rsrp: -70, sinr: c.sinr), c.level,
                      "SINR cap: \(rat) RSRP -70, SINR \(String(describing: c.sinr))")
            }
        }
        equal(signalLevel(rat: "LTE", rsrp: -105, sinr: 30), 1, "SINR cap: a good SINR does not raise RSRP's 1")
        equal(signalLevel(rat: "LTE", rsrp: -95, sinr: 3), 2, "SINR cap: under 5 dB keeps RSRP's 2")
        equal(signalLevel(rat: "LTE", rsrp: -95, sinr: -1), 1, "SINR cap: under 0 dB takes RSRP's 2 to 1")
        equal(signalLevel(rat: "NR5G-SA", rsrp: -85, sinr: 4), 2, "SINR cap: under 5 dB takes RSRP's 3 to 2")
        equal(signalLevel(rat: "LTE", rsrp: -115, sinr: -5), 0, "SINR cap: RSRP's 0 stays 0")
        equal(signalLevel(rat: "LTE", rsrp: -115, sinr: 20), 0, "SINR cap: RSRP's 0 is not raised")
    }

    // RSCP in `rsrp`: ≥ −75 → 4, ≥ −85 → 3, ≥ −95 → 2, ≥ −105 → 1, else 0; WCDMA has no SINR cap.
    static func wcdma() {
        let edges: [(rscp: Int, level: Int)] = [(-25, 4), (-75, 4), (-76, 3), (-85, 3), (-86, 2), (-95, 2), (-96, 1),
                                                (-105, 1), (-106, 0), (-120, 0)]
        for e in edges {
            equal(signalLevel(rat: "WCDMA", rsrp: e.rscp, sinr: nil), e.level, "WCDMA: RSCP \(e.rscp) dBm")
        }
        equal(signalLevel(rat: "WCDMA", rsrp: -70, sinr: -5), 4, "WCDMA: a SINR caps nothing")
        // The LTE scale would give RSCP -78 3 bars; WCDMA's gives 4.
        equal(signalLevel(rat: "WCDMA", rsrp: -78, sinr: nil), 3, "WCDMA: -78 is 3 bars")
        equal(signalLevel(rat: "LTE", rsrp: -78, sinr: nil), 4, "LTE: -78 is 4 bars")
    }

    static func noRsrp() {
        for rat in ["LTE", "NR5G-SA", "NR5G-NSA", "NR", "WCDMA", "GSM"] {
            equal(signalLevel(rat: rat, rsrp: nil, sinr: 20), 0, "nil RSRP: \(rat) has no signal, whatever the SINR")
            equal(signalLevel(rat: rat, rsrp: nil, sinr: nil), 0, "nil RSRP: \(rat) with no SINR")
        }
    }

    static func words() {
        equal((0...4).map(signalWord), ["No signal", "Poor", "Fair", "Good", "Excellent"], "words: the five words")
        equal(signalWord(-1), "No signal", "words: below 0 reads as no signal")
        equal(signalWord(7), "Excellent", "words: above 4 reads as excellent")
    }

    // NR for 5G SA; for EN-DC the NR leg when it has an RSRP, else the LTE leg; otherwise the first leg.
    static func servingLegs() {
        let sa = leg("NR5G-SA", rsrp: -86, sinr: 10, band: "n41")
        let lte = leg("LTE", rsrp: -95, sinr: 8, band: "B3")
        let nr = leg("NR5G-NSA", rsrp: -88, sinr: 12, band: "n78")
        let nrNoRsrp = leg("NR5G-NSA", rsrp: nil, sinr: 12, band: "n78")
        let umts = leg("WCDMA", rsrp: -80)
        equal(servingLeg([sa]), sa, "serving leg: 5G SA's NR leg")
        equal(servingLeg([lte, nr]), nr, "serving leg: EN-DC's NR leg when it has an RSRP")
        equal(servingLeg([nr, lte]), nr, "serving leg: EN-DC's NR leg, listed first")
        equal(servingLeg([lte, nrNoRsrp]), lte, "serving leg: EN-DC's LTE leg when NR has no RSRP")
        equal(servingLeg([nrNoRsrp, lte]), lte, "serving leg: EN-DC's LTE leg, NR listed first without RSRP")
        equal(servingLeg([lte]), lte, "serving leg: LTE alone")
        equal(servingLeg([umts]), umts, "serving leg: WCDMA alone")
        equal(servingLeg([leg("GSM", rsrp: nil)])?.rat, "GSM", "serving leg: a RAT not known here, as given")
        check(servingLeg([]) == nil, "serving leg: none without a leg")
    }

    // The connection's bars: the serving leg's. 0 when the modem says there is no signal: the radio off (airplane
    // mode or minimum functionality), or a serving cell read with no leg (searching, limited or no service). nil
    // when it is not known: the serving cell not read, or the leg that stands for the connection without an RSRP.
    static func connectionLevel() {
        equal(signalLevel(info([leg("NR5G-SA", rsrp: -86, sinr: 10)])), 3, "connection: 5G SA -86 dBm, SINR 10")
        equal(signalLevel(info([leg("LTE", rsrp: -95, sinr: 20), leg("NR5G-NSA", rsrp: -78, sinr: 15)])), 4,
              "connection: EN-DC takes the NR leg")
        equal(signalLevel(info([leg("LTE", rsrp: -95, sinr: 20), leg("NR5G-NSA", rsrp: nil, sinr: 15)])), 2,
              "connection: EN-DC takes LTE when NR has no RSRP")
        equal(signalLevel(info([leg("WCDMA", rsrp: -80)])), 3, "connection: WCDMA RSCP -80")
        equal(signalLevel(info([leg("LTE", rsrp: -125, sinr: 2)])), 0, "connection: a leg too weak for a bar is 0")

        // 0: the modem says there is no signal.
        equal(signalLevel(info([], state: "SEARCH")), 0, "connection: searching (a serving cell with no leg) is 0")
        equal(signalLevel(info([], state: "LIMSRV")), 0, "connection: limited service with no leg is 0")
        equal(signalLevel(info([], state: "NOCONN")), 0, "connection: a serving cell read with no leg is 0")
        equal(signalLevel(info([leg("LTE", rsrp: -70, sinr: 20)], radio: .airplane)), 0, "connection: radio off")
        equal(signalLevel(NetworkInfo(radio: .airplane)), 0, "connection: radio off, serving cell not read")
        equal(signalLevel(info([leg("LTE", rsrp: -70, sinr: 20)], radio: .minimum)), 0,
              "connection: minimum functionality (radio off)")

        // nil: not known.
        check(signalLevel(NetworkInfo(radio: .on)) == nil, "connection: serving cell not read is unknown")
        check(signalLevel(NetworkInfo()) == nil, "connection: nothing read is unknown")
        check(signalLevel(NetworkInfo(radio: .on, accessTechnology: 12)) == nil,
              "connection: an AcT without a serving cell read is unknown")
        check(signalLevel(info([leg("LTE", rsrp: nil, sinr: 20)])) == nil, "connection: a leg without RSRP is unknown")
        check(signalLevel(info([leg("LTE", rsrp: nil, sinr: 20), leg("NR5G-NSA", rsrp: nil, sinr: 15)])) == nil,
              "connection: EN-DC with no RSRP on either leg is unknown")
        check(signalLevel(info([leg("GSM", rsrp: nil)])) == nil, "connection: a RAT not known here is unknown")
        check(signalLevel(NetworkInfo(serving: ServingCell(state: "NOCONN", cells: [leg("NR5G-SA", rsrp: -86)]))) == 3,
              "connection: the radio not read does not hide a serving cell read")
    }

    // The word beside the bars. The radio off says so, whatever else was read: "Radio off (airplane mode)" (the menu
    // bar panel's old first line; the Network screen's Radio row), "Minimum functionality" (that row's words). The
    // serving cell searching or in limited service says so, with a leg or without (its Connection row's words, as the
    // old first line had them). "Signal not known" with nothing read or no level. Otherwise the bars' word: "No
    // signal" also for a serving cell read with no leg in another state (no service), which has no word of its own.
    static func captions() {
        let sa = leg("NR5G-SA", rsrp: -86, sinr: 10)
        // The radio off.
        equal(signalCaption(info([sa], radio: .airplane)), "Radio off (airplane mode)", "caption: airplane mode, a leg read")
        equal(signalCaption(NetworkInfo(radio: .airplane)), "Radio off (airplane mode)",
              "caption: airplane mode, nothing else read")
        equal(signalCaption(info([], radio: .airplane, state: "SEARCH")), "Radio off (airplane mode)",
              "caption: airplane mode before searching")
        equal(signalCaption(info([sa], radio: .minimum)), "Minimum functionality", "caption: minimum functionality, a leg read")
        equal(signalCaption(NetworkInfo(radio: .minimum)), "Minimum functionality",
              "caption: minimum functionality, nothing else read")
        equal(signalCaption(info([], radio: .minimum, state: "LIMSRV")), "Minimum functionality",
              "caption: minimum functionality before limited service")
        // Searching, limited service, no service.
        equal(signalCaption(info([], state: "SEARCH")), "Searching", "caption: searching")
        equal(signalCaption(info([], state: "LIMSRV")), "Limited service", "caption: limited service")
        equal(signalCaption(info([leg("LTE", rsrp: -86, sinr: 20)], state: "LIMSRV")), "Limited service",
              "caption: limited service on a cell with a good signal")
        equal(signalCaption(info([], state: "NOCONN")), "No signal", "caption: no service (a serving cell with no leg)")
        equal(signalCaption(info([], state: "")), "No signal", "caption: no service, no state given")
        // Not known.
        equal(signalCaption(nil), "Signal not known", "caption: nothing read")
        equal(signalCaption(NetworkInfo(radio: .on)), "Signal not known", "caption: the serving cell not read")
        equal(signalCaption(NetworkInfo()), "Signal not known", "caption: neither the radio nor the serving cell read")
        equal(signalCaption(info([leg("LTE", rsrp: nil, sinr: 20)])), "Signal not known", "caption: a leg without RSRP")
        // Otherwise the bars' five words, idle or connected, and with another AT+CFUN value.
        let levels: [(CellLeg, String)] = [
            (leg("LTE", rsrp: -125, sinr: 2), "No signal"),
            (leg("LTE", rsrp: -105, sinr: 20), "Poor"),
            (leg("NR5G-SA", rsrp: -95, sinr: 20), "Fair"),
            (sa, "Good"),
            (leg("NR5G-SA", rsrp: -75, sinr: 20), "Excellent"),
        ]
        for (l, word) in levels {
            equal(signalCaption(info([l])), word, "caption: \(word)")
            equal(signalCaption(info([l], state: "CONNECT")), word, "caption: \(word), connected")
            equal(signalCaption(info([l])), signalWord(signalLevel(info([l])) ?? -1), "caption: \(word) is the bars' word")
        }
        equal(signalCaption(info([sa], radio: .other(5))), "Good", "caption: another AT+CFUN value reads as the bars")
    }

    static func badges() {
        equal(techBadgeText(info([leg("NR5G-SA", rsrp: -86)])), "5G SA", "badge: 5G SA")
        equal(techBadgeText(info([leg("LTE", rsrp: -90), leg("NR5G-NSA", rsrp: -88)])), "5G NSA", "badge: 5G NSA")
        equal(techBadgeText(info([leg("LTE", rsrp: -90)])), "LTE", "badge: LTE")
        equal(techBadgeText(info([leg("WCDMA", rsrp: -80)])), "3G", "badge: WCDMA is 3G")
        equal(techBadgeText(NetworkInfo(radio: .on, accessTechnology: 10)), "LTE", "badge: LTE with a 5G core is LTE")
        equal(techBadgeText(NetworkInfo(radio: .on, accessTechnology: 12)), "5G SA", "badge: AcT 12 alone")
        check(techBadgeText(info([leg("LTE", rsrp: -90)], radio: .airplane)) == nil, "badge: none with the radio off")
        check(techBadgeText(info([], state: "SEARCH")) == nil, "badge: none while searching")
        check(techBadgeText(info([], state: "LIMSRV")) == nil, "badge: none in limited service")
        check(techBadgeText(NetworkInfo()) == nil, "badge: none when unknown")
        check(techBadgeText(info([leg("GSM", rsrp: nil)])) == nil, "badge: none for a RAT not named here")
    }

    // The carriers, primary first, then a leg's band they do not list; nil with none.
    static func bands() {
        equal(bandText(info([leg("NR5G-SA", rsrp: -86, band: "n41")])), "n41", "bands: one leg's band")
        equal(bandText(info([leg("LTE", rsrp: -90, band: "B3")], carriers: ["B3", "B41"])), "B3 + B41",
              "bands: the carriers")
        equal(bandText(info([leg("LTE", rsrp: -90, band: "B3"), leg("NR5G-NSA", rsrp: -88, band: "n78")],
                            carriers: ["B3"])), "B3 + n78", "bands: EN-DC's NR band after the carriers")
        equal(bandText(info([leg("NR5G-SA", rsrp: -86, band: "n41")], carriers: ["n41", "n78"])), "n41 + n78",
              "bands: no band twice")
        check(bandText(info([leg("WCDMA", rsrp: -80)])) == nil, "bands: none for WCDMA")
        check(bandText(NetworkInfo()) == nil, "bands: none when unknown")
    }

    static func zone(_ level: Int, _ lower: Double, _ upper: Double) -> QualityZone {
        QualityZone(level: level, lower: lower, upper: upper)
    }

    // The gauges' ranges, and the zones the charts shade (poor, fair, good, excellent; clipped to the range).
    static func metrics() {
        equal(SignalMetric.allCases, [.rsrp, .rsrq, .sinr], "metrics: RSRP, RSRQ, SINR")
        equal(SignalMetric.rsrp.range(rat: "LTE"), -140...(-44), "metrics: RSRP's range")
        equal(SignalMetric.rsrp.range(rat: "NR"), -140...(-44), "metrics: NR RSRP's range")
        equal(SignalMetric.rsrq.range(rat: "LTE"), -20...(-3), "metrics: RSRQ's range")
        equal(SignalMetric.sinr.range(rat: "LTE"), -10...30, "metrics: SINR's range")
        equal(SignalMetric.rsrp.range(rat: "WCDMA"), -120...(-25), "metrics: RSCP's range")
        equal(SignalMetric.rsrp.title(rat: "LTE"), "RSRP", "metrics: RSRP's name")
        equal(SignalMetric.rsrp.title(rat: "WCDMA"), "RSCP", "metrics: WCDMA's RSCP")
        equal([SignalMetric.rsrq.title(rat: "NR"), SignalMetric.sinr.title(rat: "NR")], ["RSRQ", "SINR"], "metrics: names")
        equal(SignalMetric.allCases.map { $0.unit }, ["dBm", "dB", "dB"], "metrics: units")

        equal(qualityZones(.rsrp, rat: "LTE"), [zone(1, -140, -100), zone(2, -100, -90), zone(3, -90, -80), zone(4, -80, -44)],
              "zones: RSRP, as the bars' thresholds")
        equal(qualityZones(.rsrp, rat: "WCDMA"), [zone(1, -120, -95), zone(2, -95, -85), zone(3, -85, -75), zone(4, -75, -25)],
              "zones: RSCP")
        equal(qualityZones(.sinr, rat: "NR"), [zone(1, -10, 0), zone(2, 0, 5), zone(3, 5, 13), zone(4, 13, 30)],
              "zones: SINR, as the caps")
        equal(qualityZones(.rsrq, rat: "LTE"), [zone(2, -20, -15), zone(3, -15, -10), zone(4, -10, -3)],
              "zones: RSRQ (poor is below the range)")

        let quality: [(SignalMetric, Double, Int)] = [
            (.rsrp, -80, 4), (.rsrp, -80.5, 3), (.rsrp, -90, 3), (.rsrp, -100, 2), (.rsrp, -100.5, 1), (.rsrp, -130, 1),
            (.sinr, 13, 4), (.sinr, 12.9, 3), (.sinr, 5, 3), (.sinr, 0, 2), (.sinr, -0.1, 1),
            (.rsrq, -3, 4), (.rsrq, -10, 4), (.rsrq, -10.5, 3), (.rsrq, -15, 3), (.rsrq, -15.5, 2), (.rsrq, -20, 2),
            (.rsrq, -21, 1),
        ]
        for (metric, value, level) in quality {
            equal(metricQuality(metric, value, rat: "LTE"), level, "quality: \(metric) \(value)")
        }
        equal(metricQuality(.rsrp, -76, rat: "WCDMA"), 3, "quality: RSCP -76")
        check(metricQuality(.rsrp, nil, rat: "LTE") == nil, "quality: none for no value")
    }

    // Rising, falling or steady: the last value against the mean of up to ten before it.
    static func trends() {
        check(trendWord([], tolerance: 2) == nil && trendWord([-90], tolerance: 2) == nil, "trend: none with under two values")
        equal(trendWord([-90, -90, -89], tolerance: 2), "steady", "trend: within the tolerance")
        equal(trendWord([-95, -95, -90], tolerance: 2), "rising", "trend: rising")
        equal(trendWord([-85, -85, -92], tolerance: 2), "falling", "trend: falling")
        // Only the ten values before the last count.
        equal(trendWord([-140] + Array(repeating: -90.0, count: 10) + [-90], tolerance: 2), "steady",
              "trend: older values do not count")
    }
}
