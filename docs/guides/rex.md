# Connect Rex

Connect Heeler over SSH to a Rex server that already runs on a Mac or Linux Host, and open its terminals on your iPhone or iPad while Rex keeps running them.

> [!IMPORTANT]
> Rex support is experimental. It was built and tested against Rex 0.1.0-preview.14 (Rex API revision 12) on macOS, and it opens the terminals Rex already has: see [What Heeler does not do yet](#what-heeler-does-not-do-yet) and [Known limits](#known-limits).

## Before you start

- Rex running on the Host under the account you will sign in as over SSH. Heeler connects only to a Rex server that is already running and never starts one.
- Remote Login turned on for the Mac and its SSH fingerprint noted: [Prepare the Host](overlay-networks.md#prepare-the-host). On Linux, run OpenSSH. Native Windows is not supported for Rex Hosts.
- An SSH server that allows forwarding to a Unix socket, as OpenSSH does by default. If its `sshd_config` sets `AllowStreamLocalForwarding no` or `AllowTcpForwarding no`, Heeler cannot reach Rex.
- A way for your iPhone or iPad to reach the Host: directly on the same network, over an [overlay network](overlay-networks.md), or through a [Jump Host](vps-jump-host-setup.md). A Host can have [multiple routes](host-routes.md).

## Add a Host

Heeler never starts Rex when connecting or checking, and never runs the `rex` command.

### 1. Enter the SSH settings

1. In **Hosts**, tap **Add Host**, or **Add Manually** when empty. A [Pairing Code](pairing.md) always adds a Herdr TUI Host.
2. Enter the SSH **User** of the account that runs Rex, add a Route, and pick **Device Key**, **RSA Key**, or **Password**.
3. For **Device Key**, copy the form's public-key line into the Host's `~/.ssh/authorized_keys`.
4. Leave **Session name** blank, since a Rex Host has none. Tap **Save**, then **Trust** after checking the Host's key fingerprint.

### 2. Confirm the Server Kind

Heeler checks once without starting anything, then lists what it found under **Server Kind**:

| Rex reads | What to do |
| --- | --- |
| **Socket found** | Tap **Use Rex**. |
| **Installed, not running** | Start Rex on the Host, then tap **Run Checks Again**. |
| **Socket found, but this account cannot use it** | Rex runs under another account. Edit the Host's **User** to that account. |
| **Not found** | Install and start Rex, then tap **Run Checks Again**. |

If the machine also runs Herdr TUI, herdr-core, or tmux, confirm one kind here, then add the machine again as another Host for the other. Once confirmed, **Server Kind** is fixed.

**It worked if** Host detail shows **Server Kind** as `Rex`, **Socket** with the path Rex listens on, and **SSH connection**, **Rex installed**, **Rex server running**, and **protocol compatible** passing.

## When it does not connect

| Host reads | What to do |
| --- | --- |
| **Rex is not running** | Start Rex on the Host, then tap **Run Checks Again**. |
| **The SSH server refuses socket forwarding** | Allow forwarding to a Unix socket in the Host's SSH server (see [Before you start](#before-you-start)), then tap **Run Checks Again**. |
| **Rex is not answering** | Heeler could not tell which of the two above it is. Check both, then tap **Run Checks Again**. |
| **Rex did not let this account in** | Edit the Host's **User** to the account that runs Rex. |
| **This version of Rex is not supported** | Heeler works with Rex API revision 12 only. Update Rex if the message says it offers an older revision; if it offers a newer one, wait for a Heeler update. |
| **Rex was not found on this Host** | Install and start Rex, then tap **Run Checks Again**. |

## The Console

Heeler shows your Rex layout as it is and changes nothing in it:

- **Workspaces, Tabs, and Panes:** Each Rex session is a Workspace, each window is a Tab, and each terminal is a Pane, in Rex's order. A session's terminals that are in none of its windows share a Tab named **Detached**. A session with no terminal is not listed.
- **Terminals only:** Rex Hosts appear in **Terminals**, never in **Agents**, even when a terminal runs a coding Agent. Titles, programs, and directories follow Rex as they change.

## Working in a terminal

Tap a terminal in **Terminals** to open it. Other Rex clients keep showing it while you work:

- **Opening:** The terminal appears once Rex has redrawn its screen and history, so a long history can take a few seconds on a slow connection. A program that keeps writing, such as a spinner, can show a few lines twice or out of place until it pauses; Heeler then paints it again.
- **Typing and pasting:** Type in Text or Keys mode, tap **Paste**, or send a Snippet. You can type whichever device set the terminal's size. What you type reaches the terminal in order, and Heeler never sends it twice: when the connection drops before Rex answers, the terminal shows **Connection dropped** with **Reattach**, and nothing typed after that point was sent. Keys typed while Heeler reconnects are not sent either; the terminal reconnects and paints again. A paste too large to send in one piece is blocked rather than split; paste less at a time.
- **Ending:** When a terminal closes in Rex or its program exits, its view ends.

When a terminal stops, it says why:

| Terminal reads | What to do |
| --- | --- |
| **Connection dropped** | Something you typed may not have arrived. Tap **Reattach** and check the screen before typing again. |
| **This terminal's history is too long to show** | Clear the terminal's scrollback in Rex, then tap **Reattach**. |
| **Rex stopped sending this terminal's output** | Rex stopped the terminal's output while the Host stayed connected. Tap **Reattach**. When the connection to the Host drops, the terminal reconnects and paints again by itself instead. |
| **This Terminal belongs to a Rex server that is gone** | Rex restarted. Open the terminal again from **Terminals**. |

### Sized for another device

A Rex terminal has one size, set by one device at a time. When no device has set it, the terminal fits your screen. When another device has, such as the Rex app on your Mac, Heeler shows the terminal at that size without scaling it: lines wider than your screen wrap onto the next row, so a program drawn to the full width, such as a table or an editor, can look jumbled. After a second **Sized for another device** appears over the terminal, at the bottom while the output ends in its upper half and at the top otherwise, so it stays clear of the prompt:

- **Fit to Screen** takes the size for your screen. Rex resizes the terminal itself, not only your view of it, so every device showing it, the Rex app included, gets your screen's size while you have it open here.
- Heeler gives the size back when you leave the terminal, when Heeler goes to the background, or when the terminal ends, and the device that had it gets it back. Coming back never takes it again on its own; tap **Fit to Screen** again.
- The **×** button dismisses the notice and keeps the other device's size. The notice returns when yet another device sets the size.
- If fitting does not go through, the notice says why, and **Try Again** asks once more.

## What Heeler does not do yet

- **No Agents:** no Agent Status, Chat, Composer, Agent Notifications, Live Activities, Usage, or widgets for Rex Hosts.
- **Nothing started, renamed, or closed:** New Agent, New Terminal, New Workspace, Rename, and Close are not offered. Do these in Rex; Heeler shows the result.
- **No uploads, Worktrees, Host Helper, or Pairing Code** for Rex Hosts.

## Known limits

- **Rex API revision 12 only:** A Rex that does not offer revision 12 is refused. Heeler was built and tested against Rex 0.1.0-preview.14.
- **Linux not yet tried:** Heeler looks where Rex keeps its socket on Linux, but no Linux Rex server has been tried yet.
- **What the first paint leaves out:** Rex's redraw does not carry the cursor shape or the terminal's own default colors, so the cursor keeps Heeler's shape until the program sets it again, and the terminal wears your Heeler theme. While a full-screen program is open, the history behind it appears only after the program closes.
- **A size set elsewhere does not fit:** Until you tap **Fit to Screen**, a terminal another device sized wider than your screen wraps its lines at your screen's width, so a full-width program can look jumbled. Heeler does not scale it down or cut it off.
- **What has been tested so far:** Rex Hosts have been tried in the iOS Simulator against Rex 0.1.0-preview.14 on macOS, with test clients standing in for other devices. They have not been tried on a physical iPhone or iPad, or with the Rex app showing the same terminal.

Last checked on 2026-11-15 against Rex 0.1.0-preview.14 (API revision 12) on macOS, in the iOS Simulator.
