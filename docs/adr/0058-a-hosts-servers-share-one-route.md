---
status: proposed
---

# A Host's Servers share one Route, and Host detail owns the connection

[ADR 0047](0047-a-host-is-one-machine-and-lists-its-servers.md) made a Host
one machine that lists its Servers, and kept one SSH connection for each
Server. Every one of those connections raced the Host's Routes for itself
([ADR 0022](0022-host-routes.md)), so two Servers on one machine could settle
on different Routes, and each Server's page showed a connection card, the
Routes with their In Use and Failed marks, a row naming its Host and a Show in
Heeler switch. Host detail listed the same Routes with no state. The question
a user asks is about the machine, "how am I reaching this Mac", and the app
answered it once per Server and nowhere for the Host.

ADR 0022 also left a live connection on its Route until it ended. A phone
that connected through an Overlay Network away from home stayed on it after
reaching the LAN, until the user pressed Reconnect.

## Decision

- **A Host's connections hold one Route.** Each Server keeps its own SSH
  connection; what they share is which Route it is on. The app keeps that
  per Host, by the identity ADR 0047 gives one (account, authentication and
  the Routes in order), and names the Route by its position in that list,
  since each Server's record gives the same Route an id of its own.
  - A dial asks which Route the Host's live connections hold. When there is
    one, it dials that Route alone. When there is none, it races the Routes
    as ADR 0022 says.
  - A dial that connected says which Route it took. If the Host settled on
    another one in the meantime, which happens when two Servers race at
    once, it closes its connection and dials the Host's Route. It tries
    three times and then fails as a timeout.
  - The Route is held for as long as a connection that took it is alive.
    When the last one drops, the next dial races again.
  - A dial that follows the Host's Route and fails reports
    `TransportError.noRouteReached` with that one Route's failure, so the
    excuse for a local address and the Route named in the failure stay as
    ADR 0022 has them. It does not race on its own: the Route is in doubt
    for every Server, and the rule below settles it.
  - A race is never shared. The Console never asks about a host key and the
    checks do, so a race that failed for one would fail the other wrongly.
- **A connection that may be dead is asked at once.** A dead link that
  nothing has noticed still holds its Host's Route, and a Server
  reconnecting would follow it nowhere. So when the device's network path
  changes, every connected Server proves its link, and when one Server of a
  Host loses its connection, the Host's other connected Servers prove
  theirs.
- **A Host moves to a direct Route that comes into reach.** A race settles on
  a Route through an Overlay Network or a Jump Host only when no direct Route
  answered. When the device's network path changes, and when the app returns
  to the foreground, each Host with a connected Server on such a Route has
  its direct Routes dialled as far as a verified host key, without
  authenticating and without asking about a key, for at most five seconds.
  If one presents the Host's key, the Host's Route becomes that one and its
  connected Servers reconnect once. The new Route stands for fifteen seconds
  with no connection on it, so those dials follow it and do not race.
  - "Better" means only this: a direct Route over one that is not. Routes of
    the same kind are never compared, and nothing measures latency.
  - Nothing looks on a timer.
- **Host detail shows the connection, and only Host detail.** Its Routes
  section marks the Route the Host's Servers hold In Use, or each Route
  Failed with its own reason when none reached the Host, and says a failure
  of the whole connection (the account, the host key) beneath them. Its
  header carries the one action: Stop while a Server is dialling, otherwise
  Reconnect, which forgets the Host's Route and dials every Server that is
  on, so the Routes race afresh.
  - Host detail's look at the Host serves the connection it shows. The
    Console never asks about a host key, so when a dial stops at a key nobody
    has confirmed, the Host's or a Jump Host's, the page looks at the Host,
    and the look asks. A key the user declined is not asked about again
    until they tap Scan Again.
  - A look that reaches the Host dials again, at once, the Servers that
    stopped on the connection or are waiting out a backoff. A Server the
    user stopped, and one whose own Server is missing, stay as they are.
- **A Server's row says the Server's own state.** Running with its version, a
  sync issue, or a failure that is the Server's (a missing socket, a core
  that is not running, a tmux server that stopped). A failure of the
  connection is the Host's and reads under Routes; the row then stays as the
  Server was last seen.
- **A Server's page holds what is the Server's.** The connection card, the
  Routes, the Host row, the Server Kind and Session or Socket rows and the
  Show in Heeler switch are gone from it; the switch is on Host detail,
  beside the Server's name. The page keeps its checks, plugin, Host Helper,
  sessions and the sections each kind adds.
  - Opened from elsewhere in the app, a Server's page sits on top of its
    Host's detail, so Back leads to the connection and the switch before it
    leads back to where the user came from.
  - The page has no Reconnect, so checks that pass reconnect its Server when
    the Console had stopped or was waiting out a backoff.

## Considered options

- **One SSH connection shared by a Host's Servers.** It would make "one
  channel for the machine" literally true. ADR 0047 set it aside as a rework
  of every transport, and that still holds: each kind opens its own channels
  and ends its own connection, and one stuck channel would then be every
  Server's problem. Sharing the Route gives what the user sees, one Route and
  one place that shows it, without that.
- **One race that every dial of a Host waits on.** Fewer connections opened
  when two Servers start together. Rejected because the dials differ in
  whether they may ask about a host key, and in when they are cancelled.
  Racing apart and reconciling costs at most a second dial.
- **Looking for a better Route on a timer.** It would also catch a computer
  that joins the device's network later. It would dial a LAN address every
  few minutes on whatever network the device is on, where that address is
  somebody else's machine, and keep the radio awake for a change the two
  triggers nearly always announce. Reconnect covers the rest.
- **Ranking Routes by the user's order or by latency.** ADR 0022 says the
  order is not a priority, and latency moves from one minute to the next. One
  step, direct over not direct, keeps a move rare and explainable.
- **Moving a Server to the new Route without reconnecting it.** Its events
  subscription and terminal attaches would have to pass from one connection
  to the other. Reconnecting is the path that already exists and is tested.
- **Keeping the connection card on a Server's page as well.** That is the
  duplication this decision removes.

## Consequences

- ADR 0022's rule that a network change does not switch Routes on a live
  connection holds in one direction only: a Host leaves an indirect Route
  for a direct one. It never leaves a direct Route that still works.
- A move reconnects every connected Server of the Host. Arriving home shows a
  brief Reconnecting, and open terminals attach again, as after any
  reconnect.
- With the device's network unchanged, a direct Route that starts answering
  later (the computer wakes, or joins the Wi-Fi) is not noticed until the
  app is opened again or the user presses Reconnect.
- While a Host is connected through an indirect Route, each network change
  and each return to the app dials its direct Routes once. The host key
  check stops another machine at that address before any authentication, as
  it does in every race.
- Two Servers that start together may each open a connection before one of
  them closes its own and follows the other.
- A link that died without a network change holds the Host's Route until a
  keepalive notices, and a Server reconnecting meanwhile fails against that
  Route. The first Server to notice makes the others prove their links.
- The Route a Host holds lives in the app's memory. It is not saved, and the
  widget and notification extensions take no part in it.
- Hosts that ADR 0047 keeps apart, because their Routes differ, hold their
  Routes apart too.
- A path change still does not wake a Host that stopped retrying. Reconnecting
  promptly then remains #278.
- The Reconnect Request moves from a Server's page to Host detail and covers
  every Server of the Host that is on.
