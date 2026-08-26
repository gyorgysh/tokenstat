// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation
import UserNotifications

/// Being told when an agent finished, on the two paths that need different
/// machinery.
///
/// **The Mac tells itself.** It is the machine the run happened on, the app is
/// watching the run list already, and a local notification needs no account,
/// no network and nobody else's server. That is `RunNotifications` below.
///
/// **A phone cannot.** With the app closed there is nothing running to notice,
/// so Apple has to wake it, which means a push and therefore a server. That is
/// `PushRegistrar`, and what it sends is covered in `tokenstat-sync::push`: a
/// reason from a fixed list and a machine id, never a folder name, a prompt or
/// a path.
///
/// Both are off until somebody turns them on. A notification permission prompt
/// on first launch, for a feature nobody has asked for yet, is the reason
/// people say no to notifications forever.

/// Presents banners while the app is in front.
///
/// Without a delegate the system swallows a notification whose app is already
/// frontmost. That is exactly the case here: the run finished in a window the
/// person is looking at but not watching, and a silent notification is the
/// same as no notification.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    /// Install once, early. Setting this after a notification has already been
    /// delivered loses that delivery's callbacks, so it goes in at launch.
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}

#if os(macOS)
/// Local notifications for runs that ended on this Mac.
///
/// Fed from the same run lists the sidebar already polls, so there is no second
/// source of truth about what a run is doing and nothing new to keep in step.
///
/// Only transitions are notified, and only after the first read: a launch that
/// found four finished runs from last night must not post four banners.
@MainActor
@Observable
final class RunNotifications {
    static let shared = RunNotifications()

    private static let onKey = "notifications.runsFinished"

    /// Off until asked for. See the type comment.
    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            UserDefaults.standard.set(isOn, forKey: Self.onKey)
            if isOn {
                Task { await requestAuthorization() }
            }
        }
    }

    /// What the system last said about permission, for the settings row. Nil
    /// until asked, because "not decided" and "denied" need different words.
    private(set) var authorization: UNAuthorizationStatus?

    /// Which list a refresh came from.
    ///
    /// Kept apart because the two arrive on their own timers into one object.
    /// Holding a single map meant each feed's refresh replaced the other's
    /// baseline, so by the time a run finished its previous status had been
    /// wiped by the other list and nothing was ever posted.
    private enum Feed: Hashable {
        case automations
        case workflows
    }

    /// Run id to the status it last had, per feed. The whole state this needs.
    private var lastStatus: [Feed: [String: String]] = [:]
    /// Feeds that have been read once. Before that, everything is history, and
    /// it is per feed for the same reason the statuses are.
    private var primed: Set<Feed> = []

    private init() {
        // `bool(forKey:)` is false for a key that was never written, which is
        // the default this wants.
        isOn = UserDefaults.standard.bool(forKey: Self.onKey)
    }

    /// Ask, once, and remember the answer for the settings row.
    ///
    /// Called when the switch goes on rather than at launch, so the system
    /// prompt arrives in the same second as the request that explains it.
    func requestAuthorization() async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Read the current permission without asking for it.
    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
    }

    /// A helpful sentence for the settings row, or nil when there is nothing
    /// to say beyond the switch.
    var authorizationNote: String? {
        guard isOn else { return nil }
        switch authorization {
        case .denied:
            return "Notifications are turned off for tokenstat in System Settings."
        case .none, .notDetermined:
            return nil
        default:
            return nil
        }
    }

    /// Agent runs, as of this refresh.
    ///
    /// A workflow node starts an ordinary automation run, so a five-step
    /// workflow used to say "Run finished" five times on its way to saying it
    /// once more for itself. A step is machinery under something the person
    /// started, and machinery does not report to them: the workflow speaks for
    /// its own steps.
    func settle(automations runs: [RunRecord]) {
        settle(
            runs
                .filter { $0.parentRunID == nil }
                .map { Ended(id: $0.id, name: $0.name, status: $0.status, exitCode: $0.exitCode) },
            from: .automations
        )
    }

    /// Workflow runs, as of this refresh. A workflow that is `waiting` has hit
    /// a gate, which is a person's turn and worth saying so.
    func settle(workflows runs: [WorkflowRunRecord]) {
        settle(
            runs.map { Ended(id: $0.id, name: $0.name, status: $0.status, exitCode: nil) },
            from: .workflows
        )
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
            // This feed's slice only. Replacing the whole map is what made one
            // list forget the other, and merging without replacing would keep
            // every run this app has ever seen.
            lastStatus[feed] = Dictionary(
                runs.map { ($0.id, $0.status) },
                uniquingKeysWith: { _, last in last }
            )
            primed.insert(feed)
        }
        guard isOn, primed.contains(feed) else { return }
        for run in runs {
            guard let before = before[run.id], before != run.status else { continue }
            // Only a live run can produce news. A record rewritten by a
            // reconcile is not something that just happened.
            guard before == "running" || before == "queued" else { continue }
            switch run.status {
            case "ok":
                post(run.id, title: "Run finished", body: "\(run.name) is done.")
            case "error":
                let code = run.exitCode.map { " (exit \($0))" } ?? ""
                post(run.id, title: "Run failed", body: "\(run.name) did not finish cleanly\(code).")
            case "waiting":
                post(run.id, title: "Waiting for you", body: "\(run.name) needs an answer to carry on.")
            default:
                // "stopped" is somebody at this keyboard. They know.
                continue
            }
        }
    }

    /// An agent in a terminal stopped to ask its person something.
    ///
    /// The one notification that is worth interrupting somebody for: a run
    /// that finished can be read whenever, a question is holding the work up.
    /// It was also the one the app never sent, because the local notifier only
    /// ever watched automations and workflows, and a permission prompt in a
    /// terminal is neither.
    ///
    /// Nothing about the session travels: the name is the folder and the
    /// harness, which is what the sidebar already shows.
    func attention(sessionID: String, name: String) {
        guard isOn else { return }
        post(
            "session.\(sessionID)",
            title: "Waiting for you",
            body: "\(name) is asking a question."
        )
    }

    /// Take that notification back when the person arrives at the terminal.
    ///
    /// They answered the call by walking over to it. A banner still sitting in
    /// Notification Centre about a question they are looking at is the same
    /// nagging as a pill that will not go away.
    func attentionHandled(sessionID: String) {
        let identifier = "run.session.\(sessionID).Waiting for you"
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func post(_ runID: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Grouped per run, so a run that ends and is retried replaces its own
        // banner rather than stacking a history in Notification Centre.
        content.threadIdentifier = runID
        let request = UNNotificationRequest(
            identifier: "run.\(runID).\(title)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// The settings button. Posts through the same path a real run would, so
    /// a test that arrives proves the real one will.
    func sendTest() {
        post("test", title: "Notifications are on", body: "This is the only test notification.")
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
    /// The last token this device registered, kept across launches.
    ///
    /// Switching off has to name the device to the account, and the token
    /// otherwise only exists in memory after Apple hands it over. A person who
    /// relaunches and turns the switch off in the same second would have taken
    /// the switch off a device the account was still sending to.
    private static let tokenKey = "notifications.pushToken"
    /// A token whose removal did not reach the account yet.
    ///
    /// Turning notifications off while offline used to be silently lost, and
    /// the failure is invisible: the switch reads off and the notifications
    /// keep arriving. Retried on the next launch.
    private static let pendingRemovalKey = "notifications.pushPendingRemoval"

    /// Whether this device wants notifications. Off until asked for.
    private(set) var isOn: Bool
    /// The last thing that went wrong, for the settings row. Registration is
    /// silent when it works and a person needs to know when it does not.
    private(set) var errorMessage: String?
    /// Whether a token has reached the account this launch.
    private(set) var isRegistered = false
    private(set) var isWorking = false

    /// The token Apple last handed us, kept so switching off can name the
    /// device to remove rather than waiting for Apple to notice it is dead.
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

    /// Turn notifications on for this device: ask the person, then ask Apple.
    ///
    /// A refusal at the system prompt leaves the switch off, because a switch
    /// that says on while the system says no is a lie the app tells daily.
    func enable() async {
        isWorking = true
        defer { isWorking = false }
        errorMessage = nil
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else {
            isOn = false
            UserDefaults.standard.set(false, forKey: Self.onKey)
            errorMessage = "Notifications are off for tokenstat in Settings."
            return
        }
        isOn = true
        UserDefaults.standard.set(true, forKey: Self.onKey)
        // A removal that never landed is moot now: this device is asking to be
        // sent to again, and retrying it later would take it back off.
        UserDefaults.standard.removeObject(forKey: Self.pendingRemovalKey)
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Stop notifications for this device, at the account rather than only on
    /// the phone, so nothing is sent that a Do Not Disturb happens to hide.
    ///
    /// The token comes from the stored one when Apple has not handed one over
    /// yet this launch, and a removal that does not reach the account is
    /// remembered rather than dropped: a switch that reads off while
    /// notifications keep arriving is the worst of the states this can be in.
    func disable() async {
        isOn = false
        UserDefaults.standard.set(false, forKey: Self.onKey)
        UIApplication.shared.unregisterForRemoteNotifications()
        isRegistered = false
        guard let token = deviceToken else { return }
        do {
            try await Bridge.pushUnregister(token: token)
            UserDefaults.standard.removeObject(forKey: Self.pendingRemovalKey)
        } catch {
            UserDefaults.standard.set(token, forKey: Self.pendingRemovalKey)
        }
    }

    /// Re-register at launch, and after signing in. Cheap, and it is the only
    /// thing that keeps a reissued token reachable.
    ///
    /// Also finishes a removal that never reached the account. That has to
    /// happen before the registration below, or a device that was switched off
    /// offline and switched back on would race its own removal.
    func refresh() {
        if let pending = UserDefaults.standard.string(forKey: Self.pendingRemovalKey) {
            Task {
                if (try? await Bridge.pushUnregister(token: pending)) != nil {
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

    /// Apple answered. Hand the token to the account.
    func received(token: Data) {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        deviceToken = hex
        Task {
            do {
                try await Bridge.pushRegister(token: hex, platform: Self.platform, environment: Self.environment)
                isRegistered = true
                errorMessage = nil
            } catch {
                isRegistered = false
                // Signed out is the ordinary case, not a fault worth shouting
                // about: notifications need an account and the account screen
                // is already saying so.
                errorMessage = Bridge.isSignedOutError(error) ? nil : error.localizedDescription
            }
        }
    }

    /// Apple refused. Usually a build with no push entitlement, or a simulator.
    func failed(_ error: Error) {
        isRegistered = false
        errorMessage = error.localizedDescription
    }

    /// Ask the account to send one, so somebody can tell "on" from "on but
    /// nothing has happened yet".
    func sendTest() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await Bridge.pushTest()
            if !result.signedIn {
                errorMessage = "Sign in first. A notification has to reach this device from your account."
            } else if !result.enabled {
                // The server, not this device. Saying "check your settings"
                // here would send somebody looking for a switch that is
                // already on.
                errorMessage = "Notifications are not switched on for the service yet. Nothing is wrong with this device."
            } else if result.sent == 0 {
                errorMessage = "The account has no device to notify yet."
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// iPad and iPhone are one app and one bundle id, so this is a label for
    /// the account's own device list rather than anything Apple routes on.
    private static var platform: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
    }

    /// Which Apple host this build's tokens belong to. A development build's
    /// token is a sandbox token and the production host answers it with
    /// BadDeviceToken, which is why the account stores this per device.
    private static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }
}
#endif
