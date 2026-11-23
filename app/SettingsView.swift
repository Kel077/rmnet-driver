// The app's Settings window (the Settings scene of RMNetApp, StatusView.swift; Cmd-, or the gear in the menu bar
// item's panel): how the menu bar item draws itself, the antenna or the signal bars, kept in the user defaults by
// MenuBarStatus (MenuBarIconPreference) and in effect at once.
import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var menuBar: MenuBarStatus

    var body: some View {
        Form {
            Section {
                Picker("Menu bar icon", selection: Binding(get: { menuBar.iconStyle },
                                                           set: { menuBar.setIconStyle($0) })) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        HStack(spacing: Spacing.s) {
                            preview(style)
                                .frame(width: 34, alignment: .center)
                            Text(verbatim: style.title)
                        }
                        .tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Menu bar")
            } footer: {
                Text(verbatim: footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: String {
        switch menuBar.iconStyle {
        case .antenna:
            return "The antenna is struck through unless the connection is up. It never asks the modem anything."
        case .signal:
            return "The bars show the modem's signal and its technology, like a phone's. While RMNet runs they read the "
                + "signal every 15 seconds: one short command over the modem's AT port, skipped while another program "
                + "uses the port (the last bars stay, dimmed). A slash means no connection; an airplane, the radio is off."
        }
    }

    @ViewBuilder private func preview(_ style: MenuBarIconStyle) -> some View {
        switch style {
        case .antenna:
            Image(systemName: "antenna.radiowaves.left.and.right")
        case .signal:
            Image(nsImage: menuBarSignalImage(MenuBarSignalIcon(bars: .filled(3), text: "5G", accessibilityLabel: "")))
                .accessibilityHidden(true)
        }
    }
}
