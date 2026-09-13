// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
// Compile with JSONValue.swift.
import Foundation

@main
struct JSONValueTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) {
            assert(condition, message)
        }
        func roundTrip(_ value: JSONValue) -> JSONValue {
            let data = try! JSONEncoder().encode(value)
            return try! JSONDecoder().decode(JSONValue.self, from: data)
        }
        check(roundTrip(.null) == .null, "null")
        check(roundTrip(.bool(true)) == .bool(true), "bool")
        check(roundTrip(.int(7)) == .int(7), "int stays an int")
        check(roundTrip(.double(2.5)) == .double(2.5), "double")
        check(roundTrip(.string("keep me")) == .string("keep me"), "string")
        check(
            roundTrip(.array([.int(1), .string("two"), .null]))
                == .array([.int(1), .string("two"), .null]),
            "array"
        )
        check(
            roundTrip(.object(["a": .int(1), "b": .object(["c": .bool(false)])]))
                == .object(["a": .int(1), "b": .object(["c": .bool(false)])]),
            "nested object"
        )
        // Raw host JSON with keys no model names: every value kind survives.
        let raw = #"{"futureFlag":true,"retries":3,"ratio":1.5,"label":"x","nothing":null,"list":[1,"two"],"nested":{"a":1}}"#
        let decoded = try! JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        guard case .object(let fields) = decoded else {
            fatalError("top-level object")
        }
        check(fields["futureFlag"] == .bool(true), "object bool")
        check(fields["retries"] == .int(3), "object int")
        check(fields["ratio"] == .double(1.5), "object double")
        check(fields["label"] == .string("x"), "object string")
        check(fields["nothing"] == .null, "object null")
        check(fields["list"] == .array([.int(1), .string("two")]), "object array")
        check(fields["nested"] == .object(["a": .int(1)]), "object nested")
        let again = try! JSONEncoder().encode(decoded)
        let canon = try! JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
        let back = try! JSONSerialization.jsonObject(with: again) as! [String: Any]
        check(NSDictionary(dictionary: canon).isEqual(to: back), "re-encoded JSON matches")
        // The UnknownFields helpers as the models use them: known keys decode
        // normally, the rest lands in the bag and encodes back untouched.
        struct Widget: Codable, Equatable {
            var id: String
            var extra: [String: JSONValue] = [:]
            enum CodingKeys: String, CodingKey, CaseIterable { case id }
            init(id: String) { self.id = id }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                extra = try UnknownFields.decode(
                    from: decoder,
                    known: Set(CodingKeys.allCases.map(\.stringValue))
                )
            }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try UnknownFields.encode(extra, to: encoder)
            }
        }
        let widgetJSON = #"{"id":"w1","futureFlag":true,"count":3}"#
        let widget = try! JSONDecoder().decode(Widget.self, from: Data(widgetJSON.utf8))
        check(widget.id == "w1", "known key decodes")
        check(widget.extra == ["futureFlag": .bool(true), "count": .int(3)], "unknown keys bagged")
        var edited = widget
        edited.id = "w2"
        let widgetBack = try! JSONEncoder().encode(edited)
        let widgetDict = try! JSONSerialization.jsonObject(with: widgetBack) as! [String: Any]
        check(widgetDict["id"] as? String == "w2", "edited key encodes")
        check(widgetDict["futureFlag"] as? Bool == true, "bag survives an edit")
        check(widgetDict["count"] as? Int == 3, "int bag survives an edit")
        print("JSONValueTests passed")
    }
}
