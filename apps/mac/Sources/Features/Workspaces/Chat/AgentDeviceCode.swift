// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct AgentDeviceCode: Equatable, Sendable {
    let url: URL
    let code: String

    static func parse(_ screen: String) -> AgentDeviceCode? {
        guard let link = screen.firstMatch(of: #/https://[^\s"'<>]+/#) else { return nil }
        let rest = screen[link.range.upperBound...]
        guard let code = rest.firstMatch(of: #/\b[A-Z0-9]{4,}-[A-Z0-9]{4,}\b/#),
              let url = URL(string: String(link.output)), url.host != nil else { return nil }
        return AgentDeviceCode(url: url, code: String(code.output))
    }

    func browserPromptReply(backend: String, screen: String) -> [UInt8]? {
        guard backend == "muse", url.host == "auth.meta.com",
              screen.contains("Open this page to sign in:"),
              let printedCode = screen.range(of: code, options: .backwards),
              screen[printedCode.upperBound...].contains("Press Enter to open it in your browser:") else { return nil }
        return [0x04]
    }
}
