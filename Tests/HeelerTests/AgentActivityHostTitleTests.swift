import Foundation
import Testing

@testable import Heeler

@Suite("Agent activity host title")
struct AgentActivityHostTitleTests {
    @Test func prefersTheRegisteredHostNameOverTheEnvelopeHost() {
        #expect(
            AgentActivityHostTitle.resolved(
                registeredName: "zingerbee@127.0.0.1",
                envelopeName: "ZingerBees-MacBook-Pro")
                == "zingerbee@127.0.0.1")
    }

    @Test func fallsBackToTheEnvelopeHostWhenTheRecordIsMissing() {
        #expect(
            AgentActivityHostTitle.resolved(
                registeredName: nil,
                envelopeName: "ZingerBees-MacBook-Pro")
                == "ZingerBees-MacBook-Pro")
    }

    @Test func fallsBackToTheEnvelopeHostWhenTheRegisteredNameIsEmpty() {
        #expect(
            AgentActivityHostTitle.resolved(
                registeredName: "",
                envelopeName: "ZingerBees-MacBook-Pro")
                == "ZingerBees-MacBook-Pro")
    }
}
