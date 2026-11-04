# Windows setup

Set up a native Windows Host for Heeler, including SSH login and automatic
startup of SSH and herdr.

## Before you start

- Windows 11 with administrator access.
- Native herdr 0.9.3 or newer, and Heeler 0.1.13 or newer.
- Use the same Windows account for SSH login, herdr, coding agents, and the startup task.
- The examples use the named session `heeler-win-test`; replace it consistently if you choose another name.

## 1. Enable SSH

Open PowerShell **as Administrator** and check whether OpenSSH Server is
installed:

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

If its state is `NotPresent`, install it:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

Start SSH now and enable automatic startup after a reboot:

```powershell
Set-Service sshd -StartupType Automatic
Start-Service sshd
Get-Service sshd
```

The service should show `Running`. See
[Microsoft's OpenSSH installation guide](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse).

### Allow SSH through the firewall

In the same administrator window, inspect the current network profile and
the rule installed by OpenSSH:

```powershell
Get-NetConnectionProfile
Get-NetFirewallRule -Name OpenSSH-Server-In-TCP -ErrorAction SilentlyContinue |
    Select-Object Name, Enabled, Profile
```

A rule limited to `Private` does not permit SSH on a network marked
`Public`. If SSH is blocked on your local network, add an inbound rule for
TCP 22 from the local subnet:

```powershell
if (-not (Get-NetFirewallRule -Name Heeler-SSH-LocalSubnet -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name Heeler-SSH-LocalSubnet `
        -DisplayName 'Heeler SSH (local subnet)' `
        -Direction Inbound -Action Allow -Protocol TCP -LocalPort 22 `
        -RemoteAddress LocalSubnet -Profile Private,Public
}
```

This rule covers local-subnet connections on Private and Public networks.
Review other SSH allow rules if you want all SSH access limited to that
scope. For a VPN or Jump Host outside the local subnet, allow its trusted
source addresses instead. See
[Microsoft's firewall rule reference](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule).

## 2. Install and start native herdr

Open a normal PowerShell window as the account you will use for SSH. Install
herdr with its official Windows installer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "irm https://herdr.dev/install.ps1 | iex"
```

Open a new PowerShell window so it picks up the updated PATH, then check:

```powershell
herdr --version
herdr remote-api-bridge --check
```

Expect herdr 0.9.3 or newer and the bridge marker `herdr-api-bridge-v1`.
See [herdr's native Windows guide](https://herdr.dev/docs/windows-beta/).

Start the named session once in a normal native Windows terminal, not one
opened as Administrator:

```powershell
herdr --session heeler-win-test
```

This initializes a Workspace and shell pane. Start your configured coding
agent inside that session from its project directory. You can detach the
herdr client and reconnect later; the session remains running.

In another PowerShell window, confirm the session is running:

```powershell
herdr session list --json
```

## 3. Connect from Heeler

On Windows, find the account name and network address:

```powershell
whoami
ipconfig
```

For a local account, use the username shown after the computer name in
`whoami`. Use the IPv4 address of the active network adapter.

In Heeler, open **Hosts > Add Host**, tap **Add Route** under **Routes** to enter the address and port and tap **Save**, then fill in the Host fields:

| Field | Value |
| --- | --- |
| User | The Windows account running herdr |
| Address (in Route) | The Windows address reachable from your phone |
| Port (in Route) | `22`, unless you configured a different SSH port |
| Authentication | `Password` |
| Password | The Windows account password, rather than its Windows Hello PIN |
| herdr Session | `heeler-win-test` |

Before trusting the first connection, compare Heeler's SSH host key
fingerprint with the matching public host key on Windows. For Ed25519:

```powershell
ssh-keygen -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
```

The connection checks should pass, and Console should show the selected
session's Terminals and Agents. You can also check SSH from another device:

```sh
ssh <username>@<windows-address> "herdr --version"
ssh <username>@<windows-address> "herdr session list --json"
```

Device Key and RSA Key authentication require manual public-key
registration. See the [key setup steps in the Windows test checklist](native-windows-testing.md#4-test-device-key-authentication)
and [Microsoft's key-management guide](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement).

## 4. Start herdr automatically at boot

Use Task Scheduler to run the headless server under the same Windows
account as SSH. Its command is:

```powershell
herdr --session heeler-win-test server
```

The `server` command is intended for supervised or service-style setups.
See [herdr's CLI reference](https://herdr.dev/docs/cli-reference/#server).

Find a full executable path and the account's home directory in a normal
PowerShell window:

```powershell
$HeelerHerdrExe = Join-Path $env:LOCALAPPDATA 'Programs\Herdr\bin\herdr.exe'
if (-not (Test-Path -LiteralPath $HeelerHerdrExe)) {
    $HeelerHerdrExe = (Get-Command herdr.exe).Source
}
$HeelerHerdrExe
$env:USERPROFILE
```

Use the stable path if it exists. Otherwise, use the path returned by
`Get-Command` and update the task after upgrading herdr. Copy the paths
printed above into Task Scheduler, rather than the PowerShell expressions.

Open **Task Scheduler as Administrator**, select **Create Task**, and use:

| Tab | Setting |
| --- | --- |
| General | Name: `Herdr Server`. Run as the Windows account used by Heeler. |
| General | Select **Run whether user is logged on or not**. Clear **Do not store password**. Leave **Run with highest privileges** cleared. |
| Triggers | **At startup**, optionally delayed by 30 seconds. |
| Actions | **Start a program**. Program: the full `herdr.exe` path printed above. |
| Actions | Arguments: `--session heeler-win-test server`. Start in: the home directory printed above. |
| Conditions | Clear the AC-power-only and stop-on-battery options if the server should run on battery. |
| Settings | Clear **Stop the task if it runs longer than**. Choose **Do not start a new instance** when it is already running. |

Enter the Windows account password in the Windows dialog when saving. This
allows the task to run before desktop login with that account's profile and
network access. If the account password changes, save the task again with
the new password. Running under SYSTEM would use a different account and
configuration directory. Microsoft documents the
[task login types](https://learn.microsoft.com/en-us/windows/win32/taskschd/principal-logontype)
and the [default 72-hour execution limit](https://learn.microsoft.com/en-us/windows/win32/taskschd/tasksettings-executiontimelimit).

From herdr 0.9.4, an elevated server, one started with highest privileges or
from a terminal opened as Administrator, accepts only administrator
terminals. To let normal terminals in, start it with
`--allow-unelevated-clients` or set `[server] allow_unelevated_clients = true`
in herdr's config.

### Verify the saved task

First check `herdr session list --json`. If `heeler-win-test` is already
running, wait until its agents can be stopped, then stop that session before
testing the task. herdr rejects a second server for the same session.

In Task Scheduler, right-click **Herdr Server** and select **Run**. Confirm
that its status is **Running**, then run these checks in PowerShell under
the SSH account:

```powershell
Get-Service sshd | Select-Object Name, Status, StartType
herdr --session heeler-win-test status server --json
```

Expect `sshd` to show `Running` and `Automatic`. The herdr response should
contain `running: true` and `session: "heeler-win-test"`.

The task stays **Running** while serving the session. A **Last Run Result**
of `0x41301` (`267009`) means it is still running; this is normal for a
long-running server. See [Microsoft's task status codes](https://learn.microsoft.com/en-us/windows/win32/taskschd/task-scheduler-error-and-success-constants).

Reconnect from Heeler and confirm that the named session loads.

### Verify after a reboot

Restart Windows when your agents can be stopped. Before logging in to the
Windows desktop, connect from Heeler and check that the named session loads.
After logging in, repeat the service and API checks above and confirm that
the task is **Running**. A successful manual run does not verify startup
after a reboot.

## Supported features and further checks

Native Windows supports manual SSH connections, session selection, live
Agents and Terminals, and directory browsing. Pairing, Chat, Usage, Changes,
Skills, uploads, and notification registration are currently unavailable. Keep
herdr running before connecting; Heeler does not start the Windows server
automatically.

For resize, scrolling, reconnect, session isolation, and authentication
acceptance checks, use the [Windows test checklist](native-windows-testing.md).
