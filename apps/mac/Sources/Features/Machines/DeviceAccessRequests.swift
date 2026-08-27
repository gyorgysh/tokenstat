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
/// and surfaces it the way the app surfaces everything else that is worth
/// knowing but not worth interrupting for: a toast with a way to the question,
/// and a local notification when the app is not in front. The sheet that
/// actually asks is opened from either, never on its own.
@MainActor
@Observable
final class DeviceAccessRequests {
    static let shared = DeviceAccessRequests()

    private(set) var pending: [DeviceAccessPending] = []
    private(set) var errorMessage: String?

    /// The toast's sentence, or nil. Cleared by the toast itself when it times
    /// out or when its action is taken.
    var toast: String?
    /// The request the sheet is asking about, set by the toast's action or by
    /// the Devices card. Nothing opens it on its own: a question about a
    /// device is worth answering, not worth stopping what you were doing.
    var asking: DeviceAccessPending?

    /// The oldest question still standing, which is the one a toast names.
    var oldest: DeviceAccessPending? { pending.min { $0.askedAt < $1.askedAt } }

    /// Open the sheet on the oldest standing request. The toast's action.
    func askAboutOldest() {
        asking = oldest
    }

    /// A toast that goes away on its own.
    ///
    /// `TransientToast` renders whatever its binding holds and never clears it,
    /// so the timing belongs to whoever set it. The generation guard is what
    /// stops an older toast's timer taking a newer one off the screen.
    private var toastGeneration = 0
    private func showToast(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.toastGeneration == generation else { return }
            self.toast = nil
        }
    }

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
        // Both kinds, in one pass, so the queue is ordered by when somebody
        // asked rather than by which policy answered first.
        async let screen = try? Bridge.pendingDeviceAccess(.screen)
        async let workspace = try? Bridge.pendingDeviceAccess(.workspace)
        let rows = (await screen ?? []) + (await workspace ?? [])
        let arrived = rows.filter { !announced.contains($0.id) }
        pending = rows
        // Forget what is gone, so a device that asks again in an hour is
        // announced again rather than being silently swallowed.
        announced.formIntersection(Set(rows.map(\.id)))
        // A question that expired or was answered elsewhere must not be left
        // on screen with buttons that no longer do anything.
        if let asking, !rows.contains(where: { $0.id == asking.id }) {
            self.asking = nil
        }
        for request in arrived {
            announced.insert(request.id)
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

    /// Say it once, in whichever way suits where the person is.
    ///
    /// In front of the app it is a toast, the same furniture sync and updates
    /// use, with a way to the question rather than the question itself. Away
    /// from it, a notification carrying the answers so it can be dealt with
    /// without coming back.
    private func announce(_ request: DeviceAccessPending) {
        guard !NSApplication.shared.isActive else {
            showToast(request.headline)
            return
        }
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
