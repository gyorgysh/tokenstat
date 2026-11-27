// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available, not open source. See LICENSE for permissions and restrictions.

import Foundation
import Observation

@MainActor
@Observable
final class AppUpdateModel {
    static let upToDateMessage = L10n.text("apple.appupdatemodel.you_are_on_the_latest_version.eeced728")

    enum Stage: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case readyToRelaunch
        case failed(String)
    }

    private(set) var release: AppUpdate?
    private(set) var stage: Stage = .idle
    private(set) var retryAfter: Date?
    private(set) var failureDismissed = false
    private let runningVersion: String

    init(runningVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") {
        self.runningVersion = runningVersion
    }

    var isRateLimited: Bool { retryAfter.map { $0 > Date() } ?? false }

    func dismissFailure() {
        failureDismissed = true
        checkNotice = nil
    }

    var isAvailable: Bool {
        guard let release else { return false }
        return release.isAvailable && AppUpdateVersion.isNewer(release.latest, than: runningVersion)
    }
    var latest: String { release?.latest ?? "" }
    var current: String { runningVersion }
    var htmlURL: String { release?.htmlURL ?? "" }
    var downloadURL: URL? { release?.downloadURL }

    var isReady: Bool { stage == .readyToRelaunch }

    var failure: String? {
        if case .failed(let why) = stage { return why }
        return nil
    }

    var isChecking: Bool { stage == .checking || stage == .downloading || stage == .installing }

    private var noticeGeneration = 0

    private(set) var checkNotice: String?

    private(set) var isRetrying = false

    func checkNow() async {
        guard !isChecking, !isReady else { return }
        failureDismissed = false
        guard !isRateLimited else { return }
        noticeGeneration += 1
        let generation = noticeGeneration
        checkNotice = nil
        let before = release?.latest
        stage = .idle
        UserDefaults.standard.removeObject(forKey: Self.skippedKey)
        await checkAndInstall()

        if isReady {
            checkNotice = L10n.text("apple.appupdatemodel.update_installed_relaunch_to_finish.d191ced5")
        } else if let failure {
            checkNotice = failure
        } else if isAvailable, release?.latest != before {
            checkNotice = L10n.text("apple.appupdatemodel.version_0_found.a4c4e509", "\(latest)")
        } else {
            checkNotice = Self.upToDateMessage
        }

        try? await Task.sleep(for: .seconds(6))
        if generation == noticeGeneration { checkNotice = nil }
    }

    func checkAndInstall() async {
        guard stage == .idle || failure != nil else { return }
        guard !isRateLimited else { return }
        retryAfter = nil
        failureDismissed = false
        stage = .checking
        do {
            let found = try await Bridge.appUpdateCheck()
            if let timestamp = found.retryAt {
                let date = Date(timeIntervalSince1970: timestamp)
                retryAfter = date
                stage = .failed(L10n.text("apple.appupdatemodel.github_is_limiting_update_checks_you_can_t.01b98ce8", "\(date.formatted(date: .omitted, time: .shortened))"))
                return
            }
            release = found
            guard isAvailable, !isSkipped else {
                stage = .idle
                return
            }
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }

        #if os(macOS)
        stage = .downloading
        do {
            let downloaded = try await Bridge.appUpdateDownload()
            stage = .installing
            let runningVersion = self.runningVersion
            try await Task.detached(priority: .utility) {
                try AppInstaller.install(imagePath: downloaded.path, runningVersion: runningVersion)
            }.value
            stage = .readyToRelaunch
        } catch {
            stage = .failed(error.localizedDescription)
        }
        #else
        stage = .failed(L10n.text("apple.appupdatemodel.updates_on_this_platform_come_from_the_app.95715312"))
        #endif
    }

    func retry() async {
        guard failure != nil, !isChecking, !isRetrying, !isRateLimited else { return }
        isRetrying = true
        defer { isRetrying = false }
        stage = .idle
        await checkAndInstall()
    }

    func relaunch() {
        #if os(macOS)
        AppInstaller.relaunch()
        #endif
    }

    private static let skippedKey = "AppUpdate.skippedVersion"

    var isSkipped: Bool {
        guard let latest = release?.latest, !latest.isEmpty else { return false }
        return UserDefaults.standard.string(forKey: Self.skippedKey) == latest
    }

    func skipThisVersion() {
        guard let latest = release?.latest, !latest.isEmpty else { return }
        UserDefaults.standard.set(latest, forKey: Self.skippedKey)
        stage = .idle
    }
}

enum AppUpdateVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        func components(_ version: String) -> [UInt64]? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
            let values = parts.compactMap { UInt64($0) }
            return values.count == parts.count ? values : nil
        }
        guard let left = components(lhs), let right = components(rhs) else { return nil }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ offered: String, than current: String) -> Bool {
        compare(offered, current) == .orderedDescending
    }

    static func canInstall(offered: String, running: String, installed: String) -> Bool {
        isNewer(offered, than: running) &&
            [.orderedSame, .orderedDescending].contains(compare(offered, installed))
    }
}
