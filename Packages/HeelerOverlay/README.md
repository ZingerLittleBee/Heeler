# HeelerOverlay

`HeelerOverlay` runs overlay-network nodes inside the app process — no
NetworkExtension, no system VPN — and exists only to dial TCP byte streams
that `HeelerSSH` then uses through `SSHExternalStream`. The public contract is
`Sources/HeelerOverlay/OverlayNode.swift`.

| Backend | Native library | Notes |
| --- | --- | --- |
| Tailscale | libtailscale (tsnet, Go `c-archive`) as `CTailscale` | One tsnet server per configured tailnet, with its own state directory. Interactive login surfaces tsnet's `AuthURL`. |
| ZeroTier | libzt (ZeroTierOne + lwIP, C++) as `CZeroTier` | One node per process, started once and never stopped (Heeler does not call `zts_node_stop`); networks are joined and left on demand; each dial is bound to its network's interface, so networks that assign the same address stay apart. |
| EasyTier | EasyTier (Rust, smoltcp data plane, no TUN) through the `heeler-easytier` crate as `CEasyTier` | Any number of networks side by side, one EasyTier instance per `EasyTierConfiguration.instanceKey` (the app uses the Overlay Network's UUID); a different configuration under the same key replaces that key's network only. A network is either configured in full (peers are `tcp://`, `udp://`, `ws://` or `wss://`; the address comes from DHCP unless a fixed `ipv4` is configured) or assigned by an EasyTier config server (`--config-server`, EasyTier's web console), which may assign up to eight; a dial picks the one the destination fits. |

The native libraries come from
[heeler-overlay-natives](https://github.com/Ylarod/heeler-overlay-natives),
which builds them from pinned upstream sources with Heeler's patches and glue
into static XCFrameworks and publishes them as a Swift package with the
products `CTailscale`, `CZeroTier`, and `CEasyTier` (ADR 0021). That
repository owns the upstream pins, patches, build, reproducibility and audit
checks, exported-symbol checks, and the licence notices; this package keeps
the Swift layer and `CHeelerOverlaySupport` (the libzt stream pump and
connect).

## Dependency

`Package.swift` depends on one release of heeler-overlay-natives with an
`exact` version, never a range or branch:

```swift
.package(url: "https://github.com/Ylarod/heeler-overlay-natives.git", exact: "<version>")
```

Until its first release (1.0.0) is published, the manifest uses a path
dependency on a sibling checkout instead (`../../../heeler-overlay-natives`,
next to this repository), whose development manifest serves the frameworks
its `scripts/build.sh` wrote to `build/Artifacts`. A path dependency never
appears in `Package.resolved`, and CI cannot resolve it; the switch to the
release is one command (below).

### Upgrading

1. In heeler-overlay-natives: change the sources, build, verify, and cut a
   release (`scripts/release.sh <version>`, then push the tag and create the
   GitHub release; see its README, "Releases").
2. Here, from the repository root:

   ```sh
   scripts/use-overlay-natives-release.sh <version>
   ```

   It sets the `exact` version in `Package.swift`, downloads the release's
   `Notices.zip` (checked against its `SHA256SUMS`), copies the notices
   into `Sources/Heeler/Resources/Notices`, and resolves the packages, so
   `Heeler.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   records the new pin. It commits nothing.
3. Review the notice diff and update `inventory.json` (component versions,
   and `dependencyCoverage.heelerOverlayNatives` when a product's components
   change); `LicenseNoticeTests` checks that every product the manifest uses
   is covered and that EasyTier's notice names heeler-overlay-natives as the
   corresponding source. Then run this package's tests and the app tests,
   and commit the manifest, `Package.resolved`, and the notices together.

When a sibling checkout with a build exists, `LicenseNoticeTests` also
compares the bundled overlay notices with its `build/Artifacts/Notices` byte
for byte.

### Working against a local build

To try native changes before a release, build them in a checkout named
`heeler-overlay-natives` and add it to Heeler's Xcode project as a local
package: SwiftPM lets a local package override the remote one of the same
identity (heeler-overlay-natives' README, "Using a local build in Heeler").
Do not commit a path dependency once a release is pinned.

## EasyTier

CEasyTier wraps EasyTier in the `heeler-easytier` crate (heeler-overlay-natives,
`native/easytier`) behind C ABI version 2 (`HEELER_ET_ABI_VERSION`):
every call takes an instance key (Heeler passes the Overlay Network's UUID);
a key holds one manual network (`heeler_et_start`) or one config-server
session (`heeler_et_web_start`), each network its own EasyTier instance on
one shared runtime, at most 32 keys at once. `heeler_et_tcp_connect_fd`
returns a non-blocking `AF_UNIX` socketpair end with `SO_NOSIGPIPE` and dials
through exactly one network (the app passes no network name and relies on
the automatic choice; several fits are refused as ambiguous);
`heeler_et_status_json` reports a key's networks, addresses, and peers
(hostname, virtual IPv4, `direct` for route cost 1, and a latency). A fixed
`ipv4` (`a.b.c.d/n`) turns DHCP off; one that does not parse or is not
unicast is refused, there and in the Swift renderer.

The node only dials out. `heeler_et_start` forces `no_tun`, no exit-node
service, `disable_relay_data`, an empty `relay_network_whitelist`, and
`private_mode`; turns off peer-RPC relaying, foreign-network KCP/QUIC
relaying, KCP/QUIC proxying and input, `proxy_forward_by_system`, UDP
broadcast relay, magic DNS (`accept_dns`), UPnP port mappings, and the
public-IPv6 provider (and client); and refuses listeners, `exit_nodes`,
`proxy_network`, `port_forward`, SOCKS5, and VPN portals.
`patches/easytier/0001-outbound-only-packet-proxy.patch` also stops
EasyTier's packet proxy from honouring a peer-set exit-node bit or
forwarding a peer to the phone's loopback through its virtual IP; CEasyTier
does not start that proxy at all, so the patch is defence in depth.

### Config servers

`heeler_et_web_start(key, url, machine_id, hostname, secure_mode, …)` runs
the device side of `easytier-core --config-server` (`native/easytier/src/web.rs`): it connects to an EasyTier
config server — `udp://` or `tcp://host:port/<user>`, or `ws://` or
`wss://host[:port]/…/<user>`; the official server is
`udp://config-server.easytier.cn:22020/<user>`, which
`EasyTierConfigServer.normalizedURL` expands a bare user name to — registers as
the device `machine_id` (a UUID the app keeps; iOS has no machine-id file for
EasyTier to derive one from) and runs the networks the console assigns.
Under one instance key, `heeler_et_start` and `heeler_et_web_start` replace
each other; other keys are untouched.

Upstream hands the server EasyTier's whole process-management RPC.
`patches/easytier/0002-web-client-backend.patch` only makes the client's backend
pluggable (visibility, and `run_web_client_with_backend`), and Heeler's
backend serves `WebClientService` and `ConfigRpc` alone — no peer, connector,
port-forward, credential or logger management, and no file storage — under
these rules:

- every network passes the `heeler_et_start` policy after `listener_urls` is
  dropped (the console adds tcp, udp and wg listeners to every new network);
  a credential file, disabled encryption and managed credentials are refused;
- at most eight networks (`HEELER_ET_MAX_WEB_NETWORKS`), each its own
  EasyTier instance; a ninth, or a second network with a name already
  running, is refused and reported to the server as a failed instance (and
  in the status's `web.failures`);
- `PatchConfig` is refused (hot patches would bypass the policy); the server
  reads back the configuration it sent, so its reconcile does not take the
  forced flags for drift and restart the network;
- network reports carry no underlay address: no interface, LAN or public
  addresses, listeners, STUN public IPs or ports, tunnel local and remote
  addresses, peers' public IPv4/IPv6, or management events (they name
  tunnels by address); virtual addresses, hostnames, routes, costs,
  latencies and NAT types stay;
- at most the 16 most recent refused networks are remembered;
- a network without a hostname gets the app's.

The session always upgrades to EasyTier's encrypted web tunnel (Noise NN)
when the server offers it. With `secure_mode` (the app's per-network
Require Encryption, on by default; `EasyTierConfigServer.requireEncryption`)
a server that does not offer it — or a path that strips the offer from the
plaintext feature probe — is retried, never used in clear text; without it
such a server is used in clear text, where the token and the networks it
sends can be read and changed on the path. A session with a different
`secure_mode` is a different session (restarted, not kept). That tunnel does not authenticate the server, and the server
knows every network secret it hands out, so the server is trusted either
way; only wss:// authenticates it. The user name (token) travels inside the
Noise tunnel for udp:// and tcp://, inside TLS for wss://, and in clear text
for ws:// (it is the HTTP upgrade request's path); the app's form warns
about ws:// and about udp:// and tcp:// not verifying the server.
`patches/easytier/0003-websocket-verify-server-certificates.patch` makes the
config-server connection (only the connector `run_web_client_with_backend`
creates, flagged through its `GlobalCtx`) verify the wss:// server's
certificate and name with the system trust store (rustls-platform-verifier;
upstream accepts any certificate and sends "localhost" for an IP host).
Self-signed config servers are refused; a trusted fingerprint option could be
added later. Manual wss:// peers keep upstream's behaviour and do not check
certificates: EasyTier listeners serve a self-signed one by default, and
peers authenticate each other with the network secret. ws:// and wss://
cost about 20 more crates (rustls, rustls-platform-verifier,
tokio-websockets, webpki-roots, rcgen…); ws/wss listeners stay refused.

## Licences

The notices for everything linked into the three frameworks are generated by
heeler-overlay-natives (`build/Artifacts/Notices`, and `Notices.zip` in each
release) and copied verbatim into `Sources/Heeler/Resources/Notices`, listed
in `inventory.json`. libzt is under the Business Source License 1.1 with
Change Date 2026-01-01 and has converted to Apache-2.0; ZeroTier One 1.16's
core (`node/`, `osdep/`) is MPL-2.0 (its source-available `nonfree/`
controller is not linked), with prometheus-cpp-lite (MIT) and
moodycamel::ConcurrentQueue (BSD-2-Clause); `ZeroTier-Heeler-modifications.txt`
lists Heeler's patches and the files they change, and names the
heeler-overlay-natives release tag as the source of the modified MPL files. libtailscale, Tailscale, and Go are BSD-3-Clause;
the other Go modules are listed in `Tailscale-Go-modules.txt`. EasyTier is
LGPL-3.0 and linked statically: `EasyTier-LGPL-3.0.txt` names the
corresponding source (the heeler-overlay-natives release tag the CEasyTier
binary was published under) and the installation information LGPL-3.0
section 4(e) asks for; the `heeler-easytier` wrapper is LGPL-3.0-or-later,
and the Rust crates and standard library linked into CEasyTier are listed in
`EasyTier-Rust-crates.txt`.

## Runtime notes

- Every native call runs on a dedicated thread, never on the cooperative
  pool (`BlockingCall`). `tailscale_dial` cannot be cancelled: a dial that
  outlives its deadline closes the descriptor it eventually returns.
- tsnet does not refuse an address no peer owns; the dial hangs until its
  deadline. So a Tailscale dial to an IP literal first checks the network map
  in `tailscale_status_json`: an address that is no peer's or this node's
  (`TailscaleIPs`), in no peer's `AllowedIPs` or `PrimaryRoutes` (subnet
  routes, 4via6; default routes count only through the selected exit node),
  with no exit node in use (`ExitNodeStatus`, or a peer's `ExitNode`), fails
  at once with "… is not on this tailnet". tsnet reports Running before the
  network map lists every peer, so within 5 seconds of coming online such an
  address is checked again until it routes or the window ends. Names, a
  status that cannot be read, and one without a network map (`CurrentTailnet`)
  are left to tsnet.
- Node details (`OverlayNode.details()`) never start a node. ZeroTier's come
  from `native/zerotier/heeler_zerotier.cpp` in heeler-overlay-natives,
  compiled into libzt's `src/` (hash in `PROVENANCE.md`): libzt cannot list peers itself (its
  `zts_core_query_path*` are stubs and its peer events copy `ZT_Peer` into a
  struct with a different layout), so `heeler_zt_peers` reads
  `ZeroTier::Node::peers()` under libzt's service lock. Like libzt's own
  control calls, it is not safe against a fatal exit of libzt's service
  thread, which deletes the node without those locks; it refuses once a
  termination reason is recorded, which narrows but cannot close that window
  without changing libzt. The list is
  node-wide, and planet and moon roots are left out. Tailscale's come from
  `tailscale_status_json`; EasyTier's from `heeler_et_status_json`.
- Moons (`ZeroTierConfiguration.moons`, seeds of at most 10 hex digits) are
  reference-counted across joined networks: orbited once the node is online
  and before the network join, deorbited when the last network declaring them
  leaves. Network and moon references change before the runtime actor first
  suspends, and the libzt calls they imply are queued in that same step, so
  concurrent joins and leaves stay in step with libzt. `zts_moon_orbit`
  reports success whenever the node runs, so a moon that cannot be reached
  is not reported.
- The node always runs on ZeroTier's own planet. A network's self-hosted
  planet (`ZeroTierConfiguration.roots`) is checked by
  `heeler_zt_planet_inspect` before the join and added to the running node as
  a local moon (`heeler_zt_add_moon`, signed with a throwaway key; the moon ID
  is the planet's world ID, or one derived from its roots when that is
  ZeroTier's 149604618 or taken), reference-counted like moons and removed
  with `zts_moon_deorbit`. Local and orbited moons share libzt's moon IDs and
  a deorbit removes whichever has the ID, so an orbited moon keeps its world
  ID and a local moon holding it moves to its roots ID first. An add the node
  refuses is shown in the diagnostics and tried again by the next join,
  leave, or status poll (at most every 5 seconds). So networks on ZeroTier's
  roots and on any number of self-hosted ones run side by side, and changing
  a planet needs no relaunch. ZeroTierOne assumes all of a node's roots
  share one peer database; `patches/libzt/0001-independent-root-sets.patch`
  makes it look peers up in one root of each root set and relay through the
  root that relayed the peer to it (or one per set), and adds
  `Node::addLocalMoon`.
- `patches/libzt/0002-managed-gateway-routes.patch` installs a network's
  IPv4 managed routes through a gateway (a LAN behind a member) in lwIP;
  libzt itself only assigns addresses. Each network's controller sets its
  own routes, so they must not carry another network's traffic, and two
  joined networks may assign this device the same address and overlapping
  subnets. `heeler_zt_connect` (`CHeelerOverlaySupport`) therefore binds
  every dial to the Host's network twice: to the node's address there (a
  network without an address of the destination's family refuses the dial)
  and, with `heeler_zt_bind_network`, to that network's lwIP interface, so
  the connection leaves and returns on that network alone, whatever another
  network declares. A socket bound to an interface bypasses lwIP's routing
  table, so a destination its network cannot reach would go unanswered
  until the timeout; before connecting, `heeler_zt_network_reaches` checks
  that the network reaches an IPv4 destination by itself (its subnet, or
  one of its managed routes through a gateway on that subnet), and the dial
  otherwise fails at once with "<address> is not reachable on ZeroTier
  network <id>" (`HEELER_OVERLAY_ERR_NO_ROUTE`). IPv6 is not checked. An
  unbound socket uses gateway routes only while a single network is up.
- `logout` signs out where the overlay has accounts. Tailscale's runs
  Heeler's `heeler_tailscale_logout` (LocalAPI logout: the coordination
  server forgets the node key) on a server started without the auth key, then
  empties the state directory; a directory without `tailscaled.state` was
  never logged in and is only emptied. ZeroTier and EasyTier have no sign-out,
  so their `logout` is `stop` (a config-server node's machine ID stays).
- Tailscale log upload is off. `setenv(3)` from Swift cannot do it: the Go
  runtime copies the environment at startup, and tsnet starts its logtail
  uploader without consulting `TS_NO_LOGS_NO_SUPPORT`. So the build adds
  `native/tailscale/heeler_tailscale.go` (heeler-overlay-natives) to
  libtailscale's package main (recorded with its hash in `PROVENANCE.md`). Its
  `heeler_tailscale_disable_log_upload` calls `envknob.SetNoLogsNoSupport`
  and `logtail.Disable` inside the Go runtime, and Swift calls it once before
  the first `tailscale_new`; `heeler_tailscale_log_upload_state` lets tests
  confirm both from the Go side. tsnet's own log lines are also discarded.
- libzt is configured without a storage path and with every cache disabled,
  so nothing it does reaches the disk; the identity goes to the app through
  `identityGenerated`, for the Keychain.
- libzt descriptors are lwIP descriptors, and lwIP is built without
  full-duplex sockets. `CHeelerOverlaySupport` therefore pumps each stream on
  one thread between the lwIP socket and a socketpair, with short timed polls
  on each side and half-close forwarded in both directions. `zts_errno` is a
  process-wide global, so the pump trusts readiness from `zts_bsd_poll`, not
  errno.

- EasyTier's native calls block; `EasyTierRuntime` runs them on one
  concurrent queue where start and stop are barriers, so a dial never lands
  on a network that replaced its own mid-call. Closing a dialled descriptor
  ends EasyTier's pump; there is nothing else to release.
- A dial to a port nobody listens on fails only at its timeout: EasyTier's
  userspace stack does not answer with a reset.
- A config-server node is `.waiting` while the server is unreachable
  ("Connecting to the config server") or has not assigned a network ("Assign
  a network to this device (machine ID …)"), `.failed` with the reason when
  the network the server sent was refused, and `.online` once that network
  has an address, even if the server becomes unreachable. `start` keeps
  polling while it waits and, at its timeout, throws the wait reason. Its
  details carry the machine ID as `nodeID` and the assigned network's name.

## Tests

```sh
xcodebuild test -scheme HeelerOverlay \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath /tmp/overlay-dd
```

The pump is exercised over an ordinary socketpair. Live suites that bring a
real ZeroTier node online and start a tsnet node to its login URL need
Internet access and run only when `TEST_RUNNER_HEELER_OVERLAY_LIVE=1` is set
for `xcodebuild` (adding `TEST_RUNNER_HEELER_OVERLAY_ZT_NETWORK=<id>` also
joins that ZeroTier network).

`TailscaleTwoTailnetLiveTests` runs two tsnet nodes on two independent
tailnets in one process: each sees only its own peers, the same address
(`100.64.0.1`) reaches each tailnet's own host, the other tailnet's
addresses are refused, and concurrent dials, stop and restart, and logout
keep them apart. `Tests/Support/two-tailnets.sh up` starts two Headscale
servers and their banner hosts in Docker and prints the variables the suite
reads (see the suite's documentation for their defaults):

```sh
Tests/Support/two-tailnets.sh up > /tmp/two-tailnets.env
env $(cat /tmp/two-tailnets.env | xargs) xcodebuild test -scheme HeelerOverlay \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -derivedDataPath /tmp/overlay-dd \
    -only-testing:HeelerOverlayTests/TailscaleTwoTailnetLiveTests
Tests/Support/two-tailnets.sh down
```

The servers speak plain HTTP on the Mac's en0 address (`HOST_IP` overrides
it), which tsnet accepts as a coordination server. Their embedded DERP is
HTTP too, and Tailscale clients only reach DERP over TLS unless
`TS_DEBUG_USE_DERP_HTTP=1` is set; without DERP no path to the hosts forms.
The script sets it for the hosts and prints
`TEST_RUNNER_TS_DEBUG_USE_DERP_HTTP=1` for the test: the Go runtime reads
the environment when the test process starts, so tsnet sees it. Nothing in
the app sets it.

`EasyTierMultiLiveTests` runs several EasyTier networks through the real
CEasyTier against the peers heeler-overlay-natives' `multi-peer` example
runs on the Mac (`native/easytier`, after `scripts/easytier-dev.sh`):

```sh
cargo run --locked --release --example multi-peer -- --web <easytier-web>
TEST_RUNNER_HEELER_OVERLAY_EASYTIER_LIVE=1 TEST_RUNNER_HEELER_OVERLAY_EASYTIER_WEB=1 \
    xcodebuild test -scheme HeelerOverlay \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -only-testing:HeelerOverlayTests/EasyTierMultiLiveTests
```

Without `..._WEB=1` only the manual-network test runs.

`ZeroTierDupIPTests` joins two ZeroTier networks of a self-hosted
controller that assign this device the same address, with one peer each at
the same address, and checks that every dial, sequential and concurrent,
reaches its own network's peer, and (phase `noRouteA`) that an address one
network has no route to fails at once. It runs with
`TEST_RUNNER_HEELER_OV_DUPIP=1` and the fixture variables its documentation
lists (`..._DIR`, `..._NETWORK_A`, `..._NETWORK_B`, `..._PHASE`).
