enum HostMonogram {
    static func labels(for hosts: [(id: String, name: String)]) -> [String: String] {
        let entries = hosts.map { Entry(host: $0) }
        var labels = entries.map(\.initialLabel)

        let baseCounts = counts(of: entries) { (entry: Entry) -> String? in
            guard !entry.isIPv4, !entry.isEmpty else { return nil }
            return entry.base.uppercased()
        }

        for index in entries.indices where !entries[index].isIPv4
            && !entries[index].isEmpty
            && (baseCounts[entries[index].base.uppercased()] ?? 0) > 1 {
            labels[index] = entries[index].collisionLabel
        }

        var collisionLabelCounts: [String: Int] = [:]
        for index in entries.indices where !entries[index].isIPv4 && !entries[index].isEmpty {
            collisionLabelCounts[labels[index].uppercased(), default: 0] += 1
        }
        let unnumberedLabels = Set(collisionLabelCounts.filter { $0.value == 1 }.keys)
        var collisionNumbers: [String: Int] = [:]
        for index in entries.indices where !entries[index].isIPv4
            && !entries[index].isEmpty
            && (collisionLabelCounts[labels[index].uppercased()] ?? 0) > 1 {
            let key = entries[index].base.uppercased()
            var number = (collisionNumbers[key] ?? 0) + 1
            while unnumberedLabels.contains(key + String(number)) {
                number += 1
            }
            collisionNumbers[key] = number
            labels[index] = key + String(number)
        }

        let finalLabelCounts = counts(of: labels) { label in
            label.uppercased()
        }
        for index in entries.indices where entries[index].isIPv4
            && (finalLabelCounts[labels[index].uppercased()] ?? 0) > 1 {
            labels[index] = entries[index].lastTwoOctets
        }

        var result: [String: String] = [:]
        for (entry, label) in zip(entries, labels) {
            result[entry.id] = label
        }
        return result
    }

    private struct Entry {
        let id: String
        let base: String
        let isEmpty: Bool
        let isIPv4: Bool
        let lastOctet: String?
        let lastTwoOctets: String
        let collisionLabel: String

        init(host: (id: String, name: String)) {
            id = host.id
            let trimmedName = Self.trimmed(host.name)
            isEmpty = trimmedName.isEmpty

            if let octets = Self.ipv4Octets(trimmedName) {
                isIPv4 = true
                lastOctet = String(octets[3])
                lastTwoOctets = "\(octets[2]).\(octets[3])"
                base = ""
                collisionLabel = ""
            } else {
                isIPv4 = false
                lastOctet = nil
                lastTwoOctets = ""
                base = trimmedName.first.map { String($0) } ?? "?"
                collisionLabel = Self.collisionLabel(for: trimmedName, base: base)
            }
        }

        var initialLabel: String {
            if isEmpty { return "?" }
            if let lastOctet { return lastOctet }
            return base.uppercased()
        }

        private static func trimmed(_ value: String) -> String {
            let leadingTrimmed = value.drop(while: { $0.isWhitespace })
            let trailingTrimmed = leadingTrimmed.reversed().drop(while: { $0.isWhitespace })
            return String(trailingTrimmed.reversed())
        }

        private static func ipv4Octets(_ value: String) -> [Int]? {
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 4 else { return nil }

            var octets: [Int] = []
            octets.reserveCapacity(4)
            for component in components {
                guard !component.isEmpty else { return nil }
                var value = 0
                for scalar in component.unicodeScalars {
                    guard scalar.value >= 48, scalar.value <= 57 else { return nil }
                    let digit = Int(scalar.value - 48)
                    guard value <= (255 - digit) / 10 else { return nil }
                    value = value * 10 + digit
                }
                octets.append(value)
            }
            return octets
        }

        private static func collisionLabel(for value: String, base: String) -> String {
            let words = splitIntoWords(value)
            if words.count >= 2 {
                guard let first = words[0].first, let second = words[1].first else {
                    return base.uppercased()
                }
                return String(first) + String(second)
            }

            let graphemes = Array(value)
            guard let first = graphemes.first else { return base.uppercased() }
            let prefix = String(first).uppercased()
            guard graphemes.count >= 2 else { return prefix }
            return prefix + String(graphemes[1])
        }

        private static func splitIntoWords(_ value: String) -> [[Character]] {
            var words: [[Character]] = []
            var word: [Character] = []
            var previous: Character?

            func finishWord() {
                if !word.isEmpty {
                    words.append(word)
                    word.removeAll(keepingCapacity: true)
                }
            }

            for character in value {
                let separator = character.isWhitespace || character == "-"
                    || character == "_" || character == "."
                if separator {
                    finishWord()
                } else {
                    if let previous, previous.isLowercase, character.isUppercase {
                        finishWord()
                    }
                    word.append(character)
                }
                previous = character
            }
            finishWord()
            return words
        }
    }

    private static func counts<Value, Key>(
        of values: [Value], key: (Value) -> Key?
    ) -> [Key: Int] where Key: Hashable {
        var result: [Key: Int] = [:]
        for value in values {
            guard let key = key(value) else { continue }
            result[key, default: 0] += 1
        }
        return result
    }
}
