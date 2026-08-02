# VPS Jump Host and Reverse-Tunnel Deployment

This guide describes the recommended way to reach a Mac running herdr from
Heeler when the Mac is behind NAT and has no stable public address. A
public VPS acts as a restricted SSH Jump Host. The Mac creates an outbound
reverse SSH tunnel to the VPS, and the VPS keeps the forwarded port on its
loopback interface.

This is not a public port mapping. The Mac's SSH port must not be exposed as a
public VPS listener.

For a copy-and-check workflow organized by device, start with
[Set Up Remote Access Through a VPS](vps-jump-host-setup.md). Return here for
the complete trust model, operational details, and migration procedure.

## Architecture

There are three systems and three distinct SSH identities:

```text
                                     persistent outbound SSH
                              +-----------------------------------+
                              |                                   |
                              v                                   |
+------------------+    +-----------------------------+    +------------------+
| iOS              |    | VPS                         |    | macOS            |
| Heeler     |    | public TCP 22               |    | Remote Login    |
|                  |    |                             |    | TCP 22           |
| Device Key       +--->| restricted Jump account    |    |                  |
| in Keychain      |    | direct-tcpip only           |    | launchd         |
|                  |    |          |                  |    | reverse SSH     |
| verifies both    |    |          v                  |    |                  |
| host keys        |    | 127.0.0.1:2222 only        +--->| 127.0.0.1:22    |
+------------------+    +-----------------------------+    +--------+---------+
                                                                   |
                                                                   v
                                                        herdr API and Attach
```

The persistent path is created by the Mac:

```text
VPS 127.0.0.1:2222 -> reverse SSH channel -> Mac 127.0.0.1:22
```

An iOS connection then uses two independent SSH handshakes:

1. Heeler authenticates to the VPS Jump Host with its Device Key.
2. The Jump Host opens only `127.0.0.1:2222`.
3. Heeler performs a second SSH handshake with the Mac through that
   forwarded byte stream.
4. After authenticating to the Mac, the app reaches the herdr Unix socket
   through SSH exec channels and opens Attach through an SSH PTY.

The VPS terminates the first SSH connection and the Mac-to-VPS tunnel, but the
payload passed between them is another SSH connection. The VPS can observe
connection metadata and interrupt traffic. It cannot passively read the inner
iOS-to-Mac SSH session while the app verifies the Mac host key correctly.

## Public and Private Ports

| Location | Listener | Reachability | Purpose |
|---|---:|---|---|
| VPS | `0.0.0.0:22` and/or `[::]:22` | Public, subject to firewall policy | VPS SSH service |
| VPS | `127.0.0.1:2222` | VPS loopback only | Reverse-forwarded Mac SSH |
| Mac | `127.0.0.1:22` as the tunnel target | Reached through the tunnel | macOS Remote Login |

The Mac's SSH daemon may also listen on LAN interfaces when Remote Login is
enabled. This guide controls the VPS path; it does not change LAN firewall or
router policy.

The VPS cloud firewall and host firewall need only allow the SSH service port.
Do not add a public rule for `2222`.

## Identities and Trust Boundaries

Use separate identities for separate roles:

| Identity | Stored on | Authorized on | Capability |
|---|---|---|---|
| VPS administrator key | Administrator device | VPS administrator account | VPS administration only |
| Tunnel key | Mac filesystem | Restricted VPS tunnel account | Create one reverse listener |
| Device Key | iOS Keychain | VPS Jump account and Mac login account | Reach the one forwarded endpoint, then authenticate to the Mac |

Do not:

- copy the VPS administrator private key to iOS;
- use the VPS root account as the Jump Host;
- reuse the tunnel key for interactive login;
- put a private key in `authorized_keys`, documentation, shell history, or an
  issue;
- disable host-key verification to avoid a first-connection prompt.

Heeler verifies the Jump Host and Host independently. Confirm a new VPS
host-key fingerprint through the VPS console or another trusted administrative
path before accepting it in the app.

## Security Policy on the VPS

The recommended VPS has two unprivileged accounts:

- `herdr-tunnel`: accepts the Mac's automated connection and permits remote
  forwarding only.
- `herdr-jump`: accepts Device Keys and permits local forwarding only to
  `127.0.0.1:2222`.

Both accounts deny password login, keyboard-interactive login, shell sessions,
commands, SFTP, PTY allocation, agent forwarding, X11 forwarding, Unix-socket
forwarding, user SSH startup scripts, and TUN/TAP tunnels.

`MaxSessions 0` is load-bearing. OpenSSH documents that it prevents shell,
login, and subsystem sessions while still permitting forwarding.

The restrictions are applied twice:

1. `sshd_config` restricts every key accepted by the account.
2. `authorized_keys` restricts each individual key.

This defense in depth prevents an accidentally unqualified key line from
turning either account into a general-purpose VPS login.

## Prerequisites

- A VPS running a maintained OpenSSH version with `PermitListen` and
  `PermitOpen` support.
- Administrative SSH or console access to the VPS.
- macOS Remote Login enabled for the intended Mac user.
- A public-key login path that has been tested before password authentication
  is disabled anywhere.
- `socat` and herdr installed on the Mac as described by the main transport
  documentation.

The examples use:

```text
VPS address: VPS_PUBLIC_IP
VPS SSH port: 22
VPS tunnel account: herdr-tunnel
VPS Jump account: herdr-jump
VPS loopback tunnel port: 2222
Mac account: MAC_USER
SSH aliases: work-vps-tunnel, work-vps-jump, work-mac
```

Replace these values consistently. If several Macs share one VPS, allocate a
different loopback port to every Mac.

## 1. Create a Dedicated Tunnel Key on the Mac

The tunnel runs unattended, so use a dedicated key with an empty passphrase.
Its restrictions on the VPS make it useless for shell access.

```bash
ssh-keygen \
  -t ed25519 \
  -a 100 \
  -N '' \
  -f ~/.ssh/work-vps-tunnel \
  -C work-vps-tunnel
```

Record only the public half:

```bash
cat ~/.ssh/work-vps-tunnel.pub
ssh-keygen -lf ~/.ssh/work-vps-tunnel.pub
```

## 2. Obtain the Heeler Device Key

Copy the public-key line shown by Heeler. The private half remains in the
iOS Keychain.

The same Device Key public line must be authorized:

- on the VPS Jump account, with forwarding-only restrictions; and
- on the Mac account, so the second SSH handshake can authenticate.

Authorizing the key on only one hop results in a password prompt or an
authentication failure on the other hop.

On the Mac, keep PTY, exec, and SFTP available for Heeler while disabling
capabilities the app does not need:

```text
no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc DEVICE_PUBLIC_KEY
```

Append that line to `~/.ssh/authorized_keys`, then enforce:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

## 3. Create Restricted Accounts on the VPS

Run as a VPS administrator:

```bash
sudo adduser --disabled-password --gecos '' herdr-tunnel
sudo adduser --disabled-password --gecos '' herdr-jump

sudo install -d -m 700 \
  -o herdr-tunnel \
  -g herdr-tunnel \
  /home/herdr-tunnel/.ssh

sudo install -d -m 700 \
  -o herdr-jump \
  -g herdr-jump \
  /home/herdr-jump/.ssh
```

Do not change the administrator login policy yet. Keep the current
administrator session open until the new configuration has passed validation.

## 4. Install Restricted Public Keys on the VPS

Install the tunnel public key:

```text
restrict,port-forwarding,permitlisten="127.0.0.1:2222" TUNNEL_PUBLIC_KEY
```

Install every approved Device Key on the Jump account:

```text
restrict,port-forwarding,permitopen="127.0.0.1:2222" DEVICE_PUBLIC_KEY
```

Set ownership and permissions:

```bash
sudo chown -R herdr-tunnel:herdr-tunnel /home/herdr-tunnel/.ssh
sudo chmod 700 /home/herdr-tunnel/.ssh
sudo chmod 600 /home/herdr-tunnel/.ssh/authorized_keys

sudo chown -R herdr-jump:herdr-jump /home/herdr-jump/.ssh
sudo chmod 700 /home/herdr-jump/.ssh
sudo chmod 600 /home/herdr-jump/.ssh/authorized_keys
```

`restrict` disables forwarding as part of its default restrictions.
`port-forwarding` re-enables forwarding, then `permitlisten` or `permitopen`
narrows it to the one required endpoint.

## 5. Apply Account-Level OpenSSH Restrictions

On Debian and Ubuntu, confirm the main configuration includes drop-ins:

```bash
grep -nE '^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/' \
  /etc/ssh/sshd_config
```

Create `/etc/ssh/sshd_config.d/60-herdr-forwarding.conf`:

```sshconfig
# Restrict the persistent reverse-tunnel account.
Match User herdr-tunnel
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding remote
    AllowStreamLocalForwarding no
    PermitListen 127.0.0.1:2222
    PermitOpen none
    GatewayPorts no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    X11Forwarding no
    AllowAgentForwarding no
    MaxSessions 0

# Restrict the external Jump Host account.
Match User herdr-jump
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding local
    AllowStreamLocalForwarding no
    PermitListen none
    PermitOpen 127.0.0.1:2222
    GatewayPorts no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    X11Forwarding no
    AllowAgentForwarding no
    MaxSessions 0

Match all
```

`Match all` ends the second conditional block. It is especially important in a
drop-in that may be included before later global directives.

Validate before reloading:

```bash
sudo /usr/sbin/sshd -t

sudo /usr/sbin/sshd -T \
  -C user=herdr-tunnel,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'

sudo /usr/sbin/sshd -T \
  -C user=herdr-jump,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'
```

Reload only after `sshd -t` succeeds:

```bash
sudo systemctl reload ssh
```

Some distributions name the service `sshd` instead.

## 6. Configure the Mac SSH Aliases

Add entries like these to `~/.ssh/config`:

```sshconfig
Host work-vps-tunnel
  HostName VPS_PUBLIC_IP
  User herdr-tunnel
  Port 22
  IdentityFile ~/.ssh/work-vps-tunnel
  IdentitiesOnly yes
  BatchMode yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  StrictHostKeyChecking yes

Host work-vps-jump
  HostName VPS_PUBLIC_IP
  User herdr-jump
  Port 22
  IdentityFile ~/.ssh/work-client
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes

Host work-mac
  HostName 127.0.0.1
  User MAC_USER
  Port 2222
  IdentityFile ~/.ssh/work-client
  IdentitiesOnly yes
  ProxyJump work-vps-jump
  HostKeyAlias work-mac-via-vps
  StrictHostKeyChecking yes
```

The desktop client identity is only for command-line validation. Heeler
uses its own Device Key.

Verify the VPS host-key fingerprint through a trusted VPS console before adding
it to `known_hosts`. Do not use `StrictHostKeyChecking no`.

## 7. Test the Tunnel Interactively

On the Mac:

```bash
ssh -NT \
  -R 127.0.0.1:2222:127.0.0.1:22 \
  work-vps-tunnel
```

On the VPS:

```bash
sudo ss -ltnp | grep ':2222'
```

The local-address column must show:

```text
127.0.0.1:2222
```

It must not show:

```text
0.0.0.0:2222
[::]:2222
```

The `0.0.0.0:*` value commonly shown in the peer-address column is not a public
listener. Read the local-address column.

From a desktop client with the validation key:

```bash
ssh work-mac
```

This test proves more than process liveness: the Jump account authenticated,
the direct TCP channel reached the loopback listener, the reverse tunnel
reached the Mac, the Mac host key matched, and the Mac accepted the inner SSH
identity.

## 8. Make the Mac Tunnel Persistent

Use a user LaunchAgent that runs:

```text
/usr/bin/ssh -NT -R 127.0.0.1:2222:127.0.0.1:22 work-vps-tunnel
```

The LaunchAgent should define:

- a unique label;
- `RunAtLoad`;
- `KeepAlive`;
- a retry throttle;
- dedicated stdout and stderr log files.

Validate both initial startup and recovery:

```bash
launchctl print gui/$(id -u)/YOUR_LAUNCH_AGENT_LABEL
```

Terminate the managed SSH process once, confirm `launchd` starts a new PID, and
repeat the end-to-end `ssh work-mac` test. A running process alone does not
prove the reverse listener or either authentication hop works.

macOS user LaunchAgents start after that user logs in. If the Mac reboots but
no user logs in, this user-level tunnel is not yet running.

## 9. Configure Heeler

Create or edit the Host:

```text
Host address: 127.0.0.1
Host port: 2222
Host user: MAC_USER

Jump Host address: VPS_PUBLIC_IP
Jump Host port: 22
Jump Host user: herdr-jump
Authentication: Device Key
```

Confirm both host keys independently:

- the public VPS endpoint;
- the Mac host key presented through `127.0.0.1:2222`.

The Jump Host does not make the Mac trusted. A changed fingerprint on either
hop is a separate security event.

## macOS Authentication Hardening

The reverse-tunnel design removes the Mac from the public Internet, but VPS
root can reach the loopback tunnel endpoint. Anyone holding an approved Jump
Host key can also reach it. If the Mac advertises password or
keyboard-interactive authentication, those parties can attempt the Mac
password.

Prefer public-key-only Remote Login after validating a second administrative
path:

```sshconfig
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

Test the effective server authentication methods before ending the existing
session. Do not disable passwords until Device Key access and an independent
recovery path are proven.

The Device Key intentionally grants the app the Mac capabilities needed by
Heeler, including exec channels, SFTP, and PTY access. Losing an
authorized iOS device therefore requires revoking its public key from both the
VPS Jump account and the Mac.

## Failure Behavior

| Failure | Result |
|---|---|
| iOS is offline or the app is closed | The persistent Mac-to-VPS tunnel remains up |
| Mac sleeps, shuts down, or loses networking | The VPS loopback listener disappears; `launchd` reconnects when macOS resumes |
| VPS restarts | Both iOS and tunnel connections drop; `launchd` reconnects when the VPS SSH service returns |
| Tunnel key is rejected | No reverse listener is created |
| Jump Device Key is rejected | iOS cannot open the first hop |
| Mac Device Key is rejected | The Jump Host succeeds, but the inner Mac authentication fails |
| VPS host key changes | Stop and verify through the VPS console before trusting it |
| Mac host key changes | Stop and verify the Mac before trusting it |

## Adding or Migrating to a New VPS

Treat a new VPS as a new security boundary. Do not overwrite the working path
in place.

### Phase 1: Prepare the New VPS in Parallel

1. Patch the operating system and install the maintained OpenSSH server.
2. Confirm the VPS host-key fingerprint through its provider console:

   ```bash
   sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

3. Allow only the VPS SSH port in the provider firewall. Do not open the
   reverse-forward port.
4. Create fresh restricted tunnel and Jump accounts.
5. Generate a new tunnel key for the new VPS. Do not reuse the old VPS tunnel
   key.
6. Authorize the existing Heeler Device Key on the new Jump account. The
   Device Key may remain the same because its private half never leaves iOS.
7. Apply the `sshd_config` restrictions and validate them with `sshd -t` and
   `sshd -T`.

The old VPS and its tunnel remain untouched during this phase.

### Phase 2: Stage a Separate Mac Path

Create new Mac aliases rather than editing the old aliases:

```text
new-vps-tunnel
new-vps-jump
new-mac
```

Create a second LaunchAgent with:

- a different label;
- the new tunnel identity;
- the new VPS alias;
- separate log files.

The same loopback port may be used on two different VPSs. If the new path
shares one VPS with another Mac, allocate a unique port instead.

Start the new tunnel and validate:

```bash
ssh new-mac
```

On the new VPS:

```bash
sudo ss -ltnp | grep ':2222'
```

Confirm the listener is exactly `127.0.0.1:2222`, then terminate the new tunnel
process once and prove the new LaunchAgent reconnects.

### Phase 3: Move Heeler

Edit only the Jump Host fields:

```text
Jump Host address: NEW_VPS_PUBLIC_IP
Jump Host port: NEW_VPS_SSH_PORT
Jump Host user: new restricted Jump account
```

The Host remains:

```text
Address: 127.0.0.1
Port: 2222
User: MAC_USER
```

Confirm the new VPS fingerprint when prompted, then complete app preflight and
open an Agent through Attach. This is the functional cutover point.

### Phase 4: Retire the Old VPS

Only after the new path has passed command-line and app validation:

1. Stop and unload the old LaunchAgent.
2. Confirm the new LaunchAgent remains healthy.
3. Remove old SSH aliases and the old VPS host-key entry from the Mac.
4. Remove the Device Key from the old Jump account.
5. Remove the old tunnel public key and restricted accounts.
6. Close the old VPS firewall rules or destroy the old VPS.

Keep a short rollback window when practical, but do not leave two forgotten
public Jump Hosts running indefinitely.

If `remote port forwarding failed for listen port 2222` appears during a
cutover, inspect tunnel ownership before changing security policy. It usually
means two tunnel processes are competing for the same listener on one VPS.
Never solve it by enabling `GatewayPorts yes` or publishing another unrestricted
port.

## Revocation and Rotation

### Lost or Replaced iOS Device

Remove its exact public-key line from:

- `/home/herdr-jump/.ssh/authorized_keys` on every active VPS;
- `~/.ssh/authorized_keys` on every reachable Mac.

Generate a new Device Key on the replacement device and enroll it independently.

### Compromised Tunnel Key

1. Generate a new dedicated tunnel key on the Mac.
2. Replace the old public key on the one VPS tunnel account.
3. Update the Mac alias and LaunchAgent.
4. Validate reconnection, then delete the old private key.

A tunnel key alone cannot open a VPS shell or authenticate to the Mac.

### Compromised VPS

Build a clean VPS with a new host key and a new tunnel key. Treat the old VPS
host key, restricted accounts, logs, and firewall policy as untrusted. The Mac
Device Key does not need rotation unless the attacker obtained the corresponding
private key or another Mac credential.

## Validation Checklist

- [ ] VPS SSH host-key fingerprint verified out of band.
- [ ] VPS public firewall exposes only the intended SSH service port.
- [ ] Tunnel and Jump accounts reject passwords.
- [ ] Tunnel account permits only remote forwarding to
      `127.0.0.1:2222`.
- [ ] Jump account permits only local forwarding to
      `127.0.0.1:2222`.
- [ ] Both restricted accounts have `MaxSessions 0`.
- [ ] VPS `ss` shows `127.0.0.1:2222`, never `0.0.0.0:2222`.
- [ ] Mac-to-VPS tunnel is managed by `launchd`.
- [ ] Killing the tunnel process produces a new PID and a working connection.
- [ ] Heeler verifies both VPS and Mac host keys.
- [ ] Device Key is authorized on both hops.
- [ ] `ssh` or an equivalent real end-to-end test reaches the Mac.
- [ ] Heeler preflight and Attach work through the Jump Host.

## References

- [OpenSSH `sshd_config`](https://man.openbsd.org/sshd_config)
- [OpenSSH `authorized_keys` options](https://man.openbsd.org/sshd#AUTHORIZED_KEYS_FILE_FORMAT)
- [Apple: Allow a remote computer to access your Mac](https://support.apple.com/guide/mac-help/mchlp1066/mac)
- [Transport ADR](../adr/0002-ssh-exec-socat-transport.md)
- [Pairing ADR](../adr/0007-pairing-via-herdr-plugin.md)
