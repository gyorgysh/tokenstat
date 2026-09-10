// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

// The client is iOS and iPadOS only.
#if !os(macOS)

/// Everywhere in the client search can send somebody.
///
/// One catalogue, kept next to the destinations it names, because a place
/// nobody can be sent to is worse than one that is missing: it reads as a
/// search result that does nothing. Adding a screen means adding its case here
/// and the arm that opens it in `ClientRootView.openPendingPlace`, and the
/// compiler says so.
enum ClientAppDestination: Hashable {
    case tab(ClientTab)
    /// Home, with its editor open over it.
    case customizeHome
    /// The account sheet, on one of its panes, optionally one screen deeper.
    case account(ClientAccountPane, ClientAccountDetail?)
    /// Devices, showing one machine.
    case device(String)
}

/// A screen inside the account sheet, rather than one of its panes.
enum ClientAccountDetail: String, Hashable {
    case tabs
    case plans
    case sample
    case licenses
}

/// Where the account sheet should land when something outside it asked for a
/// setting. Read once by the sheet, which clears it.
struct ClientAccountRequest: Hashable {
    let pane: ClientAccountPane
    let detail: ClientAccountDetail?
}

@MainActor
enum ClientAppPlaces {
    /// The places matching what somebody typed, best first.
    static func matches(_ query: String, machines: [Machine]) -> [WorkSearchPlace] {
        WorkSearchPlaceMatch.rank(query, in: all(machines: machines))
    }

    /// Where a place goes. The identifier carries it, so the shared sheet can
    /// hand a place back without knowing what a tab is.
    ///
    /// The last segment of an account identifier names a screen inside the
    /// pane when there is one, and otherwise only tells two places on the same
    /// pane apart, which is what keeps the list's identifiers unique. A word
    /// that names no screen lands on the pane, which is where those settings
    /// are.
    static func destination(of place: WorkSearchPlace) -> ClientAppDestination? {
        let parts = place.id.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "tab":
            guard parts.count > 1, let tab = ClientTab(rawValue: parts[1]) else { return nil }
            return .tab(tab)
        case "home":
            return .customizeHome
        case "account":
            guard parts.count > 1, let pane = ClientAccountPane(rawValue: parts[1]) else { return nil }
            return .account(pane, parts.count > 2 ? ClientAccountDetail(rawValue: parts[2]) : nil)
        case "device":
            guard parts.count > 1, !parts[1].isEmpty else { return nil }
            return .device(parts[1])
        default:
            return nil
        }
    }

    static func all(machines: [Machine]) -> [WorkSearchPlace] {
        tabs + screens + devices(machines)
    }

    /// The tabs, whether or not this device shows them in the bar. A hidden
    /// tab is still in the app, and the bar makes room for the open one.
    private static var tabs: [WorkSearchPlace] {
        ClientTab.allCases.map { tab in
            WorkSearchPlace(
                id: "tab:\(tab.rawValue)",
                title: tab.label,
                detail: "Tab · \(tab.editorDetail)",
                icon: icon(for: tab),
                keywords: keywords(for: tab)
            )
        }
    }

    /// Every machine on the account, so a name somebody knows finds the device
    /// rather than making them count rows on Devices.
    private static func devices(_ machines: [Machine]) -> [WorkSearchPlace] {
        machines.compactMap { machine in
            guard let id = machine.machineID, !id.isEmpty else { return nil }
            return WorkSearchPlace(
                id: "device:\(id)",
                title: machine.displayName,
                detail: "Devices · \(machine.platform ?? "Linked device")",
                icon: .device,
                keywords: ["machine", "computer", "device"]
            )
        }
    }

    /// The screens and settings that are not tabs. Written out rather than
    /// derived, because what somebody would type for a setting is rarely its
    /// heading: nobody searches for "This device", they search for "traffic".
    private static var screens: [WorkSearchPlace] {
        [
            .init(id: "home:editor", title: "Customize Home", detail: "Home",
                  icon: .layout,
                  keywords: ["cards", "arrange", "sections", "customise", "edit", "rearrange", "hide"]),
            .init(id: "account:thisDevice", title: "Settings", detail: "Behind your avatar · This device",
                  icon: .settings,
                  keywords: ["preferences", "options", "config", "setup", "device"]),
            .init(id: "account:account", title: "Account", detail: "Behind your avatar",
                  icon: .account,
                  keywords: ["profile", "handle", "sign out", "log out", "avatar", "relay", "usage"]),
            .init(id: "account:account:plans", title: "Plan", detail: "Account",
                  icon: .plans,
                  keywords: ["plans", "subscription", "billing", "upgrade", "price", "tier", "pro", "renew"]),
            .init(id: "account:account:delete", title: "Delete account", detail: "Account · Danger zone",
                  icon: .delete,
                  keywords: ["remove", "close", "erase", "danger"]),
            .init(id: "account:thisDevice:notifications", title: "Notifications", detail: "Account · This device",
                  icon: .settings,
                  keywords: ["push", "alerts", "notify", "sounds", "badge", "settings"]),
            .init(id: "account:thisDevice:tabs", title: "Tabs", detail: "Account · This device",
                  icon: .layout,
                  keywords: ["tab bar", "sidebar", "arrange", "hide", "show", "ssh", "settings"]),
            .init(id: "account:thisDevice:traffic", title: "Local traffic", detail: "Account · This device",
                  icon: .connect,
                  keywords: ["network", "connections", "direct", "relayed", "lan", "settings"]),
            .init(id: "account:thisDevice:cache", title: "tokenstat cache", detail: "Account · This device",
                  icon: .archive,
                  keywords: ["storage", "downloads", "files", "space", "clear", "settings"]),
            .init(id: "account:thisDevice:savedWork", title: "Saved work", detail: "Account · This device",
                  icon: .archive,
                  keywords: ["offline", "conversations", "changes", "storage", "encrypted", "clear", "settings"]),
            .init(id: "account:thisDevice:layout", title: "Layout", detail: "Account · This device",
                  icon: .layout,
                  keywords: ["sidebar", "tab bar", "ipad", "appearance", "settings"]),
            .init(id: "account:legal:sample", title: "See a sample", detail: "Account · Legal",
                  icon: .run,
                  keywords: ["demo", "example", "try", "help", "invented", "tour"]),
            .init(id: "account:legal", title: "Terms and privacy", detail: "Account · Legal",
                  icon: .security,
                  keywords: ["legal", "policy", "licence", "license", "conditions"]),
            .init(id: "account:legal:licenses", title: "Open source licenses", detail: "Account · Legal",
                  icon: .docs,
                  keywords: ["notices", "third party", "attribution", "libraries"])
        ]
    }

    private static func icon(for tab: ClientTab) -> ActionIcon {
        switch tab {
        case .home: return .home
        case .workspaces: return .reveal
        case .insights: return .benchmarks
        case .machines: return .device
        case .ssh: return .source
        }
    }

    private static func keywords(for tab: ClientTab) -> [String] {
        switch tab {
        case .home: return ["dashboard", "spend", "today", "week", "activity", "limits", "start"]
        case .workspaces: return ["folders", "projects", "chat", "sessions", "repos", "git", "terminal"]
        case .insights: return ["breakdown", "models", "projects", "reports", "charts", "cost"]
        case .machines: return ["computers", "laptop", "mac", "linked", "pair", "remote"]
        case .ssh: return ["servers", "terminal", "keys", "vault", "shell"]
        }
    }
}

#endif
