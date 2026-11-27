// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

#if !os(macOS)
import SwiftUI

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
