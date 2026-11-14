import Testing

@testable import Heeler

@Suite("Host monograms")
struct HostMonogramTests {
    @Test func singleHostUsesUppercasedFirstGrapheme() {
        #expect(labels([("host", "Laptop")]) == ["host": "L"])
    }

    @Test func baseLabelsRemainDistinct() {
        #expect(labels([
            ("laptop", "Laptop"),
            ("oak", "oak4d"),
        ]) == ["laptop": "L", "oak": "O"])
    }

    @Test func ipv4UsesLastOctet() {
        #expect(labels([("host", "192.0.2.15")]) == ["host": "15"])
        #expect(labels([
            ("ip", "10.0.0.15"),
            ("letter", "Laptop"),
        ]) == ["ip": "15", "letter": "L"])
    }

    @Test func wordInitialsResolveBaseCollision() {
        #expect(labels([
            ("book", "MacBook"),
            ("mini", "Mac mini"),
        ]) == ["book": "MB", "mini": "Mm"])

        #expect(labels([
            ("one", "build-server"),
            ("two", "brick"),
        ]) == ["one": "bs", "two": "Br"])

        #expect(labels([
            ("one", "build-server"),
            ("two", "build_server"),
        ]) == ["one": "B1", "two": "B2"])
    }

    @Test func singleWordUsesTwoGraphemesOnCollision() {
        #expect(labels([
            ("one", "Laptop"),
            ("two", "Lemon"),
        ]) == ["one": "La", "two": "Le"])
    }

    @Test func identicalNamesUseCatalogNumbers() {
        #expect(labels([
            ("one", "Laptop"),
            ("two", "Laptop"),
        ]) == ["one": "L1", "two": "L2"])

        #expect(labels([
            ("one", "Laptop"),
            ("two", "Laptop"),
            ("three", "Laptop"),
        ]) == ["one": "L1", "two": "L2", "three": "L3"])

        #expect(labels([
            ("lower", "laptop"),
            ("upper", "Laptop"),
        ]) == ["lower": "L1", "upper": "L2"])
    }

    @Test func stepFourRunsAfterTwoCharacterCollision() {
        #expect(labels([
            ("first", "MacBook"),
            ("second", "Mac mini"),
            ("third", "MacBook"),
        ]) == ["first": "M1", "second": "Mm", "third": "M2"])
    }

    @Test func caseInsensitiveExpandedCollisionsAreNumbered() {
        #expect(labels([
            ("first", "Mac mini"),
            ("second", "Mac Mini"),
        ]) == ["first": "M1", "second": "M2"])
    }

    @Test func numbersContinueAcrossTwoCharacterCollisionGroups() {
        #expect(labels([
            ("one", "Laptop"),
            ("two", "Laptop"),
            ("three", "Lemon"),
            ("four", "Lemon"),
        ]) == ["one": "L1", "two": "L2", "three": "L3", "four": "L4"])
    }

    @Test func numbersSkipLabelsHeldByUnnumberedHosts() {
        #expect(labels([
            ("one", "Laptop"),
            ("two", "Laptop"),
            ("literal", "L1"),
        ]) == ["one": "L2", "two": "L3", "literal": "L1"])

        #expect(labels([
            ("literal", "L2"),
            ("one", "Laptop"),
            ("two", "Laptop"),
        ]) == ["literal": "L2", "one": "L1", "two": "L3"])
    }

    @Test(arguments: [
        ["Laptop", "Laptop", "Lemon", "Lemon"],
        ["Laptop", "Laptop", "L1", "L2"],
        ["L1", "L1", "Laptop", "Laptop", "L3"],
        ["MacBook", "Mac mini", "MacBook", "Mac Mini", "M1"],
        ["laptop", "Laptop", "lemon", "Lemon", "Oak"],
        ["Laptop", "Laptop", "l-1"],
    ])
    func labelsAreUniqueIgnoringCase(_ names: [String]) {
        let result = labels(names.enumerated().map { (String($0.offset), $0.element) })
        #expect(result.count == names.count)
        #expect(Set(result.values.map { $0.uppercased() }).count == names.count)
    }

    @Test func ipCollisionUsesLastTwoOctets() {
        #expect(labels([
            ("first", "10.0.0.15"),
            ("second", "10.0.1.15"),
        ]) == ["first": "0.15", "second": "1.15"])

        #expect(labels([
            ("first", "10.0.180.255"),
            ("second", "10.0.181.255"),
        ]) == ["first": "180.255", "second": "181.255"])
    }

    @Test func ipCollisionChecksNonIpLabelsToo() {
        #expect(labels([
            ("ip", "10.0.0.1"),
            ("number", "1"),
        ]) == ["ip": "0.1", "number": "1"])
    }

    @Test func lowercaseInputKeepsOriginalCaseForWordInitials() {
        #expect(labels([
            ("one", "macbook"),
            ("two", "mac mini"),
        ]) == ["one": "Ma", "two": "mm"])
    }

    @Test func nonLatinAndEmojiGraphemesAreKept() {
        #expect(labels([
            ("jp", "東京"),
            ("emoji", "🧑‍💻"),
        ]) == ["jp": "東", "emoji": "🧑‍💻"])
    }

    @Test func trimsWhitespaceAndGuardsEmptyNames() {
        #expect(labels([
            ("trimmed", "  Laptop  "),
            ("empty", " \t\n"),
        ]) == ["trimmed": "L", "empty": "?"])
    }

    @Test func invalidIPv4NamesUseNormalNameRules() {
        #expect(labels([("bad", "256.1.1.1")]) == ["bad": "2"])
        #expect(labels([("alsoBad", "1.2.3")]) == ["alsoBad": "1"])
        #expect(labels([("sign", "+1.2.3.4")]) == ["sign": "+"])
        #expect(labels([("space", "1.2.3 .4")]) == ["space": "1"])

        #expect(labels([
            ("leadingZero", "010.000.001.015"),
            ("outOfRange", "1.2.3.999"),
        ]) == ["leadingZero": "15", "outOfRange": "1"])

        #expect(labels([("unicode", "١.٢.٣.٤")]) == ["unicode": "١"])
        #expect(labels([("emptyComponent", "1..2.3")]) == ["emptyComponent": "1"])
        #expect(labels([("tooMany", "1.2.3.4.5")]) == ["tooMany": "1"])

        #expect(labels([
            ("zero", "0.0.0.0"),
            ("max", "255.255.255.255"),
        ]) == ["zero": "0", "max": "255"])
    }

    @Test func oneGraphemeNamesNumberAfterCollision() {
        #expect(labels([
            ("one", "Å"),
            ("two", "Å"),
        ]) == ["one": "Å1", "two": "Å2"])
    }

    @Test func numberingAndOutputAreStableForTheSameCatalogOrder() {
        let hosts = [
            ("first", "Laptop"),
            ("second", "Laptop"),
            ("third", "Laptop"),
        ]
        #expect(labels(hosts) == labels(hosts))
        #expect(labels(hosts) == ["first": "L1", "second": "L2", "third": "L3"])
        #expect(labels(Array(hosts.reversed())) == [
            "first": "L3", "second": "L2", "third": "L1",
        ])
    }

    @Test(arguments: [
        "Oak tree", "Oak-tree", "Oak_tree", "Oak.tree", "Oak\ttree", "Oak\ntree",
    ])
    func delimiterBoundariesProduceWordInitials(_ name: String) {
        #expect(labels([
            ("first", name),
            ("second", "Olive"),
        ]) == ["first": "Ot", "second": "Ol"])
    }

    @Test func emptyCatalogAndEmptyNamesAreSafe() {
        #expect(labels([]).isEmpty)
        #expect(labels([
            ("blank", ""),
            ("spaces", "   "),
        ]) == ["blank": "?", "spaces": "?"])
    }

    @Test func duplicateIDsUseTheLastCatalogEntry() {
        #expect(labels([
            ("same", "Laptop"),
            ("same", "Oak"),
        ]) == ["same": "O"])
    }

    @Test func identicalIPFallbacksRemainEqual() {
        #expect(labels([
            ("first", "10.0.0.15"),
            ("second", "11.0.0.15"),
        ]) == ["first": "0.15", "second": "0.15"])
    }

    private func labels(_ hosts: [(String, String)]) -> [String: String] {
        HostMonogram.labels(for: hosts.map { (id: $0.0, name: $0.1) })
    }
}
