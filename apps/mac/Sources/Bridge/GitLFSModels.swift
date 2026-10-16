// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

struct GitLFSStatus: Codable, Sendable, Equatable {
    let installed: Bool
    let configured: Bool
    let canInstall: Bool
    var ready: Bool { installed && configured }
}

protocol GitLFSService: Sendable {
    func setupLFS(allowInstall: Bool) async throws -> GitLFSStatus
}

extension GitLFSService {
    func setupLFS(allowInstall: Bool) async throws -> GitLFSStatus { throw CocoaError(.featureUnsupported) }
}

extension GitCommitTarget: GitLFSService {
    func setupLFS(allowInstall: Bool) async throws -> GitLFSStatus {
        try await call("workspace.lfsSetup", ["allowInstall": allowInstall], patience: Bridge.Patience.long, as: GitLFSStatus.self)
    }
}
