// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

struct ChatRouteDestination: Codable, Sendable, Hashable {
    var backend: String
    var model: String? = nil
    var effort: String? = nil
}
struct ChatRoutingPolicy: Codable, Sendable, Hashable {
    var enabled = false
    var routes: [ChatRouteDestination] = []
    var waitForReset = false
    var returnPreferred = false
    var useAsDefault = false
    var failoverOnThrottle = false
    var failoverOnErrors = false
    var failoverOnAuth = false
    var failoverOnFailures = false
    var notify: Bool? = nil
    var preferred: ChatRouteDestination? = nil
    init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, routes, waitForReset, returnPreferred, useAsDefault, failoverOnThrottle, failoverOnErrors, failoverOnAuth, failoverOnFailures, notify, preferred
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        routes = try c.decodeIfPresent([ChatRouteDestination].self, forKey: .routes) ?? []
        waitForReset = try c.decodeIfPresent(Bool.self, forKey: .waitForReset) ?? false
        returnPreferred = try c.decodeIfPresent(Bool.self, forKey: .returnPreferred) ?? false
        useAsDefault = try c.decodeIfPresent(Bool.self, forKey: .useAsDefault) ?? false
        failoverOnThrottle = try c.decodeIfPresent(Bool.self, forKey: .failoverOnThrottle) ?? false
        failoverOnErrors = try c.decodeIfPresent(Bool.self, forKey: .failoverOnErrors) ?? false
        failoverOnAuth = try c.decodeIfPresent(Bool.self, forKey: .failoverOnAuth) ?? false
        failoverOnFailures = try c.decodeIfPresent(Bool.self, forKey: .failoverOnFailures) ?? false
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify)
        preferred = try c.decodeIfPresent(ChatRouteDestination.self, forKey: .preferred)
    }
}
struct ChatProviderLimit: Codable, Sendable, Hashable {
    var provider: String
    var kind: String
    var reason: String
    var resetsAtMs: Int64?
    var observedAtMs: Int64
}
struct ChatRoutingActivityPage: Codable, Sendable {
    var activity: [ChatRoutingActivity]
    var cursor: String?
}
struct ChatRoutingActivity: Codable, Sendable, Hashable {
    var id: String?
    var atMs: Int64
    var kind: String
    var source: ChatRouteDestination?
    var target: ChatRouteDestination?
    var reason: String
    var resetsAtMs: Int64?
    var label: String {
        switch kind {
        case "usage": L10n.text("common.chat_route_event_usage")
        case "throttle": L10n.text("common.chat_route_event_throttle")
        case "error": L10n.text("common.chat_route_event_error")
        case "auth": L10n.text("common.chat_route_event_auth")
        case "failure": L10n.text("common.chat_route_event_failure")
        case "settings": L10n.text("common.chat_route_event_settings")
        case "switched": L10n.text("common.chat_route_event_switched")
        case "resumed": L10n.text("common.chat_route_event_resumed")
        case "returned": L10n.text("common.chat_route_event_returned")
        case "cancelled": L10n.text("common.chat_route_event_cancelled")
        case "skipped": L10n.text("common.chat_route_event_skipped")
        default: L10n.text("common.chat_route_event_paused")
        }
    }
}
struct ChatRoutingReset: Codable, Sendable, Hashable {
    var destination: ChatRouteDestination
    var atMs: Int64
}
struct ChatRoutingState: Codable, Sendable, Hashable {
    var policy: ChatRoutingPolicy
    var limit: ChatProviderLimit?
    var waiting: Bool
    var needsDeliveryCheck: Bool
    var note: String?
    var tried: [ChatRouteDestination]
    var preferred: ChatRouteDestination?
    var activity: [ChatRoutingActivity]?
    var nextReset: ChatRoutingReset? = nil
}
