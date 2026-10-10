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

Tailscale commands were checked against official documentation and **1.104.1** CLI help on **2026-10-09**. ZeroTier's guide was checked against Heeler's source and its linked official documentation on the same date.

### EasyTier test details

On Simulators, candidate `bb266061` passed a Network entry against the official **v2.6.4** no-TUN peer: SSH, Host checks, herdr inventory, terminal input and output, background recovery, and peer restart. A local v2.6.4 Config Server with encryption required passed registration, assignment, SSH and terminal traffic, and continued use of an assigned network while the server was stopped. Candidate `eb52bf0c` added peer-to-Host onboarding on iPhone and iPad Simulators.

Not covered: physical phones, other internet, NAT, and relay setups, the eight-network limit, overlapping assignments, and WSS certificate failures. The self-hosting command was checked against v2.6.4 help and source; the live Config Server test used an isolated container.

## Screenshots

The guides' screenshots are unedited Add Network forms from build `137a4aa3`, captured on **2026-10-10** on an iPhone 17 Pro Simulator (iOS 26.5), in dark appearance at the default text size. Names, addresses, and the server URL are examples. Credentials are blank, and the Machine ID belongs to a disposable Simulator.

When labels or behavior change, update the tutorial and its screenshot together. Keep required fields in the text so the steps work without images.

## Source references

- Shared UI: [network form](../../Sources/Heeler/Settings/OverlayNetworkFormView.swift), [network screen](../../Sources/Heeler/Settings/OverlayNetworkDetailView.swift), and [Host form](../../Sources/Heeler/Hosts/HostFormView.swift).
- ZeroTier: [ZeroTierNetworkNode](../../Packages/HeelerOverlay/Sources/HeelerOverlay/ZeroTierNetworkNode.swift) and [ZeroTierRuntime](../../Packages/HeelerOverlay/Sources/HeelerOverlay/ZeroTierRuntime.swift). Recheck the guide's custom-root startup limitation when they change.
- EasyTier: [configuration URL contract](../../Packages/HeelerOverlay/Sources/HeelerOverlay/OverlayNode.swift) and [overlay package documentation](../../Packages/HeelerOverlay/README.md).
- Architecture and ownership: [ADR 0021](../adr/0021-in-process-overlay-networks.md) and [source map](navigation.md).
