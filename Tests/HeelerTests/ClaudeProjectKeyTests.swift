import Testing

@testable import Heeler

@Suite("Claude project key")
struct ClaudeProjectKeyTests {
    @Test(arguments: [
        ("/home/dev/project", "-home-dev-project"),
        ("/Users/dev/My Project.v2", "-Users-dev-My-Project-v2"),
        ("/private/tmp/heeler-tmp-chat2/probe-claude", "-private-tmp-heeler-tmp-chat2-probe-claude"),
        ("/home/dev/caf\u{E9}", "-home-dev-caf-"),
        ("/home/dev/\u{1F600}", "-home-dev---"),
        (#"C:\Users\dev\proj"#, "C--Users-dev-proj"),
    ])
    func shortKeysReplaceEveryOtherUnitWithADash(directory: String, key: String) {
        #expect(ClaudeProjectKey.key(forDirectory: directory) == key)
        #expect(ClaudeProjectKey.longKeyPrefix(forDirectory: directory) == nil)
    }

    @Test func decomposedNamesAreNormalizedFirstButTheRawFormStaysAvailable() {
        let decomposed = "/home/dev/cafe\u{301}"
        #expect(ClaudeProjectKey.key(forDirectory: decomposed) == "-home-dev-caf-")
        #expect(ClaudeProjectKey.unnormalizedKey(forDirectory: decomposed) == "-home-dev-cafe-")
    }

    @Test func longKeysKeepTwoHundredUnitsAndAppendTheHash() {
        let ascii = "/home/dev/" + String(repeating: "a", count: 250)
        let asciiKey = ClaudeProjectKey.key(forDirectory: ascii)
        #expect(asciiKey == "-home-dev-" + String(repeating: "a", count: 190) + "-u4xdh7")
        #expect(ClaudeProjectKey.longKeyPrefix(forDirectory: ascii) == String(asciiKey.prefix(201)))

        let emoji = "/home/dev/" + String(repeating: "\u{1F600}", count: 100) + "bbbbbbbbbb"
        #expect(
            ClaudeProjectKey.key(forDirectory: emoji)
                == "-home-dev-" + String(repeating: "-", count: 190) + "-asy115")
    }

    @Test func exactlyTwoHundredUnitsIsStillExact() {
        let directory = "/" + String(repeating: "b", count: 199)
        #expect(ClaudeProjectKey.key(forDirectory: directory) == "-" + String(repeating: "b", count: 199))
        #expect(ClaudeProjectKey.longKeyPrefix(forDirectory: directory) == nil)
        let longer = directory + "b"
        #expect(ClaudeProjectKey.key(forDirectory: longer).count > 201)
    }

    /// `abs(Int32.min)` traps, so the magnitude must be taken in 64 bits.
    @Test func aHashOfInt32MinUsesItsSixtyFourBitMagnitude() {
        let directory = "/home/dev/" + String(repeating: "a", count: 255) + "\u{92F4}\u{FFFF}\u{FE71}"
        #expect(ClaudeProjectKey.hashSuffix(Array(directory.utf16)) == "zik0zk")
        #expect(ClaudeProjectKey.key(forDirectory: directory).hasSuffix("-zik0zk"))
    }
}
