# Reach a Mac through Cloudflare Tunnel

Cloudflare Tunnel connects the Mac to Cloudflare with an outbound-only
connection, so your router opens no port. A Cloudflare client app on the phone
then carries Heeler's SSH session over that connection. The Mac still runs
Remote Login and herdr, and the Host is set up exactly as in the other guides.

This is a different route from [Overlay Networks](overlay-networks.md): you add
nothing under **Settings > Overlay Networks**, and Heeler gains no new network.
Cloudflare's own app runs as a system VPN on the phone, which makes the Mac's
private address reachable; a Host route then points at that address.

Because the phone runs a system VPN, it can't run alongside another VPN app such
as the official Tailscale client. Heeler's in-app Overlay Networks are not a
system VPN and keep working next to it.

## Choose a setup

| Approach | You need | Domain on Cloudflare |
| --- | --- | --- |
| [A private network route](#1-connect-the-mac-to-cloudflare) (this page) | A Cloudflare account, and the Cloudflare One Agent app on the phone | No |
| [A VPS with client-side `cloudflared`](#appendix-use-a-vps-instead-of-a-vpn-app) | A Cloudflare account, a domain on Cloudflare, and a VPS | Yes |

## Before you start

- A Cloudflare account with Zero Trust set up, giving you a team name. The
  personal free plan is usually enough; the dashboard says if a feature needs
  another plan.
- The Mac with [Remote Login and herdr prepared](overlay-networks.md#prepare-the-host),
  and its private address, such as `192.168.1.10`. That address is what Heeler
  will connect to.
- A current Heeler with Host Routes, and the phone or iPad you will connect from.

## 1. Connect the Mac to Cloudflare

1. In the [Cloudflare dashboard](https://dash.cloudflare.com/), go to
   **Networking > Tunnels** and select **Create a tunnel**.
2. Choose **Cloudflared**, name the tunnel (for example `herdr-mac`), and
   select **Save tunnel**.
3. Choose **macOS** and copy the installation command the page shows. It
   installs `cloudflared` and runs it as a background service with the tunnel's
   token, for example:

   ```sh
   brew install cloudflared
   sudo cloudflared service install <TOKEN>
   ```

   Run it in a terminal on the Mac. Use the exact command from the dashboard;
   the token is specific to this tunnel.
4. Wait for the tunnel's status to become **Healthy**, then select **Continue**.

The service keeps running after you close the terminal. Nothing on the Mac now
accepts a connection from the internet.

## 2. Route the Mac's address to that tunnel

1. Go to **Networking > Routes** and select **Create route > Tunnel CIDR**.
2. Select the tunnel you just created.
3. In **Network**, enter the Mac's address with `/32`, for example
   `192.168.1.10/32`. A whole LAN, such as `192.168.1.0/24`, also works, but
   every address in it then becomes reachable from your phone.
4. Select **Create route**.

By default every device enrolled in your organization may use this route. That
is usually what you want with one phone and one Mac; Gateway network policies
narrow it when it isn't, as the last troubleshooting row describes.

## 3. Enroll the phone

1. Install **Cloudflare One Agent** from the App Store.
2. Open it, enter your team name, and sign in through the browser when it asks.
   Accept the VPN configuration prompt. The app shows **Connected** when it is
   done.
3. In the dashboard, go to **Zero Trust > Team & Resources > Devices > Device
   profiles > General profiles** and select **Configure** on the profile your
   device uses.
4. Under **Split Tunnels**, select **Include IPs and domains**, then **Manage**
   and add two entries:

   | Type | Value |
   | --- | --- |
   | IP address | The address from step 2, for example `192.168.1.10/32` |
   | Domain | `<your-team-name>.cloudflareaccess.com` |

   **Include** mode sends only these destinations through the VPN app, so the
   rest of the phone's traffic is untouched. On iOS, domain entries are looked
   up when the VPN starts, so reconnect the app after you change them.

   If you would rather keep the default **Exclude** mode, delete the entry that
   covers the Mac (usually `192.168.0.0/16`, `10.0.0.0/8`, or
   `172.16.0.0/12`) and re-add the ranges you still want excluded with
   [Cloudflare's calculator](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/#remove-a-route).
   Don't empty the list: the phone would then send all its traffic through
   Cloudflare.

5. Wait up to ten minutes for the profile to reach the phone, then reconnect the
   app. Settings made here take a while to propagate.

## 4. Add the Mac as a Host

Follow [Prepare the Host](overlay-networks.md#prepare-the-host) for the Mac's
user, sign-in method, and herdr session, then add the Host with these values:

1. Open **Hosts** and tap **Add Host**. Under **Routes**, tap **Add Route**, set
   **Network** to **Direct**, fill in the address from step 2 and port `22`,
   leave **Jump Host** blank, and tap **Save**. (**Direct** means Heeler dials
   the address itself; the VPN app is what makes it reachable.)
2. In **Add Host**, fill in the remaining fields and tap **Save**.
3. Tap **Trust** only if the fingerprint matches the one from the Mac.
4. If iOS asks whether Heeler may find devices on your local network, allow it.
   The Mac's address is a private one, and the route fails without that
   permission.

At home the Mac usually answers on its LAN address too. A Host can have several
routes, so add the LAN address as a second route and Heeler keeps whichever
connects first. See [multiple routes](host-routes.md).

## Verify the connection

1. Cloudflare One Agent shows **Connected**, and the tunnel is **Healthy** in
   **Networking > Tunnels**.
2. Open the Host from **Hosts** and check that the route marked **In Use** is the
   one pointing at the Mac's private address.
3. The Host checks pass and the session's Agents or Terminals load.
4. In a **New Terminal**, `pwd` prints a folder on the Mac.
5. Turn off Wi-Fi on the phone and repeat over cellular, checking **In Use**
   again.
6. Leave Heeler for more than 20 seconds and come back. The Host and terminal
   reconnect. The VPN app runs its own connection in the background; check
   **In Use** again to confirm which route reconnected.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| Tunnel is **Inactive**, **Down**, or **Degraded** | The background service on the Mac is not running. Re-run the dashboard's install command, then check **Networking > Tunnels**. |
| The phone connects, SSH times out | Check the three pieces: the route CIDR (**Networking > Routes**), the Split Tunnels entry (same address), and that the VPN app is **Connected**. Then confirm the Mac is awake and Remote Login is on. |
| The Route CIDR matches, but nothing reaches the Mac | The Split Tunnels mode may still be **Exclude** with the Mac's range excluded. Add the Mac's address to the include list, or remove the covering exclude entry. |
| Settings were changed, nothing changed on the phone | Wait ten minutes, then disconnect and reconnect the VPN app. |
| **Can't Connect** with a timeout, on a phone that is on the Mac's own LAN | iOS may have denied local network access to Heeler. Check **Settings > Privacy & Security > Local Network** on the phone. |
| SSH login fails | Check the username, Remote Login access, and the key or password. |
| SSH works, herdr checks fail | Read the failing check. Usually herdr isn't installed for this account or the session name is wrong. |
| Another device on the LAN can reach services it shouldn't | A CIDR route exposes every address inside it, and by default every enrolled device may use it. Narrow the route to the Mac's `/32`, and add Gateway network policies under **Traffic policies** to allow only the destinations you want. |

## Appendix: use a VPS instead of a VPN app

This path needs no app on the phone, but it does need a domain on Cloudflare and
a small VPS. iOS can't run `cloudflared` itself, so the client side of an
arbitrary-TCP tunnel lives on a machine you already control, and Heeler reaches
it as a Jump Host. See also [the Jump Host guide](vps-jump-host-setup.md) for a
restricted jump account.

1. **Publish the Mac's SSH port.** Either give the tunnel a public hostname in
   the dashboard (**Networking > Tunnels**, **Routes > Add route > Published
   application**, service type **TCP**, `localhost:22`), or manage it locally:

   ```sh
   cloudflared tunnel login
   cloudflared tunnel create herdr-ssh
   cloudflared tunnel route dns herdr-ssh herdr-ssh.example.com
   ```

   with a config file, by default `~/.cloudflared/config.yml`, whose ingress rule
   is `- hostname: herdr-ssh.example.com` and `service: tcp://localhost:22`, run
   as `cloudflared tunnel run herdr-ssh`. `cloudflared tunnel run` does not take a
   `--hostname` shortcut, so name the hostname in the dashboard or in the config
   file.

2. **Protect the hostname.** In **Zero Trust > Access controls > Applications**,
   add a self-hosted application for that hostname, and give it a **Service Auth**
   policy. Create the token under **Access controls > Service Auth > Service
   tokens** and keep its secret on the VPS, not in the repository.

3. **Run the client on the VPS** as a service that restarts on failure:

   ```sh
   cloudflared access tcp \
     --hostname herdr-ssh.example.com \
     --listener 127.0.0.1:2222 \
     --service-token-id <ID> \
     --service-token-secret <SECRET>
   ```

   The listener stays on the VPS's loopback interface.

4. **Add the Host in Heeler** with the route's **Jump Host** set to the VPS and
   its address `127.0.0.1`, port `2222`. Heeler authenticates to the VPS, asks it
   for that loopback port, and then performs its own SSH handshake with the Mac.

If the SSH banner never arrives and the VPS logs show a browser login instead of
the service token, you are hitting a known `cloudflared` regression
([cloudflared#1674](https://github.com/cloudflare/cloudflared/issues/1674)) in
which `access tcp` ignored service tokens. Pin a version that works and upgrade
after checking that ticket.

## What Cloudflare sees

The SSH session stays encrypted between Heeler and the Mac, and Heeler still
verifies the Mac's host key before it sends anything. Cloudflare sees the
connection itself: the client's address, the Mac's address and port, when the
connection opened, and how much traffic passed. In the appendix's setup it also
terminates the connection from the VPS, exactly as a Jump Host does.

Last checked on 2026-10-23 on a physical iPhone.

Maintainers: see the [guide maintenance record](../agents/overlay-network-guides.md).