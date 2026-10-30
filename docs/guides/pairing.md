# Pair a Host by scanning a code

Show a Pairing Code on the machine that runs herdr and scan it in Heeler. The Host is added with its key and fingerprint already set up, no form to fill in.

## Before you start

- A Mac or Linux machine that runs [herdr](https://herdr.dev/docs/install/) 0.7.5 or newer, with [Node.js](https://nodejs.org/) 20 or newer. Windows Hosts can't pair; add them by hand with [Windows setup](windows-setup.md).
- Your iPhone or iPad on the same network as the machine, such as the same Wi-Fi, or connected to the same VPN. Pairing doesn't use the networks in Heeler's **Settings > Overlay Networks**; you can add those afterwards for [use away from home](#use-it-away-from-home).
- About two minutes: a Pairing Code works once and expires after two minutes.

## 1. Turn on SSH

**Run on: Mac or Linux**

On a Mac, turn on **System Settings > General > Sharing > Remote Login** and allow your account ([Apple's guide](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac)). Keep the Mac awake.

On Linux, install and start the OpenSSH server. On Debian or Ubuntu:

```sh
sudo apt install openssh-server
sudo systemctl enable --now ssh
```

If a firewall is on, allow SSH (port 22).

Then check the versions from [Before you start](#before-you-start):

```sh
herdr --version
node --version
```

## 2. Install the Heeler plugin

**Run on: Mac or Linux**

```sh
herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes
```

herdr downloads and builds the plugin. When the plugin is older than your version of Heeler expects, the Host's page in Heeler says so and can update it for you; running the same command on the Host also updates it.

## 3. Show a Pairing Code

**Run on: Mac or Linux**

Open herdr (run `herdr`) as the account Heeler should sign in to, and make its window large: about 40 lines tall and 90 columns wide, so the whole QR code fits. In one of its panes, run:

```sh
herdr plugin action invoke heeler.pair
```

The Pairing Code opens in a popup over the herdr window.

1. The popup lists the machine's network addresses. Check each one your iPhone or iPad can reach, usually the machine's Wi-Fi or Ethernet address: use the arrow keys to move and Space to check or uncheck. Each checked address becomes a route of the Host, so checking more than one is fine. If none of them is one your iPhone or iPad can reach, see [Pair through a port mapping](#pair-through-a-port-mapping).
2. Press Enter. A QR code appears, along with the time it stops working.

Leave the popup open and don't press any keys while you scan. Any key except `c` closes it and cancels the code.

## 4. Scan it in Heeler

**Run on: iPhone or iPad**

1. Open **Hosts** and tap **Scan to Pair** (the QR code button next to **+**). On an iPad with the sidebar, open **Hosts** from the bottom of the sidebar.
2. Allow camera access and, if iOS asks, access to devices on your local network. Then point the camera at the QR code.
3. Pairing starts right away and Heeler shows each step as it completes. There is no fingerprint to compare: the code carries it.

When pairing finishes, Heeler opens the new Host and runs its checks.

If you can't use the camera, press `c` in the popup. On a Mac this copies the code; get it onto your iPhone or iPad (for example with Universal Clipboard) and tap **Paste Pairing Code** in **Scan to Pair**. On Linux, `c` prints the code below the QR code instead: send it to your iPhone or iPad, for example in a note or message to yourself, then copy it there and paste it the same way.

**Then run on: Mac or Linux**

The popup shows **Device paired** and the key that was just added. If you didn't pair a device just now, press `r` to revoke it. Any other key closes the popup.

**It worked if** the popup shows **Device paired**, and the Host's checks pass in Heeler and its Agents or Terminals load.

## After pairing

- The Host is named after your username and its address. To rename it, open it from **Hosts** and tap **Edit**.
- Heeler signs in with this device's Device Key. To pair another iPhone or iPad, repeat steps 3 and 4 on it.
- Pairing a machine that is already in **Hosts** adds a second entry. Delete the one you no longer need.
- To get alerts when an Agent needs you or finishes, go to **Settings > Notifications**, tap **Enable Notifications**, tap **Continue**, and allow notifications when iOS asks. Then turn on **Notifications** for this Host.

## Use it away from home

A paired Host has only the addresses you checked, so it connects on the networks where those addresses answer. To reach it from cellular, set up an [Overlay Network](overlay-networks.md) or a [Jump Host](vps-jump-host-setup.md), then add the Host's address there as another route: see [Reach a Host on several routes](host-routes.md#add-a-route). Heeler uses whichever route answers first.

## Pair through a port mapping

**Run on: Mac or Linux**

The popup lists only the addresses on the machine's own network interfaces. When your iPhone or iPad reaches herdr some other way, for example herdr runs in a Docker container whose SSH is published on a port of a NAS, or the machine sits behind NAT, tell the plugin which address and port to put in the code. This needs Heeler plugin 0.6.2 or later; to update it, run the install command from [step 2](#2-install-the-heeler-plugin) again.

1. Find the plugin's config directory:

   ```sh
   herdr plugin config-dir heeler
   ```

2. In that directory, create `pair.json` with the addresses (IPs or host names) and the SSH port your iPhone or iPad reaches. For a container published as port 2222 of a NAS at 192.168.1.10:

   ```json
   {"ssh_port": 2222, "addresses": ["192.168.1.10", "nas.example.com"]}
   ```

3. Run `herdr plugin action invoke heeler.pair` again. The addresses from `pair.json` come first in the popup and are already checked. The machine's own addresses follow, unchecked.

The port must lead to the OpenSSH server of the machine that runs herdr, because the code carries the fingerprint of its host key under `/etc/ssh`. If the popup says it could not use `pair.json`, fix the file, press `q`, and run the command again. The [plugin README](../../plugin/README.md#install) describes every field.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| **no herdr server is running** in the terminal | Run `herdr` first, then run the command in one of its panes. |
| The bottom of the QR code is cut off | Make the herdr window larger, or zoom out the terminal, then press `q` and run the command again. |
| **No SSH host key found under /etc/ssh.** (popup) | Turn on Remote Login, or run `sudo ssh-keygen -A`, then run the command again. |
| **No routable network address found.** (popup) | Connect the machine to Wi-Fi, Ethernet, or a VPN, then run the command again. |
| The popup lists no address your iPhone or iPad can reach, for example only a `172.17.x.x` container address | herdr is behind a port mapping or NAT. Add the address your iPhone or iPad reaches to `pair.json`, as [Pair through a port mapping](#pair-through-a-port-mapping) describes, then run the command again. |
| **The Host did not answer at any of its addresses.** | Put your iPhone or iPad on the same network or VPN as the machine, check that Heeler is allowed in iOS **Settings > Privacy & Security > Local Network** and that Remote Login is on, then tap **Try Again**. |
| **This Pairing Code has expired.**, **The Host rejected this Pairing Code.**, or **The Host has no pairing in progress for this code.** | Codes work once, for two minutes, and stop working when the popup closes. Press Enter in the popup for a new code, or run the command again, then tap **Scan Again**. |
| **Enrollment did not complete, likely a network hiccup.** or **This device was enrolled, but the verifying reconnect did not get through.** | Tap **Try Again**. |
| **Tailscale SSH answers port 22…** (popup or Heeler) | Pairing needs OpenSSH, and Tailscale SSH takes over port 22 on the Tailscale address. Uncheck that address and pair on the LAN address, or turn off Tailscale SSH on the machine. To pair over Tailscale anyway, set `ssh_port` in `pair.json` as the [plugin README](../../plugin/README.md#install) describes. Then show a new code and tap **Scan Again**. |
| **The Host accepted this Pairing Code, but its pairing command ended without answering.** | Run the install command again, and make sure the machine's own OpenSSH server (Remote Login) answers port 22. Then show a new code and tap **Scan Again**. |
| A message to update the app and the pairing plugin | If **Try Again** is shown, try once more. Otherwise update Heeler and run the install command again, then show a new code and tap **Scan Again**. |
| **Camera Access Needed** or **Scanning Unavailable** | Tap **Open Settings** and allow the camera, or use **Paste Pairing Code**. |

Pairing errors appear in the popup or in Heeler, not in herdr's plugin log.

Checked against Heeler plugin 0.6.0 on 2026-10-14.

## herdr-app / herdr-core

The legacy plugin's Pairing Code connects to herdr, not to herdr-core. For Agents started in the desktop client, [add a herdr-core Host with SSH authentication](herdr-core.md).
