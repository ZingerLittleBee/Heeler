import Foundation

/// Tool output read again for expanded rows, laid over the entries it
/// belongs to. Held in memory only, like the previews it extends.
struct ChatToolOutputs: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loading
        /// What the read found.
        case read(ChatExpandedOutput)
        case failed(ChatToolOutputFailure)
    }

    struct Load: Equatable, Sendable {
        /// The line the read was for. A row that now references another
        /// line ignores it.
        var reference: ChatOutputReference
        var state: State
    }

    private(set) var loads: [ChatEntryID: Load] = [:]

    var isEmpty: Bool { loads.isEmpty }

    /// Whether the output `id` references at `reference` still needs
    /// reading: never read, read for another line, or failed in a way that
    /// reading again could fix.
    func needsRead(_ id: ChatEntryID, at reference: ChatOutputReference) -> Bool {
        guard let load = loads[id], load.reference == reference else { return true }
        if case .failed(let failure) = load.state { return failure.canRetry }
        return false
    }

    mutating func begin(_ id: ChatEntryID, at reference: ChatOutputReference) {
        loads[id] = Load(reference: reference, state: .loading)
    }

    mutating func finish(
        _ id: ChatEntryID, at reference: ChatOutputReference,
        with result: Result<ChatExpandedOutput, ChatToolOutputFailure>
    ) {
        guard loads[id]?.reference == reference else { return }
        switch result {
        case .success(let output): loads[id]?.state = .read(output)
        case .failure(let failure): loads[id]?.state = .failed(failure)
        }
    }

    /// The entries with each read laid over its row: the preview and file
    /// changes it found, and how the read went.
    func marking(_ entries: [ChatEntry]) -> [ChatEntry] {
        guard !isEmpty else { return entries }
        return entries.map { entry in
            guard case .tool(var tool) = entry.content, let load = loads[entry.id],
                load.reference == tool.output
            else { return entry }
            switch load.state {
            case .loading:
                tool.outputRead = .loading
            case .read(let output):
                // A line that holds none of it, such as a Codex end event
                // whose call recorded the output, keeps the row's own.
                tool.preview = output.preview ?? tool.preview
                if let changes = tool.fileChanges, var found = output.fileChanges {
                    // The row read the command; the line alone can't.
                    found.movesWorkingTree = changes.movesWorkingTree
                    tool.fileChanges = found
                }
                tool.outputRead = .read
            case .failed(.tooLong) where tool.preview != nil:
                // The row keeps showing the start, which says where the
                // rest is.
                tool.outputRead = .read
            case .failed(let failure) where !failure.canRetry:
                tool.outputRead = .unavailable(failure.message)
            case .failed(let failure):
                tool.outputRead = .failed(failure.message)
            }
            var entry = entry
            entry.content = .tool(tool)
            return entry
        }
    }
}
