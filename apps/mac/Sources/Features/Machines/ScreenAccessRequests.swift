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

/// Devices asking to see this computer's screen, and the answer.
///
/// The permission has always been real and enforced on the host. Until now
/// there was no way to ask for it: pressing Request access on a phone sent a
/// push, and a push carries a reason and a machine id by design, never the id
/// of the device that asked. This Mac does not register for push at all. So
/// people pressed the button, nothing happened here, and they could not find
/// the toggle in Devices either.
///
/// The request now travels the tunnel and lands in `screen-policy.json`. This
/// polls for it, raises the sheet while the app is running, and posts a local
/// notification when it is not.
@MainActor
@Observable
final class ScreenAccessRequests {
    static let shared = ScreenAccessRequests()

    private(set) var pending: [ScreenAccessPending] = []
    private(set) var errorMessage: String?

    /// The one being asked about right now. The sheet shows the oldest, so a
    /// second request queues behind the first rather than replacing it under
    /// somebody's cursor mid-answer.
    var showing: ScreenAccessPending? { pending.min { $0.askedAt < $1.askedAt } }

    /// Requests a notification has already been posted for, so a poll every
    /// few seconds does not post the same banner every few seconds.
    private var announced: Set<String> = []
    private var polling: Task<Void, Never>?

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
        do {
            let rows = try await Bridge.pendingScreenAccess()
            errorMessage = nil
            let arrived = rows.filter { !announced.contains($0.peerID) }
            pending = rows
            // Forget what is gone, so a device that asks again in an hour is
            // announced again rather than being silently swallowed.
            announced.formIntersection(Set(rows.map(\.peerID)))
            for request in arrived {
                announced.insert(request.peerID)
                announce(request)
            }
        } catch {
            // A host that is not up yet is the ordinary case at launch, and a
            // question nobody asked is not worth an error on screen.
            pending = []
        }
    }

    /// Grant, narrow or deny. Denying is view and control both false: refusing
    /// and revoking are the same state, and the host clears the request either
    /// way.
    func answer(_ request: ScreenAccessPending, view: Bool, control: Bool) async {
        do {
            try await Bridge.answerScreenAccess(peerID: request.peerID, view: view, control: control)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        withdraw(request.peerID)
        await refresh()
    }

    /// Take the banner back once the question has been answered, wherever it
    /// was answered. A notification still sitting in Notification Centre about
    /// a device that already has access is the same nagging as a stuck badge.
    private func withdraw(_ peerID: String) {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.identifier(peerID)])
    }

    // MARK: - Notification

    // Nonisolated: the notification delegate reads these from outside the main
    // actor to decide whether a response is even ours before hopping onto it.
    nonisolated static let category = "screen.access"
    nonisolated static let allowViewAction = "screen.access.view"
    nonisolated static let allowControlAction = "screen.access.control"
    nonisolated static let denyAction = "screen.access.deny"

    nonisolated static func identifier(_ peerID: String) -> String { "screen.access.\(peerID)" }

    /// Register the actions the banner carries. Called at launch, beside the
    /// presenter, because a category registered after a notification is
    /// delivered does not apply to it.
    static func registerCategory() {
        let category = UNNotificationCategory(
            identifier: Self.category,
            actions: [
                UNNotificationAction(
                    identifier: allowViewAction,
                    title: "View only",
                    options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: allowControlAction,
                    title: "Full access",
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
    func handleNotification(action: String, peerID: String) async {
        // Re-read first. A request that expired or was answered in the window
        // between the banner and the click must not grant anything now.
        await refresh()
        guard let request = pending.first(where: { $0.peerID == peerID }) else { return }
        switch action {
        case Self.allowViewAction: await answer(request, view: true, control: false)
        case Self.allowControlAction: await answer(request, view: true, control: true)
        case Self.denyAction: await answer(request, view: false, control: false)
        default: break
        }
    }

    private func announce(_ request: ScreenAccessPending) {
        // The sheet is already in front of them. A banner as well would be the
        // same question twice.
        guard !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(request.displayName) wants to see this screen"
        content.body = request.control
            ? "It asked for the picture, and for mouse and keyboard."
            : "It asked for the picture only."
        content.sound = .default
        content.categoryIdentifier = Self.category
        content.threadIdentifier = Self.category
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: Self.identifier(request.peerID),
                content: content,
                trigger: nil
            )
        )
    }
}

#endif
