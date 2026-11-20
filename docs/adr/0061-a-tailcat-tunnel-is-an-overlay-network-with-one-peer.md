---
status: proposed
---

# A tailcat tunnel is an Overlay Network with one peer

Issue #716 asks for [tailcat](https://github.com/tailscale/tailcat) as a way
to reach a Host that is on no network Heeler can join. `tailcat serve 22` on
the machine prints one address, and a client holding it reaches that port
through a WireGuard tunnel set up over a DERP relay, with no tailnet, account,
or coordination server. The Overlay Networks of ADR 0021 each join a network
of many peers that somebody administers. A tailcat tunnel reaches exactly one
machine, and its address is the whole configuration and the whole credential.

## Decision

- tailcat is a fourth Overlay Network kind. The user adds a tunnel in
  Settings › Overlay Networks by pasting the server's address, and a Route
  names it like any other network. `OverlayNode`, `OverlayRoute`, the runtime
  and the failure taxonomy are unchanged.
- The address is the network's Keychain secret
  (`overlay-tailcat-address-<network id>`). By default it holds the tunnel's
  pre-shared key, and it is all anyone needs to connect. The catalog entry
  holds only the id, name and kind. The form never shows a saved address. It
  says what it recognizes in a typed one, and warns when that has no
  pre-shared key.
- The client is tailcat's own Go client, linked inside CTailscale
  (heeler-overlay-natives), which already carries the Tailscale data plane
  tailcat is built from. There is one client per tunnel. Clients are
  independent of each other and of the tsnet nodes beside them.
- The server has no address a user could type, so a Route names it
  `<first 6 hex digits of the network id>.tailcat`
  (`OverlayNetwork.tailcatServerName`), and `TailcatNode.dial` accepts no
  other host. The route form fills the name in when a tailcat network is
  chosen. The port is typed as for any Route and must be one `tailcat serve`
  exposes.
- Every start and dial pings the server first. tailcat registers a client
  with its server once, so a server that restarted never answers an old
  client again. A client that was answered before and is not now is closed
  and replaced within the same dial, unless streams still run through it.
  The ping also tells a server that is gone from one that does not serve the
  port, which both look like silence to a dial.
- The client's own log is discarded. It names the server's public keys, and
  for an address without a pre-shared key those are the credential.

## Why

- The address is a credential, and Routes are stored in the Host catalog in
  UserDefaults. On a Route it would need a Keychain item per Route, repeated
  for every record of a Host with several Servers (ADR 0047), each running a
  tunnel of its own. As a network, one tunnel carries every Route that names
  it, one screen shows whether it is direct or relayed, and replacing the
  address is one edit.
- The server's name comes from the network id because host-key trust for a
  Jump Host, and for a connection outside the catalog, is keyed by address
  and port. One fixed name for every tunnel would file two servers' keys
  under the same entry. It does not come from the server's key, so pasting a
  new address after that key changes leaves Routes and trust as they are.
- A dial to any other host is refused instead of being sent to the server
  anyway. A Route typed for another machine would otherwise reach the wrong
  one and ask the user to trust its host key under the wrong name.

## Considered options

- **The address on a Route**, as a transport of its own. Rejected above.
- **tailcat as an XCFramework of its own.** A second Go runtime and a second
  copy of the data plane: 14.6 MB linked, against 0.26 MB inside CTailscale.
- **Reaching other machines through the server**, with `tailcat serve` as an
  exit node. Not now. The native interface only dials the ports the server
  exposes, and a Jump Host on the server already reaches the machines behind
  it under SSH's own authentication.
- **A client identity key**, so `tailcat serve --allow` can name this device.
  Not now. Each client makes a fresh key, so an allow list cannot name a
  Heeler device yet.

## Consequences

- Without a saved key on the server (`tailcat genkey --key=default`), every
  start of `tailcat serve` prints a new address, which the user pastes into
  the network again. Routes stay as they are.
- A server that restarts with the same key is reached again by the next
  dial, after one probe of at most five seconds that goes unanswered.
- Every dial costs one more round trip, for the ping.
- A wrong port fails only at the dial's deadline, as "answered, but not on
  port N": the server answers nothing on a port it does not serve.
- The client speaks the tailcat version its natives release pins (v0.7.0 when
  this was written). tailcat promises no stable wire format, so a server far
  from that version may need a natives upgrade.
- An address that names a relay region makes the client fetch tailcat's relay
  map from `tailcat.dev` and use the DERP relays it lists. An address that
  names its own relays uses only those.
- A build before this change keeps the entry untouched, as it does any kind
  it does not know, and reports its Routes' network as unavailable.
