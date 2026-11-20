# Update the Heeler plugin and Host Helper

A new version of Heeler can bring a newer Heeler plugin for Herdr TUI Hosts, or a newer Host Helper for herdr-core and tmux Hosts. Update them from Heeler, or by hand when an update from the app keeps failing.

## Update from Heeler

When a Host holds an older version, the **Hosts** tab shows a count and a card above the Hosts list says how many updates are waiting.

1. Tap **Update All** on the card. Every Host updates at the same time.
2. To update one at a time, tap the card to open **Updates**, then tap **Update** on a row.

**It worked if** the card reads **All Up to Date** and then goes away.

**Update All** only updates what is already installed. Install a plugin or Helper for the first time from its Server's page: open the Host in **Hosts**, then tap the Server.

## When an update fails

The row says why. The old version keeps working, unless the row reads **Damaged**. Tap the row to read what the Host said. Fix the cause, then tap **Try Again**. **Copy Details** copies the whole message for a bug report.

| The row says | What to do |
| --- | --- |
| Heeler could not connect to the Host | Check that the Host is connected in **Hosts**, then tap **Try Again**. |
| Check that the Host can reach github.com | The Host downloads the plugin from GitHub. Fix its network, or [update the plugin by hand](#update-the-heeler-plugin-by-hand). |
| Node.js or npm is missing or too old | Install Node.js 20 or newer with npm on the Host, then tap **Try Again**. |
| The connection ended or the Host took too long | The update may still finish on the Host. Wait a minute, then pull down on **Updates**. |
| **Damaged**, with a **Repair** button | Tap **Repair**. |

If it still fails, update by hand.

## Update the Heeler plugin by hand

**Run on: Mac or Linux**

On the Host, run the command that installed the plugin. It also updates it:

```sh
herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes
```

herdr downloads the plugin from GitHub and builds it with Node.js 20 or newer and npm, so the Host needs both. When the Host uses a named herdr session, tap the **Heeler Plugin** row on its **Herdr TUI** Server's page to see the command with that session filled in.

**It worked if** the **Heeler Plugin** row shows the new version after you pull down on **Updates**, or open the Server's page again.

## Update the Host Helper by hand

The Host Helper comes inside the Heeler app, so there is no command to run on the Host. Update it from the Server's page, one Host at a time:

1. Open the Host in **Hosts**, tap its **herdr-core** or **tmux** Server, then tap **Host Helper**.
2. Tap **Update**, or **Repair** when the row reads **Damaged**. The sheet says what went wrong when it fails.
3. If it still fails, tap **Remove**, then **Install**.

**Remove** also deletes that Host's notification registrations. After installing again, turn the Host back on under **Settings > Notifications**.

The Helper needs Node.js 20 or newer on the Host. For what each status on the **Host Helper** row means, see [Host Helper](herdr-core.md#host-helper).

**It worked if** the **Host Helper** row shows the new version and the sheet reads **The Host Helper is running.**
