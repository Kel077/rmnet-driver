// The window's Overview: the connection at a glance. For now its hero card only (the state, the technology, the
// bars, the operator, the bands and the addresses), from the shared driver status (StatusController) and the
// modem's network read (ModemController, which reads the network every 5 s while the Overview is shown, never
// the bands). The rest of the Overview (the throughput chart, the signal sparkline, the data counters, the
// SIM, Messages and Driver cards) comes with its own task.
import SwiftUI

/// What the shell gives the Overview: the shared controllers, the throughput sampler (sampled every second while
/// the Overview is shown) and a way to show another screen. The controllers are observed by the cards that draw
/// them, so that the throughput's turn every second, or a message being typed, redraws only what shows it.
struct OverviewView: View {
    let driverStatus: StatusController
    let modem: ModemController
    let messages: SmsController
    let throughput: ThroughputSampler
    let navigate: (Screen) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                OverviewHero(driverStatus: driverStatus, modem: modem)
            }
            .padding(Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    driverStatus.refresh()
                    modem.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Read the driver's status and the network again")
            }
        }
    }
}

/// The hero card: the state in large type (Connected only while the driver's link is up), the technology badge, the
/// bars with their word, the operator and the bands; the addresses while connected. A value not known is "—".
struct OverviewHero: View {
    @ObservedObject var driverStatus: StatusController
    @ObservedObject var modem: ModemController

    var body: some View {
        let pill = connectionPill(driverStatus.connectionHeadline)
        let info = modem.info
        let level = info.map(signalLevel)
        Card {
            VStack(alignment: .leading, spacing: Spacing.m) {
                StatusPill(state: pill.state, text: pill.text, prominent: true)
                HStack(alignment: .center, spacing: Spacing.s) {
                    if let tech = info.flatMap(techBadgeText) {
                        TechBadge(text: tech)
                    }
                    SignalBars(level: level, height: 14)
                    Text(verbatim: level.map(signalWord) ?? "Signal not known")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    KeyValueRow(label: "Operator", value: info.flatMap { $0.networkName ?? $0.operatorName } ?? "—")
                    KeyValueRow(label: "Band", value: info.flatMap(bandText) ?? "—")
                }
                if let failure = modem.infoFailure {
                    Label {
                        Text(verbatim: failure + (modem.infoAt.map { " Shown " + asOfText($0) + "." } ?? ""))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                let addresses = pill.state == .connected ? addressRows(driverStatus.status.properties) : []
                if !addresses.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        ForEach(addresses, id: \.label) { row in
                            KeyValueRow(label: row.label, value: row.value, copyable: true)
                        }
                    }
                }
            }
        }
    }
}
