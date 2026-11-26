---
status: accepted
---

# The GitHub tab runs gh on a Host and holds no token

Agents open pull requests and get asked for reviews, and the user wants to
see where those stand from the phone. The machines Heeler connects to often
have the GitHub CLI installed and signed in already. The maintainer decided
on 2026-11-24 that Heeler reads GitHub by running that `gh` over the Host's
existing SSH connection, and never sees, stores or carries a GitHub token.
This ADR covers the list (the GitHub tab), a pull request's or an issue's
detail, Send to Agent, and the detail's writes: Comment, Approve, Merge and
Close.

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
  token; a write needs stricter proof, below), the script runs the same
  request once more as a one-shot launchd job in the `gui/<uid>` domain,
  whose gh reads the keychain as the desktop's does. The job inherits only where gh, its configuration and its tools are,
  and the proxy variables (`GitHubCLIScript.desktopVariables`), never a token
  variable. It writes to a private temporary folder the script made, the
  script polls for its status for up to 30 seconds by the clock, then
  `launchctl bootout`s the job and removes the folder. The wait ends at the
  latest 44 seconds after the script started, before the exec's 50-second
  watchdog, which kills the script with no cleanup. When the exec's gh
  proves no token later than 41 seconds in, no job starts and the route
  reports a timeout, so the watchdog never meets a loaded job that would go
  on to run the request. Every other exit the script can trap boots the job
  out and removes the folder, and each run first sweeps what an earlier one
  could not (below). The Console remembers the route for that connection
  (`ConsoleStore.gitHubDesktopRoutes`), so later reads go straight to the
  desktop session until the connection is replaced or the user taps Check
  Again. With no one logged in at the desktop there is no `gui/<uid>`
  domain, and the Host is Not Signed In. A Worktree start's fetch takes the
  same route (below). Linux needs none of this.
- **A Host, not a Server.** gh belongs to the machine, so the tab lists Hosts
  ([ADR 0047](0047-a-host-is-one-machine-and-lists-its-servers.md)) and runs
  gh through any of the Host's connected Servers that can, in order. A read
  goes on to the next Server when one cannot run gh this way or its link
  fails; a timeout ends it, since trying on would double the wait. One Host
  is read at a time, chosen from a menu at the top of the list; the menu is
  hidden when there is one Host, unless that Host has a status to show, and
  the choice is remembered.
- **Reads are GraphQL, parsed on the device.** A list read is one
  `gh api graphql -i` request (`GitHubListRead`): the account's login and one
  or more searches of unarchived items across repositories, 30 each, most
  recently updated first, each search's query and cursor passed as a variable.
  At the filters' defaults it reads both segments: pull requests the user
  opened, pull requests that request the user's review and that they did not
  open, issues assigned to the user, and issues the user opened that are not
  assigned to them. A filter changed from its defaults reads its segment's
  searches, and Show More the next page of the searches it needs. The title
  bar says when a rate limit ends. gh exits 1 whenever GitHub's answer
  lists errors, even beside its data. When every error names a field
  (`path`), the read takes the data: a search result GitHub will not show,
  behind SAML or an OAuth App restriction, comes back null and is left out
  of its section, and an item that is gone or hidden reads as GitHub no
  longer showing it. An error that names no field fails the read with
  GitHub's message; not signed in and a rate limit are told apart first.
  Writes are not GraphQL: they are gh's porcelain commands, below.
- **One list per segment, under a row of filters.** Pull Requests and Issues
  each show one list with no headings, most recently updated first. A row of
  chips under the list's title sets State, Person, Repository and Label
  (`GitHubListFilter`, `GitHubFilterBar`); each segment keeps its own on the
  device (`GitHubSettings`, written only when the user picks one), and a
  change reads once. State is Open (drafts included), Draft, Merged, Closed
  (unmerged) or All States for pull requests, and Open, Closed or All States
  for issues. Person is Yours, Anyone, a role of the account's (Created by,
  Needs Review or Reviewed by for pull requests, Assigned to, Mentioning) or
  a role of another login, picked from the people the lists read or typed in
  a sheet. Its default follows Repository: Yours across repositories, Anyone
  in a repository or an owner's, so choosing Heeler shows everyone's pull
  requests there, as a repository's page on GitHub does. Anyone is offered
  only with a Repository, since without one it would search all of GitHub.
  Repository is a repository or an owner, `org:` or `user:` as GitHub says
  the owner is, asked first when no list has shown it. Label is one name.
- **The list's title is the segment, and switches it.** A large title cannot
  be tapped on iOS 26 (a `.largeTitle` toolbar item is drawn about 25 points
  too high and takes no taps on 26.5 or 27.0), so the bar stays inline and
  the list's first row is its own header: "Pull Requests" or "Issues" in the
  large title's font with a chevron, a menu of the two (`GitHubListHeader`),
  the line under it, then the chips. It scrolls with the rows and does not
  pin. The title and its line each fade with the scroll as they pass under
  the bar (`FadesUnderBar`), since iOS 26's glass shows what is under it;
  once both are gone the bar's own title fades in, with the same menu
  (`toolbarTitleMenu`) and, on iOS 26, the line as its subtitle
  (`GitHubListTitle`). Scrolling back, the header stays clear until the
  bar's title has faded out, so no frame shows both. The bar is crossfaded
  because SwiftUI swaps a bar's title without animation (`BarTitleFade`).
  The rows never move when it switches. A pushed detail's back button reads the segment. A screen that
  takes the list's place shows GitHub in the same place, without a menu, so
  going between it and the list leaves the title where it is. iOS 18 has the
  same header. Beside an iPad's detail the sidebar's title is its menu of
  lists, so a segmented control sized to its words sits over the chips there.
- **A row is a line about the item over its title.** The list is plain and
  full width, with no disclosure chevron, so a row is as wide offline as
  online (`GitHubItemRow`). Its first line is the state's glyph in its colour,
  then `repo #number · author · age`, and at its end the status: a pull
  request's checks glyph with one word (Needs your review, the change's size,
  Approved, Changes requested, else the checks' Passing, failing count or
  Running; Draft or that word alone without checks; Merged or Closed in their
  colour), an issue's comment count when above zero. Short of room the author
  gives way first, shortening and then leaving with its dot, then the
  repository, which keeps about eight characters; past that the status goes
  under the first line (`GitHubOverLineLayout`). The number and the age never
  shorten. The title follows on up to two lines (four at accessibility sizes,
  where the status is always under the first line), and an issue's labels
  take a third line when it has any.
- **Yours is two searches that never share an item.** Person Yours is what
  involves the account: for pull requests `author:@me` and
  `review-requested:@me -author:@me`, for issues `assignee:@me` and
  `author:@me -assignee:@me`. Their counts add up, and the list shows the
  newest of what both read; Show More reads only the search whose read items
  run out before the next 30, and stops where a search with more on GitHub has
  none left to place. Anyone is one search with no role in it.
- **The list is kept for display, never watched.** Each Host's list at the
  filters' defaults is saved on the device (`FileGitHubListCache`, `v2`) by
  the rules
  [FileChatTranscriptCache](../../Sources/Heeler/Chat/Cache/FileChatTranscriptCache.swift)
  follows: the Caches folder, complete file protection, excluded from backup,
  removed with the Host, and dropped after 30 days. Opening the tab shows the
  saved list with when and where it was read, then reads again if it is older
  than two minutes. A pull and Check Again read too. Nothing polls, and a
  detail read stays in memory, as a filter's list does: while the Host is
  offline a changed filter shows that it is, with Clear Filters, rather than
  rows from another search.
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
  follows after. An item GitHub no longer shows to the account says so as
  a failed read's words: in the detail's "⋯" on iOS 26, in its banner
  before.
- **A description's pictures and videos load on the phone, from GitHub.**
  The detail read asks for the body as GitHub renders it (`bodyHTML`) beside
  its Markdown, and keeps of it only each `<img>` and `<video>`: the address
  GitHub gives a browser, the size its tag gives, and the upload id and
  addresses it stands for (`GitHubMedia`). An upload, written as
  `github.com/user-attachments/assets/<id>`, which needs a signed-in browser,
  is there at `private-user-images.githubusercontent.com` with a `jwt`
  signed for five minutes, in public repositories too. Another site's image
  goes through GitHub's image proxy (`camo.githubusercontent.com`), and an
  image in a repository keeps its address on GitHub. The phone fetches these
  over HTTPS itself, with no cookie and no token, and never an address only
  the Markdown names, so no other site learns the phone's address. Each
  picture or video the Markdown writes is put back where it is written
  (`GitHubBody`), matched by upload id or address, else in order when as
  many are left on each side; one GitHub does not show, such as one in code,
  stays as written. An address whose signature ends within 20 seconds, or
  that GitHub refuses, reads the item again for a new one
  (`GitHubStore.mediaURL`). What loaded is kept in memory by upload id, so
  a new read's addresses load nothing again. A picture opens in Chat's
  zoomable viewer and a video in the system's player. An animated GIF or
  PNG plays a frame at a time as ImageIO decodes it (`AnimatedImageView`):
  a walk-through recorded as a GIF can hold over a thousand frames, which
  decoded up front would take gigabytes or play blurred and cut short. A
  description longer than Chat's parser takes (48 KB, where GitHub allows
  65,536 characters) parses in sections that end at a blank line outside a
  code fence, rather than showing as one plain paragraph.
- **A description's HTML shows as its text.** GitHub renders the HTML a
  description holds, so the detail shows an HTML block as a browser would
  show its text, a line for each block element, and drops inline tags but
  `<br>`. Pictures and videos inside it show as above.
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
  4 KB each, a list cut there losing its last line, which may be a URL cut
  short; a remote names the repository in https, scp-like (`git@host:`)
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
  the Worktree is made, two execs through the gh seam (`GitHubWorktreeStart`,
  via `GitHubStore.worktreeStart`) run git in the Agent's checkout, on the
  Server the Agent starts on. The first is the gh script with git as its
  program (`GitHubCLIRequest.Program.git`). It fetches, from the checkout's
  remote that names the repository, by the remote's name so its own settings
  and credential helper apply, `refs/pull/<n>/head` for a pull request
  (GitHub keeps it for a fork's pull request too) or `refs/heads/<default>`
  for an issue, into `refs/heeler/start/<epoch>-<nonce>`, with
  `GIT_TERMINAL_PROMPT=0` and standard input from `/dev/null`. For a pull
  request from the repository itself whose own branch the Worktree checks
  out, it then fetches that branch too, best effort, so the upstream the
  branch is made to track exists rather than showing as gone, and a merged
  pull request whose branch was deleted still starts.
  On a Mac a fetch that fails in the exec, for any reason, runs once more in
  the desktop session's one-shot job, as a gh read does: an https remote
  whose credential helper reads the login keychain, as `gh auth
  git-credential` does on a Mac, cannot answer in an SSH login. Nothing in
  git's output is matched, since a fetch changes nothing on GitHub and a
  network failure just fails again. The job gets the variables gh's job
  gets, never a token variable or `SSH_AUTH_SOCK`, so an ssh remote uses the
  desktop session's own agent, and git's location and override variables
  are unset in the exec and the job alike. The failure names git's first
  error line from its last run: the desktop session's once that ran, the
  exec's when no one is logged in at the desktop or the job did not finish.
  A git request tries the exec first every time and leaves the route the
  connection remembers for gh as it was.
  The second exec has no network step. It reads the commit from the private
  ref and deletes it, whatever follows, along with any other start's ref
  there named more than five minutes earlier by the device's clock, which a
  connection lost between the two execs leaves behind. It then checks the
  branch is not checked out in a Worktree of that repository, and answers
  with the commit. On the pull request's own branch it also makes the branch
  at that commit, tracking the remote's branch for a pull request from the
  repository itself, or moves an existing branch forward to it with `git
  branch -f`. git 2.35 and later refuse that for a branch a Worktree is
  rebasing or bisecting, which `git worktree list` shows only as a detached
  HEAD, and the Start fails with git's words; older git moves it.
  A branch ahead of the pull request, holding its commits and more, is
  checked out as it is, as `gh pr checkout` leaves it; only a branch that
  has diverged from the pull request is left alone and fails the Start,
  asking for another name.
  For a fork's pull request the same refusal covers a name that belongs to
  the checkout's remote, a local branch with an upstream or a name among the
  remote's branches (`refs/remotes/<remote>/<branch>`), since moving or
  making it would send a later push to the repository's branch. A branch an
  earlier Start made for the fork's pull request has no upstream, and is
  moved forward.
  The commit becomes the Worktree's start point (`WorktreeSpec.base`): herdr's
  `worktree.create` takes it as `base` on Herdr TUI, and herdr-core and tmux
  run `git worktree add -b <branch> <path> <commit>` in place of `HEAD`
  (ADR 0032, ADR 0045). A branch that exists is checked out as it is, as
  before. The fetches are the first exec's and the only network steps,
  bounded by the seam's 60 seconds. They write the private ref, which carries
  the commit to the second exec because an Agent fetching in the same
  checkout could replace `FETCH_HEAD` first, and, as any fetch does,
  `FETCH_HEAD` and, for an issue or a tracked branch, the remote's
  `refs/remotes/<remote>/<branch>`, which git updates on its own when the
  remote's refspec maps the branch. The second exec writes the branch it
  makes or moves and that branch's tracking settings. Nothing is pushed. A
  fetch that fails writes no private ref, and the second exec does not run.
  In a repository over its auto-gc limit a fetch starts git's detached
  maintenance, which keeps the descriptors it was given; the fetch's are
  `/dev/null` and files in the gh script's private folder, in the exec and
  in the job, so the answer does not wait for it. The repository's
  maintenance settings stay as they are.
- **Writes are gh's porcelain commands.** The detail's "⋯" menu ends with
  Comment… (any item), Approve… (an open pull request that is not the
  account's own), Merge… (an open pull request that is not a draft) and
  Close… (anything open). Each runs one command through the same script
  (`GitHubWrite`, `GitHubStore.write(_:on:host:shownBy:)`): `gh pr comment`
  or `gh issue comment` with `--body-file`, `gh pr review --approve` with an
  optional `--body-file`, `gh pr merge` with `--squash`, `--merge` or
  `--rebase`, `--match-head-commit` and optionally `--delete-branch`,
  `gh pr close`, and `gh issue close --reason "completed"` or
  `"not planned"`. gh keeps its own checks, and its messages are shown word
  for word. Every sheet and confirmation names the command, the Host and the
  account ("Runs gh pr merge on Studio Mac as @login.").
- **A write cannot reach a checkout or the shell.** It names the item by its
  URL and runs in the script's private temporary folder, with
  `GIT_CEILING_DIRECTORIES` set to that folder's parent and git's location
  variables unset, so gh finds no local repository: it acts on GitHub only,
  and `--delete-branch` cannot delete a local branch. What the user typed is
  written into that folder as `printf` octal escapes, one per byte, and gh
  reads it with `--body-file`. No shell reads the text, and the desktop job
  reads the same file.
- **A write is sent once.** It runs on the Server whose connection answered
  the read just before it, and on no other: trying each connected Server in
  turn is for reads. On a Herdr TUI Server it runs on the current connection
  only (`EventsSession.withTransportOnce`), never again on a replacement. The
  desktop route runs it a second time only on proof that the first gh had
  no token, when it could have changed nothing: exit status 4, or another
  failure with a line of error output that begins `HTTP 401`, as gh's
  `HTTP 401: Bad credentials (…)` does
  (`GitHubCLIScript.writeHadNoToken`, and the same test in the script). gh
  names the item when a write succeeds, title and all (`✓ Merged pull
  request o/r#1 (<title>)`), so a title holding "HTTP 401" must prove
  nothing: it comes mid-line and holds no newline, and exit status 0 never
  counts. The same test decides when Heeler says a write did not run. Reads
  keep the wider test, GitHub's mark for a request without a token
  included, since running a read again is harmless. An exec that
  ends without gh's exit status (the watchdog, a lost connection, a desktop
  job past its wait) may have changed GitHub: once the exec was handed to
  SSH, `HeelerSSHTransport.runGitHubScript` reports a failure as
  `coreMutationOutcomeUnknown`, as a herdr-core mutation does. Heeler says
  the outcome is unknown, does not send it again, keeps what the user wrote
  on screen, and offers the item in the browser.
- **The item is read before and after.** A read that starts after the write
  is asked for runs first (`GitHubStore.freshAnswer`), never one already
  running, which may have begun before what the write needs to see. If
  the item is no longer open, is a draft again, or for Merge has a new head
  commit, Heeler says so and runs nothing; Merge passes the head it read as
  `--match-head-commit`, so GitHub refuses a merge of commits pushed since.
  After a write that ran, Heeler reads again, so the detail, the list row and
  the saved list follow; a list read already running when that read came
  back keeps its row when it lands. Merge's result comes from that read, not from the
  exit status alone: Merged when GitHub shows the pull request merged, naming
  the method only when gh exited 0, the account merged it and the merge
  commit's parents match the method, and saying whether the branch is gone;
  Not Merged Yet with gh's output when gh exited 0 and the pull request is
  still open (auto-merge or a merge queue); GitHub Refused the Merge with
  gh's output when it did not exit 0. When gh exited 0 and the read after
  failed, nothing shows whether the change took, so a Merge or Close page
  is titled gh Finished, says gh reported success but Heeler could not read
  the item again to confirm it, shows gh's output and offers the item in
  the browser. The other writes end without a page when gh exits 0 (Close
  when the read shows the item closed), and otherwise show gh's output
  under a title that says what happened. A result page names the item at
  its top and opens at full height, so its Done is in view once the
  keyboard has gone.
- **A write's sheet belongs to the Console.** Comment, Approve and Merge
  open from the Console, as Send to Agent does (`GitHubWriteSheetPresenter`),
  and their request holds the sheet's state: the text, the method, the
  branch switch and the write's progress. A sheet keeps the presentation it
  opened with (`ConsoleSheetContent`), so when an iPad window crosses size
  classes it is not built again and carries on with the draft or the write
  in flight, then shows its result. `GitHubStore.write` says which of
  three things happened: nothing ran (another write on the item was
  running), the result is the sheet's to show, or the sheet had gone by the
  end. In the last case a sheet still up closes rather than offer its form
  again, since the write may have gone through.
- **A result is shown once, wherever the user went.** A write outlives the
  sheet or detail it began on. Comment, Approve and Merge hold their sheet
  until the write ends, since it cannot be dismissed while working; Close
  has no sheet, and the user can go back, pick another row or leave the
  tab while it runs. A result with no sheet left to show it, every Close's
  among them, waits in `GitHubStore.reports` unless it is a plain success.
  The Console's presenter shows the same page once the GitHub tab is the
  one shown and none of the Console's sheets is up, since one such as Send
  to Agent can end by opening an Agent on another tab. It names the Host
  under the item, since it can land over another item's detail. Turning
  GitHub off drops what waits.
- **Merge offers what the repository allows.** The detail read adds the
  repository's allowed methods, the account's default
  (`viewerDefaultMergeMethod`), whether the repository deletes merged
  branches, and the head commit. The sheet lists the allowed methods,
  starting on the default, and warns, worded for each case, when checks fail,
  changes were requested, or both. Delete Branch starts on, then as the user
  left it in the last Merge they ran where they could set it, kept on the
  device. It is not offered for a fork's pull request. When the repository
  deletes merged branches itself, the switch shows on and cannot be
  changed, a line says why, and Heeler passes no flag, so the page after
  reports what GitHub did.
- **The tab can be turned off.** Settings has a GitHub switch under Usage's,
  on by default. Off hides the tab, runs no gh and removes the saved lists.
  A write whose read before is still running when it goes off runs nothing.
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
  fields differ by command and version, and each search would take an exec.
  One GraphQL request is one round trip and one rate-limit cost.
- **All as one advanced search with `OR`.** GitHub documents `AND`, `OR` and
  parentheses for issue search (`ISSUE_ADVANCED`, from 2025), not for pull
  requests or with `sort:`. Two plain searches whose qualifiers exclude each
  other give the same items, and both counts are exact.
- **Filtering the saved list on the device.** It holds 30 items of each
  search, the account's own roles only, so other people, closed items and
  anything past the first page could not be found.
- **Polling while the tab is open.** It spends the rate limit and a Host's
  connection for a list that changes slowly. Pull to refresh is enough.
- **Sending the message for the user.** Placing it as a draft lets the user
  read, reword or drop it, as Hand Off does, and keeps a mistaken tap from
  starting work.
- **Fetching with `gh pr checkout` or `gh repo sync`.** Both act on the
  checkout's own HEAD, which belongs to the Agent working there. A fetch of
  the pull request's ref leaves that checkout as it is.
- **Fetching only in the exec.** One exec, no launchd job. But on a Mac the
  commonest https setup, a credential helper that reads the login keychain,
  fails in every SSH login, so a private repository's Worktree could never
  start from the item there. The retry costs the failed attempt, about a
  second, and changes nothing.
- **Copying the desktop job into the start's script.** It would keep one
  exec, but two copies of the job, its sweep and its time budget would have
  to stay in step. The fetch reuses the gh script's, and the branch's rules
  take a second exec.
- **Fetching a same-repository pull request's `refs/heads/<branch>`, falling
  back to `refs/pull/<n>/head`.** One fetch instead of two for an open pull
  request, but a closed one's branch may have moved on, and the Worktree
  would start from commits the pull request does not have.
- **Fetching the fork's branch from the fork's URL.** It needs a remote or a
  URL per fork, and a private fork may not be reachable from the Host.
  `refs/pull/<n>/head` on the repository's own remote has the same commits.
- **Matching Agents to a repository by directory name.** A clone can have
  any name and a fork any owner. git's own answer, read in one script, also
  gives the branch.
- **Writes as GraphQL mutations through `gh api graphql`.** One request shape
  for reads and writes, but Heeler would own each mutation's input and
  errors, give up gh's checks such as `--match-head-commit`, and show
  messages the user has never seen from gh.
- **Retrying a write after a lost connection.** The first exec may have
  finished, and a comment would post twice. The read after it lets the user
  decide.

- **Loading a description's pictures through the Host.** gh or curl there
  reaches GitHub wherever gh does, but an exec returns text: each picture
  would cross the SSH link encoded, a video in full before it plays, each at
  the cost of an exec. A phone reaches GitHub wherever GitHub's own app
  does; one that cannot shows each picture's name, which retries on a tap.
- **Showing `bodyHTML` instead of the Markdown.** It would lay out as GitHub
  does, but needs an HTML renderer beside Chat's Markdown, and Send to Agent
  needs the Markdown anyway.

## Consequences

- Read on 2026-11-27 through `gh api graphql`: an upload's `<img>` and
  `<video>` in `bodyHTML` pointed at
  `private-user-images.githubusercontent.com/<user>/<n>-<id>.<ext>?jwt=…`,
  whose token's `nbf` and `exp` were 300 seconds apart, in a private
  repository and in a public one; the address loaded with no cookie. A video
  sat in a `<details>` with its file name, its Markdown a bare
  `user-attachments` address on a line of its own. A new upload's `<img>`
  carried `width` and `height`; a proxied image carried the written address
  as `data-canonical-src`; `github.com/<owner>/<repo>/raw/…` stayed as
  written. The walk-through GIF of PR #632 was 400 by 869 pixels with about
  1,400 frames in 7.9 MB, and a Renovate description 58 KB.

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
- Asked on 2026-11-24 for a node id that resolves to nothing, gh 2.105
  exited 1 with `data` holding the viewer and a null `node` beside a
  `NOT_FOUND` error whose `path` is `["node"]`; the detail then said GitHub no
  longer shows the item. A list whose answer had one search node null with a
  `FORBIDDEN` error on its path (as SAML gives, made by the stand-in) showed
  the section's other items.
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
  script removes when it ends, or a later run once it is stale.
- gh not installed or not signed in takes the list's place, even when a list
  was read before, so a signed-out gh does not sit under another account's
  list: `brew install gh` on macOS and GitHub's instructions on Linux, or
  `gh auth login` with Open Terminal on the Host where it can start Terminals,
  each with Check Again. A Host that fails reads otherwise shows the last list
  it gave, dimmed when the Host is offline, and the title bar says why, never
  a line among the rows: the Host button, the toolbar's own, puts an amber
  glyph before the Host's name (offline, rate limited, or a failed read),
  with no fill of its own inside iOS 26's glass. A line under the list's
  title is there whenever the list area is, from its first frame, so the
  header keeps its height and the list does not move for anything that
  comes and goes (at accessibility sizes it takes the lines its words need,
  with none kept empty under a short one): Reading… while a read has nothing to show yet or runs over
  the rows, then when the rows were read, or the status with when they were
  read or when to try again, the status alone where no rows show. It is the
  only place the list says so: no footer or heading among the rows repeats
  it. A screen that takes the list's place has no line. An iPad sidebar,
  whose bar shows its title menu instead of a title, has that line just
  under the bar. On iOS 26 a detail has one under its number by the same
  rules once it shows, with gh's words after a failed read in its "⋯" over
  Check Again; before iOS 26 a banner between its header and its facts says
  it instead. After a failed read the Host menu holds gh's own words and
  Check Again, so the button shows with one Host too while it has a status.
  Without a list, the tab says why in its place: offline, rate limited
  (with when to try again), or gh's own message.
- Lists are per Host. Two Hosts signed in to the same account each keep and
  read their own.
- The choice in the menu and the saved list are kept under the Host's first
  record, as a Usage widget names it (ADR 0047). Turning that Server off
  removes the record, and both move to the record that is first now, so the
  Host stays chosen and its list stays shown.
- On 2026-11-24 the list, a detail and Send to Agent were tried on tmux,
  herdr-core and Rex Hosts on a Mac, the herdr-core one through a
  `SessionCreate` sshd and so by the desktop route, and on a Host with a tmux
  and a herdr-core Server. That Host read through whichever was connected, and
  Send to Agent listed both Servers' Agents.
- On Debian 13, whose `sh` is dash, the script wrote nothing to standard
  error outside its frames, a gh that exits 4 read as Not Signed In with no
  second run, and the checkout read answered with git 2.47. No gh was signed
  in there: the list and a detail were parsed from a recorded response.
- A list shows 30 items, then Show More with how many it shows of how many
  GitHub found. Under Yours the count is the two searches' sum. The next
  page reads by itself once the row ten above the end comes on, or Show More
  does, about a screen ahead on an iPhone; the row stays a button for
  VoiceOver and Switch Control. A read that failed waits for Try Again.
  Offline the row stays, greyed and not tappable, so the rows read do not
  look like all there is; a failure row stays too, with Try Again greyed, so
  nothing above it moves. When reading
  the next page fails, its row says why in Show More's place, with Try Again:
  the rows stay, and the title bar keeps the status of the list's own read.
  gh missing or signed out, or the Host offline, is shown as for any read.
- The Person menu offers the people the lists read (the default list and the
  segment's results), apps left out, so it changes with what was read; anyone
  else is typed.
  A label name cannot hold a double quote, since the query quotes it.
- A pull request asking for the account's review says "Needs your review" at
  the end of its first line when a pending review request names the account, or names
  the team whose request reached it (`viewerLatestReviewRequest`). Under
  Needs Your Review, where every row asks, it gives the change's size instead.
- The Worktree is made in the Workspace's checkout, and its commit is
  fetched in the checkout of the Agent the form matched in that Workspace.
  When a Workspace holds two clones, the fetched commit may be missing from
  the one the Worktree is made in, and git refuses it with its own message.
- The checked-out rule in the form counts the Worktrees of the checkouts the
  Agents work in. A branch checked out in a separate clone no Agent works in
  is caught by the script, at Start, not in the footer.
- Over git's auto-gc limits a fetch starts `git maintenance run --auto
  --detach` (git 2.47 and 2.55), which keeps the descriptors it was given.
  Measured through sshd on 2026-11-25, before the fetch closed them the
  start script's answer waited for the detached maintenance: 6 to 16
  seconds for the repack of a full clone of this repository over
  `gc.autoPackLimit` on a Mac, 31 seconds on Debian 13 with a `pre-auto-gc`
  hook drawing it out. With them closed the answer came in 0.9 to 2.6
  seconds, and a Start from the app answered while maintenance went on.
  Since the fetch runs in the gh script, measured the same day through the
  `SessionCreate` sshd: a repack the desktop job's fetch started, loosening
  about 59,000 unreachable objects, went on for 44 seconds after the fetch
  exec answered in 2.8 seconds, and `launchctl bootout` did not stop it; one
  the exec's fetch started went on 2.7 seconds after that exec answered in
  1.2.
- In a blobless clone `git worktree add` fetches the blobs its checkout
  needs, and that fetch starts the same detached maintenance, so the
  Worktree command closes the frame's descriptors for git as well.
  Measured on 2026-11-25 with a blobless clone of this repository over its
  auto-gc limits, the command answered in 75.2 seconds before and 15.2
  after on Debian 13 (git 2.47.3), where a `pre-auto-gc` hook sleeping 30
  seconds ran twice; through the `SessionCreate` sshd on a Mac (git 2.55),
  36.4 seconds before, waiting for a 22-second repack, and 16.7 after, the
  repack going on 21.5 seconds past the answer.
- Measured on 2026-11-25 through the `SessionCreate` sshd, with a private
  repository's https remote whose credential helper was `gh auth
  git-credential`, the exec's fetch failed in 0.6 seconds (`could not read
  Username for 'https://github.com': terminal prompts disabled`), and the
  same fetch worked in the desktop job. A Start from the app for a pull
  request from that repository spent 13.4 seconds in the fetch exec on a
  loaded Mac (5.1 replayed later), both fetches running in the job, and the
  Worktree's branch had its upstream. A public repository's fetch through
  that sshd ran in the exec in 1.1 to 1.2 seconds, with no job. A default
  branch that does not exist failed after the desktop retry with git's
  `couldn't find remote ref` line, not the exec's, and left no job, folder
  or private ref. With the job's folder unusable, the route was unavailable
  and the answer kept the exec's status 128 and its line. On Debian 13 the
  fetch ran in the exec, and a failed one ran once. A private ref whose
  second exec never ran was gone after the next Start in that repository,
  eight minutes later. The ssh form could not be shown working: GitHub
  accepts no key on this Mac, from either session.
- A Start for a branch a Worktree was rebasing left the branch where it
  was, with git's line "cannot force update the branch '<branch>' used by
  worktree at '<path>'", on a Mac (git 2.54 and 2.55) and on Debian 13 (git
  2.47.3) on 2026-11-25. git's source has the same refusal from 2.35, worded
  "checked out at" before 2.42.
- Writes were measured on 2026-11-24 against a stand-in gh that records what
  it was given and answers as told, never against GitHub. A body with
  quotes, `$(...)`, backticks, newlines, CJK and emoji arrived byte for byte,
  through the desktop job too, and gh ran in the private folder, where
  `git rev-parse` found no repository. `printf` octal escapes rebuilt every
  byte from 1 to 255 in macOS `sh`, `bash`, `zsh`, `ksh` and `dash`, BusyBox
  `ash` and Debian `dash`.
- Before writes had a test of their own, a merge or close of a pull request
  titled "Fix HTTP 401 on token refresh" that gh finished with exit status 0
  ran twice on a Mac, once more in the desktop session, because the title
  in gh's "✓ Squashed and merged pull request …" line matched; and Heeler
  would have said it did not run. With the test, measured on 2026-11-24 with
  the stand-in gh, each ran once in the exec, a failure naming the title
  mid-line ran once, and only a failure whose first line was `HTTP 401: Bad
  credentials` went on to the desktop session.
- 300 rounds of `sleep 0.1`, the desktop wait before it read the clock, took
  33 to 43 seconds on a Mac. After the exec's own gh, that outlasted the
  50-second watchdog, whose SIGKILL skipped the bootout and the folder's
  removal and left a loaded job in `gui/<uid>`. `launchctl bootout` stops a
  job whose gh is still running: a 40-second gh never answered.
- An exec learns that its connection is gone only when it next writes.
  Measured on 2026-11-24 over an sshd in a security session of its own, with
  macOS `sh` and `dash`: killing the client, killing either `sshd-session`
  process, or closing the channel alone sent no SIGHUP or SIGTERM. The
  script ran on and got SIGPIPE at its next write to standard output, after
  the desktop wait. `dash` (macOS's and Debian's) and BusyBox's `sh` then
  ran no EXIT trap and left the folder; macOS `sh` ran it. The script traps
  SIGPIPE, SIGHUP, SIGINT and SIGTERM and leaves through its EXIT trap, which
  boots the job out and removes the folder. Killing the client, or sending
  SIGTERM, before the job's bootstrap, while it ran, and after it ended,
  left no job and no folder.
- So a desktop job runs to its end, or to the wait's, after the connection
  is gone, and a write it carries may complete on GitHub. That is the
  unknown outcome above: Heeler never sends it again.
- The watchdog kills the exec's process group with SIGKILL, which no trap
  sees: its job and folder stay, and a job whose gh is still running
  finishes. Each run therefore first sweeps this user's leftovers. A
  `heeler-gh.<nonce>.*` folder goes once its last change is more than two
  minutes old by GNU `find -mmin`, three by macOS's and BusyBox's, which
  count whole minutes, its job booted out with it, unless that job is
  running. A `dev.bybee.heeler.gh.<nonce>` job goes once it has run and
  stopped and its folder, which `launchctl print` names, is gone or as old.
  A running job, a job not yet started and a younger folder may belong to a
  run still reading them: two reads can overlap, and another Heeler can read
  the same Host. Measured: SIGKILL before the bootstrap left a folder, and
  while the job ran or after it ended a job and a folder, the running gh
  finishing; the first read once they were stale left none. A write whose
  exec was killed while its desktop gh ran kept its job and folder through a
  read made with the folder ten minutes old, and its gh ran on; once gh had
  finished, the next read with the folder stale removed both. A read while
  another run's job had ended, before that run collected it, left both, and
  that run then read its answer. On Debian and Alpine the sweep removed
  stale folders and kept a younger one, another user's and a symlink.
- A job and folder left on 2026-11-24 were this case: a 70-second desktop
  job, from before the wait read the clock, outlasted the watchdog.
- The watchdog of every bounded exec ignores SIGPIPE, so a lost connection
  still ends the exec at its bound. Before it did, the marker write to the
  closed standard error got SIGPIPE before the `kill -KILL 0`, and the script
  ran until its wait or its gh ended. Measured on 2026-11-25 on macOS 27.0.1
  with `/bin/sh` (bash 3.2.57) and `/bin/dash` over OpenSSH 10.3's sshd, by
  killing the client, killing both `sshd-session` processes, closing the
  channel with the connection kept, and through a pipe whose reader exited,
  and on Debian 13 with dash 0.5.12 through the pipe: a 30-second child of a
  3-second bound outlived it before and died 3.0 to 3.1 seconds in after,
  and a gh hung in the exec ran past 50 seconds before and was killed at 50
  after. A desktop route's wait still ended at 44 seconds and cleaned up.
  OpenSSH's own client, when a multiplexed session's client dies, sends
  `eow@openssh.com` rather than closing the channel, and sshd then closes
  only standard output, so that watchdog fired either way.
- On 2026-11-24, against the same kind of stand-in, Comment, Merge and Close
  each ran once on tmux, herdr-core and Rex Hosts on a Mac (Rex through its
  Server's SSH exec), and Comment and Close on Debian 13 under dash. The body
  arrived byte for byte on each, Merge left out `--delete-branch` where the
  repository deletes merged branches itself, a two-line refusal with
  backticks, quotes and CJK was shown word for word, and no `heeler-gh.`
  folder was left in `/tmp` on Debian.
- On a Host with a tmux and a herdr-core Server, reads and writes went
  through the tmux Server, its first record, and the herdr-core Server ran
  nothing. With the tmux connection killed during a read, the read went on
  to the herdr-core Server: the list arrived, and a write whose read before
  it was cut ran once there, on the Server whose read answered. Killed 0.1
  seconds after the read answered, the write's script reached the tmux
  Server and died of SIGPIPE before gh ran; killed 0.3 seconds after, gh ran
  once on the tmux Server, after the connection was gone. Both said the
  outcome was unknown, the herdr-core Server ran no write, and nothing was
  sent again after Heeler reconnected.
- A gh that outlasted the exec was killed by the watchdog at 50 seconds, and
  Heeler said gh did not answer in time and did not send it again. A wrapper
  on the Host that relays the exec's standard error from inside its process
  group loses the watchdog's mark: the `kill -KILL 0` ends the relay first,
  the exec seems to end normally, and Heeler says it could not read what gh
  printed. A connection killed while gh ran, on tmux and on herdr-core,
  read as the connection ending before gh said how it went. gh finished on
  the Host and its folder went, and nothing was sent again after reconnect.
