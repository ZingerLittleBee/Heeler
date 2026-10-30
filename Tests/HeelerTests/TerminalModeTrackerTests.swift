import Foundation
import Testing

@testable import Heeler

@Suite("Terminal mode tracker")
struct TerminalModeTrackerTests {
    private static let trackedModes = "2004;1;1000;1049"

    private static func modes(of tracker: TerminalModeTracker) -> [String: Bool] {
        [
            "bracketedPaste": tracker.usesBracketedPaste,
            "cursorKeys": tracker.usesApplicationCursorKeys,
            "mouseTracking": tracker.tracksMouse,
            "alternateScreen": tracker.isAlternateScreen,
        ]
    }

    @Test func queryingSavingAndRestoringAModeLeavesItOn() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data("\u{1B}[?\(Self.trackedModes)h".utf8))
        let allOn = [
            "bracketedPaste": true, "cursorKeys": true,
            "mouseTracking": true, "alternateScreen": true,
        ]
        #expect(Self.modes(of: tracker) == allOn)

        for mode in ["2004", "1", "1000", "1049", Self.trackedModes] {
            for sequence in ["\u{1B}[?\(mode)$p", "\u{1B}[?\(mode)s", "\u{1B}[?\(mode)r"] {
                tracker.receive(Data(sequence.utf8))
                #expect(Self.modes(of: tracker) == allOn, "\(sequence.dropFirst())")
            }
        }
    }

    @Test func queryingSavingAndRestoringAModeLeavesItOff() {
        var tracker = TerminalModeTracker()
        let allOff = [
            "bracketedPaste": false, "cursorKeys": false,
            "mouseTracking": false, "alternateScreen": false,
        ]

        for mode in ["2004", "1", "1000", "1049", Self.trackedModes] {
            for sequence in ["\u{1B}[?\(mode)$p", "\u{1B}[?\(mode)s", "\u{1B}[?\(mode)r"] {
                tracker.receive(Data(sequence.utf8))
                #expect(Self.modes(of: tracker) == allOff, "\(sequence.dropFirst())")
            }
        }
    }

    // MARK: Kitty keyboard flags

    private static func csi(_ body: String) -> Data {
        Data("\u{1B}[\(body)".utf8)
    }

    /// Feeds each sequence and returns the flags after each one.
    private static func flags(
        after sequences: [String],
        in tracker: inout TerminalModeTracker
    ) -> [UInt8] {
        sequences.map { sequence in
            tracker.receive(csi(sequence))
            return tracker.kittyKeyboardFlags
        }
    }

    @Test func pushedFlagsBecomeCurrentAndPopRestoresThePreviousEntry() {
        var tracker = TerminalModeTracker()
        #expect(tracker.kittyKeyboardFlags == 0)

        #expect(
            Self.flags(after: [">1u", ">9u", ">u", "<u", "<1u"], in: &tracker)
                == [1, 9, 0, 9, 1])
    }

    @Test func popTakesSeveralEntriesAndStopsAtAnEmptyStack() {
        var tracker = TerminalModeTracker()
        #expect(
            Self.flags(after: [">1u", ">3u", ">9u", ">11u", "<2u", "<2u"], in: &tracker)
                == [1, 3, 9, 11, 3, 0])

        // Past empty, one entry and many: nothing fails, and pushing still works.
        #expect(
            Self.flags(after: ["<u", "<99u", ">5u", ">6u", "<99999u", ">2u"], in: &tracker)
                == [0, 0, 5, 6, 0, 2])
    }

    @Test func poppingZeroEntriesKeepsTheFlags() {
        var tracker = TerminalModeTracker()
        #expect(Self.flags(after: [">9u", "<0u"], in: &tracker) == [9, 9])
    }

    @Test func setReplacesAddsOrRemovesBitsByMode() {
        var tracker = TerminalModeTracker()
        #expect(
            Self.flags(
                after: ["=9;1u", "=5;1u", "=2;2u", "=5;3u", "=8u", "=;1u"],
                in: &tracker)
                == [9, 5, 7, 2, 8, 0])
    }

    @Test func setChangesOnlyTheTopEntry() {
        var tracker = TerminalModeTracker()
        #expect(
            Self.flags(after: [">1u", ">2u", "=8;1u", "<u", "<u"], in: &tracker)
                == [1, 2, 8, 1, 0])
        // On an empty stack it sets the base, which a later push sits on.
        #expect(
            Self.flags(after: ["=8;1u", ">1u", "<u", "<u"], in: &tracker)
                == [8, 1, 8, 0])
    }

    @Test func flagsOrModesOutsideTheProtocolChangeNothing() {
        var tracker = TerminalModeTracker()
        #expect(
            Self.flags(
                after: [
                    ">9u", ">32u", "=32;1u", "=1;4u", "=1;0u",
                    ">99999999999999999999999u", "=99999999999999999999999;1u",
                    "=1;99999999999999999999999u", ">1:2u",
                ],
                in: &tracker)
                == [9, 9, 9, 9, 9, 9, 9, 9, 9])
    }

    @Test func aFullStackDropsItsOldestEntry() {
        var tracker = TerminalModeTracker()
        _ = Self.flags(after: (1...9).map { ">\($0)u" }, in: &tracker)
        #expect(tracker.kittyKeyboardFlags == 9)

        // Eight entries are kept, so the push of 1 is gone.
        #expect(Self.flags(after: ["<7u", "<u"], in: &tracker) == [2, 0])
    }

    @Test(arguments: ["1049", "1047", "47"])
    func eachScreenKeepsItsOwnStack(alternateScreenMode mode: String) {
        var tracker = TerminalModeTracker()
        #expect(
            Self.flags(
                after: [
                    ">1u", "?\(mode)h", ">8u", ">9u", "?\(mode)l", ">2u",
                    "?\(mode)h", "<u", "?\(mode)l", "<u", "?\(mode)h", "<u", "?\(mode)l",
                ],
                in: &tracker)
                == [1, 0, 8, 9, 1, 2, 9, 8, 2, 1, 8, 0, 1])
    }

    @Test func aFlagsQueryChangesNothing() {
        var tracker = TerminalModeTracker()
        tracker.receive(Self.csi(">1u"))
        tracker.receive(Self.csi(">9u"))
        let before = tracker

        tracker.receive(Self.csi("?u"))

        #expect(tracker == before)
        #expect(tracker.kittyKeyboardFlags == 9)
        #expect(Self.flags(after: ["<u"], in: &tracker) == [1])
    }

    @Test func otherSequencesEndingInTheSameBytesAreNotKittyRequests() {
        var tracker = TerminalModeTracker()
        tracker.receive(Self.csi(">9u"))
        let before = tracker

        // Restore cursor, a key report, and requests that share a prefix or
        // carry an intermediate.
        for sequence in ["u", "13u", ">4;1m", ">0q", ">c", "=5c", "<1m", ">1$u", "<1 u", "=1;1$u"] {
            tracker.receive(Self.csi(sequence))
            #expect(tracker == before, "\(sequence)")
        }
    }

    // MARK: Parsing

    private struct SplitCase {
        let sequence: String
        let flags: UInt8
        var bracketedPaste = true
        var cursorKeys = false
        var mouseTracking = false
        var alternateScreen = false
    }

    /// Each case's expected state starts from flags 2 over 1 and bracketed
    /// paste on.
    private static let splitCases: [SplitCase] = [
        SplitCase(sequence: ">9u", flags: 9),
        SplitCase(sequence: ">u", flags: 0),
        SplitCase(sequence: "<u", flags: 1),
        SplitCase(sequence: "<2u", flags: 0),
        SplitCase(sequence: "=8;1u", flags: 8),
        SplitCase(sequence: "=8;2u", flags: 10),
        SplitCase(sequence: "=2;3u", flags: 0),
        SplitCase(sequence: "?u", flags: 2),
        SplitCase(sequence: "?2004l", flags: 2, bracketedPaste: false),
        SplitCase(sequence: "?1h", flags: 2, cursorKeys: true),
        SplitCase(sequence: "?1000h", flags: 2, mouseTracking: true),
        SplitCase(sequence: "?1049h", flags: 0, alternateScreen: true),
        SplitCase(
            sequence: "?1;1000;1049h", flags: 0,
            cursorKeys: true, mouseTracking: true, alternateScreen: true),
        SplitCase(sequence: "?2004$p", flags: 2),
        SplitCase(sequence: "?1049$p", flags: 2),
        SplitCase(sequence: "?2004s", flags: 2),
        SplitCase(sequence: "?1049s", flags: 2),
        SplitCase(sequence: "?2004r", flags: 2),
        SplitCase(sequence: "?1049r", flags: 2),
    ]

    private static func startingTracker() -> TerminalModeTracker {
        var tracker = TerminalModeTracker()
        tracker.receive(csi(">1u"))
        tracker.receive(csi(">2u"))
        tracker.receive(csi("?2004h"))
        return tracker
    }

    private static func expect(
        _ tracker: TerminalModeTracker,
        matches expected: SplitCase,
        _ comment: Comment
    ) {
        #expect(tracker.kittyKeyboardFlags == expected.flags, comment)
        #expect(tracker.usesBracketedPaste == expected.bracketedPaste, comment)
        #expect(tracker.usesApplicationCursorKeys == expected.cursorKeys, comment)
        #expect(tracker.tracksMouse == expected.mouseTracking, comment)
        #expect(tracker.isAlternateScreen == expected.alternateScreen, comment)
    }

    @Test func everySequenceParsesTheSameInOneChunkOrSplitAtAnyByte() {
        for testCase in Self.splitCases {
            let bytes = Self.csi(testCase.sequence)

            var whole = Self.startingTracker()
            whole.receive(bytes)
            Self.expect(whole, matches: testCase, "\(testCase.sequence) in one chunk")

            for split in 1..<bytes.count {
                var parts = Self.startingTracker()
                parts.receive(bytes.prefix(split))
                parts.receive(bytes.dropFirst(split))
                Self.expect(parts, matches: testCase, "\(testCase.sequence) split at \(split)")
                #expect(parts == whole, "\(testCase.sequence) split at \(split)")
            }

            var byteByByte = Self.startingTracker()
            for byte in bytes {
                byteByByte.receive(Data([byte]))
            }
            #expect(byteByByte == whole, "\(testCase.sequence) byte by byte")
        }
    }

    @Test func anEscapeOrCancelAbandonsTheSequenceInProgress() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data("\u{1B}[?2004\u{1B}[?1h".utf8))
        #expect(!tracker.usesBracketedPaste)
        #expect(tracker.usesApplicationCursorKeys)

        tracker.receive(Data("\u{1B}[?2004\u{18}h".utf8))
        #expect(!tracker.usesBracketedPaste)
        tracker.receive(Data("\u{1B}[?2004\u{1A}h".utf8))
        #expect(!tracker.usesBracketedPaste)
    }

    @Test func aControlByteInsideASequenceDoesNotEndIt() {
        var tracker = TerminalModeTracker()
        tracker.receive(Data("\u{1B}[?20\n04h".utf8))
        #expect(tracker.usesBracketedPaste)
    }

    @Test func oversizedParameterListsAreBounded() {
        var tracker = TerminalModeTracker()
        let longList = String(repeating: "7;", count: 100_000)
        tracker.receive(Data("\u{1B}[?\(longList)2004h".utf8))
        // The list outran the tracker, which drops the parameters past its
        // limit; what matters is that it stays usable.
        tracker.receive(Data("\u{1B}[?1h".utf8))
        #expect(tracker.usesApplicationCursorKeys)
    }
}
