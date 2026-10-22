// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Lose a fictional Ask reply, then accept only an exact retry. There is no
/// host or provider in this fixture, and Stop only changes this actor's state.
actor TeamFixtureAsks {
    static let shared = TeamFixtureAsks()
    private var accepted: JSONValue?
    private var running = false
    private var reviews = 0
    private let fence = JSONValue.object(["runId":.string("run_" + String(repeating: "a", count: 32)), "incarnation":.string(String(repeating: "b", count: 64))])

    func call(_ request: JSONValue) throws -> JSONValue {
        guard case let .object(body) = request, case let .string(method)? = body["method"] else { throw CancellationError() }
        switch method {
        case "team.chat.ask.review":
            reviews += 1
            return .object(["review":.string(String(repeating: reviews == 1 ? "a" : "b", count: 64)), "agentRuns":.bool(true)])
        case "team.chat.ask":
            guard let input = body["params"] else { throw CancellationError() }
            if let accepted {
                guard input == accepted else {
                    throw TeamRequestFailure(code: "fixture_duplicate", message: "The retry changed the fictional Ask.")
                }
                return .object(["state":.string("running"), "fence":fence])
            }
            accepted = input; running = true
            throw TeamRequestFailure(code: "delivery_unknown", message: "The fictional Ask reply was interrupted after acceptance.")
        case "team.chat.ask.status": return .object(["running":.bool(running)])
        case "team.chat.ask.stop":
            running = false
            return .object(["stopping":.bool(true)])
        default: throw CancellationError()
        }
    }
}
