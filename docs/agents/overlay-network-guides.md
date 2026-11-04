# Overlay network guide maintenance

Use this record when maintaining the [setup guides](../guides/overlay-networks.md), checking their test coverage, or handing setup to another agent.

## Setup handoff

Record the tutorial and mode, Host OS and client version, Heeler build, SSH username and port, network identifier, Host overlay IP, herdr session, and last passing check. Exclude passwords, auth keys, network secrets, private keys, and token-bearing URLs; share sanitized errors only.

Inspect an existing installation before starting another daemon. Reuse its network and account when enrollment stalls. Complete browser sign-ins and OS prompts in their own UI, where the operator can see the account and requested access.

## Verification scope

The tutorials were written on **2026-10-09** against PR #426 at `eb52bf0c`. The scenarios below ran on `bb266061`; `eb52bf0c` also passed EasyTier peer-to-Host onboarding on iPhone and iPad Simulators. Not every scenario was rerun on the later build. These are historical results, not acceptance evidence for later candidates.

| Route | Verified live | Still needs deployment-specific checks |
| --- | --- | --- |
| Tailscale | Userspace daemon on a Mac, real tailnet, Simulator SSH, herdr, terminal, background recovery | Standard macOS app, physical phone on cellular |
| ZeroTier | Controller-less IPv6 ad-hoc network, Simulator SSH, herdr, terminal, recovery | Central enrollment, custom Planet and Moons, private controller, overlapping IPv4 |
| EasyTier | Network and encrypted Config Server, Simulator SSH, herdr, terminal, peer restart | Physical phone, eight-network limit, overlapping assignments, WSS failures |
| Cloudflare Tunnel | Physical iPhone over cellular: connector **Healthy**, a **Tunnel CIDR** route, Cloudflare One Agent with Split Tunnels in **Include** mode, a **Direct** Host route, herdr inventory and a terminal, background recovery | The VPS appendix, Gateway network policies, a route wider than one `/32`, two Hosts on one phone, the iPad, Cloudflare One Agent release drift |

Tailscale commands were checked against official documentation and **1.104.1** CLI help on **2026-10-09**. ZeroTier's guide was checked against Heeler's source and its linked official documentation on the same date.

On **2026-10-11** the guides were simplified for end users. Verification history and mechanism details now live only in this record and [ADR 0021](../adr/0021-in-process-overlay-networks.md); keep them out of the guides.

### Details removed from the guides (2026-10-11)

- **Tailscale userspace no longer uses Serve.** The guide relies on userspace netstack forwarding: with `--tun=userspace-networking`, a TCP connection to the node's own Tailscale IP on a port Serve does not handle is dialed to `127.0.0.1` on the same port (Tailscale v1.104.1 `wgengine/netstack/netstack.go`, enabled in userspace mode by `cmd/tailscaled`). Serve therefore added no access, and turning it off did not close port 22. The consequence the guide keeps is that every loopback-only Mac service is reachable from allowed tailnet devices, so access rules must limit Heeler to `tcp:22`. The live userspace run in the table below used Serve; the Serve-free flow and the `logout` removal steps were checked against source and CLI documentation only.
- **ZeroTier:** the Sockets SDK (libzt) userspace alternative was dropped because it needs a custom forwarding program. Custom Planet and Moon roots join one root set shared by every ZeroTier network in Heeler (ADR 0021); the guide keeps only that user-visible consequence.
- **EasyTier Config Server:** Heeler accepts `tcp://host:port/USER`, `udp://host:port/USER`, and `wss://host/path/USER`. A bare user name expands to `udp://config-server.easytier.cn:22020/USER`, but as of 2026-10-09 the EasyTier project no longer runs that hosted service. Required encryption uses EasyTier's Noise handshake, which does not authenticate a `tcp://` or `udp://` server; `ws://` would expose the account token, and Heeler rejects untrusted and self-signed WSS certificates. Details: [Config Server contract](../../Packages/HeelerOverlay/README.md#config-servers).
- **EasyTier relay:** the guide no longer says the Linux relay is untested. Its status is the [relay recipe check](#easytier-relay-recipe-check-2026-10-11) below: a local loopback check only, with no Linux VPS, public firewall, cellular, SSH authentication, or Heeler run. The guide's cellular step remains the user's acceptance check.

### EasyTier test details

On Simulators, candidate `bb266061` passed a Network entry against the official **v2.6.4** no-TUN peer: SSH, Host checks, herdr inventory, terminal input and output, background recovery, and peer restart. A local v2.6.4 Config Server with encryption required passed registration, assignment, SSH and terminal traffic, and continued use of an assigned network while the server was stopped. Candidate `eb52bf0c` added peer-to-Host onboarding on iPhone and iPad Simulators.

Not covered: physical phones, other internet, NAT, and relay setups, the eight-network limit, overlapping assignments, and WSS certificate failures. The self-hosting command was checked against v2.6.4 help and source; the live Config Server test used an isolated container.

### EasyTier relay recipe check (2026-10-11)

The relay documentation update on base `4395595d` was checked with the official macOS **2.6.4-8428a89d** binaries. Relay and Mac arguments were extracted from the tutorial, substituting loopback endpoints, isolated ports, a temporary network name and secret, and subnet `10.222.241.0/24`. A third CLI node stood in for the phone and forwarded a local test port to the Mac node's virtual port 22.

- A private no-TUN relay without an IPv4 assignment connected two outbound-only no-TUN peers with P2P disabled. The test client received the Mac's actual SSH banner through the relay.
- Stopping the relay prevented new SSH connections, confirming that traffic did not bypass it. All three test processes and scratch logs were removed; existing test services stayed running.
- The CLI's flag-only `--check-config` invocation exited with code 1 and no diagnostics; the checks above used actual process startup instead.
- Not tested: a Linux VPS, public firewall rules, cellular access, SSH authentication, or Heeler through this relay. This local check does not replace the tutorial's cellular acceptance step.

### Cloudflare Tunnel guide (2026-10-21)

The [Cloudflare Tunnel guide](../guides/cloudflare-tunnel.md) is adjacent to these
ones but not an Overlay Network: nothing in it is configured under **Settings >
Overlay Networks**, and Heeler gains no in-process node. Cloudflare's own app on
the phone is a system VPN (a Network Extension), which is what ADR 0021 avoids
running itself. Two shapes are documented:

- **Private network route.** `cloudflared` on the Mac as an outbound-only
  connector, a tunnel CIDR route in **Networking > Routes**, and the Cloudflare
  One Agent app on the phone enrolled in the same Zero Trust organization. The
  Host route is **Direct** with the Mac's private address. No domain is needed.
- **VPS appendix.** A published TCP hostname behind an Access application with a
  Service Auth policy, client-side `cloudflared access tcp` on a VPS holding its
  loopback listener, and a **Jump Host** route in Heeler. Requires a domain on
  Cloudflare, because a published hostname needs a zone, and non-HTTP service
  types require the client-side `cloudflared` or the VPN app.

Verification state: the **private network route** ran end to end on **2026-10-23
on a physical iPhone**: `cloudflared` on the Mac as the connector with the tunnel
**Healthy**, a **Tunnel CIDR** route for the Mac's address, Cloudflare One Agent
enrolled in the same team with Split Tunnels in **Include** mode, a **Direct** Host
route that connected, herdr inventory and a terminal, the same over cellular, and
a Host and terminal that reconnected after more than 20 seconds in the
background.

Also checked on 2026-10-21, without a Cloudflare account: the command surface
against `cloudflared 2026.9.0` (`tunnel route ip add`, `service install`,
`access tcp --hostname/--listener/--service-token-id/--service-token-secret`, and
the absence of `--hostname` on `tunnel run`), and the dashboard paths and Split
Tunnels behaviour against Cloudflare's pages of that date.

Not covered:

- The **VPS appendix**: published TCP hostname, Access application, Service Auth,
  and a **Jump Host** route. `cloudflared access tcp` ignored service tokens in
  2026.6.0 ([cloudflared#1674](https://github.com/cloudflare/cloudflared/issues/1674)),
  so read that ticket before relying on the appendix.
- Gateway network policies beyond the default allow, and a route wider than one
  `/32`.
- Two Hosts through the same VPN app at once, and the iPad.
- Cloudflare One Agent releases: one device, and no version number recorded, so
  treat the guide as a 2026-10-23 snapshot of that app's UI.

## Screenshots

The guides' screenshots are unedited Add Network forms from build `137a4aa3`, except the EasyTier Config Server form, recaptured in `f5f35846` after its Server prompt and footer changed. All were captured on **2026-10-10** on an iPhone 17 Pro Simulator (iOS 26.5), in dark appearance at the default text size. Names, addresses, and the server URL are examples. Credentials are blank, and the Machine ID belongs to a disposable Simulator.

When labels or behavior change, update the tutorial and its screenshot together. Keep required fields in the text so the steps work without images.

## Source references

- Shared UI: [network form](../../Sources/Heeler/Settings/OverlayNetworkFormView.swift), [network screen](../../Sources/Heeler/Settings/OverlayNetworkDetailView.swift), and [Host form](../../Sources/Heeler/Hosts/HostFormView.swift).
- Cloudflare Tunnel: [guide](../guides/cloudflare-tunnel.md), its pair page
  entry in [guides.json](../../docs-site/src/guides.json), and Cloudflare's
  [private network routes](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/private-net/cloudflared/connect-cidr/),
  [Split Tunnels](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/),
  and [arbitrary TCP](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/non-http/cloudflared-authentication/arbitrary-tcp/) pages.
- ZeroTier: [ZeroTierNetworkNode](../../Packages/HeelerOverlay/Sources/HeelerOverlay/ZeroTierNetworkNode.swift) and [ZeroTierRuntime](../../Packages/HeelerOverlay/Sources/HeelerOverlay/ZeroTierRuntime.swift). Recheck the guide's custom-root startup limitation when they change.
- EasyTier: [configuration URL contract](../../Packages/HeelerOverlay/Sources/HeelerOverlay/OverlayNode.swift) and [overlay package documentation](../../Packages/HeelerOverlay/README.md).
- Architecture and ownership: [ADR 0021](../adr/0021-in-process-overlay-networks.md) and [source map](navigation.md).
