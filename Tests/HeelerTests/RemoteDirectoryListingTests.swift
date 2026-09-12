import Foundation
import Testing

@testable import Heeler

@Test("directory paths accept absolute quotable paths")
func directoryPathsAcceptAbsoluteQuotablePaths() {
    #expect(HeelerSSHTransport.validatedDirectoryPath("/") == "/")
    #expect(HeelerSSHTransport.validatedDirectoryPath("/photos") == "/photos")
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/a/b/c") == "/a/b/c")
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/with space") == "/with space")
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/dotted.name_v2-0")
            == "/dotted.name_v2-0")
}

@Test("directory paths reject empty, relative, and unquotable paths")
func directoryPathsRejectUnsafePaths() {
    #expect(HeelerSSHTransport.validatedDirectoryPath("") == nil)
    #expect(HeelerSSHTransport.validatedDirectoryPath("relative/path") == nil)
    #expect(HeelerSSHTransport.validatedDirectoryPath("~") == nil)
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/with'quote") == nil)
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/with\\backslash") == nil)
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/with\0nul") == nil)
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/with\nnewline") == nil)
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/with\ttab") == nil)
    #expect(
        HeelerSSHTransport.validatedDirectoryPath("/with\u{7F}del") == nil)
}

@Test("invalid directory paths are not retryable")
func invalidDirectoryPathsAreNotRetryable() {
    #expect(
        TransportError.invalidDirectoryPath(path: "/x").isRetryable == false)
}
