// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation
import UserNotifications

#if os(macOS)
import AppKit
#endif


@MainActor
@Observable
final class NotificationOpen {
    static let shared = NotificationOpen()

    struct Request: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case chat
            case session
        }

        var kind: Kind
        var conversationID: String? = nil
        var sessionID: String? = nil
        var workspaceID: String? = nil
        var machineID: String? = nil
        var waiting: Bool = false
    }

    private(set) var request: Request?
    private var deadline: Date = .distantPast

    static let patience: TimeInterval = 60

    func offer(_ request: Request) {
        self.request = request
        deadline = Date().addingTimeInterval(Self.patience)
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first { $0.canBecomeMain && $0.isVisible }
            ?? NSApp.windows.first { $0.canBecomeMain }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        #endif
    }

    func take() -> Request? {
        let value = request
        request = nil
        deadline = .distantPast
        return value
    }

    func dropIfStale() -> Bool {
        guard request != nil, Date() >= deadline else { return false }
        request = nil
        deadline = .distantPast
        return true
    }

    nonisolated static func parse(
        userInfo: [AnyHashable: Any],
        identifier: String
    ) -> Request? {
        let ts = payload(named: "ts", from: userInfo) ?? userInfo
        if let reason = string("reason", from: ts) {
            switch reason {
            case "chat.finished", "chat.failed":
                return Request(
                    kind: .chat,
                    machineID: string("machine", from: ts),
                    waiting: false
                )
            case "run.needs_input":
                return Request(
                    kind: .chat,
                    machineID: string("machine", from: ts),
                    waiting: true
                )
            default:
                return nil
            }
        }
        switch string("kind", from: ts) {
        case "session":
            return Request(
                kind: .session,
                sessionID: string("sessionId", from: ts),
                workspaceID: string("workspaceId", from: ts),
                waiting: true
            )
        case "chat":
            return Request(
                kind: .chat,
                conversationID: string("conversationId", from: ts),
                workspaceID: string("workspaceId", from: ts),
                waiting: bool("waiting", from: ts)
            )
        default:
            break
        }
        return parseIdentifier(identifier)
    }

    private nonisolated static func parseIdentifier(_ identifier: String) -> Request? {
        if identifier.hasPrefix("run.session.") {
            let rest = String(identifier.dropFirst("run.session.".count))
            let suffix = ".Waiting for you"
            guard rest.hasSuffix(suffix) else { return nil }
            let id = String(rest.dropLast(suffix.count))
            guard !id.isEmpty else { return nil }
            return Request(kind: .session, sessionID: id, waiting: true)
        }
        let prefix = "run.chat."
        guard identifier.hasPrefix(prefix) else { return nil }
        let rest = String(identifier.dropFirst(prefix.count))
        for title in ["Waiting for you", "Chat finished", "Chat did not finish"] {
            let suffix = ".\(title)"
            guard rest.hasSuffix(suffix) else { continue }
            let id = String(rest.dropLast(suffix.count))
            guard !id.isEmpty else { return nil }
            return Request(
                kind: .chat,
                conversationID: id,
                waiting: title == "Waiting for you"
            )
        }
        return nil
    }

    private nonisolated static func payload(
        named key: String,
        from userInfo: [AnyHashable: Any]
    ) -> [AnyHashable: Any]? {
        if let dict = userInfo[key] as? [AnyHashable: Any] {
            return dict
        }
        if let text = userInfo[key] as? String,
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [AnyHashable: Any]
        {
            return dict
        }
        return nil
    }

    private nonisolated static func string(_ key: String, from dict: [AnyHashable: Any]?) -> String? {
        guard let value = dict?[key] else { return nil }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "1" : "0"
            }
            let text = number.stringValue
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private nonisolated static func bool(_ key: String, from dict: [AnyHashable: Any]?) -> Bool {
        guard let value = dict?[key] else { return false }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            return number.intValue != 0
        }
        if let text = string(key, from: dict) {
            switch text.lowercased() {
            case "1", "true", "yes": return true
            default: return false
            }
        }
        return false
    }
}

@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    static func install() {
        UNUserNotificationCenter.current().delegate = shared
        #if os(macOS)
        DeviceAccessRequests.registerCategory()
        #endif
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// A tap on a banner. Device access still answers from its own buttons.
    /// Everything else that names a chat is handed to `NotificationOpen` so
    /// the window that owns the transcript can open it.
    ///
    /// Completion-handler form on purpose. The async method returned on a
    /// cooperative thread, and UIKit then snapshotted from
    /// `_performBlockAfterCATransactionCommitSynchronizes` (TestFlight 83,
    /// tap on a chat push). Finish on the main queue after the view update.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let action = response.actionIdentifier
        let parsed = NotificationOpen.parse(
            userInfo: request.content.userInfo,
            identifier: request.identifier
        )
        #if os(macOS)
        let category = request.content.categoryIdentifier
        let identifier = request.identifier
        #endif
        Task { @MainActor in
            defer {
                DispatchQueue.main.async {
                    completionHandler()
                }
            }
            #if os(macOS)
            if category == DeviceAccessRequests.category {
                let prefix = DeviceAccessRequests.identifier("")
                guard identifier.hasPrefix(prefix) else { return }
                let requestID = String(identifier.dropFirst(prefix.count))
                await DeviceAccessRequests.shared.handleNotification(
                    action: action,
                    requestID: requestID
                )
                return
            }
            #endif
            guard action == UNNotificationDefaultActionIdentifier, let parsed else { return }
            NotificationOpen.shared.offer(parsed)
        }
    }
}

#if os(macOS)
@MainActor
@Observable
final class RunNotifications {
    static let shared = RunNotifications()

    private static let onKey = "notifications.runsFinished"

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            UserDefaults.standard.set(isOn, forKey: Self.onKey)
            if isOn {
                Task { await requestAuthorization() }
            }
        }
    }

    private(set) var authorization: UNAuthorizationStatus?

    private enum Feed: Hashable {
        case automations
        case workflows
    }

    private var lastStatus: [Feed: [String: String]] = [:]
    private var primed: Set<Feed> = []

    private struct ChatState {
        let title: String
        let workspaceID: String
        let running: Bool
        let pending: Bool
        let doneStatus: String?
        let routingActivity: ChatRoutingActivity?
        let routingNotifies: Bool
        let hasRoutingLimit: Bool
    }

    private var lastChats: [String: ChatState] = [:]
    private var chatsPrimed = false

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.onKey)
    }

    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        authorization = await center.notificationSettings().authorizationStatus
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    var authorizationNote: String? {
        guard isOn else { return nil }
        switch authorization {
        case .denied:
            return L10n.text("apple.runnotifications.notifications_are_turned_off_for_tokenstat.c726e897")
        case .none, .notDetermined:
            return nil
        default:
            return nil
        }
    }

    func settle(automations runs: [RunRecord]) {
        settle(
            runs
                .filter { $0.parentRunID == nil }
                .map { Ended(id: $0.id, name: $0.name, status: $0.status, exitCode: $0.exitCode) },
            from: .automations
        )
    }

    func settle(workflows runs: [WorkflowRunRecord]) {
        settle(
            runs.map { Ended(id: $0.id, name: $0.name, status: $0.status, exitCode: nil) },
            from: .workflows
        )
    }

    func settle(
        chats: [ChatConversation],
        approvals: [ChatApproval],
        selectedID: String?,
        selectedDoneStatus: String?
    ) {
        let pending = Set(approvals.lazy.filter { $0.decision == nil }.map(\.conversationID))
        let current = Dictionary(
            chats.map { chat in
                (
                    chat.id,
                    ChatState(
                        title: chat.title,
                        workspaceID: chat.workspaceID,
                        running: chat.running,
                        pending: pending.contains(chat.id),
                        doneStatus: chat.id == selectedID ? selectedDoneStatus : nil,
                        routingActivity: chat.routing?.activity?.last,
                        routingNotifies: chat.routing?.policy.notify != false,
                        hasRoutingLimit: chat.routing?.limit != nil
                    )
                )
            },
            uniquingKeysWith: { _, last in last }
        )
        defer {
            lastChats = current
            chatsPrimed = true
        }
        guard isOn, chatsPrimed else { return }
        for (id, chat) in current {
            guard let before = lastChats[id] else { continue }
            let watching = UserPresence.shared.isWatching(conversation: id)
            if let entry = chat.routingActivity, entry != before.routingActivity,
               chat.routingNotifies, !watching, entry.kind != "settings" {
                post("chat.\(id)", title: entry.label, identifierTitle: "Chat routing",
                     body: "\(chat.title): \(entry.reason)",
                     extras: chatExtras(id: id, workspaceID: chat.workspaceID, waiting: false))
                continue
            }
            if !before.pending, chat.pending, !watching {
                post(
                    "chat.\(id)",
                    title: L10n.text("apple.runnotifications.waiting_for_you.9f760ab2"),
                    identifierTitle: "Waiting for you",
                    body: L10n.text("apple.runnotifications.0_needs_an_answer.c42f4cd9", "\(chat.title)"),
                    extras: chatExtras(id: id, workspaceID: chat.workspaceID, waiting: true)
                )
            }
            guard before.running, !chat.running, !watching else { continue }
            switch chat.doneStatus {
            case "ok":
                post(
                    "chat.\(id)",
                    title: L10n.text("apple.runnotifications.chat_finished.a49ea476"),
                    identifierTitle: "Chat finished",
                    body: L10n.text("apple.runnotifications.0_is_done.2eff6579", "\(chat.title)"),
                    extras: chatExtras(id: id, workspaceID: chat.workspaceID, waiting: false)
                )
            case "error":
                if chat.hasRoutingLimit && !chat.routingNotifies { continue }
                post(
                    "chat.\(id)",
                    title: L10n.text("apple.runnotifications.chat_did_not_finish.45962bbc"),
                    identifierTitle: "Chat did not finish",
                    body: L10n.text("apple.runnotifications.0_did_not_finish_cleanly.c823f56e", "\(chat.title)"),
                    extras: chatExtras(id: id, workspaceID: chat.workspaceID, waiting: false)
                )
            default:
                continue
            }
        }
    }

    private struct Ended {
        let id: String
        let name: String
        let status: String
        let exitCode: Int?
    }

    private func settle(_ runs: [Ended], from feed: Feed) {
        let before = lastStatus[feed] ?? [:]
        defer {
            lastStatus[feed] = Dictionary(
                runs.map { ($0.id, $0.status) },
                uniquingKeysWith: { _, last in last }
            )
            primed.insert(feed)
        }
        guard isOn, primed.contains(feed) else { return }
        for run in runs {
            guard let before = before[run.id], before != run.status else { continue }
            guard before == "running" || before == "queued" else { continue }
            switch run.status {
            case "ok":
                post(run.id, title: L10n.text("apple.runnotifications.run_finished.22488bd9"), identifierTitle: "Run finished", body: L10n.text("apple.runnotifications.0_is_done.2eff6579", "\(run.name)"))
            case "error":
                let code = run.exitCode.map { " (exit \($0))" } ?? ""
                post(run.id, title: L10n.text("apple.runnotifications.run_failed.97fddf2d"), identifierTitle: "Run failed", body: L10n.text("apple.runnotifications.0_did_not_finish_cleanly_1.25a03a73", "\(run.name)", "\(code)"))
            case "waiting":
                post(run.id, title: L10n.text("apple.runnotifications.waiting_for_you.9f760ab2"), identifierTitle: "Waiting for you", body: L10n.text("apple.runnotifications.0_needs_an_answer_to_carry_on.6eb7efc2", "\(run.name)"))
            default:
                continue
            }
        }
    }

    func attention(sessionID: String, name: String, workspaceID: String = "") {
        guard isOn else { return }
        var extras: [String: String] = [
            "kind": "session",
            "sessionId": sessionID,
        ]
        if !workspaceID.isEmpty {
            extras["workspaceId"] = workspaceID
        }
        post(
            "session.\(sessionID)",
            title: L10n.text("apple.runnotifications.waiting_for_you.9f760ab2"),
            identifierTitle: "Waiting for you",
            body: L10n.text("apple.runnotifications.0_is_asking_a_question.34dd0503", "\(name)"),
            extras: extras
        )
    }

    func attentionHandled(sessionID: String) {
        let identifier = "run.session.\(sessionID).Waiting for you"
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func chatAttentionHandled(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["run.chat.\(id).Waiting for you"]
        )
    }

    private func chatExtras(id: String, workspaceID: String, waiting: Bool) -> [String: String] {
        [
            "kind": "chat",
            "conversationId": id,
            "workspaceId": workspaceID,
            "waiting": waiting ? "1" : "0",
        ]
    }

    private func post(
        _ runID: String,
        title: String,
        identifierTitle: String,
        body: String,
        extras: [String: String] = [:]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = runID
        if !extras.isEmpty {
            content.userInfo = ["ts": extras]
        }
        let request = UNNotificationRequest(
            identifier: "run.\(runID).\(identifierTitle)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func sendTest() {
        post("test", title: L10n.text("apple.runnotifications.notifications_are_on.ceaaed4b"), identifierTitle: "Notifications are on", body: L10n.text("apple.runnotifications.this_is_the_only_test_notification.45933459"))
    }
}
#endif

#if os(iOS)
import UIKit

/// Registers this iPhone or iPad for push, and takes it off the list again.
///
/// The token comes from Apple through the app delegate, goes to the host as
/// `push.register`, and from there to the account. Every launch re-registers:
/// iOS reissues tokens on restore, on reinstall and sometimes for no reason
/// anybody can see, and the account keys devices by the token itself.
@MainActor
@Observable
final class PushRegistrar {
    static let shared = PushRegistrar()

    private static let onKey = "notifications.push"
    private static let tokenKey = "notifications.pushToken"
    private static let pendingRemovalKey = "notifications.pushPendingRemoval"

    private(set) var isOn: Bool
    private(set) var errorMessage: String?
    private(set) var isRegistered = false
    private(set) var isWorking = false
    private let operations = PushRegistrationQueue()

    private var deviceToken: String? {
        didSet {
            guard deviceToken != oldValue else { return }
            UserDefaults.standard.set(deviceToken, forKey: Self.tokenKey)
        }
    }

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.onKey)
        deviceToken = UserDefaults.standard.string(forKey: Self.tokenKey)
    }

    func enable() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            isOn = false
            UserDefaults.standard.set(false, forKey: Self.onKey)
            errorMessage = L10n.text("apple.runnotifications.notifications_are_off_for_tokenstat_in_set.aa162b5c")
            return
        }
        isOn = true
        UserDefaults.standard.set(true, forKey: Self.onKey)
        UserDefaults.standard.removeObject(forKey: Self.pendingRemovalKey)
        UIApplication.shared.registerForRemoteNotifications()
    }

    func disable() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        isOn = false
        UserDefaults.standard.set(false, forKey: Self.onKey)
        UIApplication.shared.unregisterForRemoteNotifications()
        isRegistered = false
        guard let token = deviceToken else { return }
        await operations.enqueue {
            do {
                try await Bridge.pushUnregister(token: token)
                UserDefaults.standard.removeObject(forKey: Self.pendingRemovalKey)
            } catch {
                UserDefaults.standard.set(token, forKey: Self.pendingRemovalKey)
            }
        }.value
    }

    func refresh() {
        if let pending = UserDefaults.standard.string(forKey: Self.pendingRemovalKey) {
            operations.enqueue { [self] in
                if UserDefaults.standard.string(forKey: Self.pendingRemovalKey) == pending,
                   (try? await Bridge.pushUnregister(token: pending)) != nil,
                   UserDefaults.standard.string(forKey: Self.pendingRemovalKey) == pending {
                    UserDefaults.standard.removeObject(forKey: Self.pendingRemovalKey)
                }
                if isOn {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
            return
        }
        guard isOn else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func received(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        guard isOn else { return }
        operations.enqueue { [self] in
            guard isOn, deviceToken == hex else { return }
            do {
                try await Bridge.pushRegister(token: hex, platform: Self.platform, environment: Self.environment)
                guard isOn, deviceToken == hex else { return }
                isRegistered = true
                errorMessage = nil
            } catch {
                guard isOn, deviceToken == hex else { return }
                isRegistered = false
                errorMessage = Bridge.isSignedOutError(error) ? nil : error.localizedDescription
            }
        }
    }

    /// Apple refused. Usually a build with no push entitlement, or a simulator.
    func failed(_ error: Error) {
        guard isOn else { return }
        isRegistered = false
        errorMessage = error.localizedDescription
    }

    func sendTest() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await Bridge.pushTest()
            if !result.signedIn {
                errorMessage = L10n.text("apple.runnotifications.sign_in_first_a_notification_has_to_reach.c1314d42")
            } else if !result.enabled {
                errorMessage = L10n.text("apple.runnotifications.notifications_are_not_switched_on_for_the.b82ba3c6")
            } else if result.sent == 0 {
                errorMessage = L10n.text("apple.runnotifications.the_account_has_no_device_to_notify_yet.bf208fe3")
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static var platform: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    }

    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}
#endif
