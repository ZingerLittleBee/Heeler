import Foundation

@testable import Heeler

/// A macOS Host's processes as `HostProcessReader`'s macOS script reports them: the
/// lines one exec prints, parsed by the real parser. It answers only what a request
/// names, and counts each request as the exec it is.
actor MacOSProcessTable {
    private static let nonce = "0123456789abcdef01234567"

    private var rows: [Int: ScriptedProcessTable.Process] = [:]
    /// Apple's platform binaries, whose environment macOS withholds.
    private var withholdsEnvironment: Set<Int> = []
    /// Answers `-` for every process's open files, as a missing `lsof` does.
    private var answersOpenFiles = true
    /// Answers `-` for every process's start.
    private var answersStart = true
    /// More processes under the root than the walk's cap.
    private var isPastTheWalksCap = false

    private(set) var requests: [HostProcessReader.Request] = []

    init(_ rows: [HostEvidenceFixture.Row] = []) {
        for row in rows { self.rows[row.pid] = row.process }
    }

    func add(_ process: ScriptedProcessTable.Process) { rows[process.pid] = process }

    func remove(_ pid: Int) { rows[pid] = nil }

    func withholdEnvironment(of pid: Int) { withholdsEnvironment.insert(pid) }

    func stopAnsweringOpenFiles() { answersOpenFiles = false }

    func stopAnsweringStart() { answersStart = false }

    func goPastTheWalksCap() { isPastTheWalksCap = true }

    func read(_ request: HostProcessReader.Request) throws -> [String: HostProcessReader.Facts] {
        requests.append(request)
        return try HostProcessReader.parse(stdout: Data(render(request).utf8), nonce: Self.nonce, request: request)
    }

    private func render(_ request: HostProcessReader.Request) -> String {
        var lines = [HostProcessReader.beginMarker(Self.nonce)]
        for pid in request.pids { lines += self.lines(about: pid, request) }
        if let root = request.descendantsOf {
            let walked = walk(from: root)
            if isPastTheWalksCap {
                lines.append("W \(root) -")
            } else {
                if let number = Int(root), let row = rows[number] {
                    lines.append("T \(root) \(row.parent) \(row.name)")
                }
                for pid in walked {
                    if let row = rows[pid] { lines.append("T \(pid) \(row.parent) \(row.name)") }
                }
                lines.append("W \(root) ok")
                for pid in walked { lines += self.lines(about: String(pid), request) }
            }
        }
        lines += ["", HostProcessReader.endMarker(Self.nonce), ""]
        return lines.joined(separator: "\n")
    }

    /// Breadth first from the root, as the script's awk goes.
    private func walk(from root: String) -> [Int] {
        guard let start = Int(root) else { return [] }
        var found: [Int] = []
        var level = [start]
        while !level.isEmpty {
            level = rows.values.filter { level.contains($0.parent) }.map(\.pid).sorted()
            found += level
        }
        return found
    }

    /// The lines of `s`, `e`, `f` and `a` for one process. One that ended reads as
    /// the script finds it: no start, an empty environment read, no descriptors.
    private func lines(about pid: String, _ request: HostProcessReader.Request) -> [String] {
        let row = Int(pid).flatMap { rows[$0] }
        var lines: [String] = []
        if request.readsStart {
            // `lstart` pads its end.
            lines.append(answersStart ? "S \(pid) \(row.map { "\($0.start)    " } ?? "-")" : "S \(pid) -")
        }
        if request.readsEnvironment {
            if let row, let number = Int(pid), !withholdsEnvironment.contains(number) {
                for name in request.valuesOf {
                    guard let value = row.environment[name] else { continue }
                    lines.append("V \(pid) \(name) \(value.isEmpty ? "-" : Self.hex(value))")
                }
                for name in request.namesOf where row.environment[name]?.isEmpty == false {
                    lines.append("N \(pid) \(name)")
                }
                lines.append("E \(pid) ok")
            } else {
                lines.append("E \(pid) -")
            }
        }
        if request.readsOpenFiles {
            if let row, answersOpenFiles {
                lines += row.openFiles.map { "G \(pid) \($0)" }
                lines.append("O \(pid) ok")
            } else {
                lines.append("O \(pid) -")
            }
        }
        if request.readsArguments {
            if let row {
                lines += request.argumentsAmong.filter(row.argv.contains).map { "A \(pid) \(Self.hex($0))" }
                lines.append("B \(pid) ok")
            } else {
                lines.append("B \(pid) -")
            }
        }
        return lines
    }

    private static func hex(_ text: String) -> String {
        text.utf8.map { String(format: "%02x", $0) }.joined()
    }
}
