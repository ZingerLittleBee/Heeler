import Foundation
import Testing

@testable import Heeler

@Suite("Chat link policy")
struct ChatLinkPolicyTests {
    struct Link: Sendable, CustomTestStringConvertible {
        let string: String
        var testDescription: String { string }
    }

    static let allowed = [
        "https://example.com",
        "http://example.com/path?q=1#frag",
        "HTTPS://EXAMPLE.COM/P",
        "Https://Example.com",
        "https://user:pw@host.test/x",
        "http://localhost:8080/",
        "https://[::1]/",
    ].map(Link.init)

    static let blocked = [
        "heeler://pair?code=x",
        "file:///etc/passwd",
        "javascript:alert(1)",
        "JAVASCRIPT:alert(1)",
        "mailto:a@b.c",
        "data:text/html,hi",
        "tel:5551234",
        "ftp://x.test/f",
        "docs/a.md",
        "/etc/x",
        "note",
        "//example.com/x",
        "http://",
        "https:///path",
        "https:path",
    ].map(Link.init)

    @Test("Web links with a host may open", arguments: allowed)
    func allowedLink(_ link: Link) throws {
        let url = try #require(URL(string: link.string))
        #expect(ChatLinkPolicy.allows(url))
    }

    @Test("Other schemes, relative links and links without a host may not", arguments: blocked)
    func blockedLink(_ link: Link) throws {
        let url = try #require(URL(string: link.string))
        #expect(!ChatLinkPolicy.allows(url))
    }
}
