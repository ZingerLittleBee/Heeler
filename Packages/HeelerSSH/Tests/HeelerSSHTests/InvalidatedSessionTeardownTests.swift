import CLibSSH2
import Testing

@testable import HeelerSSH

@Test("invalidation attempts session reclamation only once")
func invalidationAttemptsSessionReclamationOnlyOnce() {
    var session: OpaquePointer? = OpaquePointer(bitPattern: 1)
    var calls = 0

    let result = InvalidatedSessionTeardown.reclaim(&session) { _ in
        calls += 1
        return LIBSSH2_ERROR_EAGAIN
    }

    #expect(result == LIBSSH2_ERROR_EAGAIN)
    #expect(calls == 1)
    #expect(session != nil)
}

@Test("invalidation retains ownership until native reclamation succeeds")
func invalidationRetainsOwnershipUntilNativeReclamationSucceeds() throws {
    var session: OpaquePointer? = OpaquePointer(bitPattern: 1)
    var results = [Int32(LIBSSH2_ERROR_EAGAIN), 0]

    let firstResult = InvalidatedSessionTeardown.reclaim(&session) { _ in
        results.removeFirst()
    }
    #expect(firstResult == LIBSSH2_ERROR_EAGAIN)
    #expect(session != nil)

    let secondResult = InvalidatedSessionTeardown.reclaim(&session) { _ in
        results.removeFirst()
    }
    #expect(secondResult == 0)
    #expect(session == nil)
    #expect(results.isEmpty)

    try #require(NativeLibrary.initializationResult == 0)
    let createdSession = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
    var nativeSession: OpaquePointer? = createdSession
    let nativeResult = InvalidatedSessionTeardown.reclaim(&nativeSession)
    #expect(nativeResult == 0)
    #expect(nativeSession == nil)
}
