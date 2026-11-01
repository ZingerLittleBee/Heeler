import Foundation

@testable import Heeler

/// What a native Windows Host's process read prints, from the facts the
/// read's own script names: its `$ids`, `$root`, `$want` and `$names`.
/// `say` and CIM are the Host's, so this prints the lines the script's body prints.
struct WindowsProcessTable: Sendable {
    struct Process: Sendable {
        var pid: Int
        var parent: Int = 1
        /// The image's name, as CIM reports it: `claude.exe`.
        var image: String
        /// The creation FILETIME as decimal digits; nil for one the reader cannot open.
        var start: String?
        /// Nil: the reader cannot read this process's memory.
        var environment: [String: String]? = [:]
    }

    var processes: [Int: Process] = [:]

    mutating func add(_ process: Process) {
        processes[process.pid] = process
    }

    func output(forScript script: String) -> String {
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ids = Self.value(of: "$ids=@(", in: lines)?.dropLast().split(separator: ",").map(String.init) ?? []
        let root = Self.value(of: "$root=", in: lines).flatMap { Int($0) } ?? 0
        let wanted = Self.names(of: "$want=@", in: lines)
        let named = Self.names(of: "$names=@", in: lines)
        let nonce = lines.compactMap { line -> String? in
            guard line.hasPrefix("say '__HEELER_PROC_END_") else { return nil }
            return String(line.dropFirst("say '__HEELER_PROC_END_".count).dropLast())
        }.first ?? ""

        func read(_ pid: Int) -> [String] {
            let process = processes[pid]
            var out: [String] = []
            out.append("S \(pid) \(process?.start ?? "-")")
            if !wanted.isEmpty || !named.isEmpty {
                if let environment = process?.environment {
                    for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
                        let key = name.uppercased()
                        if wanted.contains(key) {
                            let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
                            out.append("V \(pid) \(key == "USERPROFILE" ? "HOME" : key) \(hex.isEmpty ? "-" : hex)")
                        }
                        if !value.isEmpty, named.contains(key) { out.append("N \(pid) \(key)") }
                    }
                    out.append("E \(pid) ok")
                } else {
                    out.append("E \(pid) -")
                }
            }
            out.append("O \(pid) -")
            out.append("B \(pid) -")
            return out
        }

        var printed = ["", "__HEELER_PROC_BEGIN_\(nonce)"]
        for id in ids {
            if let pid = Int(id) { printed += read(pid) }
        }
        if root != 0 {
            if let top = processes[root] { printed.append("T \(root) \(top.parent) \(top.image)") }
            var walk: [Int] = []
            var queue = [root]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                let children = processes.values.filter { $0.parent == next && $0.pid != next }.map(\.pid).sorted()
                walk += children
                queue += children
            }
            for pid in walk {
                if let process = processes[pid] { printed.append("T \(pid) \(process.parent) \(process.image)") }
            }
            printed.append("W \(root) ok")
            for pid in walk { printed += read(pid) }
        }
        printed += ["", "__HEELER_PROC_END_\(nonce)", ""]
        return printed.joined(separator: "\n")
    }

    private static func value(of prefix: String, in lines: [String]) -> String? {
        lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    /// `@('A','B')`, by upper-case name, as PowerShell's `-contains` compares.
    private static func names(of prefix: String, in lines: [String]) -> Set<String> {
        guard let body = value(of: prefix, in: lines)?.dropFirst().dropLast() else { return [] }
        return Set(body.split(separator: ",").map { $0.dropFirst().dropLast().uppercased() })
    }
}
