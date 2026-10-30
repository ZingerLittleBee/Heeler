import Foundation

/// The generation-1 herdr-core API is JSON-RPC, not the legacy herdr wire
/// protocol. Keep its terminal records and event names at this boundary.
enum HerdrCoreWire {
    static let generation = 1

    static func requestLine(
        id: String, method: String, params: JSONValue = .object([:])
    ) throws -> String {
        let request: JSONValue = .object([
            "jsonrpc": .string("2.0"), "id": .string(id),
            "method": .string(method), "params": params,
        ])
        return String(decoding: try JSONEncoder().encode(request), as: UTF8.self) + "\n"
    }

    static func result(from data: Data, id: String) throws -> JSONValue {
        let envelope = try decodeLine(data)
        guard envelope["jsonrpc"] == .string("2.0"), envelope["id"] == .string(id) else {
            throw malformed("The response is not JSON-RPC 2.0 for the requested id.")
        }
        if let error = envelope["error"], error != .null {
            guard let message = error["message"]?.stringValue else {
                throw malformed("The error response has no message.")
            }
            let kind = error["data"]?["kind"]?.stringValue
                ?? integer(error["code"]).map(String.init) ?? "herdr_core_error"
            let hint = nonEmpty(error["data"]?["hint"]?.stringValue)
            throw HerdrAPIError(code: kind, message: hint.map { "\(message) \($0)" } ?? message)
        }
        guard let result = envelope["result"] else {
            throw malformed("The response has neither a result nor an error.")
        }
        return result
    }

    static func serverInfo(from hello: JSONValue) throws -> ServerInfo {
        guard let protocolGeneration = integer(hello["generation"]),
            let version = nonEmpty(hello["version"]?.stringValue)
        else { throw malformed("The hello response has no generation or version.") }
        guard protocolGeneration == generation else {
            throw TransportError.hostFeatureUnavailable(
                feature: "This app supports herdr-core protocol generation 1; the Host reports \(protocolGeneration)")
        }
        let methods = Set(array(hello["methods"])?.compactMap(\.stringValue) ?? [])
        let required: Set<String> = [
            "terminal.list", "terminal.get", "terminal.read", "terminal.send",
            "terminal.keys", "events.subscribe",
        ]
        guard required.isSubset(of: methods) else {
            throw TransportError.hostFeatureUnavailable(
                feature: "The Host's herdr-core is missing required terminal or event methods. Update herdr-core")
        }
        return ServerInfo(version: version, protocolVersion: protocolGeneration)
    }

    /// Core owns terminals, not desktop layout. Group local terminals by
    /// their launch directory; each terminal is one tab with one pane. These
    /// ids are stable across title changes and foreground directory changes.
    static func workspaceID(for directory: String) -> String { "core:" + directory }

    static func directory(forWorkspaceID id: String) -> String? {
        guard id.hasPrefix("core:/") else { return nil }
        return String(id.dropFirst("core:".count))
    }

    static func snapshot(from result: JSONValue) throws -> SessionSnapshot {
        guard let records = array(result["terminals"]) else {
            throw malformed("The terminal list has no terminals array.")
        }
        var terminals: [Terminal] = []
        var seen = Set<String>()
        for record in records {
            guard let address = nonEmpty(record["address"]?.stringValue) else {
                throw malformed("A terminal has no address.")
            }
            // Federated addresses belong to another SSH filesystem. Do not
            // let their cwd drive Changes or file staging on this Host.
            guard !address.contains("/") else { continue }
            guard record["state"] == .string("live") else { continue }
            guard seen.insert(address).inserted else {
                throw malformed("The terminal list repeats an address.")
            }
            terminals.append(try Terminal(record))
        }
        let directories = terminals.reduce(into: [String]()) { directories, terminal in
            if !directories.contains(terminal.cwd) { directories.append(terminal.cwd) }
        }
        let workspaces = directories.enumerated().map { index, cwd in
            let members = terminals.filter { $0.cwd == cwd }
            return WorkspaceInfo(
                activeTabID: members.first?.address ?? "", agentStatus: aggregateStatus(members),
                focused: false, label: directoryLabel(cwd), number: index + 1,
                paneCount: members.count, tabCount: members.count, workspaceID: workspaceID(for: cwd))
        }
        return SessionSnapshot(
            agents: terminals.filter { $0.kind != nil }.map(\.agentInfo), layouts: [],
            panes: terminals.map(\.paneInfo), protocolVersion: generation,
            tabs: terminals.enumerated().map { index, terminal in
                TabInfo(
                    agentStatus: terminal.status, focused: false,
                    label: terminal.name ?? nonEmpty(terminal.title) ?? terminal.address,
                    number: index + 1, paneCount: 1, tabID: terminal.address,
                    workspaceID: workspaceID(for: terminal.cwd))
            },
            version: "herdr-core", workspaces: workspaces)
    }

    static func agent(from record: JSONValue) throws -> Agent {
        let terminal = try Terminal(record)
        guard terminal.kind != nil, record["state"] == .string("live") else {
            throw HerdrAPIError(code: "agent_not_found", message: "The terminal is not running a recognized Agent.")
        }
        return Agent(terminal.agentInfo)
    }

    static func read(
        from result: JSONValue, target: String, source: ReadSource = .recent
    ) throws -> PaneReadResult {
        guard let text = result["text"]?.stringValue,
            case .bool(let complete) = result["complete"]
        else { throw malformed("The terminal read has no text or completeness flag.") }
        return PaneReadResult(
            format: .text, paneID: target, revision: 0, source: source,
            tabID: target, text: text, truncated: !complete, workspaceID: "")
    }

    static func decodeEvent(fromLine data: Data) throws -> HerdrEvent? {
        try event(from: decodeLine(data))
    }

    fileprivate static func event(from line: JSONValue) throws -> HerdrEvent? {
        guard line["jsonrpc"] == .string("2.0"), line["id"] == nil,
            let method = line["method"]?.stringValue
        else { throw malformed("Invalid event notification.") }
        if method == "heartbeat" { return nil }
        if method == "missed" { return .eventsDropped }
        guard method == "event" else { return nil }
        guard let params = line["params"], let type = params["type"]?.stringValue else {
            throw malformed("An event has no type.")
        }
        // Desktop layout documents do not define the directory grouping.
        if type == "doc" { return nil }
        guard let target = nonEmpty(params["terminal"]?.stringValue) else {
            throw malformed("A terminal event has no terminal address.")
        }
        guard !target.contains("/") else { return nil }
        if type == "status" {
            return HerdrEvent(
                kind: PaneEventKind.agentStatusChanged.kind,
                data: .object([
                    "pane_id": .string(target),
                    "agent_status": .string(status(from: params["data"]?["status"]).rawValue),
                ]))
        }
        let kind: GlobalEventKind
        switch type {
        case "created", "restarted": kind = .paneCreated
        case "removed": kind = .paneClosed
        case "finished", "lost": kind = .paneExited
        case "title": kind = .tabRenamed
        case "foreground", "labels", "turn", "keep": kind = .paneAgentDetected
        case "size": return nil
        default: return .eventsDropped
        }
        return HerdrEvent(kind: kind.kind, data: .object(["pane_id": .string(target)]))
    }

    fileprivate static func decodeLine(_ data: Data) throws -> JSONValue {
        do { return try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw malformed("Invalid JSON response.") }
    }

    fileprivate static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number) = value, number.isFinite,
            number.rounded(.towardZero) == number,
            number >= Double(Int.min), number < Double(Int.max)
        else { return nil }
        return Int(number)
    }

    private static func array(_ value: JSONValue?) -> [JSONValue]? {
        guard case .array(let values) = value else { return nil }
        return values
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func malformed(_ detail: String) -> TransportError {
        .malformedResponse("herdr-core: \(detail)")
    }

    private static func status(from value: JSONValue?) -> AgentStatus {
        value?["state"]?.stringValue.map(AgentStatus.init(rawValue:)) ?? .unknown
    }

    private static func directoryLabel(_ directory: String) -> String {
        directory.split(separator: "/").last.map(String.init) ?? directory
    }

    private static func aggregateStatus(_ terminals: [Terminal]) -> AgentStatus {
        for status in [AgentStatus.blocked, .working, .done, .idle] {
            if terminals.contains(where: { $0.kind != nil && $0.status == status }) { return status }
        }
        return .unknown
    }

    private static func recognizedKind(_ value: String?) -> String? {
        guard let value else { return nil }
        let basename = value.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        switch basename {
        case "claude-code", "claude code": return "claude"
        case "pi-cli": return "pi"
        case "cursor-agent": return "cursor"
        case "kiro-cli": return "kiro"
        case "antigravity": return "agy"
        default: return SupportedAgentKind(rawValue: basename)?.rawValue
        }
    }

    /// Inspect command positions, never arbitrary arguments: `echo claude`
    /// and `node server.js claude` are not Agents. These are the POSIX launch
    /// wrappers emitted by herdr-app's `window::agent_argv` and common script
    /// entry points from the programs it starts.
    private static func kind(in arguments: [String], depth: Int = 0) -> String? {
        guard depth < 4, let executable = arguments.first else { return nil }
        let program = executable.split(separator: "/").last.map(String.init)?.lowercased() ?? ""
        let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "nu", "elvish", "xonsh", "tcsh", "csh"]
        let wrapperBodies: Set<String> = [
            "\"$@\"; exec \"$0\" -i",
            "\"$@\"; exec \"${SHELL:-sh}\" -i",
        ]
        if shells.contains(program), arguments.count > 4,
            ["-c", "-ic"].contains(arguments[1]), wrapperBodies.contains(arguments[2])
        {
            return kind(in: Array(arguments.dropFirst(4)), depth: depth + 1)
        }
        if let direct = recognizedKind(executable) { return direct }
        guard ["node", "nodejs", "bun", "python", "python3", "ruby"].contains(program) else { return nil }
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { index += 1; break }
            if !argument.hasPrefix("-") { break }
            // Evaluated source is not a script name. Refuse unknown switches
            // rather than mistaking their values for an executable.
            if ["--no-warnings", "--enable-source-maps", "--experimental-strip-types", "-u", "-B"].contains(argument) {
                index += 1
            } else if ["-r", "--require", "--import", "--loader", "--experimental-loader"].contains(argument) {
                index += 2
            } else {
                return nil
            }
        }
        guard index < arguments.count else { return nil }
        return scriptKind(arguments[index])
    }

    private static func scriptKind(_ path: String) -> String? {
        let components = path.split(separator: "/").map { $0.lowercased() }
        guard let basename = components.last else { return nil }
        let entryPoints: [([String], String)] = [
            (["@anthropic-ai", "claude-code", "cli.js"], "claude"),
            (["@google", "gemini-cli", "dist", "index.js"], "gemini"),
            (["@mariozechner", "pi-coding-agent", "dist", "cli.js"], "pi"),
            (["@openai", "codex", "bin", "codex.js"], "codex"),
        ]
        for (suffix, kind) in entryPoints where components.suffix(suffix.count).elementsEqual(suffix) {
            return kind
        }
        let stem = [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"]
            .first(where: basename.hasSuffix)
            .map { String(basename.dropLast($0.count)) } ?? basename
        return recognizedKind(stem)
    }

    private struct Terminal {
        let address: String
        let cwd: String
        let foregroundCwd: String?
        let kind: String?
        let name: String?
        let title: String
        let status: AgentStatus
        let turn: Int
        let statusTime: Int?

        init(_ record: JSONValue) throws {
            guard let address = nonEmpty(record["address"]?.stringValue),
                !address.contains("/"),
                let cwd = record["cwd"]?.stringValue, cwd.hasPrefix("/")
            else { throw malformed("A local terminal is missing its address or absolute directory.") }
            self.address = address
            self.cwd = cwd
            foregroundCwd = nonEmpty(record["foreground"]?["cwd"]?.stringValue)
            name = nonEmpty(record["name"]?.stringValue)
            title = nonEmpty(record["title"]?.stringValue)
                ?? record["status"]?["title"]?.stringValue ?? ""
            status = HerdrCoreWire.status(from: record["status"])
            turn = integer(record["turn"]) ?? 0
            statusTime = integer(record["status_ms"])
            let foreground = record["foreground"]
            let foregroundArguments = array(foreground?["argv"])?.compactMap(\.stringValue) ?? []
            let foregroundName = nonEmpty(foreground?["name"]?.stringValue)
            let launchArguments = array(record["argv"])?.compactMap(\.stringValue) ?? []
            let processKind: String?
            if !foregroundArguments.isEmpty || foregroundName != nil {
                // Once the foreground is known, a desktop wrapper's original
                // command must not keep an exited Agent in the inventory.
                processKind = HerdrCoreWire.kind(in: foregroundArguments)
                    ?? recognizedKind(foregroundName)
            } else {
                processKind = HerdrCoreWire.kind(in: launchArguments)
            }
            kind = recognizedKind(record["status"]?["app"]?.stringValue) ?? processKind
        }

        var agentInfo: AgentInfo {
            AgentInfo(
                agentStatus: status, focused: false, paneID: address, revision: turn,
                tabID: address, terminalID: address, workspaceID: workspaceID(for: cwd),
                agent: kind, completionSeq: turn, cwd: cwd, foregroundCwd: foregroundCwd,
                name: name, stateChangeSeq: statusTime, terminalTitle: title)
        }

        var paneInfo: PaneInfo {
            PaneInfo(
                agentStatus: status, focused: false, paneID: address, revision: turn,
                tabID: address, terminalID: address, workspaceID: workspaceID(for: cwd),
                agent: kind, cwd: cwd, foregroundCwd: foregroundCwd, terminalTitle: title)
        }
    }
}

/// A subscription's sequence belongs to one core process. Create a fresh
/// cursor after reconnect; `missed` replaces the inventory and establishes a
/// new lower bound, so buffered older events must not be reapplied afterward.
struct HerdrCoreEventCursor {
    private(set) var sequence: Int?

    mutating func acknowledge(_ result: JSONValue) throws {
        guard let sequence = HerdrCoreWire.integer(result["seq"]), sequence >= 0,
            case .array = result["terminals"]
        else {
            throw TransportError.malformedResponse("herdr-core: Invalid subscription snapshot.")
        }
        self.sequence = sequence
    }

    mutating func decodeEvent(fromLine data: Data) throws -> HerdrEvent? {
        let line = try HerdrCoreWire.decodeLine(data)
        guard let next = HerdrCoreWire.integer(line["params"]?["seq"]), next >= 0 else {
            throw TransportError.malformedResponse("herdr-core: An event has no sequence.")
        }
        // A heartbeat reports the core's current global sequence, not a
        // delivered-event watermark. It can precede events already queued for
        // this subscriber; advancing here would silently discard them.
        if line["method"] == .string("heartbeat") {
            return try HerdrCoreWire.event(from: line)
        }
        if line["method"] == .string("missed") {
            sequence = next
            return try HerdrCoreWire.event(from: line)
        }
        guard sequence.map({ next > $0 }) ?? true else { return nil }
        sequence = next
        return try HerdrCoreWire.event(from: line)
    }
}
