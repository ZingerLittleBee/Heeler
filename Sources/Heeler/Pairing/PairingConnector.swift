import Foundation

/// Runs the pairing ceremony for a scanned Pairing Code: the seam between UI
/// stores and real SSH, mirroring `TransportConnector`. Production is
/// `SSHPairingConnector`; tests inject a scripted fake, so screen logic never
/// touches an SSH library. The ceremony client lives beside Transport, not
/// inside it — Transport keeps its herdr socket semantics (ADR 0007).
protocol PairingConnector: Sendable {
    /// Performs the ceremony: reach a candidate address presenting the
    /// pinned host key, authenticate with the Bootstrap Key, submit the
    /// Device Key public line for Enrollment, then reconnect with the Device
    /// Key to prove it took effect. Returns the facts the app persists as a
    /// Host; throws `PairingCeremonyError` classified per step.
    ///
    /// `onStep` fires as each ceremony step begins, for progress UI. `parse`
    /// never appears — decoding happens before a code reaches the connector.
    func pair(
        code: PairingCode,
        deviceKey: DeviceKey,
        onStep: @escaping @Sendable (PairingStep) -> Void
    ) async throws -> PairingResult
}
