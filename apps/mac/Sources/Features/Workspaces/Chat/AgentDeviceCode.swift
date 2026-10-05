// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// The page and one-time code a device sign-in prints, read off the screen of
/// the provider's own terminal.
///
/// The terminal stays the real sign-in. This only saves the person retyping
/// what it already shows: the sheet opens the page and copies the code. The
/// code is the half a person types into the browser, not a credential, and it
/// goes nowhere but this device's clipboard.
struct AgentDeviceCode: Equatable, Sendable {
    let url: URL
    let code: String

    /// Finds the first https link and the first code after it, shaped like
    /// `DSJZ-RD351`. Nil until both are on screen, so a half-drawn screen is
    /// simply read again.
    static func parse(_ screen: String) -> AgentDeviceCode? {
        guard let link = screen.firstMatch(of: #/https://[^\s"'<>]+/#) else { return nil }
        let rest = screen[link.range.upperBound...]
        guard let code = rest.firstMatch(of: #/\b[A-Z0-9]{4,}-[A-Z0-9]{4,}\b/#),
              let url = URL(string: String(link.output)), url.host != nil else { return nil }
        return AgentDeviceCode(url: url, code: String(code.output))
    }

    /// Muse's launcher offers to open a browser before it starts polling for
    /// approval. The sheet already opens the page on this device. EOF skips
    /// that optional launcher step, without closing the terminal or approving
    /// the login, and avoids opening another browser on a remote chat host.
    func browserPromptReply(backend: String, screen: String) -> [UInt8]? {
        guard backend == "muse", url.host == "auth.meta.com",
              screen.contains("Open this page to sign in:"),
              let printedCode = screen.range(of: code, options: .backwards),
              screen[printedCode.upperBound...].contains("Press Enter to open it in your browser:") else { return nil }
        return [0x04]
    }
}
