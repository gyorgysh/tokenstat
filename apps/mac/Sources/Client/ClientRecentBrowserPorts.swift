// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#if !os(macOS)
import SwiftUI

struct ClientRecentBrowserPorts: View {
    let owner: WorkReference?
    @Binding var portText: String
    var body: some View {
        let ports = BrowserHistory.shared.entry(for: owner).ports
        if !ports.isEmpty {
            Menu {
                ForEach(ports, id: \.self) { port in
                    Button(String(port), .browser) { portText = String(port) }
                }
            } label: {
                Label("Recent ports", systemImage: "clock.arrow.circlepath")
                    .font(ClientType.caption)
            }
            .tint(Theme.accent)
        }
    }
}
#endif
