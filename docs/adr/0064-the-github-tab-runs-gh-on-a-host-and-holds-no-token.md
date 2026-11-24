---
status: accepted
---

# The GitHub tab runs gh on a Host and holds no token

Agents open pull requests and get asked for reviews, and the user wants to
see where those stand from the phone. The machines Heeler connects to often
have the GitHub CLI installed and signed in already. The maintainer decided
on 2026-11-24 that Heeler reads GitHub by running that `gh` over the Host's
existing SSH connection, and never sees, stores or carries a GitHub token.
This ADR covers the read-only list (the GitHub tab), a pull request's or an
issue's detail, and Send to Agent; later actions build on the same seam.

## Decision

- **gh runs where it already is.** One bounded exec of POSIX `sh`
  (`GitHubCLIScript`, through `HostServices.runGitHubScript`) finds `gh` on
  the Host's `PATH` plus the directories the herdr CLI probe adds, runs one
  request, and returns gh's exit status, output and error output in framed
  sections. It is the same exec on every Server Kind, Herdr TUI, herdr-core,
  tmux and Rex, on macOS and Linux, and does not depend on Host Commands.
  A Rex Host reaches it through a seam of its own (`RexTransport.gitHub`), so
  `RexConsoleProjection.withHostServices` stays closed. A native Windows Host
  is not offered: the exec refuses it, and the tab's Host menu leaves it out.
- **No token passes through Heeler.** Heeler never runs `gh auth token`,
  never reads gh's configuration, never moves credentials and never tells the
  user to store a token in plain text. Signing in is `gh auth login`, typed on
  the Host.
- **On a Mac, gh may need the desktop session.** An SSH login runs in a
  security session of its own and cannot read the login keychain, where gh
  keeps its token on macOS. When the exec's gh has no usable token on Darwin
  (exit status 4, an HTTP 401, or GitHub's limit for requests without a
  token), the script runs the same request once more as a one-shot launchd
  job in the `gui/<uid>` domain, whose gh reads the keychain as the desktop's
  does. The job inherits only where gh, its configuration and its tools are,
  and the proxy variables (`GitHubCLIScript.desktopVariables`), never a token
  variable. It writes to a private temporary folder the script made, the
  script polls for its status for up to 30 seconds, then `launchctl bootout`s
  the job and removes the folder. The Console remembers the route for that
  connection (`ConsoleStore.gitHubDesktopRoutes`), so later reads go straight
  to the desktop session until the connection is replaced or the user taps
  Check Again. With no one logged in at the desktop there is no `gui/<uid>`
  domain, and the Host is Not Signed In. Linux needs none of this.
- **A Host, not a Server.** gh belongs to the machine, so the tab lists Hosts
  ([ADR 0047](0047-a-host-is-one-machine-and-lists-its-servers.md)) and runs
  gh through any of the Host's connected Servers that can, in order. One Host
  is read at a time, chosen from a menu at the top of the list; the menu is
  hidden when there is one Host, and the choice is remembered.
- **Reads are GraphQL, parsed on the device.** The list is one
  `gh api graphql -i` request (`GitHubListRead`): the account's login and four
  searches of open, unarchived items across repositories, 30 each, most
  recently updated first. Pull requests that request the user's review, pull
  requests the user opened, issues assigned to the user, and issues the user
  opened that are not assigned to them. The headers give each section's full
  count and say when a rate limit ends. Later writes will use gh's porcelain
  commands, one exec each, never sent twice.
- **The list is kept for display, never watched.** Each Host's list is saved
  on the device (`FileGitHubListCache`) by the rules
  [FileChatTranscriptCache](../../Sources/Heeler/Chat/Cache/FileChatTranscriptCache.swift)
  follows: the Caches folder, complete file protection, excluded from backup,
  removed with the Host, and dropped after 30 days. Opening the tab shows the
  saved list with when and where it was read, then reads again if it is older
  than two minutes. A pull and Check Again read too. Nothing polls, and a
  detail read stays in memory.
- **A detail is a second read of one item.** Opening a pull request or an
  issue runs one more `gh api graphql -i` request (`GitHubDetailRead`) for
  that item by its node id: its body, and for a pull request its branches,
  changed files, whether it is the account's or from a fork, mergeability,
  pending review requests and the latest review of each reviewer; for an issue
  its assignees. The read runs when the detail opens, unless one finished in
  the last two minutes, and on a pull. It is kept in memory
  (`GitHubStore.details`), and the row it returns replaces the list's copy,
  which is saved again. `GitHubStore.reread(_:on:)` reads one item again on
  request, so an action can check the item before it acts and the list
  follows after. An item GitHub no longer shows to the account says so in
  the detail's banner.
- **Send to Agent puts a message in a running Agent's Composer.** From a
  detail, a sheet asks what the Agent should do, worded as one English
  sentence and the item's address (not localized, ADR 0041, and shown before
  it is placed): review a pull request, fix its failing checks (the account's
  own, with failures), address review comments (changes requested), work on
  or investigate an issue, or just read it. It lists the Agents of the Host's
  connected Servers that take a Composer message. Agents whose directory is a
  checkout of the item's repository come first, marked On this branch when
  the checkout is on the pull request's head branch and This repository
  otherwise; the rest follow in the Agents list's order. One script through
  the same seam (`GitHubCheckoutRead`, so a Rex Host answers too) asks git in
  at most 24 directories for the top level, the branch and every remote URL,
  4 KB each; a remote names the repository in https, scp-like (`git@host:`)
  or `ssh://` form, on `github.com` or its `www.` and `ssh.` names. The sheet
  shows the Agents at once and marks them when the read answers, or leaves
  them unmarked after 8 seconds or a failure. Choosing an Agent puts the
  message below any draft in its Composer, by Hand Off's rules
  (`ConsoleStore.deliverDraft`), and opens the Agent. Nothing is sent.
  The read also lists each checkout's Worktrees (`git worktree list`), so
  New Agent knows every branch checked out in that repository.
- **New Agent from Send to Agent is the New Agent form, opened preset.** The
  sheet's last row, shown while one of the Host's connected Servers starts
  Agents, opens `StartAgentView` with a `StartAgentStore.GitHubLaunch`: the
  Server and Workspace of the first Agent working in a checkout of the item's
  repository, or neither when no Agent works in one. The new Agent gets the
  message the way an existing one does, once it is listed, and nothing is
  sent. The Worktree toggle stays off by default. Turned on while the
  Workspace is such a checkout, it names the branch from the item: a pull
  request's head branch when no Worktree of the repository on the Host has it
  checked out, else a generated name (`GitBranchName.generatedWorktreeBranch`),
  as for an issue. A branch checked out on the Host is refused in the
  footer, as git would refuse it. A fork's pull request whose head branch is
  named as the repository's default branch always gets a generated name,
  since that name is the user's own branch on the Host.
- **The Worktree starts from the item's commit on every Server Kind.** Before
  the Worktree is made, one script through the gh seam
  (`GitHubWorktreeStart`, via `GitHubStore.worktreeStart`) runs git in the
  Agent's checkout, on the Server the Agent starts on. It checks the branch is
  not checked out in a Worktree of that repository, then fetches, from the
  checkout's remote that names the repository, `refs/pull/<n>/head` for a pull
  request (GitHub keeps it for a fork's pull request too) or
  `refs/heads/<default>` for an issue, and answers with that commit. On the
  pull request's own branch the script also makes the branch at that commit,
  tracking the remote's branch for a pull request from the repository itself,
  or moves an existing branch forward to it; a branch with commits the pull
  request lacks is left alone and the Start fails, asking for another name.
  The commit becomes the Worktree's start point (`WorktreeSpec.base`): herdr's
  `worktree.create` takes it as `base` on Herdr TUI, and herdr-core and tmux
  run `git worktree add -b <branch> <path> <commit>` in place of `HEAD`
  (ADR 0032, ADR 0045). A branch that exists is checked out as it is, as
  before. The fetch is the only network step, bounded by the seam's 60
  seconds, and writes only `FETCH_HEAD`, the branch the script makes or moves,
  and that branch's tracking settings; nothing is pushed.
- **The tab can be turned off.** Settings has a GitHub switch under Usage's,
  on by default. Off hides the tab, runs no gh and removes the saved lists.
- **Six tabs fit by moving Settings.** The tab follows Terminals: Agents,
  Terminals, GitHub, Usage, Hosts and Settings. With both GitHub and Usage on,
  Settings leaves the tab bar and opens from a gear on the Hosts tab, pushed
  with Hosts to go back to. Flipping either switch while on Settings keeps the
  user on Settings, wherever it now lives. On an iPad beside its sidebar,
  GitHub joins the sidebar's switch between lists, as Usage does, and Hosts
  and Settings stay sheets from its foot. There the lists are the sidebar's
  selectable rows, and the detail fills the detail column.

## Considered options

- **A token kept by Heeler, through OAuth or a pasted token.** It would read
  GitHub without a Host. It puts a credential on the phone that can act for
  the account everywhere, and the maintainer ruled it out.
- **`gh auth token` read over SSH, then calls from the phone.** The same
  credential, moved off the Host.
- **`gh auth login --insecure-storage` on Macs.** It would let the SSH
  session's gh read the token without the desktop session, by writing the
  token in plain text. Heeler never suggests it.
- **`security unlock-keychain` in the exec.** It asks for the account's
  password, which Heeler does not have and should not.
- **Porcelain commands (`gh pr list`, `gh search prs`) for reads.** Their JSON
  fields differ by command and version, and the four lists would take four
  execs. One GraphQL request is one round trip and one rate-limit cost.
- **Polling while the tab is open.** It spends the rate limit and a Host's
  connection for a list that changes slowly. Pull to refresh is enough.
- **Sending the message for the user.** Placing it as a draft lets the user
  read, reword or drop it, as Hand Off does, and keeps a mistaken tap from
  starting work.
- **Fetching with `gh pr checkout` or `gh repo sync`.** Both act on the
  checkout's own HEAD, which belongs to the Agent working there. A fetch of
  the pull request's ref leaves that checkout as it is.
- **Fetching the fork's branch from the fork's URL.** It needs a remote or a
  URL per fork, and a private fork may not be reachable from the Host.
  `refs/pull/<n>/head` on the repository's own remote has the same commits.
- **Matching Agents to a repository by directory name.** A clone can have
  any name and a fork any owner. git's own answer, read in one script, also
  gives the branch.

## Consequences

- A search in GraphQL counts against the GraphQL limit, not REST's search
  limit: the response's `x-ratelimit-resource` is `graphql`, and the list
  cost 2 points of the hourly GraphQL limit. Measured on 2026-11-24, it took
  3.6 to 7.6 seconds and returned about 24 KB.
- When gh's configuration names an account but the keychain cannot be read,
  gh 2.105 sends the request with no token and exits 1, not 4. GitHub answers
  `401 Requires authentication`, or, once the address has spent what it may
  ask without a token, `403 API rate limit exceeded for <address>` with
  "Authenticated requests get a higher rate limit". Both read as Not Signed
  In and start the desktop route.
- The desktop route was measured on a Mac with an sshd started in a separate
  security session (`SessionCreate`), which could not read the login keychain,
  as an SSH login cannot. `launchctl bootstrap gui/<uid>` worked from inside
  it, and the job's gh read the keychain. A Mac with no one logged in at the
  desktop was not tried.
- On such a Mac the first read of a connection runs gh twice, and a desktop
  job that does not finish holds the read for 30 seconds. The job is booted
  out either way, and its folder goes when the exec ends.
- The desktop job sees only the variables listed. A proxy set in the SSH
  session's environment reaches it, including any credentials in a proxy URL,
  through the private folder the job reads its environment from, which the
  script removes when it ends.
- A Host that fails reads shows the last list it gave, dimmed when the Host is
  offline, with a banner saying why. Without one, the tab says why in its
  place: gh not installed (with `brew install gh` on macOS, and GitHub's
  instructions on Linux), not signed in (with `gh auth login`, Open Terminal
  on the Host where it can start Terminals, and Check Again), offline, rate
  limited (with when to try again), or gh's own message.
- Lists are per Host. Two Hosts signed in to the same account each keep and
  read their own.
- Each section shows at most 30 items. A section with more says how many it
  shows of how many.
- The Worktree is made in the Workspace's checkout, and its commit is
  fetched in the checkout of the Agent the form matched in that Workspace.
  When a Workspace holds two clones, the fetched commit may be missing from
  the one the Worktree is made in, and git refuses it with its own message.
- The checked-out rule in the form counts the Worktrees of the checkouts the
  Agents work in. A branch checked out in a separate clone no Agent works in
  is caught by the script, at Start, not in the footer.
