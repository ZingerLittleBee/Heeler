# heeler-pair

Show a Pairing Code so [Heeler](https://heeler.bybee.dev), the iOS app for
coding Agents over SSH, can add this machine by scanning it. No address,
key or fingerprint to type.

Use it on a Mac or Linux machine that runs tmux or herdr-core. A machine that
runs Herdr TUI can use Heeler's herdr plugin instead; both end the same way.

```sh
npx -y heeler-pair@latest
```

1. Run it in a terminal on the machine, as the account Heeler should sign in
   to. The terminal needs about 30 rows and 60 columns.
2. Check the addresses your iPhone or iPad can reach, and press Enter.
3. In Heeler, open **Hosts**, tap **Scan to Pair**, and point the camera at
   the code. Heeler then lists what the machine runs and adds the Servers you
   choose.

The full guide is at <https://docs.heeler.bybee.dev/pairing>.

## Requirements

- macOS or Linux, with Node.js 20 or newer.
- OpenSSH's server running on the machine (Remote Login on a Mac).
- Your iPhone or iPad on the same network or VPN as the machine.

## Options

| Option | Use |
| --- | --- |
| `--port <port>` | The port this machine's OpenSSH answers on, when it is not 22. |
| `--address <address>` | An address your device reaches this machine on that is not one of its own, such as a NAS that forwards a port to a container. Repeat it for more than one. |
| `--version` | Print the version. |
| `--help` | Print the options. |

## What it does to the machine

While the code is on screen, `~/.ssh/authorized_keys` holds one extra line: a
one-time key that can run a single command, the one that adds your device's
own key. The line is removed when a device pairs, when you close the code, or
after two minutes. A paired device's key stays until you remove it; right
after pairing, the screen shows its fingerprint and `r` revokes it.

Nothing else is installed, and nothing keeps running once the screen closes.
The short-lived records of a pairing in progress are under
`~/.local/state/heeler/pairing`.

## License

Apache-2.0
