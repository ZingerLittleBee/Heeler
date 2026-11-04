import CZeroTier
import Foundation

/// A network's self-hosted planet file (as ZeroTier's `mkworld` writes it).
///
/// libzt takes a planet only for the whole process, at its first start. So
/// the process node keeps ZeroTier's own planet, and each self-hosted planet
/// a joined network names is added beside it as a moon built and signed on
/// the device (`heeler_zt_add_moon`). Heeler's libzt patch then looks peers
/// up in, and relays them through, the root set that knows them.
struct ZeroTierPlanet: Sendable, Hashable {
    /// ZeroTier's own planet ID, which many self-hosted planets reuse.
    static let earthWorldID: UInt64 = 149_604_618

    let data: Data
    let worldID: UInt64
    /// A non-zero moon ID derived from the roots alone, never `earthWorldID`.
    let rootsID: UInt64

    /// Reads and checks a planet file; needs no running node.
    init(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else {
            throw OverlayError.invalidConfiguration(Self.message(for: HEELER_ZT_PLANET_INVALID))
        }
        var info = heeler_zt_planet_info()
        let status = data.withUnsafeBytes { bytes -> Int32 in
            heeler_zt_planet_inspect(bytes.baseAddress, UInt32(bytes.count), &info)
        }
        guard status == ZTS_ERR_OK.rawValue else {
            throw OverlayError.invalidConfiguration(Self.message(for: status))
        }
        self.data = data
        worldID = info.world_id
        rootsID = info.roots_id
    }

    static func message(for status: Int32) -> String {
        switch status {
        case HEELER_ZT_PLANET_NOT_PLANET:
            return "That ZeroTier roots file is not a planet. Use the planet file your roots' operator provides."
        case HEELER_ZT_PLANET_NO_ROOTS:
            return "That ZeroTier planet lists no roots."
        case HEELER_ZT_PLANET_ADDRESS_COLLISION:
            return "That ZeroTier planet gives two roots the same address with different identities."
        default:
            return "That file is not a ZeroTier planet."
        }
    }

    /// Adds this planet's roots to the running node as moon `moonID`; the
    /// moon is removed with `zts_moon_deorbit`. Blocks briefly.
    static func addMoon(_ data: Data, moonID: UInt64) -> Int32 {
        data.withUnsafeBytes { bytes -> Int32 in
            heeler_zt_add_moon(bytes.baseAddress, UInt32(bytes.count), moonID)
        }
    }
}

/// Which self-hosted planets the process node carries as local moons:
/// reference counts across the joined networks that name them, and the moon
/// ID each was added under. `ZeroTierRuntime` applies what `reconcile`
/// returns, as `ZeroTierMoonOrbits` does for orbited moons, and reports each
/// add's result back through `addFinished`.
///
/// Local moons and moons orbited through a seed share libzt's one moon ID
/// space, and a deorbit removes whichever moon has the ID. An orbited moon's
/// ID is its world ID and cannot change, so it always wins: a local moon
/// never takes an ID in `reserved`, and one that holds an ID an orbit now
/// needs is moved to another (removed, then added again after the orbit).
struct ZeroTierLocalMoons: Sendable, Equatable {
    enum Change: Sendable, Equatable {
        case add(ZeroTierPlanet, moonID: UInt64)
        case remove(moonID: UInt64)
    }

    /// An add the node refused; retried by the next `reconcile`.
    struct Failure: Sendable, Equatable {
        var moonID: UInt64
        var status: Int32
    }

    private(set) var references: [ZeroTierPlanet: Int] = [:]
    /// Planets added, or being added, and their moon IDs. An add that fails
    /// is dropped from here by `addFinished`.
    private(set) var added: [ZeroTierPlanet: UInt64] = [:]
    /// The latest refused add of each still-referenced planet not added since.
    private(set) var failures: [ZeroTierPlanet: Failure] = [:]

    mutating func retain(_ planet: ZeroTierPlanet?) {
        guard let planet else { return }
        references[planet, default: 0] += 1
    }

    /// Gives back what one `retain` of the same planet took.
    mutating func release(_ planet: ZeroTierPlanet?) {
        guard let planet, let count = references[planet] else { return }
        references[planet] = count > 1 ? count - 1 : nil
    }

    /// The removals and additions that bring `added` in line with
    /// `references`, recorded as under way. `reserved` holds the IDs of the
    /// moons orbited through a seed: a local moon holding one of them is
    /// removed and added again under another ID. A new moon takes the
    /// planet's world ID unless that is ZeroTier's, reserved, in use by
    /// another local moon, or the ID the node last refused for this planet;
    /// it then takes the ID derived from its roots, counting up past any
    /// taken one. Refused adds are tried again here.
    mutating func reconcile(reserved: Set<UInt64>) -> [Change] {
        var changes: [Change] = []
        for (planet, moonID) in added.sorted(by: { $0.value < $1.value })
        where references[planet] == nil || reserved.contains(moonID) {
            added[planet] = nil
            changes.append(.remove(moonID: moonID))
        }
        failures = failures.filter { references[$0.key] != nil }
        let wanted = references.keys.sorted { lhs, rhs in
            lhs.worldID != rhs.worldID
                ? lhs.worldID < rhs.worldID : lhs.data.lexicographicallyPrecedes(rhs.data)
        }
        for planet in wanted where added[planet] == nil {
            var taken = reserved.union(added.values)
            // The node already has a moon under that ID (not one of ours).
            if let failure = failures[planet], failure.status == ZTS_ERR_ARG.rawValue {
                taken.insert(failure.moonID)
            }
            let moonID = Self.moonID(for: planet, taken: taken)
            added[planet] = moonID
            changes.append(.add(planet, moonID: moonID))
        }
        return changes
    }

    /// Records how adding `planet` as `moonID` went. A refused add is
    /// forgotten (unless the moon was removed or moved meanwhile), so the
    /// next `reconcile` tries it again.
    mutating func addFinished(_ planet: ZeroTierPlanet, moonID: UInt64, status: Int32) {
        guard added[planet] == moonID else { return }
        if status == ZTS_ERR_OK.rawValue {
            failures[planet] = nil
        } else {
            added[planet] = nil
            failures[planet] = Failure(moonID: moonID, status: status)
        }
    }

    static func moonID(for planet: ZeroTierPlanet, taken: Set<UInt64>) -> UInt64 {
        let worldID = planet.worldID
        if worldID != 0, worldID != ZeroTierPlanet.earthWorldID, !taken.contains(worldID) {
            return worldID
        }
        var candidate = planet.rootsID
        while candidate == 0 || candidate == ZeroTierPlanet.earthWorldID || taken.contains(candidate) {
            candidate &+= 1
        }
        return candidate
    }
}
