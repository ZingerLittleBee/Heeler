---
status: proposed
---

# Reach Hosts through in-process Overlay Networks

Many Hosts sit behind NAT or carrier-grade NAT and are reachable only from
inside a Tailscale tailnet, a ZeroTier network, or an EasyTier network. Today
the user must run that network's own iOS app as a system VPN, or keep a Jump
Host with a reverse tunnel. Heeler adds **Overlay Networks**: a user
configures one in Settings, and a Host can name it so that the Host's first
hop is dialled through a userspace node running inside the app.

## Decision

- The repository-local `Packages/HeelerOverlay` package runs one userspace node
  per configured network (libtailscale/tsnet, libzt, EasyTier). Its public
  contract is `OverlayNode`: start, dial a TCP stream to `host:port`, status,
  stop. A dialled stream is one connected OS descriptor.
- `HeelerSSH` accepts that descriptor as an `SSHExternalStream` through
  `SSHConnection.connect(to:timeout:transportLabel:openStream:)`. Each
  handshake attempt dials a fresh stream.
- A Host stores an optional `overlayNetworkID`. When set, only the first hop
  uses the overlay: the Host itself, or its Jump Host when one is configured.
  The Jump Host's onward `direct-tcpip` hop to the Host is unchanged.
- Overlay failures are `TransportError.overlayFailed(network:reason:)`. They
  are never wrapped in `jumpHostFailed`, because the overlay sits in front of
  the Jump Host and nothing past this device was contacted.
- Network settings are persisted in UserDefaults like the Host catalog.
  Auth keys, network secrets, and the ZeroTier identity live in the Keychain
  under the separate `dev.bybee.heeler.overlay` service. Tailscale state lives
  in `Application Support/Overlay/<network id>/`, excluded from backup and
  protected until first unlock.

## Native libraries

The native libraries (CTailscale, CZeroTier, CEasyTier) are built and
published by their own repository,
[Ylarod/heeler-overlay-natives](https://github.com/Ylarod/heeler-overlay-natives),
as a Swift package of static XCFrameworks. That repository owns the pinned
upstream sources (submodules), Heeler's patches and C glue, the build, its
reproducibility and audit checks, and the licence notices; each release is a
tag whose manifest downloads the zipped XCFrameworks by URL and SwiftPM
checksum. `Packages/HeelerOverlay` depends on one release with an `exact`
version and keeps only the Swift layer and `CHeelerOverlaySupport`.

- Earlier builds committed the XCFrameworks, their build scripts, and the
  native sources under `Packages/HeelerOverlay`. Every native change grew
  Heeler's history by tens of megabytes and mixed Go, C++, and Rust builds
  with app review; the separate repository keeps them out of Heeler and
  lets CI rebuild and compare them byte for byte.
- An upgrade is a release there, then an exact version bump here (the
  manifest and `Package.resolved`) with the release's notices copied into
  the app bundle. A version range or branch is never used, so a build of
  Heeler always names the exact binaries it links.
- The LGPL corresponding source for CEasyTier is the natives release tag the
  binary was published under, and its Installation Information describes
  rebuilding there and overriding the release with a local checkout of that
  repository in Heeler's Xcode project.
- A distributed build records the Heeler commit it was archived from
  (`HeelerSourceRevision`, shown in About › Acknowledgements), and that
  commit's `Packages/HeelerOverlay/Package.swift` names the natives release.
  The marketing version alone cannot: an interim TestFlight build keeps the
  version of an earlier tag. A local archive records the commit only when it
  is pushed and nothing but the build number is uncommitted
  (`scripts/source-revision.sh`).

## Why not NetworkExtension

A packet-tunnel extension would make the overlay a system VPN: it requires
the Network Extension entitlement, a separate extension target with its own
memory limit, a VPN configuration profile the user must approve, and it
conflicts with any VPN the user already runs (including the official
Tailscale or ZeroTier apps). Heeler needs only outbound TCP to a few Hosts,
from its own process, while it is open. A userspace node in the app
process provides exactly that without changing the device's routing.

## Relationship to ADR 0011 and ADR 0018

ADR 0011 keeps one SSH backend and refuses a second transport path such as
`exec + socat`. Overlay Networks do not add a second SSH path. They replace
only the byte stream under the same libssh2 session: host-key TOFU,
authentication, direct-streamlocal channels, PTY exec, SFTP, and the
Windows branch of ADR 0018 behave identically. The overlay is a property of
the Host chosen by the user, never a fallback after a direct dial fails.

## Consequences

- libzt runs one ZeroTier node and identity per process. Every ZeroTier
  network shares that node and one device identity, generated on first use
  and saved through the node's `identityGenerated` callback. The identity is
  deleted only with the last ZeroTier network. Stopping a ZeroTier network
  only leaves that network; the process-wide node keeps running.
- The device's ZeroTier identity is created up front with
  `ZeroTierIdentity.generate()` when a ZeroTier network is added or viewed,
  so its node ID can be shown and authorized in ZeroTier Central or a
  self-hosted controller before the first connect. Generation (up to a
  second of key derivation) runs off the runtime actor; concurrent requests
  share it, and a ZeroTier node built meanwhile waits for it. If generation
  fails, the node mints the identity on first connect as before. When the
  process node still runs with an identity the Keychain no longer holds (the
  last ZeroTier network was deleted meanwhile), that identity is saved again
  instead of minting a conflicting one. An identity generated for an Add
  form that was cancelled is kept — its ID may already have been authorized
  — and shown in Settings with a way to forget it; it otherwise goes with
  the last ZeroTier network as before.
- Moons are per-network settings (world ID and seed, as in
  `zerotier-cli orbit`: a 10-to-16-hex-digit world ID and a 10-digit root
  address); changing them rebuilds that network's node. A custom planet is
  a per-network setting too: a planet-type World blob of at most 16 KB
  (moon files are refused) kept base64 in the network's catalog entry, so
  changing it rebuilds only that network's node, without a relaunch. libzt
  still takes one planet per process, so the process node keeps ZeroTier's
  own planet and Heeler's libzt patch adds each network's custom planet as
  a locally injected moon; a network on ZeroTier Central and one on
  self-hosted roots then run side by side. The trade-off is privacy: the
  node's root set is the union of every joined network's roots, and
  ZeroTier sends WHOIS lookups (and relays) through any of them, so a
  self-hosted root may learn which ZeroTier addresses this device looks up
  for other networks, and ZeroTier's roots those of the self-hosted network.
  The device-wide `Application Support/Overlay/zerotier-planet` of earlier
  builds is migrated once into every ZeroTier network without a planet of
  its own, then deleted.
- Tailscale Sign Out logs the device out at the coordination server through
  the node (building an unstarted one when none runs), then discards the
  node and deletes its state directory. tsnet marks itself logged out
  before it asks the server, so the state goes even when the server could
  not be told; the screen then asks the user to remove the device in the
  tailnet's admin console. Hosts connected through the network lose their
  connections, and the network stays signed out — recorded in memory and
  as a marker file in its state directory, so a relaunch keeps it — so
  Host dials fail with a non-retryable `signedOut` reason rather than
  silently registering again with a saved auth key. Only Connect in
  Settings clears it (as does a new auth key or coordination server); it
  then signs in, automatically when an auth key is saved. The revision is
  unchanged. ZeroTier and EasyTier have no sign-in and no Sign Out.
- A network's screen shows what its node reports through `details()` —
  this device's name, overlay addresses, node ID, and peers with
  online/direct/latency — polled with the status while the screen is open,
  never starting a node. The name and peers appear only while the node is
  online: before tsnet has a network map it reports the OS host name, not
  the device name it will register. ZeroTier lists the node's peers across every
  ZeroTier network it joined, with physical paths (public IP and port)
  instead of overlay addresses, so that list is titled and labelled as such
  and offers no copying. An EasyTier network may fix this device's virtual
  IPv4 address in CIDR form instead of taking one from the network's DHCP;
  the form applies the package's rules (no 0.x, 127.x, or 224 and up) and
  notes that EasyTier treats /32 as part of its /24.
- The Host form can fill the first hop's address (the Jump Host's when one
  is set) from a Tailscale or EasyTier network's peers. Unlike the
  network's screen, choosing does start a node that is not online, as
  Connect does, except a signed-out Tailscale network. It fills the peer's
  IPv4 address by default, or the Tailscale machine name (the MagicDNS
  name's first label, which tsnet resolves); the package reports no full
  MagicDNS name. ZeroTier peers carry only physical paths, so ZeroTier
  offers no choice.
- An EasyTier network is either manual (the app holds its name, secret,
  and peers) or comes from an EasyTier **Config Server** (`--config-server`,
  the web console), which assigns it to the device. The server URL
  (`udp`, `tcp`, `ws`, or `wss://host:port/<user>`; a bare user name means
  the official `config-server.easytier.cn`) is validated by the package.
  Its user name is the only credential: anyone who knows it can register a
  device to that account, so the full URL lives in the Keychain and the
  catalog keeps only `scheme://host:port`; the detail screen shows the user
  name masked. The app mints a machine ID for the device (iOS has no
  machine-id file) and saves it with the settings; Reset Machine ID makes
  the console list the device as new. Trust model: the session upgrades to
  EasyTier's Noise NN tunnel whenever the server offers it, and by default
  must (Require Encryption, a per-network setting that is on unless turned
  off; catalog entries saved without it require it): a server that does
  not offer it, or a path that strips the offer from the plaintext feature
  probe, is retried, never used in clear text. Turned off, such a server is
  used in clear text — for older or minimal servers on a trusted network —
  and the form warns that the user name and network secret can be read,
  the network changed, and the server impersonated. Noise NN encrypts but does
  not authenticate the server, so over udp, tcp and ws anyone who can
  intercept the path can pose as the server and learn the user name and
  every network secret it hands out; only wss authenticates the server (the
  certificate and name are checked against the system trust store;
  self-signed certificates are not supported). Token exposure: udp and tcp
  send the user name only inside the Noise tunnel; ws sends it in clear text
  in the HTTP upgrade path, wss inside TLS. The form warns about ws (clear
  text, prefer wss) and udp/tcp (server not verified). Whatever the
  transport, the server knows the network secret and decides which peers
  the device connects to, so the server — and, short of wss, the network
  path to it — must be trusted. Network reports to the server carry no
  underlay address (interface, LAN, or public addresses, ports, peers'
  public addresses, or management events). The package forces whatever the
  server sends to be outbound-only — listeners are stripped, exit nodes,
  port forwards, and subnet proxies refused, relaying, public-IPv6
  provision, broadcast relay, magic DNS and UPnP forced off, config patches
  rejected. A server may assign up to eight networks, each run as an
  EasyTier instance of its own under the same policy; one more, or a second
  network with a name already running, is refused and reported to the
  server as failed. Manual wss peers do not check
  certificates (EasyTier listeners use self-signed ones by default); peers
  authenticate each other with the network secret.
  Until the server assigns one the node reports `waiting`; a Host dial then
  fails as retryable `notReady` and the screen asks the user to assign a
  network to the device's machine ID. A source added by a newer build is
  preserved untouched, like an unknown kind.
- EasyTier networks run side by side. The native library keys every call
  with an instance key — the Overlay Network's UUID — and each key holds one
  manual network or one config-server session, as EasyTier instances of
  their own (own peers, routes, and smoltcp stack) on one shared two-worker
  Tokio runtime: each running network costs about 3 MB of memory and no
  threads of its own. Keys start, stop, and fail independently (a slow start
  of one never holds up another); a new configuration under a key replaces
  only that key, and suspension stops them all. A dial goes through exactly
  one instance, and hostnames resolve only in that instance's route table,
  so two networks may share a subnet — even this device's address and a
  peer's — without one network's traffic reaching the other: EasyTier's
  data plane is per instance, with no shared routing table or socket
  between instances. The process allows 32 keys at once.
- ZeroTier networks share the process node, and two of them may assign
  this device the same address and overlapping subnets. Every dial is bound
  to its Host's network: to the device's address there and to that
  network's lwIP interface, so it goes out and comes back on that network
  alone and never takes a route another network's controller pushed. A
  bound socket bypasses lwIP's routing table, so before connecting the dial
  checks that the network reaches the IPv4 destination by itself (its
  subnet, or one of its managed routes through a gateway on it) and fails
  at once when it does not, instead of waiting for the timeout.
- A config-server session with several networks picks one per dial; a Host
  names only the Overlay Network, not one of its assigned networks. With
  one running network it takes every dial. With several, an IPv4 address
  selects the one network with a peer at exactly that address, else the one
  whose own virtual subnet holds it; a name selects the one network with a
  peer of that name. More than one fit is refused (the console should give
  its networks distinct subnets and names) rather than guessed; peers'
  advertised subnets never select a network, so a peer of one network
  cannot draw another network's traffic by announcing a route. The C ABI
  also takes an explicit network name or instance ID, which the app does
  not use yet: a per-Host choice would need a Host field and UI, and the
  automatic choice covers distinct subnets. The trade-off: when a peer of
  one network is offline, a peer claiming the same address on another
  assigned network of the same console wins the selection — acceptable
  because one console (one trust domain) controls both. The network's
  screen lists every assigned network with its state, address and prefix,
  or why it was refused, and groups peers by network; peer choices carry
  their network's name.
- A node is replaced only after its predecessor's `stop()` has finished, so
  an old and a new Tailscale node never share a state directory. A rename
  reuses the node; a settings or secret change rebuilds it. A new Tailscale
  auth key or coordination server also discards the saved login state.
- Start failures that can clear on their own — awaiting admin approval, no
  address assigned yet, a controller briefly unreachable — are retried with
  the Console's ordinary backoff. Five consecutive failures of one network
  revision become terminal, so a rejected key does not retry forever behind
  a summary. Malformed settings and interactive sign-in stop at once.
- Every wait on a node can be cancelled (Connect, choosing a peer, a Host's
  checks, a Console connection). The runtime returns as soon as its caller
  is cancelled, without waiting for a native call that ignores it, and
  closes a stream that arrives afterwards. Cancellation is not a start
  failure. A Tailscale or EasyTier node that never came up and that nothing
  else waits for is stopped and discarded (tsnet closes the server it was
  starting); a ZeroTier network stays joined, so a later authorization
  still applies.
- Sign-in links are offered only over https (or plain http to the network's
  own http coordination server); the coordination server must be https.
- libtailscale embeds a Go runtime, which adds several megabytes to the app
  binary and its own threads at run time. That cost applies to every user,
  including those who never configure a network.
- Nodes run only while Heeler is running. On suspension after the
  Background Grace Period the app calls `stop()` on every node and discards
  it; the next dial after the app returns rebuilds it. What `stop()` does is
  the backend's: tsnet and EasyTier shut down, ZeroTier leaves the network.
  Overlay Networks therefore do not keep Hosts reachable in the background;
  Agent Notifications still arrive through the Push Relay.
- Peer discovery on the local network can trigger iOS's local-network
  prompt, so the app declares `NSLocalNetworkUsageDescription`.
- Host-key trust is keyed by the address and port the user typed. An
  overlay address (100.x, a MagicDNS name, a ZeroTier IP) is a different key
  from the same machine's LAN or public address, so the first overlay
  connection asks for fingerprint confirmation again.
- Downgrade: Host records gain `overlayNetworkID`. A build without Overlay
  Networks decodes such a Host, connects it directly, and drops the field on
  its next save of that Host; the overlay choice must then be made again
  after upgrading. The Overlay Network catalog itself is a separate
  UserDefaults key that older builds ignore.
- Pairing still dials Pairing Code addresses directly. Pairing over an
  Overlay Network is a separate decision.

## Licensing

- libtailscale and the tailscale.com modules are BSD-3-Clause.
- libzt was released under the Business Source License 1.1, whose change
  date converted it to Apache-2.0 on 2026-01-01.
- ZeroTierOne 1.16.2's core (`node/`, `osdep/`) is MPL-2.0; ZeroTier
  relicensed it from the Business Source License in 1.16.0. Heeler's libzt
  patches modify MPL-covered files in `node/`, so the natives release tag is
  their Source Code Form. Nothing from ZeroTierOne's source-available
  `nonfree/` directory is compiled.
- EasyTier is LGPL-3.0 and is linked statically. Heeler is Apache-2.0 open
  source and can be rebuilt from its repository, which satisfies the
  relinking obligation of LGPLv3 §4(d)(0); the app ships the LGPL and GPL
  texts. **Risk:** LGPLv3 §4 requires the terms of the combined work not to
  restrict modifying the library or reverse engineering to debug such
  modifications, and GPLv3 §10 forbids further restrictions. Whether the App
  Store's terms are such restrictions is unsettled: the FSF argued so in
  2010, and VLC was pulled in 2011 after a contributor's complaint. Any
  EasyTier contributor could raise it, and the project has no CLA. The
  Installation Information requirement (§4(e)) is likely not the issue: it
  applies only when the code is conveyed with the transfer of a User
  Product, and App Store distribution transfers no device. This needs legal
  review before an App Store release that includes EasyTier.
- The package's notices inventory records the audited versions; the notice
  texts are those of the heeler-overlay-natives release Heeler depends on.
