// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

// The screen a device asks to see is a Mac's. Nobody asks an iPhone for its
// display, so this whole surface is macOS only.
#if os(macOS)

import AppKit
import SwiftUI
import UserNotifications

struct DeviceAccessSelection: Equatable {
    var workspace = false
    var view = false
    var control = false
}

@MainActor
@Observable
final class DeviceAccessRequests {
    static let shared = DeviceAccessRequests()

    private(set) var pending: [DeviceAccessPending] = []
    private(set) var errorMessage: String?
    private(set) var answeringIDs: Set<String> = []

    var asking: DeviceAccessPending?

    var oldest: DeviceAccessPending? { pending.min { $0.askedAt < $1.askedAt } }

    func askAboutOldest() {
        asking = oldest
    }

    private var announced: Set<String> = []
    private var polling: Task<Void, Never>?
    /// System Screen Recording / Accessibility, asked the moment a screen
    /// grant is given. The Devices toggles already did this. Answering the
    /// sheet did not, so Mac-to-Mac could approve a device and still have no
    /// capture prompt.
    private let screenAccess = ScreenAccess()

    private func stamp(_ request: DeviceAccessPending) -> String {
        "\(request.id):\(request.control):\(request.askedAt)"
    }

    private static let pollInterval: Duration = .seconds(2)

    private init() {}

    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    func refresh() async {
        async let screen = try? Bridge.pendingDeviceAccess(.screen)
        async let workspace = try? Bridge.pendingDeviceAccess(.workspace)
        let rows = (await screen ?? []) + (await workspace ?? [])
        let arrived = rows.filter { !announced.contains(stamp($0)) }
        pending = rows
        announced.formIntersection(Set(rows.map(stamp)))
        if let asking {
            let live = rows.first { $0.id == asking.id }
            if live != asking { self.asking = live }
        }
        if self.asking == nil, let first = arrived.min(by: { $0.askedAt < $1.askedAt }) {
            self.asking = first
            if !NSApplication.shared.isActive {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        for request in arrived {
            announced.insert(stamp(request))
            announce(request)
        }
    }

    func answer(_ request: DeviceAccessPending, view: Bool, control: Bool) async {
        guard answeringIDs.insert(request.id).inserted else { return }
        defer { answeringIDs.remove(request.id) }
        do {
            switch request.kind {
            case .screen:
                // Ask macOS before the grant lands, so the prompt is up while
                // the other device retries rather than after it has already
                // failed to get a picture.
                if view {
                    _ = screenAccess.requestScreenRecording()
                    if control { _ = screenAccess.requestAccessibility() }
                }
                try await Bridge.answerScreenAccess(
                    peerID: request.peerID,
                    view: view,
                    control: control
                )
            case .workspace:
                try await Bridge.setWorkspaceAccess(peerID: request.peerID, allow: view)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
            return
        }
        if asking?.id == request.id { asking = nil }
        withdraw(request)
        await refresh()
    }

    func answerConfigured(_ request: DeviceAccessPending, selection: DeviceAccessSelection,
                          original: DeviceAccessSelection) async {
        let peerIDs = ["screen:\(request.peerID)", "workspace:\(request.peerID)"]
        guard peerIDs.allSatisfy({ !answeringIDs.contains($0) }) else { return }
        answeringIDs.formUnion(peerIDs)
        defer { answeringIDs.subtract(peerIDs) }
        do {
            await refresh()
            guard pending.contains(where: { $0.id == request.id && $0.askedAt == request.askedAt }) else {
                errorMessage = L10n.text("apple.deviceaccessrequestsheet.request_expired")
                return
            }
            async let workspaces = Bridge.workspaceAccessList()
            async let screens = Bridge.screenPermissions()
            let currentWorkspace = (try await workspaces).contains(request.peerID)
            let currentScreen = (try await screens).first { $0.peerID == request.peerID }
            let workspace = selection.workspace == original.workspace ? currentWorkspace : selection.workspace
            let selectedView = selection.view == original.view ? (currentScreen?.view ?? false) : selection.view
            let control = selection.control == original.control ? (currentScreen?.control ?? false) : selection.control
            let view = selectedView || control
            if view && currentScreen?.view != true {
                _ = screenAccess.requestScreenRecording()
            }
            if control && currentScreen?.control != true {
                _ = screenAccess.requestAccessibility()
            }
            let screenChanged = (currentScreen?.view ?? false) != view
                || (currentScreen?.control ?? false) != control
            let pendingScreen = pending.contains { $0.peerID == request.peerID && $0.kind == .screen }
            let pendingWorkspace = pending.contains { $0.peerID == request.peerID && $0.kind == .workspace }
            if pendingScreen || screenChanged {
                try await Bridge.answerScreenAccess(peerID: request.peerID, view: view, control: control)
            }
            if pendingWorkspace || currentWorkspace != workspace {
                try await Bridge.setWorkspaceAccess(peerID: request.peerID, allow: workspace)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            await refresh()
            return
        }
        if asking?.id == request.id { asking = nil }
        for row in pending where row.peerID == request.peerID { withdraw(row) }
        await refresh()
    }

    func denyPending(_ request: DeviceAccessPending) async {
        do {
            await refresh()
            let pendingWorkspace = pending.contains { $0.peerID == request.peerID && $0.kind == .workspace }
            let pendingScreen = pending.contains { $0.peerID == request.peerID && $0.kind == .screen }
            async let workspaces = Bridge.workspaceAccessList()
            async let screens = Bridge.screenPermissions()
            let currentWorkspace = (try await workspaces).contains(request.peerID)
            let screen = (try await screens).first { $0.peerID == request.peerID }
            let current = DeviceAccessSelection(workspace: currentWorkspace,
                view: screen?.view == true, control: screen?.control == true)
            await answerConfigured(request, selection: DeviceAccessSelection(
                workspace: pendingWorkspace ? false : current.workspace,
                view: current.view,
                control: pendingScreen ? false : current.control
            ), original: current)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func withdraw(_ request: DeviceAccessPending) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.identifier(request.id)])
    }


    nonisolated static let category = "device.access"
    nonisolated static let allowViewAction = "device.access.view"
    nonisolated static let allowControlAction = "device.access.control"
    nonisolated static let denyAction = "device.access.deny"

    nonisolated static func identifier(_ requestID: String) -> String { "device.access.\(requestID)" }

    static func registerCategory() {
        let category = UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(
                    identifier: allowViewAction,
                    title: L10n.text("apple.deviceaccessrequests.allow.e213c161"),
                    options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: allowControlAction,
                    title: L10n.text("apple.deviceaccessrequests.allow_with_control.6a1fb974"),
                    options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: denyAction,
                    title: L10n.text("apple.deviceaccessrequests.deny.05a2d733"),
                    options: [.destructive, .authenticationRequired]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func handleNotification(action: String, requestID: String) async {
        await refresh()
        guard let request = pending.first(where: { $0.id == requestID }) else { return }
        switch action {
        case UNNotificationDefaultActionIdentifier:
            asking = request
            NSApplication.shared.activate(ignoringOtherApps: true)
        case Self.allowViewAction: await answer(request, view: true, control: false)
        case Self.allowControlAction: await answer(request, view: true, control: true)
        case Self.denyAction: await answer(request, view: false, control: false)
        default: break
        }
    }

    private func announce(_ request: DeviceAccessPending) {
        guard !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = request.headline
        content.body = request.detail
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = Self.category
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.identifier(request.id),
                content: content,
                trigger: nil
            )
        )
    }
}

#endif
