// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatRouteDestination: Codable, Sendable, Hashable {
    var backend: String
    var model: String? = nil
}
struct ChatRoutingPolicy: Codable, Sendable, Hashable {
    var enabled = false
    var routes: [ChatRouteDestination] = []
    var waitForReset = false
    var returnPreferred = false
    var useAsDefault = false
}
struct ChatProviderLimit: Codable, Sendable, Hashable {
    var provider: String
    var kind: String
    var reason: String
    var resetsAtMs: Int64?
    var observedAtMs: Int64
}
struct ChatRoutingState: Codable, Sendable, Hashable {
    var policy: ChatRoutingPolicy
    var limit: ChatProviderLimit?
    var waiting: Bool
    var needsDeliveryCheck: Bool
    var note: String?
    var tried: [ChatRouteDestination]
}
