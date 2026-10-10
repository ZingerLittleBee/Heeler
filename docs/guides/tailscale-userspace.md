# Tailscale on macOS Without a Network Extension or TUN

This guide runs the Homebrew `tailscaled` binary with `--tun=userspace-networking` and forwards one tailnet TCP port to the Mac's ordinary SSH server. Heeler then reaches herdr over that SSH connection. The Mac daemon creates no TUN interface or macOS VPN configuration in this mode, and Heeler uses its own in-app Tailscale node on iOS.

Use a Heeler build that includes [PR #426](https://github.com/ZingerLittleBee/Heeler/pull/426). This is a manual CLI setup for users who want to manage a daemon; for the standard desktop setup, use [Connect Through Tailscale](tailscale.md).

```text
Heeler's Tailscale node
  → Mac's userspace Tailscale node, TCP 22
  → Tailscale Serve raw TCP forwarding
  → 127.0.0.1:22, macOS Remote Login
  → herdr over SSH
```

## 1. Prepare and verify the local SSH server

Complete [Prepare the Host](overlay-networks.md#prepare-the-host). Before adding the overlay, check that SSH listens on IPv4 loopback:

```sh
nc -vz 127.0.0.1 22
```

Expect a successful TCP connection. If refused, check Remote Login and its listening port. Verify SSH authentication from Heeler in step 6.

## 2. Install the CLI binaries

With [Homebrew](https://brew.sh/) installed, install the formula:

```sh
brew install --formula tailscale
```

Start the daemon with the userspace flag below; `sudo brew services start tailscale` does not select this mode.

## 3. Start a private userspace daemon

In **Terminal A**, run:

```sh
TS_BIN="$(brew --prefix tailscale)/bin"
TS_STATE_DIR="$HOME/.local/share/heeler-tailscale"
umask 077
mkdir -p "$TS_STATE_DIR"
chmod 700 "$TS_STATE_DIR"
"$TS_BIN/tailscaled" \
  --tun=userspace-networking \
  --statedir="$TS_STATE_DIR" \
  --socket="$TS_STATE_DIR/tailscaled.socket"
```

Leave Terminal A running. Reuse this private state directory to retain the node's identity and settings, with only one daemon using it at a time.

## 4. Sign in through the private socket

In **Terminal B**, define the same paths, then sign in:

```sh
TS_BIN="$(brew --prefix tailscale)/bin"
TS_STATE_DIR="$HOME/.local/share/heeler-tailscale"
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" up \
  --hostname=heeler-mac-userspace
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" status
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" ip -4
```

Open the login URL printed by `up` and join Heeler's tailnet. Complete any required administrator approval, then record the IPv4 address from `ip -4`. This daemon is separate from any existing GUI app; use its IP and the same `--socket` in every command.

Use macOS Remote Login for authentication; leave Tailscale SSH (`--ssh`) disabled.

## 5. Forward tailnet port 22 to Remote Login

In Terminal B, configure the raw TCP forwarder and inspect it:

```sh
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" serve \
  --bg --tcp=22 tcp://127.0.0.1:22
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" serve status
```

Expect tailnet TCP port `22` forwarding to `127.0.0.1:22`. Tailnet policy must allow Heeler to reach this node on TCP 22.

Serve exposes this listener only to the tailnet, without occupying the Mac's local port 22 or changing Remote Login's existing LAN access.

## 6. Connect Heeler and verify the complete path

Follow [Join the same tailnet from Heeler](tailscale.md#3-join-the-same-tailnet-from-heeler), then [Connect from Heeler](overlay-networks.md#connect-from-heeler). Choose this Overlay Network in the Host form, select `heeler-mac-userspace` through **Choose from Tailnet…**, or enter the exact IPv4 address from step 4. Use Port `22`, the Mac's local account, and the SSH authentication method from step 1. Leave Jump Host blank.

Complete [Verify the connection](overlay-networks.md#verify-the-connection) from Heeler.

## Stop forwarding or stop the daemon

To remove only this Serve listener, run in Terminal B:

```sh
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" serve \
  --bg --tcp=22 off
"$TS_BIN/tailscale" --socket="$TS_STATE_DIR/tailscaled.socket" serve status
```

To stop the daemon, press **Control-C in Terminal A**. Keep the state directory. Restart with step 3's command, then check `status` and `serve status` through the same socket.

`serve --bg` saves the forwarding configuration; it does not run `tailscaled` in the background or at boot. Keep Terminal A open and the Mac awake. For unattended use, manage the daemon as a service with the same flag, state directory, and socket, or use the standard macOS app.

## Troubleshooting

| Symptom | Check |
|---|---|
| The CLI cannot reach `tailscaled` | Terminal A is still running and Terminal B uses exactly the same socket path. |
| The wrong node appears in `status` | Use the explicit Homebrew binary path and private `--socket`, then check the recorded node IP. |
| The node is online but SSH fails | `serve status` must show TCP 22, local loopback SSH must work, and tailnet policy must allow that port. |
| Local applications cannot reach tailnet addresses | Userspace mode provides no system routes. Use Heeler, another connected device, or configure an application-specific proxy separately. |
| Access stops after reboot or logout | The foreground daemon was not a persistent service. Restart Terminal A and verify the saved Serve configuration. |

## References

Commands checked against Tailscale **1.104.1** on **2026-10-09**: [macOS CLI](https://github.com/tailscale/tailscale/wiki/Tailscaled-on-macOS), [userspace networking](https://tailscale.com/docs/concepts/userspace-networking), [Serve TCP](https://tailscale.com/docs/reference/tailscale-cli/serve), and [SSH forwarding](https://tailscale.com/docs/reference/examples/serve#bind-local-services-to-your-tailnet).

For live test coverage, see [guide maintenance](../agents/overlay-network-guides.md#verification-scope).
