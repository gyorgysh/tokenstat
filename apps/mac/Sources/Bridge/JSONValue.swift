// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// A JSON value the app's models do not name.
///
/// Workflow graphs round-trip between the Mac, the phone and the iPad
/// through the same Swift models, so known fields cannot be lost that way.
/// The loss vector is a host that sends a field no client names yet: plain
/// `Codable` drops it on decode and the next save would delete it. Models
/// that the person edits keep their unknown fields in this bag and write
/// them back untouched.
enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
            return
        }
        if let value = try? single.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? single.decode(Int64.self) {
            self = .int(value)
            return
        }
        if let value = try? single.decode(Double.self) {
            self = .double(value)
            return
        }
        if let value = try? single.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? single.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        self = .object(try single.decode([String: JSONValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null:
            try single.encodeNil()
        case .bool(let value):
            try single.encode(value)
        case .int(let value):
            try single.encode(value)
        case .double(let value):
            try single.encode(value)
        case .string(let value):
            try single.encode(value)
        case .array(let value):
            try single.encode(value)
        case .object(let value):
            try single.encode(value)
        }
    }
}

/// Coding-key box for fields no model names. Decode the known keys first,
/// then collect whatever remains into the bag.
struct UnknownFields: Sendable {
    static func decode(from decoder: Decoder, known: Set<String>) throws -> [String: JSONValue] {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        var out: [String: JSONValue] = [:]
        for key in container.allKeys where !known.contains(key.stringValue) {
            out[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return out
    }

    static func encode(_ fields: [String: JSONValue], to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        for (key, value) in fields {
            try container.encode(value, forKey: AnyCodingKey(key))
        }
    }
}

private struct AnyCodingKey: CodingKey, Hashable {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
