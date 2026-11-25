import Foundation

/// Where a New Agent's Worktree for a pull request or an issue starts
/// (ADR 0065), in a checkout of the item's repository, in two execs. The
/// first fetches the commit from that checkout's own remote as a gh request
/// would run (`GitHubCLIScript`), so on a Mac a fetch that fails over SSH,
/// whose credential helper cannot read the login keychain, runs once more
/// in the desktop session. The second, with no network step, answers with
/// the commit, so the Worktree is made from it on any Server Kind, and for
/// the pull request's own branch makes that branch, or moves it forward to
/// the pull request's commits, so the Worktree checks it out.
struct GitHubWorktreeStart: Sendable, Equatable {
    /// What the Worktree starts from.
    enum Source: Sendable, Equatable {
        /// The pull request's head commit, which GitHub keeps at
        /// `refs/pull/<number>/head` for a fork's pull request too.
        case pullRequest(number: Int, headBranch: String, isCrossRepository: Bool)
        /// The tip of the repository's default branch, for an issue.
        case defaultBranch(String)
    }

    /// The checkout's top level, where git runs.
    let directory: String
    /// The checkout's remote that names the item's repository.
    let remote: String
    let source: Source
    /// The Worktree's branch, as the form has it.
    let branch: String
    /// `branch` is the pull request's own, which the script makes or moves
    /// forward to the pull request's commits. A fork's pull request from a
    /// branch named as the repository's default one has none: that name is
    /// the user's own branch.
    let isPullRequestBranch: Bool

    static let cap = 4_096

    /// How old, in seconds by the clocks of the devices that named them,
    /// another start's private ref must be before a start in the same
    /// repository removes it: one a dropped connection left between the two
    /// execs. A start's own lives for its fetch, at most the seam's 60
    /// seconds, and the time to its second exec.
    static let staleRefSeconds = 300

    /// The ref a start's fetch writes, named by when the start began, so a
    /// later start can tell one left behind.
    static func privateRef(at epoch: Int, nonce: String) -> String {
        "refs/heeler/start/\(epoch)-\(nonce)"
    }

    /// What git is asked to fetch.
    var fetchedRef: String {
        switch source {
        case .pullRequest(let number, _, _): "refs/pull/\(number)/head"
        case .defaultBranch(let name): "refs/heads/\(name)"
        }
    }

    /// The branch a pull request from the repository itself tracks once the
    /// script makes it, so a push updates the pull request.
    private var trackedBranch: String? {
        guard case .pullRequest(_, let head, let isCrossRepository) = source, !isCrossRepository,
            isPullRequestBranch
        else { return nil }
        return head
    }

    /// A fork's pull request, whose branch name may also be a branch of the
    /// checkout's remote.
    private var isFromFork: Bool {
        if case .pullRequest(_, _, true) = source { return true }
        return false
    }

    /// The fetch, the start's one network step: plain git, from the remote
    /// by name so its own settings and credential helper apply, into
    /// `privateRef` rather than FETCH_HEAD, which an Agent fetching in the
    /// same checkout could replace before it is read. For a pull request's
    /// branch that will track the remote's, that branch is fetched after it,
    /// best effort: the pull request's ref leaves the upstream missing, and
    /// `git status` would call it gone, while a merged pull request's branch
    /// may be deleted. The fetch's descriptors are `/dev/null` and files in
    /// the gh script's folder, so git's detached maintenance, which a fetch
    /// over the repository's auto-gc limit starts, holds nothing of the exec.
    func fetchRequest(into privateRef: String) -> GitHubCLIRequest {
        let fetch = ["-C", directory, "fetch", "--quiet", "--no-tags", remote]
        return GitHubCLIRequest(
            arguments: fetch + ["+\(fetchedRef):\(privateRef)"], isMutation: false,
            program: .git(andThen: trackedBranch.map { fetch + ["refs/heads/\($0)"] }))
    }

    /// Why the fetch gave no commit, or nil when it gave one. git's line is
    /// from its last run: on a Mac, the desktop session's once that ran, and
    /// the exec's when the desktop session was missing or too slow.
    func fetchFailure(_ outcome: GitHubCLIOutcome) -> GitHubWorktreeStartFailure? {
        guard let run = outcome.run, let status = run.exitStatus else { return .incomplete }
        guard status != 0 else { return nil }
        let reason = run.errorOutput.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return .fetchFailed(ref: fetchedRef, remote: remote, reason: reason)
    }

    /// The second exec: the commit `fetchedInto` holds, and the branch's
    /// rules. `now` is the device's clock in seconds since 1970.
    func script(nonce: String, fetchedInto: String, now: Int) -> Data {
        // The fetched ref is read and deleted first, whatever follows, and
        // other starts' refs left past `staleRefSeconds` go with it. Then a
        // branch checked out in a Worktree of this repository: git refuses
        // to check it out twice, and moving it would move that checkout's
        // HEAD under it. For a fork's pull request, a branch that belongs to
        // the remote is left alone: moving or making it would send a later
        // push to the repository. A branch that exists keeps commits the
        // pull request does not have: it is moved only forward, by `git
        // branch -f`, which git 2.35 and later refuse for a branch a
        // Worktree is rebasing or bisecting on a detached HEAD, where
        // `worktree list` names no branch.
        var body = Data(
            """
            wt() {
              d=$1 r=$2 b=$3 own=$4 track=$5 fork=$6 tmp=$7 now=$8
              s=$(g -C "$d" rev-parse -q --verify "$tmp^{commit}")
              g -C "$d" update-ref -d "$tmp" 2>/dev/null
              g -C "$d" for-each-ref --format='%(refname)' refs/heeler/start/ 2>/dev/null |
                while IFS= read -r x; do
                  e=${x#refs/heeler/start/}
                  e=${e%%-*}
                  case $e in
                    '' | 0* | *[!0-9]*) ;;
                    *) [ $((now - e)) -gt \(Self.staleRefSeconds) ] || continue ;;
                  esac
                  g -C "$d" update-ref -d "$x" 2>/dev/null
                done
              [ -n "$s" ] || return 5
              list=$(g -C "$d" worktree list --porcelain) || return 3
              p=$(printf '%s\\n' "$list" | awk -v want="branch refs/heads/$b" 'index($0, "worktree ") == 1 { p = substr($0, 10) } $0 == want { print p; exit }')
              if [ -n "$p" ]; then printf 'busy %s\\n' "$p"; return 0; fi
              if [ "$own" = 1 ] && [ "$fork" = 1 ]; then
                if g -C "$d" show-ref -q --verify "refs/remotes/$r/$b" ||
                  g -C "$d" config --get "branch.$b.remote" >/dev/null ||
                  g -C "$d" config --get "branch.$b.merge" >/dev/null; then
                  printf 'remote\\n'; return 0
                fi
              fi
              if [ "$own" = 1 ]; then
                if c=$(g -C "$d" rev-parse -q --verify "refs/heads/$b^{commit}"); then
                  if [ "$c" != "$s" ] && ! g -C "$d" merge-base --is-ancestor "$s" "$c"; then
                    if g -C "$d" merge-base --is-ancestor "$c" "$s"; then
                      git -C "$d" branch -f --no-track "$b" "$s" >/dev/null || return 7
                    else
                      printf 'diverged\\n'; return 0
                    fi
                  fi
                else
                  git -C "$d" branch --no-track "$b" "$s" >/dev/null || return 6
                  if [ -n "$track" ]; then
                    git -C "$d" config "branch.$b.remote" "$r" &&
                      git -C "$d" config "branch.$b.merge" "refs/heads/$track" || return 6
                  fi
                fi
              fi
              printf 'start %s\\n' "$s"
            }

            """.utf8)
        body.append(Data("sec \(Self.cap) start wt ".utf8))
        let arguments = [
            directory, remote, branch, isPullRequestBranch ? "1" : "0", trackedBranch ?? "",
            isFromFork ? "1" : "0", fetchedInto, String(now),
        ]
        for argument in arguments {
            body.append(GitProbe.singleQuoted(Data(argument.utf8)))
            body.append(Data(" ".utf8))
        }
        body.append(Data("\n".utf8))
        return GitProbe.script(nonce: nonce, body: body)
    }

    /// The commit to start from, or why there is none.
    func result(of output: GitExecResult, nonce: String) -> Result<String, GitHubWorktreeStartFailure> {
        let frames = GitProbe.Frames(stdout: output.stdout, stderr: output.stderr, nonce: nonce)
        guard let section = try? frames.section("start", cap: Self.cap) else {
            return .failure(.incomplete)
        }
        let line = String(decoding: section.body, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        switch section.status {
        case 0:
            if line.hasPrefix("start "), let commit = line.split(separator: " ").last, commit.count >= 40 {
                return .success(String(commit))
            }
            if line.hasPrefix("busy ") {
                return .failure(.checkedOut(branch: branch, directory: String(line.dropFirst("busy ".count))))
            }
            if line == "diverged" { return .failure(.diverged(branch: branch)) }
            if line == "remote" { return .failure(.remoteBranch(branch: branch)) }
            return .failure(.incomplete)
        case 7:
            return .failure(.notMoved(branch: branch, reason: section.firstMessageLine))
        default:
            return .failure(.gitFailed(
                section.firstMessageLine ?? String(localized: "git exited with status \(section.status).")))
        }
    }
}

/// Why a Worktree for a pull request or an issue has no starting commit.
enum GitHubWorktreeStartFailure: Error, Equatable {
    case checkedOut(branch: String, directory: String)
    /// The branch on the Host has commits the pull request does not.
    case diverged(branch: String)
    /// A fork's pull request named a branch that follows the checkout's
    /// remote, or one the remote has.
    case remoteBranch(branch: String)
    /// git would not move the branch forward, as when a Worktree is
    /// rebasing it.
    case notMoved(branch: String, reason: String?)
    case fetchFailed(ref: String, remote: String, reason: String?)
    case gitFailed(String)
    /// The script's answer did not arrive whole.
    case incomplete
    /// The Host could not run it, as the connection says.
    case unreachable(String)

    var message: String {
        switch self {
        case .checkedOut(let branch, let directory):
            String(localized: "\(branch) is already checked out in \(directory).")
        case .diverged(let branch):
            String(localized: "\(branch) on the Host has commits the pull request does not, so Heeler left it as it is. Name another branch to start one from the pull request.")
        case .remoteBranch(let branch):
            String(localized: "\(branch) on the Host belongs to a remote, and this pull request comes from a fork, so Heeler left it as it is. Name another branch to start one from the pull request.")
        case .notMoved(let branch, let reason?):
            String(localized: "git would not move \(branch) on the Host to the pull request's commits, so Heeler left it as it is: \(reason)")
        case .notMoved(let branch, nil):
            String(localized: "git would not move \(branch) on the Host to the pull request's commits, so Heeler left it as it is.")
        case .fetchFailed(let ref, let remote, let reason?):
            String(localized: "git could not fetch \(ref) from \(remote): \(reason)")
        case .fetchFailed(let ref, let remote, nil):
            String(localized: "git could not fetch \(ref) from \(remote).")
        case .gitFailed(let reason):
            String(localized: "git could not get the worktree's starting commit: \(reason)")
        case .incomplete:
            String(localized: "The Host did not finish getting the worktree's starting commit.")
        case .unreachable(let reason):
            reason
        }
    }
}
