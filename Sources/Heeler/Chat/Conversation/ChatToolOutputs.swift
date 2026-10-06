import Foundation

/// Tool output read again for expanded rows, laid over the entries it
/// belongs to. Held in memory only, like the previews it extends.
struct ChatToolOutputs: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loading
        /// What the read found; nil when the output has nothing to show.
        case read(ChatToolPreview?)
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
    /// reading: never read, read for another line, or failed.
    func needsRead(_ id: ChatEntryID, at reference: ChatOutputReference) -> Bool {
        guard let load = loads[id], load.reference == reference else { return true }
        if case .failed = load.state { return true }
        return false
    }

    mutating func begin(_ id: ChatEntryID, at reference: ChatOutputReference) {
        loads[id] = Load(reference: reference, state: .loading)
    }

    mutating func finish(
        _ id: ChatEntryID, at reference: ChatOutputReference,
        with result: Result<ChatToolPreview?, ChatToolOutputFailure>
    ) {
        guard loads[id]?.reference == reference else { return }
        switch result {
        case .success(let preview): loads[id]?.state = .read(preview)
        case .failure(let failure): loads[id]?.state = .failed(failure)
        }
    }

    /// The entries with each read laid over its row: the preview it found,
    /// and how the read went.
    func marking(_ entries: [ChatEntry]) -> [ChatEntry] {
        guard !isEmpty else { return entries }
        return entries.map { entry in
            guard case .tool(var tool) = entry.content, let load = loads[entry.id],
                load.reference == tool.output
            else { return entry }
            switch load.state {
            case .loading:
                tool.outputRead = .loading
            case .read(let preview):
                // A line that holds none of it, such as a Codex end event
                // whose call recorded the output, keeps the row's own.
                tool.preview = preview ?? tool.preview
                tool.outputRead = .read
            case .failed(.tooLong) where tool.preview != nil:
                // The row keeps showing the start, which says where the
                // rest is.
                tool.outputRead = .read
            case .failed(let failure):
                tool.outputRead = .failed(failure.message)
            }
            var entry = entry
            entry.content = .tool(tool)
            return entry
        }
    }
}
