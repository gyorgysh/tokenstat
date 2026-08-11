// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
#if !os(macOS)
import UIKit
#endif

// The client is iOS and iPadOS only.
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
    /// The kernel's model identifier, `iPhone18,2` on a phone. Simulators
    /// report the host architecture, so the environment carries the real one.
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

    /// The name a person would use for this device.
    static var marketing: String {
        let id = identifier
        if let known = models[id] { return known }
        if id.hasPrefix("iPad") { return "iPad" }
        if id.hasPrefix("iPhone") { return "iPhone" }
        return UIDevice.current.model
    }

    /// Names this device on the host, unless somebody already named it.
    ///
    /// Runs at launch rather than at connect: the account directory shows this
    /// name to every other device, and a phone that only names itself when it
    /// dials a Mac sits in everyone else's list as "iPhone" until it does.
    @MainActor
    static func publish() async {
        guard let identity = try? await Bridge.machineIdentity() else { return }
        let current = identity.label.trimmingCharacters(in: .whitespacesAndNewlines)
        // A name somebody typed wins, whatever it says. Somebody who renames
        // their phone to "iPhone" meant it, and this used to overwrite them on
        // every launch because the name matched the placeholder. Our own
        // rename counts as chosen too, which is what stops this running twice.
        if identity.labelIsChosen == true, !current.isEmpty { return }
        let wanted = marketing
        guard current != wanted else { return }
        _ = try? await Bridge.renameMachine(wanted)
    }

    /// Only the generations this build can meet. Anything newer falls back to
    /// the family, which is why this table does not need to be exhaustive and
    /// must never grow a guess.
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

/// Which machine a row is, at a glance.
///
/// A list of five identical grey rectangles is a list nobody reads. The kind
/// comes from the account when it knows one, and from the name when it does
/// not: a machine called "MacBook Pro" is a laptop whatever the directory has
/// recorded, and a machine that says nothing is drawn as a desktop rather than
/// guessed at.
enum ClientDeviceIcon {
    static func symbol(name: String?, isHost: Bool) -> String {
        let lower = (name ?? "").lowercased()
        if !isHost || lower.contains("iphone") { return "iphone" }
        if lower.contains("ipad") { return "ipad" }
        if lower.contains("macbook") || lower.contains("laptop") || lower.contains("thinkpad") {
            return "laptopcomputer"
        }
        if lower.contains("imac") || lower.contains("mac studio") || lower.contains("mac mini")
            || lower.contains("mac pro") || lower.contains("desktop")
        {
            return "desktopcomputer"
        }
        if lower.contains("server") || lower.contains("linux") || lower.contains("ubuntu") {
            return "server.rack"
        }
        return "desktopcomputer"
    }
}

#endif
