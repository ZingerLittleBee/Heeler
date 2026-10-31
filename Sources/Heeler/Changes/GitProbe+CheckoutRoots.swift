import Foundation

extension GitProbe.Cap {
    /// One directory's top level: well past any platform's longest path.
    static let checkoutRoot = 8_192
}

/// The checkout root of each directory, in one script: what names a Herdr
/// desktop space nobody named (ADR 0032). The call is capped so one exec stays
/// short whatever a core's Terminals hold, and a directory git has no answer
/// for has no entry, as outside a checkout it names itself.
extension GitProbe {
    static let checkoutRootsPerCall = 16

    /// The directories one call asks about. No path is empty or holds a NUL,
    /// and either would mean something else to the script.
    static func checkoutRootDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        let askable = directories.filter { directory in
            !directory.isEmpty && !directory.utf8.contains(0) && seen.insert(directory).inserted
        }
        return Array(askable.prefix(checkoutRootsPerCall))
    }

    private static func checkoutRootSection(_ index: Int) -> String {
        "root\(index)"
    }

    /// Each path is single-quoted and goes to `-C` as one word, whatever it holds.
    static func checkoutRootsScript(directories: [String], nonce: String) -> Data {
        var body = Data()
        for (index, directory) in checkoutRootDirectories(directories).enumerated() {
            body.append(Data("dir=".utf8))
            body.append(singleQuoted(Data(directory.utf8)))
            let section = checkoutRootSection(index)
            let command =
                "\nsec \(Cap.checkoutRoot) \(section) g -C \"$dir\" rev-parse --show-toplevel\n"
            body.append(Data(command.utf8))
        }
        return script(nonce: nonce, body: body)
    }

    /// Throws `ChangesReadError.incomplete` when the script did not run to its
    /// end. One directory's failure is that directory's alone.
    static func parseCheckoutRoots(
        stdout: Data, stderr: Data, nonce: String, directories: [String]
    ) throws -> [String: String] {
        let frames = Frames(stdout: stdout, stderr: stderr, nonce: nonce)
        guard frames.reachedEnd else { throw ChangesReadError.incomplete }
        var roots: [String: String] = [:]
        for (index, directory) in checkoutRootDirectories(directories).enumerated() {
            let section = try frames.requiredSection(
                checkoutRootSection(index), cap: Cap.checkoutRoot)
            guard section.status == 0, !section.isTruncated else { continue }
            var body = section.body
            if body.last == 0x0A { body.removeLast() }
            if !body.isEmpty { roots[directory] = String(decoding: body, as: UTF8.self) }
        }
        return roots
    }
}
