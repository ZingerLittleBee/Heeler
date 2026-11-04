import Foundation

/// Raw node state for troubleshooting: labelled values and recent events,
/// newest last. Shown read-only and copied whole for a bug report.
public struct OverlayDiagnostics: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public struct Event: Sendable, Equatable {
        public var date: Date
        public var message: String

        public init(date: Date, message: String) {
            self.date = date
            self.message = message
        }
    }

    public var entries: [Entry]
    public var events: [Event]

    public init(entries: [Entry] = [], events: [Event] = []) {
        self.entries = entries
        self.events = events
    }

    public var isEmpty: Bool { entries.isEmpty && events.isEmpty }

    /// Every entry and event as plain text, one per line, with ISO 8601
    /// timestamps.
    public var text: String {
        var lines = entries.map { "\($0.label): \($0.value)" }
        if !events.isEmpty {
            lines.append("Events:")
            let format = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            lines += events.map { "\($0.date.formatted(format)) \($0.message)" }
        }
        return lines.joined(separator: "\n")
    }
}

extension OverlayNode {
    public func diagnostics() async -> OverlayDiagnostics { OverlayDiagnostics() }
}
