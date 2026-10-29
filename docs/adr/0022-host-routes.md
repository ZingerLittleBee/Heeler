---
status: proposed
---

# Separate a Host from the Routes that reach it

A Host used to carry exactly one way to reach it: an address and port,
optionally a Jump Host, optionally an Overlay Network (ADR 0021). The same
machine is often reachable in different ways depending on where the device
is: directly on its LAN address at home, through an Overlay Network or a Jump
Host everywhere else. A second Host for the same machine split its Agents,
Notification Registration, Live Activities, and pins in two.

## Decision

- A **Host** is the machine: name, account, authentication, herdr session.
  It lists one or more **Routes**, in the user's order. A Route is an address
  and port, an optional Jump Host (address, port, account) the address is
  resolved from, and an optional Overlay Network carrying the first hop.
- There are no rules saying which Route applies where (Wi-Fi name, network
  type, location). Every connection races the Host's Routes and keeps the
  first that reaches the Host:
  - Routes over the device's own network with no Jump Host start at once.
    Routes through an Overlay Network or a Jump Host start 400 ms later, or
    as soon as every direct Route has failed. At home the LAN address wins
    before an overlay node or a Jump Host is ever started; away from home an
    unanswered LAN address costs only that stagger, not its connect timeout.
    When a Host has no direct Route, every Route starts at once.
  - Routes race only as far as a verified host key. A Jump Host is
    authenticated on its own Route, since nothing past it is reachable
    otherwise; the Host itself is authenticated once, on the winning Route.
    Every other Route is cancelled, and one that connects after the race was
    decided is closed.
  - The order the user gives breaks no ties and is not a fallback order. It
    only decides which Route is primary: the one shown where a Host has a
    single address, and the one older builds connect (below).
  - A Host with one Route connects exactly as before and reports its failure
    unchanged. When every one of several Routes fails, the failure is
    `TransportError.noRouteReached`, listing each Route's own failure. A
    changed host key is a host-key security failure on its own when the
    Route's address names the same machine wherever the device is: a Route
    through an Overlay Network or a Jump Host, or a direct Route to a
    public or CGNAT address or a DNS name. It leads the presentation and
    stops automatic retries, as it does for a Host with one Route. A direct
    Route to a local address (loopback, private, link-local or unique-local,
    or a single-label, `.local`, `.lan`, `.home`, `.home.arpa`, `.internal`
    or `.localdomain` name) may be another machine on another network, so
    its changed key is excused; it counts only when every Route failed on
    its key. Otherwise the failure is retryable when any Route's is.
- The Host's key is trusted by Host, not by the endpoint dialled. Every
  Route must present the key the Host was first confirmed with, so a LAN
  address answered by another machine away from home fails as a host-key
  mismatch before any authentication. Jump Hosts keep their trust by
  endpoint. A Host with no trust of its own adopts what the endpoint it
  dialled was trusted with, which is how a Host saved before Routes keeps
  its confirmed key without a prompt.
- Routes verify host keys one at a time within a connection, so a first
  connect asks about one key at a time, and a Route behind the first sees
  the trust it just stored rather than prompting again. A prompt whose Route
  loses the race is withdrawn.
- When several Routes fail on a changed host key, the onboarding screen
  offers to trust the new key only when the Routes that saw one agree on
  it. If any Route whose address names the same machine everywhere saw a
  changed key, only those Routes are compared; a local address's
  disagreement is another machine answering elsewhere. A Jump Host's changed
  key is its own machine's: it is offered under the Jump Host's endpoint,
  when the Routes through that Jump Host agree on it, and only when no
  change to the Host's own key is offered.
- Pairing makes the address that answered the first Route and every other
  candidate address in the Pairing Code a Route of its own.
- Network changes do not switch Routes on a live connection. The next
  connection races again; reconnecting promptly when the device's network
  path changes is #278.

## Relationship to ADR 0011 and ADR 0021

ADR 0021 says an Overlay Network is chosen by the user and is never a
fallback after a direct dial fails. Routes keep that: an Overlay Network is
still a property the user gives one Route, and nothing is dialled that the
user did not list. Racing listed Routes is not a hidden fallback, and none is
chosen by guessing from the device's network. ADR 0011's single SSH backend
is unchanged: each Route is the same libssh2 session over a different byte
stream or hop, with the same channels once connected.

## Consequences

- Host records gain `routes`. The primary Route is also written in the flat
  fields Hosts used before (`address`, `port`, `jumpAddress`, `jumpPort`,
  `jumpUsername`, `overlayNetworkID`), so an older build decodes the Host
  and connects its primary Route. An older build drops `routes` when it
  saves the Host; the next build then reads the flat fields as the Host's
  one Route. A Host saved before Routes decodes as one Route whose id is the
  Host's.
- Trust moves from `address:port` to the Host. Two Hosts behind different
  Jump Hosts may now share a tunnel endpoint such as `127.0.0.1:12222`.
  Adoption copies an endpoint's trust only into a Host that has none, so a
  Host first connected after this change can still adopt a key that another
  Host confirmed at the same endpoint, as it would have shared that entry
  before. Removing a Host leaves its trust entry behind, as it already left
  its endpoint entry (#414).
- A race can open several TCP connections, and, for Jump Host Routes,
  authenticate against several Jump Hosts. Only the Host itself is
  authenticated once.
- An Overlay Network named by a deferred Route is started only when that
  Route starts. A Host whose LAN address answers never starts it.
- The Console records which Route each connection took. The Host's detail
  marks that Route In Use, and when no Route reached the Host, each Route's
  own failure.
