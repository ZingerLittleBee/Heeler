import Foundation

/// The small, bounded plugin response carried by one ordinary SSH exec.
/// Transcript paths and credentials never enter this protocol.
enum AgentUsageProbe {
    static func script(
        pluginRoot: String, timeZone: String, claudeLimits: Bool,
        nonce: String, launcher: HerdrLauncher?
    ) throws -> Data {
        guard TimeZone.knownTimeZoneIdentifiers.contains(timeZone) || timeZone == "UTC",
            pluginRoot.hasPrefix("/"), !pluginRoot.utf8.contains(0),
            !nonce.isEmpty, nonce.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || $0 == 45
            })
        else {
            throw TransportError.malformedResponse("The Usage query arguments are invalid.")
        }
        let configCommand: String
        let environment: String
        if let launcher,
            let executable = RemoteShellPath.quotedAbsolute(launcher.executablePath),
            let socket = RemoteShellPath.quotedAbsolute(launcher.socketPath)
        {
            environment = "export HERDR_SOCKET_PATH=\(socket)"
            configCommand = "\(executable) plugin config-dir heeler"
        } else {
            environment = HerdrHostPath.pathExport
            configCommand = "herdr plugin config-dir heeler"
        }
        let query = GitProbe.singleQuoted(pluginRoot + "/src/usage-query.js")
        let flags = claudeLimits ? " --claude-limits" : ""
        // Cap the entire framed response. Truncation removes the end marker,
        // so a plausible JSON prefix can never become a successful read.
        let script = """
            export LC_ALL=C
            (
              printf '%s\\n' '__HEELER_USAGE_BEGIN_\(nonce)'
              \(environment)
              usage_read() {
                config=$(\(configCommand)) || return $?
                case "$config" in /*) ;; *) return 1 ;; esac
                export HERDR_PLUGIN_CONFIG_DIR="$config"
                if ! IFS= read -r node < "$config/runtime-node"; then
                  printf '%s' '{"version":1,"runtime":"missing"}'
                  return 0
                fi
                case "$node" in
                  /*) ;;
                  *) printf '%s' '{"version":1,"runtime":"missing"}'; return 0 ;;
                esac
                "$node" \(query) --tz '\(timeZone)'\(flags)
                result=$?
                case "$result" in
                  126|127) printf '%s' '{"version":1,"runtime":"missing"}'; return 0 ;;
                  *) return "$result" ;;
                esac
              }
              usage_read
              result=$?
              printf '\\n%s:%s\\n' '__HEELER_USAGE_END_\(nonce)' "$result"
            ) | head -c 1048576
            """
        return Data((script + "\n").utf8)
    }

    static func parse(stdout: Data, nonce: String) throws -> AgentUsageReport {
        let beginBytes = Data("__HEELER_USAGE_BEGIN_\(nonce)\n".utf8)
        let endBytes = Data("\n__HEELER_USAGE_END_\(nonce):".utf8)
        guard let begin = stdout.range(of: beginBytes),
            let end = stdout.range(of: endBytes, in: begin.upperBound..<stdout.endIndex),
            let statusEnd = stdout[end.upperBound...].firstIndex(of: 10),
            String(decoding: stdout[end.upperBound..<statusEnd], as: UTF8.self) == "0"
        else {
            throw TransportError.malformedResponse("The Host did not finish its Usage response.")
        }
        return try AgentUsageReport.decode(Data(stdout[begin.upperBound..<end.lowerBound]))
    }
}
