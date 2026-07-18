import Foundation
import Testing

@testable import HerdrMobile

@Suite struct JSONValueTests {
    @Test func decodesEveryJSONShape() throws {
        let json = #"{"s":"x","n":1.5,"i":3,"b":true,"z":null,"a":[1,"two"],"o":{"k":"v"}}"#

        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))

        #expect(value["s"] == .string("x"))
        #expect(value["n"] == .number(1.5))
        #expect(value["i"] == .number(3))
        #expect(value["b"] == .bool(true))
        #expect(value["z"] == JSONValue.null)
        #expect(value["a"] == .array([.number(1), .string("two")]))
        #expect(value["o"] == .object(["k": .string("v")]))
    }

    @Test func encodingRoundTripsEveryJSONShape() throws {
        let json = #"{"s":"x","n":1.5,"i":3,"b":true,"z":null,"a":[1,"two"],"o":{"k":"v"}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))

        let reencoded = try JSONEncoder().encode(value)
        let decodedAgain = try JSONDecoder().decode(JSONValue.self, from: reencoded)

        #expect(decodedAgain == value)
    }

    @Test func subscriptOnNonObjectIsNil() {
        #expect(JSONValue.string("x")["key"] == nil)
        #expect(JSONValue.null["key"] == nil)
    }

    @Test func stringValueUnwrapsOnlyStrings() {
        #expect(JSONValue.string("x").stringValue == "x")
        #expect(JSONValue.number(1).stringValue == nil)
    }
}
