// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

#if !os(macOS)

enum ClientAppDestination: Hashable {
    case tab(ClientTab)
    case customizeHome
    case customizeWorkspaces
    case account(ClientAccountPane, ClientAccountDetail?)
    case device(String)
}

enum ClientAccountDetail: String, Hashable {
    case tabs
    case plans
    case sample
    case licenses
}

struct ClientAccountRequest: Hashable {
    let pane: ClientAccountPane
    let detail: ClientAccountDetail?
}

@MainActor
enum ClientAppPlaces {
    static func matches(_ query: String, machines: [Machine]) -> [WorkSearchPlace] {
        WorkSearchPlaceMatch.rank(query, in: all(machines: machines))
    }

    static func destination(of place: WorkSearchPlace) -> ClientAppDestination? {
        let parts = place.id.split(separator: ":", maxSplits: 2).map(String.init)
        switch parts.first {
        case "tab":
            guard parts.count > 1, let tab = ClientTab(rawValue: parts[1]) else { return nil }
            return .tab(tab)
        case "home":
            return .customizeHome
        case "workspaces":
            return .customizeWorkspaces
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

    private static var tabs: [WorkSearchPlace] {
        ClientTab.allCases.map { tab in
            WorkSearchPlace(
                id: "tab:\(tab.rawValue)",
                title: tab.label,
                detail: L10n.text("apple.clientappplaces.tab_0.48f306d2", "\(tab.editorDetail)"),
                icon: icon(for: tab),
                keywords: keywords(for: tab)
            )
        }
    }

    private static func devices(_ machines: [Machine]) -> [WorkSearchPlace] {
        machines.compactMap { machine in
            guard let id = machine.machineID, !id.isEmpty else { return nil }
            return WorkSearchPlace(
                id: "device:\(id)",
                title: machine.displayName,
                detail: L10n.text("apple.clientappplaces.devices_0.163a371d", "\(machine.platform ?? L10n.text("apple.clientappplaces.linked_device.a7ba6a12"))"),
                icon: .device,
                keywords: ["machine", "computer", "device"]
            )
        }
    }

    private static var screens: [WorkSearchPlace] {
        [
            .init(id: "home:editor", title: L10n.text("apple.clientappplaces.customize_home.642cec6e"), detail: L10n.text("common.home"),
                  icon: .layout,
                  keywords: ["cards", "arrange", "sections", "customise", "edit", "rearrange", "hide"]),
            .init(id: "workspaces:editor", title: L10n.text("apple.clientappplaces.customize_projects.00ab91c5"), detail: L10n.text("common.projects"),
                  icon: .layout,
                  keywords: ["folders", "chats", "sessions", "arrange", "sections", "customise",
                             "edit", "rearrange", "hide", "order"]),
            .init(id: "account:thisDevice", title: L10n.text("common.settings"), detail: L10n.text("apple.clientappplaces.behind_your_avatar_this_device.41f21261"),
                  icon: .settings,
                  keywords: ["preferences", "options", "config", "setup", "device"]),
            .init(id: "account:account", title: L10n.text("common.account"), detail: L10n.text("apple.clientappplaces.behind_your_avatar.f60fd55f"),
                  icon: .account,
                  keywords: ["profile", "handle", L10n.text("apple.clientappplaces.sign_out.601f2951"), L10n.text("apple.clientappplaces.log_out.6a832af4"), "avatar", "relay", "usage"]),
            .init(id: "account:account:plans", title: L10n.text("apple.clientappplaces.plan.fa8ed0bd"), detail: L10n.text("common.account"),
                  icon: .plans,
                  keywords: ["plans", "subscription", "billing", "upgrade", "price", "tier", "pro", "renew"]),
            .init(id: "account:account:delete", title: L10n.text("apple.clientappplaces.delete_account.a2e20a33"), detail: L10n.text("apple.clientappplaces.account_danger_zone.ae19bbd5"),
                  icon: .delete,
                  keywords: ["remove", "close", "erase", "danger"]),
            .init(id: "account:thisDevice:notifications", title: L10n.text("apple.clientappplaces.notifications.78801183"), detail: L10n.text("apple.clientappplaces.account_this_device.8bb3f277"),
                  icon: .settings,
                  keywords: ["push", "alerts", "notify", "sounds", "badge", "settings"]),
            .init(id: "account:thisDevice:tabs", title: L10n.text("apple.clientappplaces.tabs.8e5ea509"), detail: L10n.text("apple.clientappplaces.account_this_device.8bb3f277"),
                  icon: .layout,
                  keywords: [L10n.text("apple.clientappplaces.tab_bar.a0b47f0a"), "sidebar", "arrange", "hide", "show", "ssh", "settings"]),
            .init(id: "account:thisDevice:traffic", title: L10n.text("apple.clientappplaces.local_traffic.ab770f30"), detail: L10n.text("apple.clientappplaces.account_this_device.8bb3f277"),
                  icon: .connect,
                  keywords: ["network", "connections", "direct", "relayed", "lan", "settings"]),
            .init(id: "account:thisDevice:cache", title: L10n.text("apple.clientappplaces.tokenstat_cache.697429b6"), detail: L10n.text("apple.clientappplaces.account_this_device.8bb3f277"),
                  icon: .archive,
                  keywords: ["storage", "downloads", "files", "space", "clear", "settings"]),
            .init(id: "account:thisDevice:savedWork", title: L10n.text("apple.clientappplaces.saved_work.9204cce7"), detail: L10n.text("apple.clientappplaces.account_this_device.8bb3f277"),
                  icon: .archive,
                  keywords: ["offline", "conversations", "changes", "storage", "encrypted", "clear", "settings"]),
            .init(id: "account:thisDevice:layout", title: L10n.text("apple.clientappplaces.layout.a5119091"), detail: L10n.text("apple.clientappplaces.account_this_device.8bb3f277"),
                  icon: .layout,
                  keywords: ["sidebar", L10n.text("apple.clientappplaces.tab_bar.a0b47f0a"), "ipad", "appearance", "settings"]),
            .init(id: "account:legal:sample", title: L10n.text("apple.clientappplaces.see_a_sample.ae8b0f8d"), detail: L10n.text("apple.clientappplaces.account_legal.a5b160c5"),
                  icon: .run,
                  keywords: ["demo", "example", "try", "help", "invented", "tour"]),
            .init(id: "account:legal", title: L10n.text("apple.clientappplaces.terms_and_privacy.8d60f3a9"), detail: L10n.text("apple.clientappplaces.account_legal.a5b160c5"),
                  icon: .security,
                  keywords: ["legal", "policy", "licence", "license", "conditions"]),
            .init(id: "account:legal:licenses", title: L10n.text("apple.clientappplaces.open_source_licenses.1a1b83db"), detail: L10n.text("apple.clientappplaces.account_legal.a5b160c5"),
                  icon: .docs,
                  keywords: ["notices", L10n.text("apple.clientappplaces.third_party.c618a193"), "attribution", "libraries"])
        ]
    }

    private static func icon(for tab: ClientTab) -> ActionIcon {
        switch tab {
        case .home: return .home
        case .workspaces: return .reveal
        case .insights: return .benchmarks
        case .machines: return .device
        case .team: return .team
        case .ssh: return .source
        }
    }

    private static func keywords(for tab: ClientTab) -> [String] {
        switch tab {
        case .home: return ["dashboard", "spend", "today", "week", "activity", "limits", "start"]
        case .workspaces: return ["folders", "projects", "chat", "sessions", "repos", "git", "terminal"]
        case .insights: return ["breakdown", "models", "projects", "reports", "charts", "cost"]
        case .machines: return ["computers", "laptop", "mac", "linked", "pair", "remote"]
        case .team: return ["team", "organization", "members", "invitations", "permissions"]
        case .ssh: return ["servers", "terminal", "keys", "vault", "shell"]
        }
    }
}

#endif
