import Foundation

/// Finds an Antigravity CLI conversation's transcript,
/// `brain/<id>/.system_generated/logs/transcript_full.jsonl` under
/// `~/.gemini/antigravity-cli`, then under each added Account's directory.
/// No environment variable is known to move that directory, so on Herdr TUI
/// another one is searched only once it is an Account. On herdr-core
/// `configRoot` is the one directory searched.
///
/// The folder is named for the conversation's id, so the lookup is direct:
/// no directory is bucketed by project. Chat reads the full file, whose tool
/// arguments are JSON values; `transcript.jsonl` beside it cuts long fields
/// and encodes every argument as a string.
///
/// The folder can be there before the first message, which brings the file,
/// so a folder without it is a conversation still to start.
struct AgyTranscriptLocator: Sendable {
    enum Failure: Error, Equatable, Sendable {
        /// No directory holds the conversation's folder.
        case notFound
        /// The conversation's folder is there without its transcript yet.
        case notWritten
    }

    /// The default directory, under the Host's home.
    static let defaultRoot = ".gemini/antigravity-cli"

    let files: ChatHostFiles

    func locate(sessionID: String, configRoot: String? = nil) async throws -> Result<String, Failure> {
        // The folder's name is the id as agy writes it: a lowercase UUID.
        guard let id = ConversationReference.canonicalUUID(sessionID) else { return .failure(.notFound) }
        let roots: [String]
        if let configRoot {
            roots = [configRoot]
        } else {
            let home = try await files.home()
            roots = try await files.configRoots(
                for: .antigravity, defaultRoot: RemoteFilePath.join(home, Self.defaultRoot))
        }
        var sawFolder = false
        let found = try await ChatHostFiles.firstAnswer(across: roots) { root -> String? in
            let folder = Self.folder(in: root, id: id)
            guard RemoteFilePath.isAcceptable(folder),
                let status = try await files.status(folder), status.kind == nil || status.kind == .directory
            else { return nil }
            sawFolder = true
            let path = Self.transcriptPath(inFolder: folder)
            guard let file = try await files.status(path), ClaudeTranscriptLocator.isUsable(file) else { return nil }
            return path
        }
        if let found { return .success(found) }
        return .failure(sawFolder ? .notWritten : .notFound)
    }

    /// `<root>/brain/<id>`.
    static func folder(in root: String, id: String) -> String {
        RemoteFilePath.join(root, "brain", id)
    }

    /// The full transcript in a conversation's folder.
    static func transcriptPath(inFolder folder: String) -> String {
        RemoteFilePath.join(folder, ".system_generated", "logs", "transcript_full.jsonl")
    }
}
