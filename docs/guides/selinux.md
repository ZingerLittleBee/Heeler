# SELinux on a Fedora or RHEL Host

On Fedora, RHEL, CentOS Stream, AlmaLinux, and Rocky Linux, SELinux can block SSH
from opening herdr's socket. Heeler then reports that it cannot open the socket
even though herdr is running. This guide shows how to confirm the denial and
allow it.

## Symptom

The connection checks fail at **herdr server running** with:

> Could not open the herdr socket at /home/&lt;user&gt;/.config/herdr/herdr.sock.
> Start herdr on the Host, or enable SSH stream-local forwarding and run the
> checks again.

The hint names two causes that are not the problem here: herdr is running, and
the OpenSSH default already allows stream-local forwarding.

## Confirm it is SELinux

Check that SELinux is enforcing and that the socket is live:

```bash
getenforce
herdr status
ss -xl | grep herdr.sock
```

`getenforce` prints `Enforcing`, and the socket shows as `LISTEN`. Then look for
a recent denial:

```bash
journalctl --since "10 min ago" | grep -i 'avc.*herdr.sock'
```

On Fedora 44 a matching entry looks like this:

```text
avc: denied { write } for comm="sshd-session" name="herdr.sock"
  scontext=system_u:system_r:sshd_session_t:s0
  tcontext=unconfined_u:object_r:config_home_t:s0 tclass=sock_file
sshd-session: error: connect to /home/<user>/.config/herdr/herdr.sock port -2 failed: Permission denied
```

The target is `config_home_t` and the class is `sock_file` on every distribution.
The source domain in `scontext` is not: Fedora and RHEL 10 report
`sshd_session_t`, while RHEL 9 and its rebuilds ship an older policy that does
not define that type. Do not copy a domain out of this guide; let the denial in
your own log name it, and see [Allow it](#allow-it).

## Why this happens

Heeler does not run a shell command to reach herdr. It asks SSH for a
**direct-streamlocal** channel, so `sshd` itself calls `connect()` on herdr's
socket: `~/.config/herdr/herdr.sock` for the default session, or
`~/.config/herdr/sessions/<name>/herdr.sock` for a named one.

That sshd worker can only connect to sockets its SELinux domain is allowed to
write. Files under `~/.config` are labelled `config_home_t`, and the targeted
policy grants the SSH session no write access to those sockets. Connecting to a
Unix socket needs `write` on the socket file, so the kernel denies it.

This is not a file-permission problem. The socket is owned by the same account
the SSH session signs in as, which is why the login and every other SSH request
succeed and only the socket open fails.

## Allow it

The reliable fix is to let `audit2allow` turn the denial in your own audit log
into a policy module. It reads the source domain out of the AVC, so the same
commands work on Fedora, RHEL 9, RHEL 10, and their rebuilds.

```bash
sudo dnf install policycoreutils-python-utils
sudo ausearch -m AVC -ts recent | sudo audit2allow -M herdr_sshd_streamlocal
sudo semodule -i herdr_sshd_streamlocal.pp
```

Run the connection checks in Heeler again afterwards.

### Fedora and RHEL 10 only: write the module by hand

If you would rather not install `policycoreutils-python-utils`, write the module
explicitly. This version names `sshd_session_t`, which exists in Fedora and RHEL
10 but not in RHEL 9 or its rebuilds, where it fails to install with
`type sshd_session_t is not defined`. Use the `audit2allow` path there instead.

```bash
sudo dnf install checkpolicy policycoreutils

cat > herdr-sshd-selinux.te <<'EOF'
module herdr_sshd_streamlocal 1.0;

require {
    type sshd_session_t;
    type config_home_t;
    class sock_file write;
}

# Let an SSH session connect to herdr's Unix socket under ~/.config/herdr.
allow sshd_session_t config_home_t:sock_file write;
EOF

checkmodule -M -m -o herdr-sshd-selinux.mod herdr-sshd-selinux.te
semodule_package -o herdr-sshd-selinux.pp -m herdr-sshd-selinux.mod
sudo semodule -i herdr-sshd-selinux.pp
```

Neither module disables SELinux or grants shell access: the SSH session still
needs the same account and file permissions.

## Verify

```bash
sudo semodule -l | grep herdr_sshd_streamlocal
journalctl --since "2 min ago" | grep herdr.sock
```

The first command prints the module. After you retry the checks, the second
prints nothing; denials from before the install stay in older journal entries.

## Undo

```bash
sudo semodule -r herdr_sshd_streamlocal
```

Connections made after the removal are denied again. Existing panes are not
affected.

## Scope

- The rule covers `config_home_t`, the label SELinux gives to `~/.config`. A
  herdr socket moved somewhere else would need its own label and rule.
- macOS Hosts, and Linux Hosts without SELinux (Debian, Ubuntu with AppArmor,
  or Fedora with SELinux disabled), need no change. `getenforce` printing
  `Disabled` or `Permissive` means this guide does not apply.
- The module survives reboots and herdr updates. Reinstall it after a
  distribution upgrade only if the denial returns.
