/// The exec and SFTP services a Host offers whichever Server Kind it runs.
/// `Transport` refines this for Herdr TUI; herdr-core code depends on it
/// without going through `Transport` (ADR 0032).
protocol HostServices: Sendable {
    /// Stages one normalized app-owned image in private Host temporary
    /// storage. Concrete transports own destination selection, restrictive
    /// permissions, partial-file handling, and atomic completion (ADR 0006).
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage

    /// Stages one app-owned file in private Host temporary storage. The file
    /// follows the same SFTP, permission, and atomic-completion policy as images.
    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile

    /// Lists the skills / custom slash commands installed for a kind on this
    /// Host: global sources under the remote home plus project sources under
    /// the query's project root, per `SkillSourceCatalog`. Kinds without a
    /// catalog entry return empty. Reads the filesystem over exec, so
    /// alternative transports without a Host process environment report
    /// nothing by default.
    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill]

    /// Reads one skill document in full (capped) for the on-demand content
    /// view; `path` is what the skills probe reported. Same transport caveat
    /// as `listSkills`.
    func readSkillFile(atPath path: String) async throws -> String

    /// Reads one byte range of a Host file. A file that only ever grows — an
    /// Agent's session transcript — is followed by asking for what has not
    /// been read yet, so a screen can show a running figure without pulling
    /// the whole file on every look.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice

    /// Reads one byte range of an Agent transcript for Chat. Unlike
    /// `readFileSlice`, a read past its deadline throws `.hostFileTimedOut`
    /// rather than the link-failure `.timedOut`, so a slow read on a weak link
    /// never redials the Host; a refused read throws `.hostFileUnreadable`.
    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice

    /// Stats one Host path for Chat, following symlinks. Nil when the path
    /// does not exist. Errors follow `readHostFileRange`.
    func fileStatus(atPath path: String) async throws -> RemoteFileStatus?

    /// Lists the matching entries of one Host directory for Chat. Nil when
    /// the directory does not exist. Errors follow `readHostFileRange`.
    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing?

    /// The Host's home directory as its SSH account sees it, for Chat to
    /// find transcripts under. A probe past its deadline throws
    /// `.hostFileTimedOut`, like the file operations.
    func hostHomeDirectory() async throws -> String

    /// Reads one OpenCode session from OpenCode's own database on the Host
    /// (ADR 0025): one read-only script over one exec, one query at a time
    /// per connection. A query past its deadline throws `.hostFileTimedOut`
    /// and never redials the Host; a reader failure that is no store problem
    /// Chat can name throws `.hostStoreUnreadable`.
    func queryOpenCode(_ query: OpenCodeQuery) async throws -> OpenCodeQueryResponse

    /// The Host's operating system family, known once the transport has
    /// resolved the remote environment.
    func hostPlatform() async throws -> HostPlatform

    /// Lists the files inside one untracked directory: one git script over
    /// one exec, using the top level from the latest Changes read. Entries
    /// carry no line counts. Git-level outcomes throw `ChangesReadError`; a
    /// git read past its deadline throws `TransportError.gitTimedOut`.
    /// Transports that cannot run git on a Host throw
    /// `ChangesReadError.unavailable` by default.
    func listUntrackedDirectory(
        _ request: UntrackedDirectoryRequest
    ) async throws -> UntrackedDirectoryListing

    /// Reads the Changes of the Checkout containing `request.directory`:
    /// one git script over one exec, resolved and parsed by `GitProbe`.
    /// Git-level outcomes throw `ChangesReadError`; a git read past its
    /// deadline throws `TransportError.gitTimedOut`. Transports that cannot
    /// run git on a Host throw `ChangesReadError.unavailable` by default.
    func readChanges(_ request: ChangesReadRequest) async throws -> CheckoutChangesRead

    /// Reads one file's patch in its resolved Checkout, including both paths
    /// for a rename and an empty-file comparison for an untracked file.
    /// Transports without Host git throw `ChangesReadError.unavailable`.
    func readFilePatch(_ request: FilePatchRequest) async throws -> FilePatch

    /// The checkout root of each directory, in one git script over one exec.
    /// Asks about at most `GitProbe.checkoutRootsPerCall` of them, the first
    /// ones; a directory it asked about and that is in no checkout has no entry.
    /// Only a herdr-core projection asks, to name a desktop space nobody named.
    /// A caller goes through the Host's `GitExecGate`, as Changes does.
    func checkoutRoots(for directories: [String]) async throws -> [String: String]
}

extension HostServices {
    /// Non-SSH test doubles and alternative transports can state that SFTP is
    /// unavailable without importing or emulating an SSH library.
    func stageImage(
        _ image: PreparedImage,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedImage {
        throw AttachmentStagingError.sftpUnavailable
    }

    func stageFile(
        _ file: PreparedFile,
        progress: @escaping @Sendable (AttachmentStageProgress) async -> Void
    ) async throws -> StagedFile {
        throw AttachmentStagingError.sftpUnavailable
    }

    func listSkills(_ query: SkillListQuery) async throws -> [AgentSkill] {
        []
    }

    func readSkillFile(atPath path: String) async throws -> String {
        throw TransportError.channelFailed(
            detail: "This transport cannot read skill files.")
    }

    /// Test doubles and alternative transports without Host files can decline
    /// without emulating an SSH library; a follower then shows only what the
    /// Host reports elsewhere.
    func readFileSlice(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        throw TransportError.channelFailed(
            detail: "This transport cannot read Host files.")
    }

    /// Transports without Host files decline Chat outright, never with a
    /// link-failure error that would make the Host reconnect.
    func readHostFileRange(_ range: RemoteFileRange) async throws -> RemoteFileSlice {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func fileStatus(atPath path: String) async throws -> RemoteFileStatus? {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func listFiles(_ request: RemoteFileListingRequest) async throws -> RemoteFileListing? {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func hostHomeDirectory() async throws -> String {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func queryOpenCode(_ query: OpenCodeQuery) async throws -> OpenCodeQueryResponse {
        throw TransportError.hostFeatureUnavailable(feature: "Chat")
    }

    func hostPlatform() async throws -> HostPlatform { .posix }

    /// A transport without Host commands cannot list an untracked directory.
    func listUntrackedDirectory(
        _ request: UntrackedDirectoryRequest
    ) async throws -> UntrackedDirectoryListing {
        throw ChangesReadError.unavailable
    }

    /// A transport without Host commands cannot run git, and says so
    /// rather than reporting an empty Checkout.
    func readChanges(_ request: ChangesReadRequest) async throws -> CheckoutChangesRead {
        throw ChangesReadError.unavailable
    }

    /// A transport without Host commands cannot read a file's patch.
    func readFilePatch(_ request: FilePatchRequest) async throws -> FilePatch {
        throw ChangesReadError.unavailable
    }

    /// A transport without Host commands cannot find a checkout.
    func checkoutRoots(for directories: [String]) async throws -> [String: String] {
        throw ChangesReadError.unavailable
    }
}
