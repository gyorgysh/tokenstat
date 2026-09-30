// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatSteerContext.swift and WorkReference.swift.
import Foundation

@main enum ChatSteerContextTests {
    @MainActor static func main() async {
        let scope = WorkReference.Scope.local(installationID: "installation")
        func reference(_ chat: String, host: String = "host", workspace: String = "project") -> WorkReference {
            WorkReference(scope: scope, hostIdentity: host, workspaceID: workspace,
                          kind: .conversation, itemID: chat)
        }
        var current = reference("first")
        var generation: UInt64 = 1
        var draft = "same words"
        var sentTo: [WorkReference] = []

        func matches(_ context: ChatSteerContext) -> Bool {
            context.matches(reference: current, generation: generation, peer: nil, scope: scope)
        }

        // A Task scheduled by Send must retain the original conversation even
        // if navigation runs before the Task reaches its first bridge call.
        let reserved = ChatSteerContext(reference: current, generation: generation, peer: nil)
        current = reference("second")
        generation += 1
        let beforeSend = Task { @MainActor in
            guard matches(reserved) else { return }
            sentTo.append(reserved.reference)
            draft = ""
        }
        await beforeSend.value
        precondition(sentTo.isEmpty && draft == "same words")

        // A response for the previous selection cannot clear an identical
        // draft in the next one. Leaving and returning to the same chat also
        // creates a new selection, even though all identifiers match again.
        current = reference("first")
        generation = 3
        let inFlight = ChatSteerContext(reference: current, generation: generation, peer: nil)
        precondition(matches(inFlight))
        generation += 1
        precondition(!matches(inFlight) && draft == "same words")
        current = reference("second")
        precondition(!matches(inFlight))

        let live = ChatSteerContext(reference: current, generation: generation, peer: nil)
        precondition(matches(live))
        precondition(!live.matches(reference: reference("second", host: "another-host"),
            generation: generation, peer: nil, scope: scope))
        precondition(!live.matches(reference: reference("second", workspace: "another-project"),
            generation: generation, peer: nil, scope: scope))
        precondition(!live.matches(reference: current, generation: generation,
            peer: "remote-host", scope: scope))
        precondition(!live.matches(reference: current, generation: generation, peer: nil,
            scope: .local(installationID: "other-installation")))
        precondition(!live.matches(reference: current, generation: generation, peer: nil, scope: nil))

        // Finishing an older delivery may release only its own reservation.
        let next = ChatSteerContext(reference: current, generation: generation, peer: nil)
        precondition(live != next)
        print("Steer ownership: scheduled sends, late responses, navigation, scopes and reservations passed")
    }
}
