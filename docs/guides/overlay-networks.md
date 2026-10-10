# Connect Heeler through an Overlay Network

Use Tailscale, ZeroTier, or EasyTier to reach a machine running herdr when direct SSH is unavailable. These guides cover a macOS Host and Heeler on iPhone or iPad. They need a Heeler build with **Settings > Overlay Networks** ([PR #426](https://github.com/ZingerLittleBee/Heeler/pull/426)).

Heeler runs its own network node inside the app. The phone needs no Tailscale, ZeroTier, or EasyTier app and no iOS VPN configuration. The Host needs the provider's client, an SSH server, and herdr. Joining the network does not replace SSH authentication.

## Choose a setup

Prepare the Host below, follow one provider tutorial, then return to [Connect from Heeler](#connect-from-heeler).

| Tutorial | Host setup | How Heeler joins | Effect on Mac networking |
| --- | --- | --- | --- |
| [Tailscale](tailscale.md) | Standalone app, signed in | Browser sign-in or auth key | Network extension and VPN configuration |
| [Tailscale userspace](tailscale-userspace.md) | `tailscaled --tun=userspace-networking`, SSH forwarded with Serve | Same as Tailscale | No TUN or system VPN; other Mac apps get no tailnet routes |
| [ZeroTier](zerotier.md) | ZeroTier One, joined and authorized | An admin authorizes Heeler's own node ID | Virtual interface with managed addresses and routes |
| [EasyTier](easytier.md) | CLI peer | Matching name and secret, or a Config Server assignment | The guide's `--no-tun` peer creates no TUN |

For a Linux or Windows Host, install the provider's client from its own documentation, then follow the same Heeler steps. Native Windows also needs the [Windows SSH and herdr setup](windows-setup.md).

## Heeler setup screenshots

**Settings > Overlay Networks > Add Network** shows one form per provider; EasyTier has two sources. Tap an image to see it full size.

| Tailscale | ZeroTier |
| --- | --- |
| <a href="images/overlay-networks/tailscale-form.png"><img src="images/overlay-networks/tailscale-form.png" width="260" alt="Tailscale form with Name, Device name, and an Advanced row"></a> | <a href="images/overlay-networks/zerotier-form.png"><img src="images/overlay-networks/zerotier-form.png" width="260" alt="ZeroTier form with Name, Network ID, and an Advanced row"></a> |
| Leave **Advanced** blank and tap **Continue to Sign In**. [Tailscale setup](tailscale.md#3-join-the-same-tailnet-from-heeler) | Enter the network ID and tap **Add and Connect**. [ZeroTier setup](zerotier.md#3-heeler-and-central-join-and-authorize-the-app) |

| EasyTier Network | EasyTier Config Server |
| --- | --- |
| <a href="images/overlay-networks/easytier-manual-form.png"><img src="images/overlay-networks/easytier-manual-form.png" width="260" alt="EasyTier Network form with network name, secret, and peers"></a> | <a href="images/overlay-networks/easytier-config-server-form.png"><img src="images/overlay-networks/easytier-config-server-form.png" width="260" alt="EasyTier Config Server form with a server URL and this device's Machine ID"></a> |
| Match the Mac's network name and secret and add its peer endpoint. [Network setup](easytier.md#3-add-the-network-in-heeler) | Enter the operator's full server URL and assign a network to the Machine ID. [Config Server setup](easytier.md#2-register-heelers-device) |

The values shown are examples.

## Prepare the Host

Do these steps on the Mac that runs herdr, as the account Heeler will log into.

1. Install and start [herdr](https://herdr.dev/docs/install/) and open the session you want. QR pairing ([README](../../README.md#adding-a-machine)) is optional; you can enter the Host by hand.
2. Turn on **System Settings > General > Sharing > Remote Login** and allow the account ([Apple's guide](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac)). Keep the Mac awake.
3. Note the short username, the SSH port (usually `22`), and the herdr session name (leave it blank in Heeler for the default).
4. Read the SSH host-key fingerprint on the Mac so you can compare it in Heeler later:

```sh
id -un
herdr --version
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

If Heeler's trust prompt shows a different key type, compare it with that type's public host key instead.

Prepare one authentication method:

| Heeler method | On the Host |
| --- | --- |
| Device Key | In the Host form, choose **Device Key > Copy authorized_keys Line**. Append it to the account's `~/.ssh/authorized_keys`; keep `~/.ssh` at `700` and the file at `600`. The private key stays on the phone. |
| RSA Key | Choose **RSA Key > Copy RSA Public Key** and authorize it for the account. |
| Password | Use the account's password, if the SSH server allows passwords. Type it only into Heeler. |

You can copy a public key from an unsaved Host form and cancel it until the network is ready. A key enrolled through QR pairing also works. The userspace recipes need SSH listening on `127.0.0.1`; their tutorials show how to check.

## Connect from Heeler

First finish the provider tutorial, so the Mac and Heeler share a network and both have addresses. Adding a network opens its screen and connects it. A Tailscale network without an auth key starts browser sign-in instead; return to Heeler afterwards and it connects on its own.

1. Open **Hosts > Add Host**. For Tailscale and EasyTier you can instead tap **Add** beside a machine on the network's screen; this fills in its address.
2. Under **Network** at the top of the form, select the saved network. **Direct** uses the phone's own connection, including any system VPN, not Heeler's node.
3. Fill in the fields below and save.
4. Trust the SSH fingerprint only if it matches the one from the Mac. If a check fails, fix the cause and tap **Run Checks Again**.

| Host field | Value |
| --- | --- |
| Name | A label for this Mac |
| Address | The Mac's overlay IP, with no port or `/prefix` |
| Port | The SSH port, normally `22`; for Tailscale userspace, the Serve listener's port |
| User | The Mac's short username |
| Authentication | The method you prepared |
| herdr Session | The session name, or blank for the default |
| Jump Host | Blank for these tutorials |
| Network | The saved Tailscale, ZeroTier, or EasyTier network |

Tailscale offers **Choose from Tailnet…** and EasyTier **Choose from Network…**; pick the IP address first. For ZeroTier, copy the Mac's managed IP from Central or the Mac. The paths Heeler lists for ZeroTier members are not SSH addresses.

With a Jump Host, the overlay network carries only the hop to the Jump Host, which then reaches the final Host itself. See the [Jump Host setup](vps-jump-host-setup.md).

## Verify the connection

Check each layer on its own. A working network says nothing yet about SSH or herdr.

| Check | Passes when |
| --- | --- |
| Membership | Both devices are on the intended network, approved, with addresses |
| Heeler network | The network shows **Connected**; for a Config Server, the assigned network is running |
| SSH | The fingerprint matches the Mac and authentication succeeds |
| herdr | Host checks pass and the session's Agents or Terminals load |
| Terminal | A harmless command such as `pwd` in a disposable terminal returns output from the Mac |
| Remote access | The same works from cellular or another outside network; a Simulator on the Mac cannot show this |
| Resume | After the Background Grace Period, returning to Heeler reconnects the Host and the terminal |

Opening an Agent's live terminal can take over its existing attachment, so use a disposable terminal for these checks. Heeler's nodes stop after the Background Grace Period and restart when needed; they are not an always-on VPN.

## Diagnose the failed layer

| Observation | Next step |
| --- | --- |
| No **Overlay Networks** in Settings | The installed build predates this feature |
| **Not signed in** | Tap **Sign In**, finish in the browser, and check whether the device needs approval |
| **Waiting for authorization** (ZeroTier) or **Waiting for a network** (EasyTier Config Server) | Authorize the node ID, or assign and start a network for the Machine ID; the status card shows both |
| Network connected, SSH times out | Check the Host's Network, IP, and port, that the Mac is awake and listening, and the provider's access rules |
| SSH authentication fails | Check the account, Remote Login access, and the authorized key or password |
| SSH works, herdr fails | Read the failing check: herdr on PATH, session name, protocol version, or SSH stream-local forwarding |
| Network reconnects after you switch it off | A Host asked for it. Move or remove its Hosts before deleting the network |

For test coverage, screenshot provenance, and agent handoff, see [guide maintenance](../agents/overlay-network-guides.md).
