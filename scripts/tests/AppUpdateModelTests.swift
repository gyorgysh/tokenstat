// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with AppUpdateModel.swift.
import Foundation

struct AppUpdate: Sendable {
    var current = "1.0"
    var latest = "1.1"
    var isAvailable = true
    var htmlURL = "https://example.invalid/release"
    var downloadURL: URL? { URL(string: htmlURL) }
}
struct DownloadedFile: Sendable { var path: String }
enum TestFailure: Error { case offline, download, installation }

@MainActor enum Bridge {
    static var check: () throws -> AppUpdate = { AppUpdate() }
    static var download: () throws -> DownloadedFile = { DownloadedFile(path: "test") }
    static func appUpdateCheck() async throws -> AppUpdate { try check() }
    static func appUpdateDownload() async throws -> DownloadedFile { try download() }
}
enum AppInstaller {
    static func install(imagePath: String) throws {
        if imagePath == "fail" { throw TestFailure.installation }
    }
    static func relaunch() {}
}

@main struct AppUpdateModelTests {
    @MainActor static func main() async {
        let offline = AppUpdateModel()
        Bridge.check = { throw TestFailure.offline }
        let manual = Task { await offline.checkNow() }
        while offline.failure == nil { await Task.yield() }
        assert(offline.checkNotice != AppUpdateModel.upToDateMessage,
               "A failed check must never claim that the application is current")
        manual.cancel()
        await manual.value
        assert(offline.failure != nil)

        Bridge.check = { AppUpdate(isAvailable: false) }
        await offline.retry()
        assert(offline.stage == .idle && offline.failure == nil)

        #if os(macOS)
        let success = AppUpdateModel()
        Bridge.check = {
            assert(success.stage == .checking && success.isChecking)
            return AppUpdate()
        }
        Bridge.download = {
            assert(success.stage == .downloading && success.isChecking)
            return DownloadedFile(path: "test")
        }
        await success.checkAndInstall()
        assert(success.isReady && !success.isChecking)
        Bridge.check = { fatalError("A restart-ready update must not be downloaded again") }
        await success.checkNow()
        assert(success.isReady)

        let failedDownload = AppUpdateModel()
        Bridge.check = { AppUpdate() }
        Bridge.download = { throw TestFailure.download }
        await failedDownload.checkAndInstall()
        assert(failedDownload.failure != nil && !failedDownload.isChecking)
        Bridge.download = { DownloadedFile(path: "fail") }
        await failedDownload.retry()
        assert(failedDownload.failure != nil && !failedDownload.isReady)
        Bridge.download = { DownloadedFile(path: "test") }
        await failedDownload.retry()
        assert(failedDownload.isReady && !failedDownload.isRetrying)
        #endif
        print("AppUpdateModelTests passed")
    }
}
