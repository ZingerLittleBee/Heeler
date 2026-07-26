# Set Up Remote Access Through a VPS

Follow this guide when the Mac running herdr is behind NAT and Herdr Mobile
cannot reach it directly. The result is:

```text
iPhone -> VPS public SSH port -> VPS 127.0.0.1:2222 -> Mac SSH port 22
```

The VPS exposes only its normal SSH service. Port `2222` remains on the VPS
loopback interface and is never opened in a public firewall.

For design rationale, threat boundaries, key rotation, and a full migration
runbook, see [VPS Jump Host and Reverse-Tunnel Deployment](vps-jump-host.md).

## Before You Start

You need:

- an iPhone with Herdr Mobile installed;
- a Mac with herdr and `socat` installed;
- administrator access to a maintained Debian or Ubuntu VPS;
- the VPS public IP address;
- the VPS SSH service port, normally `22`;
- a recovery path to the VPS, such as the provider console.

Keep the current VPS administrator session open until the restricted accounts
have passed validation.

Choose values for these placeholders:

| Placeholder | Example | Meaning |
|---|---|---|
| `VPS_PUBLIC_IP` | `203.0.113.10` | Public VPS address |
| `VPS_SSH_PORT` | `22` | Public VPS SSH port |
| `VPS_NAME` | `work-vps` | Short local alias |
| `MAC_USER` | `alice` | macOS login account |
| `TUNNEL_PORT` | `2222` | VPS loopback port for this Mac |

Replace uppercase placeholders before running a command. Do not paste commands
containing unresolved placeholders.

If several Macs share one VPS, give each Mac a different `TUNNEL_PORT`.

## Step 1: Enable Remote Login on the Mac

**Run on: macOS**

Open:

```text
System Settings -> General -> Sharing -> Remote Login
```

Turn on Remote Login and allow only the Mac account Herdr Mobile should use.
Full Disk Access is not required by this network setup.

Confirm the SSH listener:

```bash
nc -z 127.0.0.1 22 && echo 'Mac SSH is reachable'
```

Expected:

```text
Mac SSH is reachable
```

Do not continue until this succeeds.

## Step 2: Create a Dedicated Tunnel Key

**Run on: macOS**

This key keeps the reverse tunnel alive. It must not be reused for administrator
or interactive login.

```bash
ssh-keygen \
  -t ed25519 \
  -a 100 \
  -N '' \
  -f ~/.ssh/VPS_NAME-tunnel \
  -C VPS_NAME-tunnel
```

For example, when `VPS_NAME` is `work-vps`:

```bash
ssh-keygen \
  -t ed25519 \
  -a 100 \
  -N '' \
  -f ~/.ssh/work-vps-tunnel \
  -C work-vps-tunnel
```

Display the public key and fingerprint:

```bash
cat ~/.ssh/VPS_NAME-tunnel.pub
ssh-keygen -lf ~/.ssh/VPS_NAME-tunnel.pub
```

Copy the public-key line. Never copy or upload the file without `.pub`.

Checkpoint:

- [ ] The private key is mode `600`.
- [ ] The public key starts with `ssh-ed25519`.
- [ ] The public key has a recorded SHA-256 fingerprint.

## Step 3: Copy the Herdr Mobile Device Key

**Run on: iOS**

In Herdr Mobile, begin adding a Host and copy the Device Key public-key line.
It looks like:

```text
ssh-ed25519 AAAA... herdr-mobile
```

The private key remains in the iOS Keychain. Only the public line is copied.

Record this line as `DEVICE_PUBLIC_KEY`. It must be authorized on both the VPS
Jump account and the Mac account.

## Step 4: Authorize the Device Key on the Mac

**Run on: macOS**

Replace `DEVICE_PUBLIC_KEY` with the complete public-key line copied from Herdr
Mobile:

```bash
DEVICE_KEY='DEVICE_PUBLIC_KEY'
DEVICE_ENTRY="no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-user-rc $DEVICE_KEY"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
grep -qxF "$DEVICE_ENTRY" ~/.ssh/authorized_keys 2>/dev/null \
  || printf '%s\n' "$DEVICE_ENTRY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

These options keep the PTY, exec, and SFTP features Herdr Mobile needs while
disabling agent, TCP, and X11 forwarding.

Checkpoint:

```bash
grep -F "$DEVICE_KEY" ~/.ssh/authorized_keys
```

The command must print exactly one matching authorized-key line.

## Step 5: Create the Restricted VPS Accounts

**Run on: VPS**

```bash
id -u herdr-tunnel >/dev/null 2>&1 \
  || sudo adduser --disabled-password --gecos '' herdr-tunnel

id -u herdr-jump >/dev/null 2>&1 \
  || sudo adduser --disabled-password --gecos '' herdr-jump

sudo install -d -m 700 \
  -o herdr-tunnel \
  -g herdr-tunnel \
  /home/herdr-tunnel/.ssh

sudo install -d -m 700 \
  -o herdr-jump \
  -g herdr-jump \
  /home/herdr-jump/.ssh
```

If an account already exists, inspect it instead of blindly recreating it:

```bash
getent passwd herdr-tunnel
getent passwd herdr-jump
```

The accounts have no password. The SSH policy added later prevents shell and
subsystem sessions while still permitting the one required forwarding mode.

## Step 6: Install the Restricted Public Keys on the VPS

**Run on: VPS**

First install the Mac tunnel public key. Replace `TUNNEL_PUBLIC_KEY` with the
complete contents of `~/.ssh/VPS_NAME-tunnel.pub`:

```bash
TUNNEL_PORT='2222'
TUNNEL_KEY='TUNNEL_PUBLIC_KEY'
TUNNEL_ENTRY="restrict,port-forwarding,permitlisten=\"127.0.0.1:${TUNNEL_PORT}\" $TUNNEL_KEY"

printf '%s\n' "$TUNNEL_ENTRY" \
  | sudo tee /home/herdr-tunnel/.ssh/authorized_keys >/dev/null
```

Replace `2222` before running the block if this Mac uses another loopback port.

Now append the Herdr Mobile Device Key. Replace `DEVICE_PUBLIC_KEY` and
change `2222` if needed:

```bash
TUNNEL_PORT='2222'
DEVICE_KEY='DEVICE_PUBLIC_KEY'
DEVICE_ENTRY="restrict,port-forwarding,permitopen=\"127.0.0.1:${TUNNEL_PORT}\" $DEVICE_KEY"

sudo grep -qxF "$DEVICE_ENTRY" /home/herdr-jump/.ssh/authorized_keys 2>/dev/null \
  || printf '%s\n' "$DEVICE_ENTRY" \
  | sudo tee -a /home/herdr-jump/.ssh/authorized_keys >/dev/null
```

Apply ownership and permissions:

```bash
sudo chown -R herdr-tunnel:herdr-tunnel /home/herdr-tunnel/.ssh
sudo chmod 700 /home/herdr-tunnel/.ssh
sudo chmod 600 /home/herdr-tunnel/.ssh/authorized_keys

sudo chown -R herdr-jump:herdr-jump /home/herdr-jump/.ssh
sudo chmod 700 /home/herdr-jump/.ssh
sudo chmod 600 /home/herdr-jump/.ssh/authorized_keys
```

Inspect both files:

```bash
sudo cat /home/herdr-tunnel/.ssh/authorized_keys
sudo cat /home/herdr-jump/.ssh/authorized_keys
```

Checkpoint:

- [ ] The tunnel line contains `permitlisten="127.0.0.1:TUNNEL_PORT"`.
- [ ] The Device Key line contains `permitopen="127.0.0.1:TUNNEL_PORT"`.
- [ ] Neither file contains a private key.

## Step 7: Restrict Both VPS Accounts in OpenSSH

**Run on: VPS**

Confirm the main SSH configuration includes drop-ins:

```bash
grep -nE '^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/' \
  /etc/ssh/sshd_config
```

If there is no matching line, stop and consult the VPS distribution
documentation before continuing.

Create `/etc/ssh/sshd_config.d/60-herdr-forwarding.conf`:

```bash
sudoedit /etc/ssh/sshd_config.d/60-herdr-forwarding.conf
```

Insert the following, replacing both instances of `TUNNEL_PORT`:

```sshconfig
# Restrict the persistent reverse-tunnel account.
Match User herdr-tunnel
    AuthenticationMethods publickey
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding remote
    AllowStreamLocalForwarding no
    PermitListen 127.0.0.1:TUNNEL_PORT
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
    PermitOpen 127.0.0.1:TUNNEL_PORT
    GatewayPorts no
    PermitTTY no
    PermitTunnel no
    PermitUserRC no
    X11Forwarding no
    AllowAgentForwarding no
    MaxSessions 0

Match all
```

Validate before reloading:

```bash
sudo /usr/sbin/sshd -t
```

No output means the syntax is valid. Do not reload if this command reports an
error.

Inspect the effective restrictions:

```bash
sudo /usr/sbin/sshd -T \
  -C user=herdr-tunnel,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'

sudo /usr/sbin/sshd -T \
  -C user=herdr-jump,host=localhost,addr=127.0.0.1 \
  | grep -E 'allowtcpforwarding|permitlisten|permitopen|gatewayports|maxsessions'
```

Reload on Debian or Ubuntu:

```bash
sudo systemctl reload ssh
```

Some distributions name the service `sshd`.

Open a second administrator connection before closing the first one.

## Step 8: Configure the VPS Firewall

**Run on: VPS provider console and VPS**

Allow inbound TCP only for the VPS SSH service port:

```text
VPS_SSH_PORT
```

Do not create a public rule for `TUNNEL_PORT`.

Inspect the host firewall without enabling or replacing it blindly:

```bash
sudo ufw status verbose
sudo nft list ruleset
```

The exact firewall tool depends on the distribution and provider. The required
result is:

```text
Public: VPS_SSH_PORT
Private loopback only: TUNNEL_PORT
```

Preserve deliberate rules for unrelated services already hosted on the VPS.
This guide requires no additional public port beyond the selected SSH port.

## Step 9: Verify the VPS Host Key

**Run first on: VPS**

```bash
sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Record the SHA-256 fingerprint through the provider console or the trusted
administrator session.

**Then run on: macOS**

```bash
ssh-keyscan -T 10 -t ed25519 -p VPS_SSH_PORT VPS_PUBLIC_IP 2>/dev/null \
  | ssh-keygen -lf -
```

The fingerprints must match exactly. `ssh-keyscan` alone is discovery, not
authentication. Stop if the fingerprints differ.

## Step 10: Add the Mac SSH Tunnel Alias

**Run on: macOS**

Add this block to `~/.ssh/config`, replacing every placeholder:

```sshconfig
Host VPS_NAME-tunnel
  HostName VPS_PUBLIC_IP
  User herdr-tunnel
  Port VPS_SSH_PORT
  IdentityFile ~/.ssh/VPS_NAME-tunnel
  IdentitiesOnly yes
  BatchMode yes
  ExitOnForwardFailure yes
  ServerAliveInterval 30
  ServerAliveCountMax 3
  StrictHostKeyChecking yes
```

Check the resolved values:

```bash
ssh -G VPS_NAME-tunnel \
  | grep -E '^(hostname|user|port|identityfile|stricthostkeychecking) '
```

Every value must point to the new VPS and dedicated tunnel identity.

## Step 11: Test the Reverse Tunnel Manually

**Run on: macOS**

```bash
ssh -NT \
  -R 127.0.0.1:TUNNEL_PORT:127.0.0.1:22 \
  VPS_NAME-tunnel
```

Leave this command running.

**Run in another session on: VPS**

```bash
sudo ss -ltnp | grep ':TUNNEL_PORT'
```

The local-address column must show:

```text
127.0.0.1:TUNNEL_PORT
```

It must not show:

```text
0.0.0.0:TUNNEL_PORT
[::]:TUNNEL_PORT
```

Stop the interactive tunnel with `Control-C` after this checkpoint passes.

## Step 12: Install the Persistent macOS LaunchAgent

**Run on: macOS**

Create:

```text
~/Library/LaunchAgents/dev.herdr.VPS_NAME-reverse-ssh.plist
```

Use this template, replacing `MAC_USER`, `VPS_NAME`, and `TUNNEL_PORT`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>dev.herdr.VPS_NAME-reverse-ssh</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/ssh</string>
        <string>-NT</string>
        <string>-R</string>
        <string>127.0.0.1:TUNNEL_PORT:127.0.0.1:22</string>
        <string>VPS_NAME-tunnel</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/Users/MAC_USER/Library/Logs/VPS_NAME-reverse-ssh.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/MAC_USER/Library/Logs/VPS_NAME-reverse-ssh.error.log</string>
</dict>
</plist>
```

Validate and load:

```bash
PLIST=~/Library/LaunchAgents/dev.herdr.VPS_NAME-reverse-ssh.plist
LABEL=dev.herdr.VPS_NAME-reverse-ssh

plutil -lint "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
launchctl print "gui/$(id -u)/$LABEL"
```

Expected state:

```text
state = running
```

Check the error log:

```bash
tail -n 50 ~/Library/Logs/VPS_NAME-reverse-ssh.error.log
```

An empty error log is expected.

This user LaunchAgent starts after the Mac user logs in. It does not run at the
pre-login FileVault screen.

## Step 13: Add the Host in Herdr Mobile

**Run on: iOS**

Enter:

```text
Host name: any descriptive name
Host address: 127.0.0.1
Host port: TUNNEL_PORT
Host user: MAC_USER
Authentication: Device Key

Jump Host address: VPS_PUBLIC_IP
Jump Host port: VPS_SSH_PORT
Jump Host user: herdr-jump
```

Run preflight.

Herdr Mobile presents two independent host-key confirmations:

1. the VPS Jump Host key;
2. the Mac host key reached through the reverse tunnel.

Confirm each fingerprint through its trusted system. Do not assume that
trusting the VPS also trusts the Mac.

Successful preflight must verify:

- Jump Host authentication;
- Mac authentication;
- `socat` discovery;
- herdr socket reachability;
- protocol compatibility.

Open an Agent through Attach to complete functional acceptance.

## Step 14: Prove Automatic Recovery

**Run on: macOS**

Find the managed tunnel process:

```bash
ps -axo pid=,command= | grep '[s]sh .*VPS_NAME-tunnel'
```

Terminate only that PID:

```bash
kill TUNNEL_PROCESS_PID
```

Wait a few seconds, then inspect the LaunchAgent:

```bash
launchctl print "gui/$(id -u)/dev.herdr.VPS_NAME-reverse-ssh"
```

It must show a new PID and `state = running`.

Repeat Herdr Mobile preflight or open an Agent. A restarted process without a
working app connection is not sufficient proof.

## Step 15: Harden Mac Authentication

**Run on: macOS, only after Device Key access works**

The VPS root user and every approved Jump Host key can reach the Mac SSH
listener through the loopback tunnel. If macOS still offers password or
keyboard-interactive authentication, those parties can attempt the Mac
password.

Check the advertised methods without entering a password:

```bash
ssh \
  -o BatchMode=yes \
  -o PubkeyAuthentication=no \
  -o PreferredAuthentications=none \
  MAC_USER@127.0.0.1 true
```

If the error lists `password` or `keyboard-interactive`, consider changing the
Mac SSH server to:

```sshconfig
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

Do this only while physically at the Mac and only after proving Device Key
access and an independent recovery path. Validate the SSH configuration before
restarting Remote Login.

## Final Acceptance Checklist

- [ ] Mac Remote Login is enabled for the intended account.
- [ ] The Mac tunnel uses a dedicated key.
- [ ] The iOS Device Key is authorized on both the VPS and Mac.
- [ ] The VPS has separate tunnel and Jump accounts.
- [ ] Both VPS accounts reject shell, password, PTY, and unrelated forwarding.
- [ ] The provider firewall exposes only the VPS SSH service port.
- [ ] The VPS listener is exactly `127.0.0.1:TUNNEL_PORT`.
- [ ] VPS and Mac host-key fingerprints were independently verified.
- [ ] The LaunchAgent reports `state = running`.
- [ ] Killing the tunnel process produces a new PID.
- [ ] Herdr Mobile preflight succeeds.
- [ ] An Agent opens successfully through Attach.

## Troubleshooting

| Symptom | Likely boundary | Check |
|---|---|---|
| Jump Host rejects the Device Key | iOS -> VPS | Device Key line in `/home/herdr-jump/.ssh/authorized_keys` |
| `remote port forwarding failed` | Mac -> VPS tunnel | Existing listener, `PermitListen`, tunnel account key |
| VPS shows no `TUNNEL_PORT` listener | Mac -> VPS tunnel | LaunchAgent state and error log |
| VPS shows `0.0.0.0:TUNNEL_PORT` | VPS security policy | Stop the tunnel; restore `GatewayPorts no` and explicit loopback binding |
| Mac asks for a password | VPS -> Mac | Device Key missing from the Mac or wrong Mac user |
| Mac host key changed | Inner SSH trust | Verify the Mac host key locally before accepting |
| VPS host key changed | Outer SSH trust | Verify through the provider console before accepting |
| App reaches Mac but not herdr | Mac application layer | herdr status, socket path, and `socat` |

## Adding Another VPS

Do not edit the working path in place:

1. Create a fresh tunnel key for the new VPS.
2. Configure new restricted accounts and a new VPS host key.
3. Add the existing Device Key public line to the new Jump account.
4. Create new Mac aliases and a second LaunchAgent.
5. Validate the new loopback listener and automatic recovery.
6. Change only the Jump Host fields in Herdr Mobile.
7. Test preflight and Attach.
8. Stop and remove the old path only after the new path works.

See [Adding or Migrating to a New VPS](vps-jump-host.md#adding-or-migrating-to-a-new-vps)
for the full staged cutover and rollback procedure.
