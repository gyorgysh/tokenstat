// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if os(macOS)
import SwiftUI
import AppKit

struct SimulatorSetupView: View {
    let setup: SimulatorSetupState
    let refreshing: Bool
    var showsHeader = true
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                Image(systemName: "iphone.and.ipad").font(Theme.font(30, weight: .light)).foregroundStyle(Theme.accent)
                Text(L10n.text("apple.simulator.setup_title")).font(Theme.font(18, weight: .semibold))
                Text(L10n.text("apple.simulator.setup_help")).font(Theme.font(12)).foregroundStyle(Theme.controlGlyph)
            }
            platform(.ios, status: setup.apple)
            platform(.android, status: setup.android)
            Button(L10n.text("apple.simulator.refresh"), .refresh, action: refresh)
                .disabled(refreshing)
            if refreshing { ProgressView().controlSize(.small).accessibilityLabel(L10n.text("apple.simulator.checking")) }
        }.frame(maxWidth: 460, alignment: .leading).frame(maxWidth: .infinity)
    }
    private func platform(_ platform: SimulatorDevice.Platform, status: SimulatorSetupState.Status) -> some View {
        let apple = platform == .ios
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: apple ? "iphone" : "apps.iphone").foregroundStyle(Theme.accent)
                Text(apple ? "iOS" : "Android").font(Theme.font(13, weight: .semibold))
                Spacer(minLength: 0)
                if case .ready = status { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
            }
            Text(title(status, apple: apple)).font(Theme.font(13, weight: .medium))
            if case .checking = status { }
            else {
                if case .ready = status { }
                else {
                    Text(help(status, apple: apple))
                        .font(Theme.font(12)).foregroundStyle(Theme.controlGlyph).fixedSize(horizontal: false, vertical: true)
                }
                if let failure = status.failure {
                    Text(failure).font(Theme.font(11)).foregroundStyle(Theme.warning)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Button(toolButton(apple: apple), .external) { openTools(apple: apple) }
                Button(L10n.text("apple.simulator.setup_guide"), .help) {
                    open(apple ? "https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components"
                               : "https://developer.android.com/studio/run/managing-avds")
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
    }
    private func title(_ status: SimulatorSetupState.Status, apple: Bool) -> String {
        switch status {
        case .checking: L10n.text("apple.simulator.checking")
        case .toolsMissing: apple ? L10n.text("apple.simulator.xcode_missing") : L10n.text("apple.simulator.android_missing_title")
        case .noDevices: apple ? L10n.text("apple.simulator.ios_devices_missing") : L10n.text("apple.simulator.android_devices_missing")
        case .ready(let count): L10n.text("apple.simulator.devices_available", String(count))
        case .failed: L10n.text("apple.simulator.discovery_failed")
        }
    }
    private func help(_ status: SimulatorSetupState.Status, apple: Bool) -> String {
        if apple { return status == .toolsMissing ? L10n.text("apple.simulator.xcode_missing_help") : L10n.text("apple.simulator.ios_devices_help") }
        return status == .toolsMissing ? L10n.text("apple.simulator.android_missing_help") : L10n.text("apple.simulator.android_devices_help")
    }
    private func openTools(apple: Bool) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: apple ? "com.apple.dt.Xcode" : "com.google.android.studio") {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        } else {
            open(apple ? "https://developer.apple.com/xcode/" : "https://developer.android.com/studio")
        }
    }
    private func toolButton(apple: Bool) -> String {
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: apple ? "com.apple.dt.Xcode" : "com.google.android.studio") != nil
        if apple { return installed ? L10n.text("apple.simulator.open_xcode") : L10n.text("apple.simulator.get_xcode") }
        return installed ? L10n.text("apple.simulator.open_android_studio") : L10n.text("apple.simulator.get_android_studio")
    }
    private func open(_ value: String) { if let url = URL(string: value) { NSWorkspace.shared.open(url) } }
}

#endif
