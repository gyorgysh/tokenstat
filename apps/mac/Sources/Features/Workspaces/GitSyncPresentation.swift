// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import SwiftUI

/// A window owns the dialog so an auto-hiding inspector can remove its
/// controls without dismissing an in-progress review or operation.
struct GitSyncPresentation: Identifiable {
    let id = UUID()
    let target: GitCommitTarget
    let folderName: String
    let hostName: String
    var pushSession: GitPushSession?
    let onCompleted: () async -> Void
}

private struct PresentGitSyncKey: EnvironmentKey {
    static let defaultValue: ((GitSyncPresentation) -> Void)? = nil
}

extension EnvironmentValues {
    var presentGitSync: ((GitSyncPresentation) -> Void)? {
        get { self[PresentGitSyncKey.self] }
        set { self[PresentGitSyncKey.self] = newValue }
    }
}

private struct GitSyncSheetHost: ViewModifier {
    @State private var presentation: GitSyncPresentation?

    func body(content: Content) -> some View {
        content
            .environment(\.presentGitSync, { presentation = $0 })
            .onChange(of: WorkSessionContext.shared.scope) { _, _ in presentation = nil }
            .sheet(item: $presentation) { request in
                if let session = request.pushSession {
                    GitPushView(session: session, folderName: request.folderName,
                                hostName: request.hostName, onPushed: request.onCompleted)
                } else {
                    RemoteHostFeatureGate(feature: .reviewedPull, peer: request.target.peer, hostName: request.hostName) {
                        GitPullSheet(service: request.target, folderName: request.folderName,
                                     hostName: request.hostName, onPulled: request.onCompleted)
                    }
                    .modalFrame(width: 520, height: 380)
                }
            }
    }
}

extension View {
    func gitSyncSheetHost() -> some View { modifier(GitSyncSheetHost()) }
}
