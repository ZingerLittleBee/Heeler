import Foundation

/// Asks omp on the Host how large a model's context window is (#325).
///
/// The session file names the model (`provider` and `model` on each
/// assistant turn) but not its window; omp keeps that in its model registry,
/// which `omp models ls <selector> --json` prints. The pattern is a substring
/// filter, so `gpt-6-astra` also lists `devin/gpt-6-astra`; the answer is
/// taken from the entry whose `selector` matches exactly.
enum AgentModelProbe {
    /// `provider/model` as omp spells it. Only these characters occur in
    /// omp's selectors; anything else is refused before it reaches a shell.
    static func isValidSelector(_ selector: String) -> Bool {
        !selector.isEmpty && selector.count <= 200
            && selector.contains("/")
            && selector.unicodeScalars.allSatisfy { scalar in
                scalar.properties.isAlphabetic && scalar.isASCII
                    || ("0"..."9").contains(scalar)
                    || "._:/-+@".unicodeScalars.contains(scalar)
            }
    }

    /// The exec command, run under `/bin/sh` with the extra prefixes so a
    /// mise-managed omp is found from a non-interactive shell (#293), the
    /// way a bare `herdr` is. `nil` for a selector that cannot be quoted.
    static func command(selector: String) -> String? {
        guard isValidSelector(selector) else { return nil }
        return "/bin/sh -c '\(HerdrHostPath.pathExport); "
            + "exec omp models ls \(selector) --json'"
    }

    /// The window of the entry whose `selector` matches exactly, or `nil`
    /// when the output names no such model or is not omp's.
    static func contextWindow(in output: Data, selector: String) -> Int? {
        guard
            let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
            let models = object["models"] as? [[String: Any]],
            let match = models.first(where: { $0["selector"] as? String == selector }),
            let window = match["contextWindow"] as? NSNumber
        else { return nil }
        let value = window.doubleValue
        guard value.isFinite, value >= 1, value <= Double(Int32.max) else { return nil }
        return Int(value)
    }
}
