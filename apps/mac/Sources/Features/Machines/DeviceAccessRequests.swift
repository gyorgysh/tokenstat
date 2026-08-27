// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

// The screen a device asks to see is a Mac's. Nobody asks an iPhone for its
// display, so this whole surface is macOS only.
#if os(macOS)

import AppKit
import SwiftUI
import UserNotifications

/// Devices asking this computer for something, and the answer.
///
/// Two grants, one queue: watching this screen, and opening the work on this
/// machine. Being approved is not being let in. Every device on the account is
/// auto-approved on first contact with the tunnel, and an approved device
/// could read and write project files, spawn a shell and push commits, so each
/// of these is now a separate yes from whoever is at the machine.
///
/// A request travels the tunnel and lands in a policy file. This polls for it
/// and surfaces it the way the app surfaces everything else worth knowing and
/// not worth interrupting for: a card in the sidebar above the account row,
/// beside what update and sync say, staying until the question is answered.
/// Away from the app it is a local notification carrying the answers. The
/// sheet that actually asks is opened from either, never on its own.
@MainActor
@Observable
final class DeviceAccessRequests {
    static let shared = DeviceAccessRequests()

    private(set) var pending: [DeviceAccessPending] = []
    private(set) var errorMessage: String?

    /// The request the sheet is asking about, set by the sidebar card's View
    /// button, by a notification, or by the Devices card. Nothing opens it on
    /// its own: a question about a device is worth answering, not worth
    /// stopping what somebody was in the middle of.
    var asking: DeviceAccessPending?

    /// The oldest question still standing, which is the one the sidebar card
    /// names and the one its View button opens.
    var oldest: DeviceAccessPending? { pending.min { $0.askedAt < $1.askedAt } }

    /// Open the sheet on the oldest standing request. The sidebar card's View
    /// button, and a click on the banner.
    func askAboutOldest() {
        asking = oldest
    }

    /// Requests already announced, so a poll every few seconds does not say
    /// the same thing every few seconds.
    ///
    /// Keyed on *what was asked*, not on which device asked. A phone that was
    /// refused the mouse and comes back asking for it is a new question, and
    /// keying on the device alone meant that second ask arrived in silence.
    private var announced: Set<String> = []
    private var polling: Task<Void, Never>?

    private func stamp(_ request: DeviceAccessPending) -> String {
        "\(request.id):\(request.control):\(request.askedAt)"
    }

    /// How often to look. A request is answered by a person walking to their
    /// Mac, so seconds of latency cost nothing and a tighter loop would spend
    /// a wake-up on a question that is almost never there.
    private static let pollInterval: Duration = .seconds(5)

    private init() {}

    /// Start the poll, once, for the life of the app.
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
        // Both kinds, in one pass, so the queue is ordered by when somebody
        // asked rather than by which policy answered first.
        async let screen = try? Bridge.pendingDeviceAccess(.screen)
        async let workspace = try? Bridge.pendingDeviceAccess(.workspace)
        let rows = (await screen ?? []) + (await workspace ?? [])
        let arrived = rows.filter { !announced.contains(stamp($0)) }
        pending = rows
        // Forget what is gone, so a device that asks again in an hour is
        // announced again rather than being silently swallowed.
        announced.formIntersection(Set(rows.map(stamp)))
        // A question that expired or was answered elsewhere must not be left
        // on screen with buttons that no longer do anything. Matched on the
        // device rather than the stamp, so a re-ask keeps the sheet up with
        // the newer question in it.
        if let asking {
            let live = rows.first { $0.id == asking.id }
            // Assigned only on a real change. `@Observable` counts every write
            // as one, so writing an identical value each poll would rebuild
            // the sheet under somebody's cursor every five seconds.
            if live != asking { self.asking = live }
        }
        for request in arrived {
            announced.insert(stamp(request))
            announce(request)
        }
    }

    /// Grant, narrow or deny. Denying is everything false: refusing and
    /// revoking are the same state, and the host clears the request either way.
    ///
    /// `control` is ignored for a workspace request, which has no half.
    func answer(_ request: DeviceAccessPending, view: Bool, control: Bool) async {
        do {
            switch request.kind {
            case .screen:
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
        }
        if asking?.id == request.id { asking = nil }
        withdraw(request)
        await refresh()
    }

    /// Take the banner back once the question has been answered, wherever it
    /// was answered. A notification still sitting in Notification Centre about
    /// a device that already has access is the same nagging as a stuck badge.
    private func withdraw(_ request: DeviceAccessPending) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.identifier(request.id)])
    }

    // MARK: - Notification

    // Nonisolated: the notification delegate reads these from outside the main
    // actor to decide whether a response is even ours before hopping onto it.
    nonisolated static let category = "device.access"
    nonisolated static let allowViewAction = "device.access.view"
    nonisolated static let allowControlAction = "device.access.control"
    nonisolated static let denyAction = "device.access.deny"

    /// The notification's id, which is also how a click finds its request
    /// again. Ours, so it can be parsed; the text is for reading.
    nonisolated static func identifier(_ requestID: String) -> String { "device.access.\(requestID)" }

    /// Register the actions the banner carries. Called at launch, beside the
    /// presenter, because a category registered after a notification is
    /// delivered does not apply to it.
    static func registerCategory() {
        let category = UNNotificationCategory(
            identifier: Self.category,
            actions: [
                // "View only" is the whole grant for a workspace request and
                // half of one for a screen request. One category rather than
                // two, because a notification category is registered once at
                // launch and a second would be a second thing to keep in step.
                UNNotificationAction(
                    identifier: allowViewAction,
                    title: "Allow",
                    options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: allowControlAction,
                    title: "Allow with control",
                    options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: denyAction,
                    title: "Deny",
                    options: [.destructive, .authenticationRequired]
                ),
            ],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Answer from the banner's own buttons.
    ///
    /// The peer comes from the notification's identifier rather than from its
    /// text: the identifier is ours, the text is for reading.
    func handleNotification(action: String, requestID: String) async {
        // Re-read first. A request that expired or was answered in the window
        // between the banner and the click must not grant anything now.
        await refresh()
        guard let request = pending.first(where: { $0.id == requestID }) else { return }
        switch action {
        case UNNotificationDefaultActionIdentifier:
            // The banner itself was clicked rather than one of its buttons.
            // That is somebody asking to look at the question, so bring the
            // app forward and open the sheet on it.
            asking = request
            NSApplication.shared.activate(ignoringOtherApps: true)
        case Self.allowViewAction: await answer(request, view: true, control: false)
        case Self.allowControlAction: await answer(request, view: true, control: true)
        case Self.denyAction: await answer(request, view: false, control: false)
        default: break
        }
    }

    /// Post a banner, for an app that is not in front.
    ///
    /// Nothing is posted while the app is active: the sidebar card is already
    /// on screen and stays there until the question is answered, which is what
    /// a banner would be trying to say.
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
