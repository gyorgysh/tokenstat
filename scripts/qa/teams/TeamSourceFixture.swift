// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Inert adapters for the production shared-source notice. This target never
// links the production Bridge, FFI, host or account storage.
import SwiftUI
import Observation

@MainActor final class WorkSessionContext {
    static let shared = WorkSessionContext()
    let scope: WorkReference.Scope? = .local(installationID: "teams-source-fixture")
    let generation: UInt64 = 1
}

struct FixtureSourceChat { struct Marker { let id: String }; var teamShare: Marker? }
@MainActor @Observable final class ChatModel {
    var selected: FixtureSourceChat? = .init(teamShare: .init(id: "share_fixture"))
    let peer: String? = nil
    let savedCopy: Bool? = nil
    let selectionGeneration: UInt64 = 1
    var currentReference: WorkReference? {
        .init(scope: .local(installationID: "teams-source-fixture"), hostIdentity: "fixture-host",
              workspaceID: "fixture-workspace", kind: .conversation, itemID: "fixture-chat")
    }
    func refreshSharingSource(reference: WorkReference, generation: UInt64, notice: String? = nil) async {
        guard reference == currentReference, generation == selectionGeneration else { return }
        selected?.teamShare = nil
    }
}

enum Bridge {
    @MainActor static func chatInvoke<T: Decodable & Sendable>(peer: String?, _ method: String, _ params: [String: Any],
        expectedScope: WorkReference.Scope, expectedGeneration: UInt64, as: T.Type) async throws -> T {
        guard peer == nil, expectedScope == WorkSessionContext.shared.scope, expectedGeneration == 1,
              params["id"] as? String == "fixture-chat", params["workspaceId"] as? String == "fixture-workspace" else { throw CancellationError() }
        let body: String
        switch method {
        case "chat.sharing.info":
            let incomplete = ProcessInfo.processInfo.arguments.contains("--fixture-source-incomplete")
            body = "{\"sharing\":{\"id\":\"share_fixture\",\"revision\":2,\"phase\":\"active\",\"privateReady\":false,\"sourceOnly\":\(incomplete),\"accountCleanupPending\":true}}"
        case "chat.sharing.stopLocal":
            guard params["share"] as? String == "share_fixture", params["confirmStop"] as? Bool == true else { throw CancellationError() }
            body = "{\"stoppedLocally\":true,\"privateReady\":true,\"localRecoveryNeeded\":false,\"accountCleanupPending\":true}"
        default: throw CancellationError()
        }
        return try JSONDecoder().decode(T.self, from: Data(body.utf8))
    }
}

@MainActor struct TeamSourceFixture: View {
    @State private var model = ChatModel()
    @State private var draft = "Private unsent note — keep this on my device."
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                Text("Example source chat").font(Theme.title2)
                Text("Fictional report: the total increased from 24 to 42.").font(Theme.body)
                if model.selected?.teamShare != nil { ChatSharingNotice(model: model) }
                else { Text("Sharing stopped on this computer").accessibilityIdentifier("fixture.source.stopped") }
                TextEditor(text: $draft)
                    .font(Theme.body).frame(height: 180)
                    .accessibilityIdentifier("fixture.source.draft")
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(Theme.background)
        .preferredColorScheme(.dark)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--fixture-large-text") ? .accessibility3 : .large)
    }
}
