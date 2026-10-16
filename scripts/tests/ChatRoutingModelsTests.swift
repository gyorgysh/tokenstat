// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with ChatRoutingModels.swift. SessionIdentities.swift.
import Foundation

@main
struct ChatRoutingModelsTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let old = Data(#"{"policy":{"enabled":true,"routes":[{"backend":"codex","model":"gpt-6.1-sol"}],"waitForReset":true,"returnPreferred":true,"useAsDefault":false},"waiting":false,"needsDeliveryCheck":true,"tried":[{"backend":"codex"}]}"#.utf8)
        let state = try decoder.decode(ChatRoutingState.self, from: old)
        precondition(state.needsDeliveryCheck && state.policy.enabled && state.policy.waitForReset)
        precondition(state.policy.routes.first?.effort == nil && state.activity == nil)
        precondition(!state.policy.failoverOnErrors && !state.policy.failoverOnAuth && !state.policy.failoverOnFailures && !state.policy.failoverOnThrottle)
        precondition(state.policy.notify == nil && state.policy.preferred == nil)

        var configured = state.policy
        configured.routes[0].effort = "high"
        configured.preferred = configured.routes[0]
        configured.failoverOnErrors = true
        configured.failoverOnAuth = true
        configured.failoverOnFailures = true
        configured.notify = false
        let roundTrip = try decoder.decode(ChatRoutingPolicy.self, from: JSONEncoder().encode(configured))
        precondition(roundTrip == configured)
        print("Routing models: older hosts retain delivery safety; effort, preferred route and explicit error policy round-trip")
    }
}
