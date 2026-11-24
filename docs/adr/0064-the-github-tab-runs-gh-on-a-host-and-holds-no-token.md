---
status: accepted
---

# The GitHub tab runs gh on a Host and holds no token

Agents open pull requests and get asked for reviews, and the user wants to
see where those stand from the phone. The machines Heeler connects to often
have the GitHub CLI installed and signed in already. The maintainer decided
on 2026-11-24 that Heeler reads GitHub by running that `gh` over the Host's
existing SSH connection, and never sees, stores or carries a GitHub token.
This ADR covers the read-only list (the GitHub tab); a pull request's or an
issue's detail, and later actions, build on the same seam.

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
  does. The job inherits only where gh, its configuration and its tools are
  (`GitHubCLIScript.desktopVariables`), never a token variable. It writes to a
  private temporary folder the script made, the script polls for its status
  for up to 30 seconds, then `launchctl bootout`s the job and removes the
  folder. The Console remembers the route for that connection
  (`ConsoleStore.gitHubDesktopRoutes`), so later reads go straight to the
  desktop session until the connection is replaced or the user taps Check
  Again. With no one logged in at the desktop there is no `gui/<uid>` domain,
  and the Host is Not Signed In. Linux needs none of this.
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
- **The tab can be turned off.** Settings has a GitHub switch under Usage's,
  on by default. Off hides the tab, runs no gh and removes the saved lists.
- **Six tabs fit by moving Settings.** The tab follows Terminals: Agents,
  Terminals, GitHub, Usage, Hosts and Settings. With both GitHub and Usage on,
  Settings leaves the tab bar and opens from a gear on the Hosts tab, pushed
  with Hosts to go back to. Flipping either switch while on Settings keeps the
  user on Settings, wherever it now lives. On an iPad beside its sidebar,
  GitHub joins the sidebar's switch between lists, as Usage does, and Hosts
  and Settings stay sheets from its foot.

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
- The desktop job sees only the variables listed. A proxy set only in the SSH
  session's environment does not reach it.
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
