/// The deadline's operation can outlive its caller; actor ownership keeps
/// partial-write evidence visible to the timeout path without a data race.
actor CoreMutationDispatch {
    private var wasAttempted = false
    private var sealed = false

    func begin() throws {
        try Task.checkCancellation()
        guard !sealed else { throw TransportError.cancelled }
        wasAttempted = true
    }

    /// Atomically prevents a timed-out pre-dispatch continuation from writing
    /// later, while preserving uncertainty if a write already began.
    func seal() -> Bool {
        sealed = true
        return wasAttempted
    }
}
