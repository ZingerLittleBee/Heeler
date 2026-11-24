import Foundation

/// Where a New Agent's Worktree for a pull request or an issue starts
/// (ADR 0064): one script through the gh seam, in a checkout of the item's
/// repository, fetches the commit from that checkout's own remote and
/// answers with it, so the Worktree is made from it on any Server Kind.
/// For the pull request's own branch it also makes that branch, or moves it
/// forward to the pull request's commits, so the Worktree checks it out.
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

    func script(nonce: String) -> Data {
        // A branch checked out in a Worktree of this repository first: git
        // refuses to check it out twice, and moving it would move that
        // checkout's HEAD under it. For a fork's pull request, a branch that
        // belongs to the remote is left alone: moving or making it would send
        // a later push to the repository. Then the fetch, from the remote by
        // name so its own settings apply. Over the repository's auto-gc limit
        // it starts git's detached maintenance, which would hold the frame's
        // descriptors open until it ends, so the fetch runs without them. It
        // fetches into a ref of this request's own, not FETCH_HEAD, which an
        // Agent fetching in the same checkout could replace before it is
        // read; the ref goes as soon as it is read, whatever happened. A
        // branch that exists keeps commits the pull request does not have:
        // it is moved only forward, by `git branch -f`, which git 2.35 and
        // later refuse for a branch a Worktree is rebasing or bisecting on a
        // detached HEAD, where `worktree list` names no branch. A branch made
        // to track the remote's has that branch fetched too, best effort:
        // the pull request's ref leaves the upstream missing, and `git
        // status` would call it gone.
        var body = Data(
            """
            wt() {
              d=$1 r=$2 ref=$3 b=$4 own=$5 track=$6 fork=$7 tmp=$8
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
              git -C "$d" fetch --quiet --no-tags "$r" "+$ref:$tmp" </dev/null 3>&- 4>&-; e=$?
              s=$(g -C "$d" rev-parse -q --verify "$tmp^{commit}")
              g -C "$d" update-ref -d "$tmp"
              [ "$e" = 0 ] || return 4
              [ -n "$s" ] || return 5
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
                    git -C "$d" fetch --quiet --no-tags "$r" "refs/heads/$track" </dev/null >/dev/null 2>&1 3>&- 4>&-
                  fi
                fi
              fi
              printf 'start %s\\n' "$s"
            }

            """.utf8)
        body.append(Data("sec \(Self.cap) start wt ".utf8))
        let arguments = [
            directory, remote, fetchedRef, branch, isPullRequestBranch ? "1" : "0", trackedBranch ?? "",
            isFromFork ? "1" : "0", "refs/heeler/start/\(nonce)",
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
        case 4:
            return .failure(.fetchFailed(ref: fetchedRef, remote: remote, reason: section.firstMessageLine))
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
