// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
import Foundation

/// Only explicit Comment scenarios accept fictional in-memory messages. No
/// network, host, credentials or personal draft store belongs to this fixture.
actor TeamFixtureComments {
    static let shared = TeamFixtureComments()
    private var rows: [JSONValue] = []
    private var receipts: [String: JSONValue] = [:]
    func events() -> [JSONValue] { rows }
    func send(_ params: JSONValue, uncertain: Bool) throws -> JSONValue {
        guard case let .object(body) = params, case let .object(target)? = body["target"],
              case let .string(share)? = target["share"], case let .object(input)? = body["input"],
              case let .string(id)? = input["clientMessageId"], case let .string(text)? = input["text"] else { throw CancellationError() }
        if let receipt = receipts[id] { return receipt }
        let sequence = Int64(1000 + rows.count)
        rows.append(.object(["kind":.string("user"), "text":.string(text), "seq":.int(sequence), "atMs":.int(1792500000100), "mode":.string("comment"), "author":.object(["kind":.string("person"),"id":.string("fixture-owner"),"name":.string("Example owner"),"handle":.string("example-owner"),"avatar":.null])]))
        let result = JSONValue.object(["receipt":.object(["shareId":.string(share),"clientMessageId":.string(id),"state":.string("accepted"),"sequence":.int(sequence),"acceptedAtMs":.int(1792500000100)])])
        receipts[id] = result
        if uncertain { throw TeamRequestFailure(code: "delivery_unknown", message: "The fictional reply was interrupted after acceptance.") }
        return result
    }
    func receipt(_ params: JSONValue) -> JSONValue {
        guard case let .object(body) = params, case let .object(target)? = body["target"],
              let share = target["share"], case let .object(query)? = body["params"],
              case let .string(id)? = query["clientMessageId"] else { return .null }
        return receipts[id] ?? .object(["receipt":.object(["shareId":share,"clientMessageId":.string(id),"state":.string("unknown"),"sequence":.null,"acceptedAtMs":.null])])
    }
}
