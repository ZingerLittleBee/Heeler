import CZeroTier
import Foundation
import Testing

@testable import HeelerOverlay

@Suite("ZeroTier self-hosted planets as local moons")
struct ZeroTierPlanetTests {
    // MARK: Reading planet files

    @Test func planetsAreReadAndChecked() throws {
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        #expect(custom.worldID == 7_777_777)
        #expect(custom.rootsID != 0 && custom.rootsID != ZeroTierPlanet.earthWorldID)
        // Re-reading yields the same value, so a leave matches its join.
        #expect(try ZeroTierPlanet(Fixtures.planetCustom) == custom)

        // Many self-hosted planets reuse ZeroTier's world ID.
        #expect(try ZeroTierPlanet(Fixtures.planetEarth).worldID == ZeroTierPlanet.earthWorldID)
        // One root listed twice with different endpoints is merged.
        _ = try ZeroTierPlanet(Fixtures.planetDup)
    }

    @Test func invalidPlanetsAreRefusedWithAReason() {
        let cases: [(Data, Int32)] = [
            (Data(), HEELER_ZT_PLANET_INVALID),
            (Data([1, 2, 3]), HEELER_ZT_PLANET_INVALID),
            (Fixtures.planetCustom + Data([0]), HEELER_ZT_PLANET_INVALID),
            (Fixtures.planetCustom.prefix(200), HEELER_ZT_PLANET_INVALID),
            (Fixtures.moon, HEELER_ZT_PLANET_NOT_PLANET),
            (Fixtures.planetEmpty, HEELER_ZT_PLANET_NO_ROOTS),
            (Fixtures.planetCollision, HEELER_ZT_PLANET_ADDRESS_COLLISION),
        ]
        for (data, status) in cases {
            #expect(throws: OverlayError.invalidConfiguration(ZeroTierPlanet.message(for: status))) {
                _ = try ZeroTierPlanet(data)
            }
        }
    }

    // MARK: Moon IDs and reference counts

    @Test func localMoonsTakeTheWorldIDUnlessItIsZeroTiersOrTaken() throws {
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        let earth = try ZeroTierPlanet(Fixtures.planetEarth)
        #expect(ZeroTierLocalMoons.moonID(for: custom, taken: []) == custom.worldID)
        #expect(ZeroTierLocalMoons.moonID(for: earth, taken: []) == earth.rootsID)
        #expect(ZeroTierLocalMoons.moonID(for: custom, taken: [custom.worldID]) == custom.rootsID)
        #expect(ZeroTierLocalMoons.moonID(for: custom, taken: [custom.worldID, custom.rootsID])
            == custom.rootsID &+ 1)
    }

    @Test func localMoonsAreAddedOnceAndRemovedWithTheLastReference() throws {
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        let earth = try ZeroTierPlanet(Fixtures.planetEarth)
        var moons = ZeroTierLocalMoons()
        moons.retain(custom)
        moons.retain(custom)
        moons.retain(nil)
        moons.retain(earth)
        // The world IDs sort ZeroTier's (149604618) after 7777777.
        #expect(moons.reconcile(reserved: []) == [
            .add(custom, moonID: custom.worldID), .add(earth, moonID: earth.rootsID),
        ])
        #expect(moons.reconcile(reserved: []) == [])
        moons.release(custom)
        moons.release(earth)
        #expect(moons.reconcile(reserved: []) == [.remove(moonID: earth.rootsID)])
        moons.release(custom)
        moons.release(custom)
        #expect(moons.reconcile(reserved: []) == [.remove(moonID: custom.worldID)])
        #expect(moons.references.isEmpty && moons.added.isEmpty)

        // A moon orbited through a seed keeps its ID.
        moons.retain(custom)
        #expect(moons.reconcile(reserved: [custom.worldID]) == [.add(custom, moonID: custom.rootsID)])
    }

    @Test func aLocalMoonMovesOffAnIDAnOrbitComesToNeed() throws {
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        var moons = ZeroTierLocalMoons()
        moons.retain(custom)
        #expect(moons.reconcile(reserved: []) == [.add(custom, moonID: custom.worldID)])
        #expect(moons.reconcile(reserved: [custom.worldID]) == [
            .remove(moonID: custom.worldID), .add(custom, moonID: custom.rootsID),
        ])
        // It stays put once the orbit is gone.
        #expect(moons.reconcile(reserved: []) == [])
        #expect(moons.added == [custom: custom.rootsID])
    }

    @Test func aRefusedLocalMoonIsRetriedUnderAnotherIDWhenTaken() throws {
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        var moons = ZeroTierLocalMoons()
        moons.retain(custom)
        #expect(moons.reconcile(reserved: []) == [.add(custom, moonID: custom.worldID)])
        // The node already has a moon under that ID.
        moons.addFinished(custom, moonID: custom.worldID, status: ZTS_ERR_ARG.rawValue)
        #expect(moons.added.isEmpty)
        #expect(moons.failures[custom] == .init(moonID: custom.worldID, status: ZTS_ERR_ARG.rawValue))
        #expect(moons.reconcile(reserved: []) == [.add(custom, moonID: custom.rootsID)])
        // The node was not running: the same ID is tried again.
        moons.addFinished(custom, moonID: custom.rootsID, status: ZTS_ERR_SERVICE.rawValue)
        #expect(moons.reconcile(reserved: []) == [.add(custom, moonID: custom.worldID)])
        moons.addFinished(custom, moonID: custom.worldID, status: ZTS_ERR_OK.rawValue)
        #expect(moons.failures.isEmpty && moons.added == [custom: custom.worldID])

        // A result for an add since removed changes nothing.
        moons.release(custom)
        #expect(moons.reconcile(reserved: []) == [.remove(moonID: custom.worldID)])
        moons.addFinished(custom, moonID: custom.worldID, status: ZTS_ERR_ARG.rawValue)
        #expect(moons.added.isEmpty && moons.failures.isEmpty)
    }

    // MARK: Runtime and network node

    @Test func networksShareALocalMoonAddedBeforeTheirJoin() async throws {
        let native = RecordingZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        try await runtime.join(42, moons: [], planet: custom)
        try await runtime.join(43, moons: [], planet: custom)
        #expect(await runtime.localMoonIDs() == [custom.worldID])
        await runtime.leave(42, moons: [], planet: custom)
        await runtime.leave(43, moons: [], planet: custom)
        #expect(await runtime.localMoonIDs() == [])
        #expect(native.log == [
            "add \(custom.worldID) \(Fixtures.planetCustom.count)", "join 42", "join 43", "leave 42",
            "deorbit \(custom.worldID)", "leave 43",
        ])
    }

    @Test func anOrbitAfterAPlanetWithItsIDMovesTheLocalMoon() async throws {
        let native = RecordingZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        let moon = ZeroTierMoon(worldID: custom.worldID, seed: 0x1234_5678_9a)
        try await runtime.join(42, moons: [], planet: custom)
        try await runtime.join(43, moons: [moon], planet: nil)
        #expect(await runtime.localMoonIDs() == [custom.rootsID])
        #expect(await runtime.orbitedMoonIDs() == [custom.worldID])
        // Leaving the orbiting network deorbits its moon, not the local one.
        await runtime.leave(43, moons: [moon], planet: nil)
        #expect(await runtime.localMoonIDs() == [custom.rootsID])
        await runtime.leave(42, moons: [], planet: custom)
        let size = Fixtures.planetCustom.count
        #expect(native.log == [
            "add \(custom.worldID) \(size)", "join 42",
            "deorbit \(custom.worldID)", "orbit \(custom.worldID)", "add \(custom.rootsID) \(size)", "join 43",
            "deorbit \(custom.worldID)", "leave 43",
            "deorbit \(custom.rootsID)", "leave 42",
        ])
    }

    @Test func aPlanetAfterAnOrbitWithItsIDTakesItsRootsID() async throws {
        let native = RecordingZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        let moon = ZeroTierMoon(worldID: custom.worldID, seed: 0x1234_5678_9a)
        try await runtime.join(43, moons: [moon], planet: nil)
        try await runtime.join(42, moons: [], planet: custom)
        #expect(await runtime.localMoonIDs() == [custom.rootsID])
        // Leaving the planet's network removes only the local moon.
        await runtime.leave(42, moons: [], planet: custom)
        #expect(await runtime.orbitedMoonIDs() == [custom.worldID])
        try await runtime.join(42, moons: [], planet: custom)
        // Leaving the orbiting network keeps the local moon.
        await runtime.leave(43, moons: [moon], planet: nil)
        #expect(await runtime.localMoonIDs() == [custom.rootsID])
        await runtime.leave(42, moons: [], planet: custom)
        let size = Fixtures.planetCustom.count
        #expect(native.log == [
            "orbit \(custom.worldID)", "join 43",
            "add \(custom.rootsID) \(size)", "join 42",
            "deorbit \(custom.rootsID)", "leave 42",
            "add \(custom.rootsID) \(size)", "join 42",
            "deorbit \(custom.worldID)", "leave 43",
            "deorbit \(custom.rootsID)", "leave 42",
        ])
        #expect(await runtime.localMoonIDs() == [])
        #expect(await runtime.orbitedMoonIDs() == [])
    }

    @Test func aRefusedLocalMoonIsReportedAndRetriedByTheNextJoin() async throws {
        let native = RecordingZeroTierControl(addResults: [ZTS_ERR_SERVICE.rawValue])
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let custom = try ZeroTierPlanet(Fixtures.planetCustom)
        try await runtime.join(42, moons: [], planet: custom)
        #expect(await runtime.localMoonIDs() == [])
        #expect(await runtime.localMoonFailures()[custom]?.status == ZTS_ERR_SERVICE.rawValue)
        let entries = await runtime.localMoonEntries()
        #expect(entries.map(\.value) == [
            "Not added: moon \(ZeroTierNetworkID.format(custom.worldID)) refused (\(ZTS_ERR_SERVICE.rawValue)); retrying",
        ])
        try await runtime.join(43, moons: [], planet: nil)
        #expect(await runtime.localMoonIDs() == [custom.worldID])
        #expect(await runtime.localMoonFailures().isEmpty)
        #expect(await runtime.localMoonEntries().map(\.value) == [
            "Moon \(ZeroTierNetworkID.format(custom.worldID))",
        ])
        let size = Fixtures.planetCustom.count
        #expect(native.log == [
            "add \(custom.worldID) \(size)", "join 42", "add \(custom.worldID) \(size)", "join 43",
        ])
    }

    @Test func aNetworkCarriesItsPlanetWhileJoined() async throws {
        let native = RecordingZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil, roots: Fixtures.planetEarth),
            identityGenerated: { _ in },
            runtime: runtime)
        let moonID = try ZeroTierPlanet(Fixtures.planetEarth).rootsID
        try await node.start(timeout: .seconds(5))
        #expect(native.log == ["add \(moonID) \(Fixtures.planetEarth.count)", "join 42"])
        await node.stop()
        #expect(native.log.suffix(2) == ["deorbit \(moonID)", "leave 42"])
        #expect(await runtime.localMoonIDs() == [])
    }

    @Test func aNetworkWithAnInvalidPlanetDoesNotJoin() async throws {
        let native = RecordingZeroTierControl()
        let runtime = ZeroTierRuntime(startedWith: "abcdef0123:0:fake", control: native.control)
        let node = ZeroTierNetworkNode(
            configuration: ZeroTierConfiguration(networkID: 42, identity: nil, roots: Fixtures.moon),
            identityGenerated: { _ in },
            runtime: runtime)
        let message = ZeroTierPlanet.message(for: HEELER_ZT_PLANET_NOT_PLANET)
        await #expect(throws: OverlayError.invalidConfiguration(message)) {
            try await node.start(timeout: .seconds(5))
        }
        #expect(await node.status() == .failed(message))
        #expect(native.log.isEmpty)
        #expect(await runtime.references(42) == 0)
    }
}

/// libzt's network and moon calls, recorded; every network is ready once
/// joined.
private final class RecordingZeroTierControl: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    private var joined: Set<UInt64> = []
    /// What the next `addMoon` calls return; OK once used up.
    private var addResults: [Int32]

    init(addResults: [Int32] = []) {
        self.addResults = addResults
    }

    var log: [String] { lock.withLock { calls } }

    private func record(_ call: String) -> Int32 {
        lock.withLock { calls.append(call) }
        return 0
    }

    var control: ZeroTierControl {
        ZeroTierControl(
            joinNetwork: { networkID in
                self.lock.withLock { _ = self.joined.insert(networkID) }
                return self.record("join \(networkID)")
            },
            leaveNetwork: { networkID in
                self.lock.withLock { _ = self.joined.remove(networkID) }
                return self.record("leave \(networkID)")
            },
            orbit: { worldID, _ in self.record("orbit \(worldID)") },
            deorbit: { worldID in self.record("deorbit \(worldID)") },
            addMoon: { planet, moonID in
                _ = self.record("add \(moonID) \(planet.count)")
                return self.lock.withLock { self.addResults.isEmpty ? 0 : self.addResults.removeFirst() }
            },
            snapshot: { networkID in
                let ready = self.lock.withLock { self.joined.contains(networkID) }
                return ZeroTierRuntime.NetworkSnapshot(
                    isReady: ready, addresses: ready ? ["10.147.17.2"] : [], failure: nil)
            },
            isOnline: { true })
    }
}

/// Planet files made with ZeroTier's World::make for these tests: random
/// roots at 192.0.2.10 and .11, signed with throwaway keys.
private enum Fixtures {
    static func data(_ base64: String) -> Data {
        Data(base64Encoded: base64) ?? Data()
    }

    static let planetCustom = data(
            "AQAAAAAAdq3xAAABi8/laABhNCsetmL67B3Ld4TvairIzw+Vl8Ls4w8kI21ibWGuCtbhhZ0Wxalb" +
            "zW4pmgQbEzQ/hG4YFXPw5LwQI1S68IXcPJiP/b5gxyFYgd9kzn2ei/7pMymsADA9uufp6ovMdHGd" +
            "IgJp66FqItR51Yxr8VQk/etSGTnD5psBpch2t1gbAx/Sgp2WEEkcHW67azVAEE+mv7158hwRIFuO" +
            "WpPBWc9WAfT7OGB3ABeOsr953FTK+wyceBRat6LlJphNGe3+NUUtWuX+2XlhHlK4j8EmK8gRne+D" +
            "8P+lUuu8nxM9Sx0DWjW5PgAdOAcAAQTAAAIKJwk=")

    static let planetEarth = data(
            "AQAAAAAI6skKAAABi8/laABBJs00RXmWP4fAbrwmvQkimPYmlaaKkJT1n818apFsKZnS546Bkc+P" +
            "ismngso7lf38/HQ3EhkvUa4KQd7j6Uw/oXlszp4YkHbe4pcf+DGNMh14m3hx60oM4CcXGsdfF5sO" +
            "WFrtxUv3JHG2C4fV25vXwzaYU8tIdD39C7D/QL/ED0RYADs1c00Z5SnS4nUzl6ROJC3bKMwryHdJ" +
            "Zi94AF0mAvT7OGB3ABeOsr953FTK+wyceBRat6LlJphNGe3+NUUtWuX+2XlhHlK4j8EmK8gRne+D" +
            "8P+lUuu8nxM9Sx0DWjW5PgAdOAcAAQTAAAIKJwnD30uD3gD6mmpMFdXhOC87Ve0flOmzrJMLhE0M" +
            "LpW8DAm+bLVZMLNsQtoL0w71id+sirTFbqS74WNB4xEYK5t9OHYk0xeCAAEEwAACCycJ")

    static let planetDup = data(
            "AQAAAAAAdq3yAAABi8/laAAbmkn5G1fG7I75eU9RCxPkCh5vMIPLHufJRb/sARtACAyBCxpwftYv" +
            "5vass4qZt9R/0TltHgoNLyLIdCNqUOnNdOyqSIONOHol+5f6PJd22ElRZa4cRac+GyN6mAqZtJM+" +
            "LUtmsg0WVDgX0ipE4pAJKXVrVD9vfn5z52qj4fAsAZvQCK/EEHqb3NAT/gOrUeDgeE1FGMLV0hTk" +
            "gGdNFXSOAvT7OGB3ABeOsr953FTK+wyceBRat6LlJphNGe3+NUUtWuX+2XlhHlK4j8EmK8gRne+D" +
            "8P+lUuu8nxM9Sx0DWjW5PgAdOAcAAQTAAAIKJwn0+zhgdwAXjrK/edxUyvsMnHgUWrei5SaYTRnt" +
            "/jVFLVrl/tl5YR5SuI/BJivIEZ3vg/D/pVLrvJ8TPUsdA1o1uT4AHTgHAAEEwAACDCcJ")

    static let planetCollision = data(
            "AQAAAAAAdq3zAAABi8/laAAsbXO0REPOqxg5jLT3+tco9WYexYtR/zK4/WRSeSZ9HHpkkd7IPl3Y" +
            "3qpDGjT7XeLTWoRLeibaarw6N0+8Z82EcrWVp960GUEnL5g0iipUpQONXJqo+/qPl0wZvo2vK/6U" +
            "L4QEfu5Mo3rnuARkoQdlXzov76CFtefcr63/5+uuAZS3yZ+mSiFywirZQRZAqjvKIAZ+T9eIFJY6" +
            "74vDe4wKAvT7OGB3ABeOsr953FTK+wyceBRat6LlJphNGe3+NUUtWuX+2XlhHlK4j8EmK8gRne+D" +
            "8P+lUuu8nxM9Sx0DWjW5PgAdOAcAAQTAAAIKJwn0+zhgdwD6mmpMFdXhOC87Ve0flOmzrJMLhE0M" +
            "LpW8DAm+bLVZMLNsQtoL0w71id+sirTFbqS74WNB4xEYK5t9OHYk0xeCAAA=")

    static let planetEmpty = data(
            "AQAAAAAAdq30AAABi8/laACuCcOc3dZD/xv+x0OlNR57nmM8703GM510Yr1iQOnpI6ca2oceZiww" +
            "IMTNLPXYt9zPCYmLX1l7CYxnBDJ5CnxD6h6ewGlE5riwXmsP/d39G2OCetm+SP9pDpckIVdv3jwL" +
            "jTvq9ZZq6Bl9hTHUA5/G0vCUXizUt1ZvtUaKhEh/AfXcaWMtBkJ9SZuppfxD7gvSVgZ9ixK3ysNx" +
            "vqd8PwWFAA==")

    static let moon = data(
            "fwAAAAAAAAq8AAABi8/laAAxPVpcQnVEvrPLbPJlPs9o8o0zUv7w7Qnmi5PO0qDgbc0DOjhydH0X" +
            "BjT+HO4EcmXOsRLnwzA1Q4G2pvCSJtgyLDT6begGkyCwoEWbxrkNX/i8RDrDJQ0XWboXQy6ITC+F" +
            "b0Wnf9Pq50mlWeHwQVFrn2M2kQjqYLOUSYyU+J6CDZhmDVWCirUErUwMd3oc9uZXmnmuyxd3pyTo" +
            "fJmu95ZfAfT7OGB3ABeOsr953FTK+wyceBRat6LlJphNGe3+NUUtWuX+2XlhHlK4j8EmK8gRne+D" +
            "8P+lUuu8nxM9Sx0DWjW5PgAdOAcAAQTAAAIKJwkAAA==")
}
