// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
#if !os(macOS)
import UIKit
#endif

#if !os(macOS)

/// What to call this phone on every other screen of the account.
///
/// A device has to name itself, because nothing else can. `UIDevice.name` has
/// answered "iPhone" for every app without the entitlement since iOS 16, and
/// the host's own fallback cannot do better from Rust: iOS has no `scutil` and
/// a sandboxed process cannot spawn `hostname`. So the app reads the model
/// identifier the kernel reports and turns it into the model's own name.
///
/// Unknown identifiers fall back to the family rather than to the raw code. A
/// device list that says "iPhone" is worse than one that says "iPhone 17 Pro
/// Max" and much better than one that says "iPhone19,4".
enum ClientDeviceName {
    static var identifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static var marketing: String {
        let id = identifier
        if let known = models[id] { return known }
        if id.hasPrefix("iPad") { return "iPad" }
        if id.hasPrefix("iPhone") { return "iPhone" }
        return UIDevice.current.model
    }

    @MainActor
    static func publish() async {
        guard let identity = try? await Bridge.machineIdentity() else { return }
        let current = identity.label.trimmingCharacters(in: .whitespacesAndNewlines)
        if identity.labelIsChosen == true, !current.isEmpty { return }
        let wanted = marketing
        guard current != wanted else { return }
        _ = try? await Bridge.renameMachine(wanted)
    }

    private static let models: [String: String] = [
        "iPhone18,1": "iPhone 17 Pro",
        "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17",
        "iPhone18,4": "iPhone Air",
        "iPhone17,1": "iPhone 16 Pro",
        "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16",
        "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,5": "iPhone 16e",
        "iPhone16,1": "iPhone 15 Pro",
        "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone15,4": "iPhone 15",
        "iPhone15,5": "iPhone 15 Plus",
        "iPhone15,2": "iPhone 14 Pro",
        "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone14,7": "iPhone 14",
        "iPhone14,8": "iPhone 14 Plus",
    ]
}

#endif

enum ClientDeviceIcon {
    static func symbol(name: String?, isHost: Bool, platform: String? = nil) -> String {
        let lower = [name, platform]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()

        if lower.contains("ipad") || lower.contains("ipados") {
            return "ipad"
        }
        if lower.contains("iphone") || lower.contains("ipod") {
            return "iphone"
        }
        if !isHost {
            if lower.contains("android") && (lower.contains("tablet") || lower.contains("tab ")) {
                return "ipad"
            }
            return "iphone"
        }
        if lower.contains("macbook") || lower.contains("laptop") || lower.contains("thinkpad") {
            return "laptopcomputer"
        }
        if lower.contains("imac") || lower.contains("mac studio") || lower.contains("mac mini")
            || lower.contains("mac pro") || lower.contains("desktop")
        {
            return "desktopcomputer"
        }
        if lower.contains("server") || lower.contains("linux") || lower.contains("ubuntu")
            || lower.contains("windows")
        {
            return "server.rack"
        }
        return "desktopcomputer"
    }

    static func symbol(for machine: Machine) -> String {
        symbol(
            name: machine.label ?? machine.displayName,
            isHost: machine.isHost,
            platform: machine.platform
        )
    }
}
