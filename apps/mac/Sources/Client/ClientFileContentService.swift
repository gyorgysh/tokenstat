// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

/// A file's diff and its full content from the machine that owns the folder.
///
/// The diff view, Review all and the edit sheet all read through this, so a
/// fixture can serve canned files and every surface agrees. Production talks
/// to the host.
protocol ClientFileContentService: Sendable {
    func diff(peer: String, workspace: String, path: String) async throws -> FileDiff
    func read(peer: String, workspace: String, path: String) async throws -> String
}

struct LiveClientFileContentService: ClientFileContentService {
    func diff(peer: String, workspace: String, path: String) async throws -> FileDiff {
        try await ClientRemote.diff(peer: peer, workspace: workspace, path: path)
    }

    func read(peer: String, workspace: String, path: String) async throws -> String {
        try await ClientRemote.readFile(peer: peer, workspace: workspace, path: path).content
    }
}

private struct ClientFileContentKey: EnvironmentKey {
    static let defaultValue: any ClientFileContentService = LiveClientFileContentService()
}

extension EnvironmentValues {
    var fileContent: any ClientFileContentService {
        get { self[ClientFileContentKey.self] }
        set { self[ClientFileContentKey.self] = newValue }
    }
}
#endif
