import Foundation
import Testing

@testable import Heeler

@Suite("Port preview target")
struct PortPreviewTargetTests {
    @Test(arguments: [
        ("http://localhost:4100/#more", "http://localhost:4100/#more", 4100, false),
        ("http://127.0.0.1:5173/docs?x=1", "http://localhost:5173/docs?x=1", 5173, true),
        ("http://[::1]:8080/", "http://localhost:8080/", 8080, true),
        ("http://0.0.0.0:3000", "http://localhost:3000", 3000, true),
        ("HTTPS://LocalHost:8443/a", "https://localhost:8443/a", 8443, false),
        ("http://localhost/", "http://localhost/", 80, false),
        ("https://localhost./", "https://localhost/", 443, false),
    ])
    func loopbackLinkLoadsUnderLocalhost(link: String, loads: String, port: Int, isRewritten: Bool) throws {
        let written = try #require(URL(string: link))
        let target = try #require(PortPreviewTarget(link: written))

        #expect(target.url.absoluteString == loads)
        #expect(target.port == port)
        #expect(target.isRewritten == isRewritten)
    }

    @Test(arguments: [
        "https://example.com:4100/",
        "http://192.168.1.20:4100/",
        "http://app.localhost:4100/",
        "http://localhost.example.com/",
        "ftp://localhost:21/",
        "file:///etc/hosts",
        "heeler://localhost:4100/",
    ])
    func otherLinkIsNotATarget(link: String) throws {
        let written = try #require(URL(string: link))
        #expect(PortPreviewTarget(link: written) == nil)
    }

    @Test(arguments: [
        ("4100", "http://localhost:4100/"),
        (" 4100/docs ", "http://localhost:4100/docs"),
        ("localhost:5173/x", "http://localhost:5173/x"),
        ("127.0.0.1:8080", "http://localhost:8080"),
        ("https://localhost:8443", "https://localhost:8443"),
    ])
    func typedPortOrAddressBecomesItsPage(text: String, loads: String) throws {
        #expect(PortPreviewTarget(typed: text)?.url.absoluteString == loads)
    }

    @Test(arguments: ["", "0", "70000", "example.com", "dev server", "localhost:99999"])
    func typedTextThatNamesNoLoopbackPortIsRefused(text: String) {
        #expect(PortPreviewTarget(typed: text) == nil)
    }
}

@Suite("Port preview SOCKS5")
struct PortPreviewSOCKS5Tests {
    @Test func handshakeMessagesParseOnlyOnceWhole() {
        let greeting: [UInt8] = [5, 2, 0, 2]
        #expect(SOCKS5.greeting(in: Array(greeting.prefix(3))) == .incomplete)
        #expect(SOCKS5.greeting(in: greeting + [1]) == .parsed([0, 2], consumed: 4))
        #expect(SOCKS5.greeting(in: [4, 1, 0]) == .malformed)

        let credentials: [UInt8] = [1, 2, 0x75, 0x31, 3, 0x70, 0x77, 0x31]
        #expect(SOCKS5.credentials(in: Array(credentials.prefix(7))) == .incomplete)
        #expect(
            SOCKS5.credentials(in: credentials)
                == .parsed(.init(username: [0x75, 0x31], password: [0x70, 0x77, 0x31]), consumed: 8))

        let request: [UInt8] = [5, 1, 0, 3, 9] + Array("localhost".utf8) + [0x10, 0x04]
        #expect(SOCKS5.request(in: Array(request.dropLast())) == .incomplete)
        #expect(
            SOCKS5.request(in: request)
                == .parsed(.init(command: 1, address: .domain("localhost"), port: 4100), consumed: request.count))
        #expect(SOCKS5.request(in: [5, 1, 0, 9, 0, 0]) == .malformed)
    }

    @Test func onlyAConnectToTheLoopbackInterfaceIsCarried() {
        func asked(
            _ address: SOCKS5.Address, port: UInt16 = 4100, command: UInt8 = SOCKS5.connect
        ) -> Result<UInt16, SOCKS5.Refusal> {
            SOCKS5.Request(command: command, address: address, port: port).loopbackPort
        }

        #expect(asked(.domain("LOCALHOST")) == .success(4100))
        #expect(asked(.ipv4([127, 0, 0, 1])) == .success(4100))
        #expect(asked(.ipv6([UInt8](repeating: 0, count: 15) + [1])) == .success(4100))

        #expect(asked(.domain("db.internal")) == .failure(.init(reply: .notAllowed)))
        #expect(asked(.domain("app.localhost")) == .failure(.init(reply: .notAllowed)))
        #expect(asked(.ipv4([10, 0, 0, 5])) == .failure(.init(reply: .notAllowed)))
        #expect(asked(.ipv4([127, 0, 0, 53])) == .failure(.init(reply: .notAllowed)))
        #expect(asked(.domain("localhost"), port: 0) == .failure(.init(reply: .notAllowed)))
        // BIND and UDP ASSOCIATE.
        #expect(asked(.domain("localhost"), command: 2) == .failure(.init(reply: .commandNotSupported)))
        #expect(asked(.domain("localhost"), command: 3) == .failure(.init(reply: .commandNotSupported)))
    }

    @Test func credentialsMatchOnlyWhenBothDo() {
        let presented = SOCKS5.Credentials(username: [1, 2], password: [3, 4])

        #expect(presented.matches(username: [1, 2], password: [3, 4]))
        #expect(!presented.matches(username: [1, 2], password: [3, 5]))
        #expect(!presented.matches(username: [1], password: [3, 4]))
    }
}

@Suite("Host listening ports")
struct HostListeningPortsTests {
    private let nonce = "0a1b2c"

    private func output(_ listing: [String], directories: [String] = []) -> Data {
        let lines = [HostListeningPorts.beginMarker(nonce)] + listing
            + [HostListeningPorts.directoriesMarker(nonce)] + directories
            + ["", HostListeningPorts.endMarker(nonce)]
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    @Test func socketStatisticsListsWhatLocalhostReaches() throws {
        let ports = try HostListeningPorts.parse(
            stdout: output(
                [
                    "tool ss",
                    "State  Recv-Q Send-Q Local Address:Port Peer Address:Port Process",
                    "LISTEN 0      511          *:4100          *:*    users:((\"node\",pid=1234,fd=23))",
                    "LISTEN 0      4096   127.0.0.53%lo:53      0.0.0.0:*",
                    "LISTEN 0      128      0.0.0.0:22       0.0.0.0:*",
                    "LISTEN 0      128         [::]:22          [::]:*",
                    "LISTEN 0      511    127.0.0.1:5173     0.0.0.0:*    users:((\"vite\",pid=77,fd=19),(\"node\",pid=78,fd=19))",
                    "LISTEN 0      128   192.168.1.20:9000   0.0.0.0:*    users:((\"python3\",pid=90,fd=3))",
                ],
                directories: ["p1234", "n/home/dev/heeler/site", "p78", "n/home/dev/api"]),
            nonce: nonce)

        #expect(
            ports == [
                HostListeningPort(port: 22, command: nil, directory: nil),
                HostListeningPort(port: 4100, command: "node", directory: "/home/dev/heeler/site"),
                // The process whose directory is known names the port.
                HostListeningPort(port: 5173, command: "node", directory: "/home/dev/api"),
            ])
        #expect(ports[1].isInside("/home/dev/heeler"))
        #expect(!ports[1].isInside("/home/dev/heel"))
        #expect(!ports[2].isInside("/home/dev/heeler"))
    }

    @Test func openFilesListsWhatLocalhostReaches() throws {
        let ports = try HostListeningPorts.parse(
            stdout: output(
                [
                    "tool lsof",
                    "p501", "cnode", "n*:4100",
                    "p620", "cControlCenter", "n*:7000", "n[::1]:7001",
                    "p702", "cpostgres", "n127.0.0.1:5432", "n[::1]:5432",
                    "p800", "cTailscale", "n100.64.0.3:41112",
                ],
                directories: ["p501", "fcwd", "n/Users/dev/heeler", "p702", "fcwd", "n/"]),
            nonce: nonce)

        #expect(
            ports == [
                HostListeningPort(port: 4100, command: "node", directory: "/Users/dev/heeler"),
                HostListeningPort(port: 5432, command: "postgres", directory: "/"),
                HostListeningPort(port: 7000, command: "ControlCenter", directory: nil),
                HostListeningPort(port: 7001, command: "ControlCenter", directory: nil),
            ])
    }

    @Test func outputWithoutItsMarkersIsRefused() {
        #expect(throws: HostListeningPorts.MalformedOutput.self) {
            try HostListeningPorts.parse(stdout: Data("tool ss\nLISTEN 0 1 *:80 *:*\n".utf8), nonce: nonce)
        }
        // Cut short by the size cap: the end marker never arrived.
        let whole = String(decoding: output(["tool ss"]), as: UTF8.self)
        #expect(throws: HostListeningPorts.MalformedOutput.self) {
            try HostListeningPorts.parse(stdout: Data(whole.dropLast(12).utf8), nonce: nonce)
        }
    }
}
