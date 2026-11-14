import Foundation

/// The experimental switch for Rex Hosts (ADR 0047), off by default. A Debug
/// build turns it on when it starts with `--rex-hosts` or finds the
/// `experimental.rexHosts` default set; a Release build has no way to turn it
/// on, and no screen shows it. Read once, so it holds for the whole process.
///
/// Off, the app is a build that does not know Rex: detection does not look for
/// it, no Host can be confirmed as one, and Rex Hosts already stored stay in
/// their own catalog, unlisted and never dialed. Code that decides by it takes
/// the value as a parameter defaulting to `isEnabled`, so tests pass their own.
enum RexHostsExperiment {
    static let launchArgument = "--rex-hosts"
    static let defaultsKey = "experimental.rexHosts"

    static let isEnabled: Bool = {
        #if DEBUG
            ProcessInfo.processInfo.arguments.contains(launchArgument)
                || UserDefaults.standard.bool(forKey: defaultsKey)
        #else
            false
        #endif
    }()
}
