import Foundation

/// One line the OpenCode record source hands the reducer (ADR 0025): a
/// `session_message` row cut to what Chat shows, the session's own row, or
/// its inbox. Decoding never throws: unknown keys are ignored, and a value of
/// an unexpected JSON type reads as absent, so one odd field costs only
/// itself.
enum OpenCodeLine: Sendable {
    case session(OpenCodeSession)
    case inbox(OpenCodeInbox)
    case row(OpenCodeRow)
    /// Not one of the three: not JSON, or without the fields its kind needs.
    case malformed

    init(_ data: Data) {
        self = (try? JSONDecoder().decode(Envelope.self, from: data))?.line ?? .malformed
    }

    private struct Envelope: Decodable {
        let line: OpenCodeLine

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: OpenCodeKey.self)
            switch container.lenient(String.self, "k") {
            case "session": line = .session(try OpenCodeSession(from: decoder))
            case "inbox": line = .inbox(try OpenCodeInbox(from: decoder))
            case "row": line = OpenCodeRow(container).map(OpenCodeLine.row) ?? .malformed
            default: line = .malformed
            }
        }
    }
}

/// The session's own row: `{"k":"session",…}`.
struct OpenCodeSession: Decodable, Sendable {
    /// The id of the session this one is a subagent of.
    var parent: String?
    var title: String?
    /// The OpenCode version that created the session. One OpenCode 2
    /// imported from 1.x keeps its 1.x version.
    var version: String?
    /// The folder the session is in now; a move rewrites it.
    var directory: String?
    /// The boundary message of a staged `/undo`.
    var revertMessage: String?
    /// The boundary message's `seq`; nil when its row is gone.
    var revertSeq: Int64?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        parent = container.lenient(String.self, "parent")
        title = container.lenient(String.self, "title")
        version = container.lenient(String.self, "version")
        directory = container.lenient(String.self, "directory")
        revertMessage = container.lenient(String.self, "revertMessage")
        revertSeq = container.lenient(Int64.self, "revertSeq")
    }

    /// The major version of `version`.
    var majorVersion: Int? {
        version?.split(separator: ".").first.flatMap { Int($0) }
    }
}

/// Prompts OpenCode has taken but not yet written as rows:
/// `{"k":"inbox","items":[…],"more":0}`.
struct OpenCodeInbox: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        /// The id the item's user row will carry.
        var id: String?
        var type: String?
        /// `enqueued_seq`.
        var seq: Int64?
        /// The text's first 16 Ki characters.
        var text: String?
        /// The text's length in characters before the cut.
        var length: Int?
        /// Attached files' names.
        var files: [String]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: OpenCodeKey.self)
            id = container.lenient(String.self, "id")
            type = container.lenient(String.self, "type")
            seq = container.lenient(Int64.self, "seq")
            text = container.lenient(String.self, "text")
            length = container.lenient(Int.self, "n")
            files = container.lossy(String.self, "files")
        }
    }

    var items: [Item]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        items = container.lossy(Item.self, "items")
    }
}

/// One `session_message` row: `{"k":"row","id","type","seq","tc","tu","f","d"}`.
struct OpenCodeRow: Sendable {
    enum Content: Sendable {
        case user(OpenCodeUserMessage)
        case assistant(OpenCodeStep)
        case idle(OpenCodeIdle)
        case compaction(OpenCodeCompaction)
        /// A `synthetic`, `system` or `skill` row.
        case note(OpenCodeNote)
        case shell(OpenCodeShell)
        case agentSwitched(agent: String?)
        case modelSwitched(model: String?)
        /// A move to `directory` from `previous`. A row over the source's
        /// limit for small rows keeps neither.
        case locationSwitched(directory: String?, previous: String?)
        /// A type this reader does not know; the source keeps only its time.
        case unknown
        /// The stored data is not JSON (`{"k":"invalid"}`).
        case invalid
        /// The data was over the source's row limit: its size in bytes.
        case oversized(Int)
    }

    var id: String
    var type: String
    var seq: Int64
    /// `time_created` and `time_updated`, in milliseconds.
    var created: Int64?
    var updated: Int64?
    /// False while the row can still change: an unfinished step, compaction
    /// or shell command.
    var isFinal: Bool
    var content: Content

    fileprivate init?(_ container: KeyedDecodingContainer<OpenCodeKey>) {
        guard let id = container.lenient(String.self, "id"), let type = container.lenient(String.self, "type"),
            let seq = container.lenient(Int64.self, "seq")
        else { return nil }
        self.id = id
        self.type = type
        self.seq = seq
        created = container.lenient(Int64.self, "tc")
        updated = container.lenient(Int64.self, "tu")
        isFinal = container.flag("f") ?? true
        if let size = container.lenient(Int.self, "big") {
            content = .oversized(size)
        } else if let data = container.object("d"), data.lenient(String.self, "k") != "invalid" {
            content = Self.content(type: type, data: data, in: container) ?? .invalid
        } else {
            content = .invalid
        }
    }

    /// The row's `d` read as its type's shape; nil when it is not one.
    private static func content(
        type: String, data: KeyedDecodingContainer<OpenCodeKey>, in row: KeyedDecodingContainer<OpenCodeKey>
    ) -> Content? {
        switch type {
        case "user": row.lenient(OpenCodeUserMessage.self, "d").map(Content.user)
        case "assistant": row.lenient(OpenCodeStep.self, "d").map(Content.assistant)
        case "idle": row.lenient(OpenCodeIdle.self, "d").map(Content.idle)
        case "compaction": row.lenient(OpenCodeCompaction.self, "d").map(Content.compaction)
        case "synthetic", "system", "skill": row.lenient(OpenCodeNote.self, "d").map(Content.note)
        case "shell": row.lenient(OpenCodeShell.self, "d").map(Content.shell)
        case "agent-switched": .agentSwitched(agent: data.lenient(String.self, "agent"))
        case "model-switched": .modelSwitched(model: data.object("model")?.lenient(String.self, "id"))
        case "location-switched":
            .locationSwitched(
                directory: data.object("location")?.lenient(String.self, "directory"),
                previous: data.object("previous")?.object("location")?.lenient(String.self, "directory"))
        default: .unknown
        }
    }
}

/// A prompt as OpenCode stored it.
struct OpenCodeUserMessage: Decodable, Sendable {
    struct Attachment: Decodable, Sendable {
        var name: String?
        var mime: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: OpenCodeKey.self)
            name = container.lenient(String.self, "name")
            mime = container.lenient(String.self, "mime")
        }
    }

    /// The text's first 256 Ki characters, untrimmed.
    var text: String?
    /// The text's length in characters before the cut.
    var length: Int?
    var files: [Attachment]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        text = container.lenient(String.self, "text")
        length = container.lenient(Int.self, "n")
        files = container.lossy(Attachment.self, "files")
    }
}

/// One model step: an `assistant` row.
struct OpenCodeStep: Decodable, Sendable {
    /// A content item, by its index in the stored step.
    struct Item: Sendable {
        enum Kind: Sendable {
            case text(OpenCodeText)
            case reasoning(OpenCodeText)
            case tool(OpenCodeTool)
            /// Another item type, or an item that is not an object.
            case other
        }

        var index: Int
        var kind: Kind
    }

    struct Retry: Sendable {
        var attempt: Int?
        var error: OpenCodeError?
    }

    var items: [Item]
    /// `stop`, `tool-calls`, `length`, `error`, `content-filter` or `unknown`.
    var finish: String?
    var error: OpenCodeError?
    var retry: Retry?
    /// When the step ended, in milliseconds.
    var completed: Int64?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        items = container.lossy(RawItem.self, "content").enumerated().map { position, item in
            Item(index: item.index ?? position, kind: item.kind)
        }
        finish = container.lenient(String.self, "finish")
        error = container.lenient(OpenCodeError.self, "error")
        retry = container.object("retry").map {
            Retry(attempt: $0.lenient(Int.self, "attempt"), error: $0.lenient(OpenCodeError.self, "error"))
        }
        completed = container.object("time")?.lenient(Int64.self, "completed")
    }

    /// One content item as the source writes it: `{"_i":0,"type":…}`.
    private struct RawItem: Decodable {
        var index: Int?
        var kind: Item.Kind

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: OpenCodeKey.self) else {
                index = nil
                kind = .other
                return
            }
            index = container.lenient(Int.self, "_i")
            switch container.lenient(String.self, "type") {
            case "text": kind = .text(OpenCodeText(container))
            case "reasoning": kind = .reasoning(OpenCodeText(container))
            case "tool": kind = OpenCodeTool(container).map(Item.Kind.tool) ?? .other
            default: kind = .other
            }
        }
    }
}

/// A text or reasoning item.
struct OpenCodeText: Sendable {
    /// The item's first 64 Ki characters.
    var text: String
    /// The text's length in characters before the cut.
    var length: Int?
    /// When a reasoning block started and ended, in milliseconds.
    var started: Int64?
    var completed: Int64?

    fileprivate init(_ container: KeyedDecodingContainer<OpenCodeKey>) {
        text = container.lenient(String.self, "text") ?? ""
        length = container.lenient(Int.self, "n")
        let time = container.object("time")
        started = time?.lenient(Int64.self, "created")
        completed = time?.lenient(Int64.self, "completed")
    }
}

/// A tool call: a step's `tool` item.
struct OpenCodeTool: Sendable {
    var callID: String?
    var name: String
    /// `streaming`, `running`, `completed` or `error`.
    var status: String?
    var input: OpenCodeToolInput
    var error: OpenCodeError?
    var metadata: OpenCodeToolMetadata?
    /// The output texts joined, cut to the source's output limit.
    var output: String?
    /// The joined output's length in characters before the cut.
    var outputLength: Int?
    /// The path of the first image the call returned, as OpenCode named it.
    var image: String?

    fileprivate init?(_ container: KeyedDecodingContainer<OpenCodeKey>) {
        guard let name = container.lenient(String.self, "name") else { return nil }
        self.name = name
        callID = container.lenient(String.self, "id")
        status = container.lenient(String.self, "status")
        input = container.lenient(OpenCodeToolInput.self, "input") ?? OpenCodeToolInput()
        error = container.lenient(OpenCodeError.self, "error")
        metadata = container.lenient(OpenCodeToolMetadata.self, "meta")
        output = container.lenient(String.self, "out")
        outputLength = container.lenient(Int.self, "outN")
        image = container.lenient(String.self, "image")
    }
}

/// The fields of a tool's input that a row names. A large input keeps only
/// these; a text input (a streaming call's arguments so far) only `text`.
struct OpenCodeToolInput: Decodable, Sendable {
    struct Question: Decodable, Sendable {
        struct Option: Decodable, Sendable {
            var label: String?
            var description: String?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: OpenCodeKey.self)
                label = container.lenient(String.self, "label")
                description = container.lenient(String.self, "description")
            }
        }

        var question: String?
        var header: String?
        var options: [Option]
        var multiple: Bool?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: OpenCodeKey.self)
            question = container.lenient(String.self, "question")
            header = container.lenient(String.self, "header")
            options = container.lossy(Option.self, "options")
            multiple = container.flag("multiple")
        }
    }

    var filePath: String?
    var path: String?
    var command: String?
    var pattern: String?
    var url: String?
    var query: String?
    var description: String?
    var agent: String?
    /// The older `task` tool's agent.
    var subagentType: String?
    var patchText: String?
    /// The `skill` tool's skill.
    var id: String?
    var questions: [Question] = []
    var text: String?

    init() {}

    init(from decoder: any Decoder) throws {
        if let text = try? decoder.singleValueContainer().decode(String.self) {
            self.text = text
            return
        }
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        filePath = container.lenient(String.self, "filePath")
        path = container.lenient(String.self, "path")
        command = container.lenient(String.self, "command")
        pattern = container.lenient(String.self, "pattern")
        url = container.lenient(String.self, "url")
        query = container.lenient(String.self, "query")
        description = container.lenient(String.self, "description")
        agent = container.lenient(String.self, "agent")
        subagentType = container.lenient(String.self, "subagent_type")
        patchText = container.lenient(String.self, "patchText")
        id = container.lenient(String.self, "id")
        questions = container.lossy(Question.self, "questions")
    }
}

/// A tool's metadata, without the copies the source drops.
struct OpenCodeToolMetadata: Decodable, Sendable {
    /// One file a call changed: 2.0's `files[]` entry, or the older
    /// `filediff`, which keeps only its counts.
    struct FileDiff: Decodable, Sendable {
        var file: String?
        /// `added`, `deleted` or `modified`; older rows say `add`, `update`.
        var status: String?
        var additions: Int?
        var deletions: Int?
        /// A unified patch, cut at 64 Ki characters.
        var patch: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: OpenCodeKey.self)
            file = container.lenient(String.self, "file")
            status = container.lenient(String.self, "status")
            additions = container.lenient(Int.self, "additions")
            deletions = container.lenient(Int.self, "deletions")
            patch = container.lenient(String.self, "patch")
        }
    }

    var exit: Int?
    /// OpenCode shortened the output itself.
    var truncated: Bool?
    /// `running` for a call that left its work running in the background.
    var status: String?
    /// The `skill` tool's skill name.
    var name: String?
    var files: [FileDiff]
    /// The older single-file patch.
    var diff: String?
    var filediff: FileDiff?
    /// A question tool's answers: each question's selected labels.
    var answers: [[String]]?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        exit = container.lenient(Int.self, "exit")
        truncated = container.flag("truncated")
        status = container.lenient(String.self, "status")
        name = container.lenient(String.self, "name")
        files = container.lossy(FileDiff.self, "files")
        diff = container.lenient(String.self, "diff")
        filediff = container.lenient(FileDiff.self, "filediff")
        answers = container.lenient([[String]].self, "answers")
    }
}

/// OpenCode's structured error. Older rows record a bare message.
struct OpenCodeError: Decodable, Sendable {
    /// `aborted` for a call or step the user stopped or declined.
    var type: String?
    var message: String?

    init(from decoder: any Decoder) throws {
        if let message = try? decoder.singleValueContainer().decode(String.self) {
            self.message = message
            return
        }
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        type = container.lenient(String.self, "type")
        message = container.lenient(String.self, "message")
    }
}

/// The marker that ends a turn.
struct OpenCodeIdle: Decodable, Sendable {
    /// `succeeded`, `failed` or `interrupted`; nil when the row was too
    /// large for the source to keep.
    var outcome: String?
    var error: OpenCodeError?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        outcome = container.lenient(String.self, "outcome")
        error = container.lenient(OpenCodeError.self, "error")
    }
}

struct OpenCodeCompaction: Decodable, Sendable {
    /// `running`, `completed` or `failed`.
    var status: String?
    /// `manual` for `/compact`, `auto` for one OpenCode started.
    var reason: String?
    var summary: String?
    /// Why it failed: `compaction.unavailable` when there was nothing new
    /// to compact, `aborted` when the user stopped a `/compact`. The source
    /// keeps the first 16 Ki characters of its message.
    var error: OpenCodeError?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        status = container.lenient(String.self, "status")
        reason = container.lenient(String.self, "reason")
        summary = container.lenient(String.self, "summary")
        error = container.lenient(OpenCodeError.self, "error")
    }
}

/// A `synthetic`, `system` or `skill` row.
struct OpenCodeNote: Decodable, Sendable {
    /// The first 16 Ki characters of the model-facing text.
    var text: String?
    var description: String?
    /// Whether the row carries metadata at all.
    var hasMetadata: Bool
    /// `subagent` or `shell` for a background completion.
    var source: String?
    /// The background shell job a `shell` completion reports.
    var jobID: String?
    /// `restart` for the note OpenCode adds when it resumes a turn.
    var notice: String?
    /// A skill row's skill and name.
    var skill: String?
    var name: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        text = container.lenient(String.self, "text")
        description = container.lenient(String.self, "description")
        let metadata = container.object("metadata")
        hasMetadata = metadata != nil
        source = metadata?.lenient(String.self, "source")
        jobID = metadata?.lenient(String.self, "jobID")
        notice = metadata?.lenient(String.self, "notice")
        skill = container.lenient(String.self, "skill")
        name = container.lenient(String.self, "name")
    }
}

/// A command the user ran in OpenCode's shell mode.
struct OpenCodeShell: Decodable, Sendable {
    var command: String?
    /// The output's first 16 Ki characters.
    var output: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: OpenCodeKey.self)
        command = container.lenient(String.self, "command")
        output = container.lenient(String.self, "output")
    }
}

// MARK: Lenient decoding

private struct OpenCodeKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

extension KeyedDecodingContainer where Key == OpenCodeKey {
    /// The value at `key`, or nil when it is absent, null or of another
    /// type.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        (try? decodeIfPresent(type, forKey: OpenCodeKey(key))) ?? nil
    }

    /// The object at `key`; nil when it is absent or not an object.
    fileprivate func object(_ key: String) -> KeyedDecodingContainer<OpenCodeKey>? {
        try? nestedContainer(keyedBy: OpenCodeKey.self, forKey: OpenCodeKey(key))
    }

    /// A flag stored as a JSON boolean, or as the 0 or 1 SQLite's
    /// `json_extract` makes of one.
    fileprivate func flag(_ key: String) -> Bool? {
        lenient(Bool.self, key) ?? lenient(Int.self, key).map { $0 != 0 }
    }

    /// The elements of the array at `key` that decode as `Element`; empty
    /// when it is absent or not an array.
    fileprivate func lossy<Element: Decodable>(_ type: Element.Type, _ key: String) -> [Element] {
        lenient([Lossy<Element>].self, key)?.compactMap(\.value) ?? []
    }
}

/// An element that never fails to decode, so one odd element costs only
/// itself.
private struct Lossy<Element: Decodable>: Decodable {
    let value: Element?

    init(from decoder: any Decoder) throws {
        value = try? Element(from: decoder)
    }
}
