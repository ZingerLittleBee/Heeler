import Foundation
import Synchronization

@testable import HerdrMobile

/// SecretStore stand-in for tests that must not touch the real Keychain.
final class InMemorySecretStore: SecretStore {
    private let secrets = Mutex<[String: Data]>([:])

    func read(account: String) throws -> Data? {
        secrets.withLock { $0[account] }
    }

    func readAll() throws -> [String: Data] {
        secrets.withLock { $0 }
    }

    func write(_ secret: Data, account: String) throws {
        secrets.withLock { $0[account] = secret }
    }

    func removeSecret(account: String) throws {
        secrets.withLock { $0[account] = nil }
    }
}
