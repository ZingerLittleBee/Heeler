import Foundation

/// Where a core Host's Worktree goes and what git is asked, as the Herdr desktop
/// app's worktree mod does it, so both clients share one checkout (ADR 0032).
enum HerdrCoreWorktrees {
    /// The folder name of a branch: each run of characters other than ASCII
    /// letters, digits, `.`, `_` and `-` is one `-`, and `-` at either end goes.
    static func slug(_ branch: String) -> String {
        var slug = String.UnicodeScalarView()
        var isInRun = false
        for scalar in branch.unicodeScalars {
            if isSlugScalar(scalar) {
                slug.append(scalar)
                isInRun = false
            } else if !isInRun {
                slug.append("-")
                isInRun = true
            }
        }
        return String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isSlugScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": true
        default: false
        }
    }

    /// Nil when the branch leaves no folder of its own: the mod would land on the
    /// repository's folder or above it.
    static func checkoutPath(home: String, mainCheckout: String, branch: String) -> String? {
        let slug = slug(branch)
        guard !["", ".", ".."].contains(slug) else { return nil }
        return "\(home)/.herdr/worktrees/\(repositoryName(mainCheckout: mainCheckout))/\(slug)"
    }

    static func repositoryName(mainCheckout: String) -> String {
        (mainCheckout as NSString).lastPathComponent
    }

    static func branchExistsArguments(branch: String) -> [String] {
        ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"]
    }

    static func addArguments(path: String, branch: String, branchExists: Bool) -> [String] {
        branchExists
            ? ["worktree", "add", path, branch]
            : ["worktree", "add", "-b", branch, path, "HEAD"]
    }

    /// Never names the branch, which stays.
    static func removeArguments(path: String, force: Bool) -> [String] {
        ["worktree", "remove"] + (force ? ["--force"] : []) + [path]
    }

    static let listArguments = ["worktree", "list", "--porcelain"]

    /// `git worktree list --porcelain`, whose first block is the main checkout.
    static func parseList(_ porcelain: String) -> [WorktreeInfo] {
        var entries: [WorktreeInfo] = []
        for block in porcelain.split(separator: "\n\n") {
            let lines = block.split(separator: "\n")
            guard let path = value(of: "worktree", in: lines) else { continue }
            let branch = value(of: "branch", in: lines).map { name in
                name.hasPrefix("refs/heads/") ? String(name.dropFirst("refs/heads/".count)) : name
            }
            entries.append(
                WorktreeInfo(
                    isBare: lines.contains("bare"),
                    isDetached: lines.contains("detached"),
                    isLinkedWorktree: !entries.isEmpty,
                    isPrunable: lines.contains { $0 == "prunable" || $0.hasPrefix("prunable ") },
                    label: branch ?? (path as NSString).lastPathComponent,
                    path: path,
                    branch: branch))
        }
        return entries
    }

    private static func value(of key: String, in lines: [Substring]) -> String? {
        lines.first { $0.hasPrefix("\(key) ") }.map { String($0.dropFirst(key.count + 1)) }
    }
}

/// Why a new Worktree did not come to be.
enum HerdrCoreWorktreeError: Error, Equatable {
    case invalidBranch(String)
    case noFolderName(branch: String)
    case notInGitRepository
    case addRefused(String)
    case addUnconfirmed(path: String)

    var message: String {
        switch self {
        case .invalidBranch(let problem):
            problem
        case .noFolderName(let branch):
            String(localized: "\"\(branch)\" leaves no folder name for the checkout. Use a branch with ASCII letters or digits in it.")
        case .notInGitRepository:
            String(localized: "This workspace is not inside a Git repository, so no worktree can be created from it.")
        case .addRefused(let reason):
            String(localized: "Creating the worktree failed: \(reason)")
        case .addUnconfirmed(let path):
            String(localized: "The Host did not confirm the worktree. Check whether \(path) is on the Host before trying again.")
        }
    }
}

/// A Template asked for by name that is not one any more.
enum HerdrCoreTemplateError: Error, Equatable {
    /// Seen before anything ran.
    case gone(String)
    /// Seen in the answer, so a program of that name is already running.
    case ranAsProgram(String, directory: String)

    var message: String {
        switch self {
        case .gone(let name):
            String(localized: "\(name) is no longer a Template on this Host, so nothing started. Detect Again refreshes the list.")
        case .ranAsProgram(let name, let directory):
            String(localized: "\(name) is no longer a Template on this Host, so the core ran a program of that name in a Terminal at \(directory). Close it if you did not mean to run it.")
        }
    }
}

/// The core answered a kill with a refusal, which left its Terminal running. On a
/// Herdr TUI Host a close's `HerdrAPIError` can mean the Pane is gone already; a
/// core says that with `not_found`, which never gets this far.
struct HerdrCoreCloseRefusal: Error, Equatable {
    let message: String
}

/// The checkout exists and only the Agent is missing, so another try with this
/// branch would find it taken.
struct WorktreeAgentStartFailure: Error {
    let checkoutPath: String
    let underlying: any Error
}

/// A Worktree's git on one Host, each command in its own turn at the Host's gate.
struct HerdrCoreWorktreeGit: Sendable {
    let services: any HostServices
    let gate: GitExecGate

    struct Created: Equatable, Sendable {
        let path: String
        let mainCheckout: String
    }

    private func run(_ command: GitCommand) async throws -> GitCommandResult {
        try await gate.run { try await services.runGitCommand(command) }
    }

    private func read(_ arguments: [String], in directory: String) async throws -> GitCommandResult {
        try await run(GitCommand(arguments: arguments, directory: directory, isMutation: false))
    }

    /// One `git worktree add`, in the checkout it starts from so a new branch
    /// begins at that checkout's HEAD.
    func create(branch: String, from directory: String) async throws -> Created {
        if let problem = GitBranchName.validationError(branch) {
            throw HerdrCoreWorktreeError.invalidBranch(problem)
        }
        let answers = try await gate.run { try await services.checkouts(for: [directory]) }
        guard let checkout = answers[directory], let mainCheckout = checkout.mainCheckout else {
            throw HerdrCoreWorktreeError.notInGitRepository
        }
        let home = try await services.hostHomeDirectory()
        guard
            let path = HerdrCoreWorktrees.checkoutPath(
                home: home, mainCheckout: mainCheckout, branch: branch)
        else { throw HerdrCoreWorktreeError.noFolderName(branch: branch) }

        let lookup = try await read(
            HerdrCoreWorktrees.branchExistsArguments(branch: branch), in: mainCheckout)
        guard lookup.status <= 1 else {
            throw HerdrCoreWorktreeError.addRefused(
                lookup.message ?? String(localized: "git exited with status \(lookup.status)."))
        }
        let result: GitCommandResult
        do {
            result = try await run(
                GitCommand(
                    arguments: HerdrCoreWorktrees.addArguments(
                        path: path, branch: branch, branchExists: lookup.status == 0),
                    directory: checkout.root, isMutation: true))
        } catch {
            throw HerdrCoreWorktreeError.addUnconfirmed(path: path)
        }
        guard result.status == 0 else {
            throw HerdrCoreWorktreeError.addRefused(
                result.message ?? String(localized: "git exited with status \(result.status)."))
        }
        return Created(path: path, mainCheckout: mainCheckout)
    }

    /// Asks git, not the inventory, that this path is still that repository's
    /// linked Worktree. Throws `.staleIdentity` otherwise, with nothing changed.
    func verifiedMainCheckout(of identity: WorktreeIdentity) async throws -> String {
        let path = identity.checkoutPath
        let answers = try await gate.run { try await services.checkouts(for: [path]) }
        guard let checkout = answers[path], checkout.root == path, checkout.isLinkedWorktree,
            let mainCheckout = checkout.mainCheckout, mainCheckout == identity.repoKey
        else { throw WorktreeRemovalError.staleIdentity }
        return mainCheckout
    }

    /// What a removal would lose. `git status` says nothing of a submodule, so
    /// `git submodule status` lists them, checked out or not, as the desktop app's
    /// `.gitmodules` read does. It fails on one it cannot map, which still counts.
    func removalRisk(ofCheckout path: String) async throws -> WorktreeRemovalRisk {
        let status = try await read(["status", "--porcelain"], in: path)
        guard status.status == 0 || status.isTruncated else {
            throw WorktreeRemovalError.riskUnread(
                status.message ?? String(localized: "git exited with status \(status.status)."))
        }
        let submodules = try await read(["submodule", "status"], in: path)
        return WorktreeRemovalRisk(
            hasChanges: !status.output.isEmpty,
            hasSubmodules: submodules.status != 0 || !submodules.output.isEmpty)
    }

    /// The same read with the Terminals gone, when failing to answer means they
    /// did end and the checkout stays.
    func riskOnceTerminalsEnded(ofCheckout path: String) async throws -> WorktreeRemovalRisk {
        do {
            return try await removalRisk(ofCheckout: path)
        } catch WorktreeRemovalError.riskUnread(let reason) {
            throw WorktreeRemovalError.removeRefused(reason)
        } catch {
            throw WorktreeRemovalError.removeRefused(String(localized: "The Host did not say what the checkout holds."))
        }
    }

    /// One `git worktree remove`, which keeps the branch.
    func remove(path: String, mainCheckout: String, force: Bool) async throws {
        let result: GitCommandResult
        do {
            result = try await run(
                GitCommand(
                    arguments: HerdrCoreWorktrees.removeArguments(path: path, force: force),
                    directory: mainCheckout, isMutation: true))
        } catch {
            throw WorktreeRemovalError.removeUnconfirmed(path: path)
        }
        guard result.status == 0 else {
            throw WorktreeRemovalError.removeRefused(
                result.message ?? String(localized: "git exited with status \(result.status)."))
        }
    }

    func list(in checkout: String) async throws -> [WorktreeInfo] {
        let result = try await read(HerdrCoreWorktrees.listArguments, in: checkout)
        guard result.status == 0 else {
            throw TransportError.malformedResponse(
                result.message ?? String(localized: "git exited with status \(result.status)."))
        }
        return HerdrCoreWorktrees.parseList(result.output)
    }
}
