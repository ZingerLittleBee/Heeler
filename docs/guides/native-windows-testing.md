# Native Windows host testing

Use this checklist to validate the manual SSH connection work for
[#399](https://github.com/ZingerLittleBee/Heeler/issues/399) on Windows 11.
Run it against the Heeler build containing that change. Sections 1 to 8 are
acceptance steps, not a record of a completed Windows test. Section 9's runs are
summarized under [herdr-core Host results](#herdr-core-host-results).

The connection under test uses native Windows OpenSSH and native herdr.
Windows environment discovery must resolve the account's home and herdr's
configuration directory, including `%APPDATA%`. API traffic must use herdr's
official `remote-api-bridge`; terminal input and output must use
`terminal session control`. The phone must not need WSL, a Unix socket forward,
or an additional bridge service.

## 1. Record the Windows environment

Use the same Windows account for SSH and the herdr session. In a normal
PowerShell window, run:

```powershell
herdr --version
(Get-Command herdr).Source
$PSVersionTable.PSVersion
$env:USERPROFILE
$env:APPDATA
Get-Service sshd
Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue
herdr session list --json
```

Start with herdr **0.9.3** and OpenSSH `DefaultShell` set to **PowerShell 7**,
matching the reported environment. Heeler also supports cmd as the OpenSSH
default shell; normal setup does not require a shell change.

Save the Heeler version/build number, Windows version, herdr version, shell
path, and session-list output with your results. Check that `herdr.exe` is
the native Windows binary.
The source references in this guide are pinned to herdr 0.9.3 commit
`7b116c05bfda646af39d2524c54e70c751f57ee8`.

OpenSSH must already accept this account from another machine on the same
network or VPN. For installation and firewall setup, follow
[Microsoft's OpenSSH setup guide](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse).

From another machine, verify noninteractive SSH commands as well as an
interactive login:

```sh
ssh -p 22 <user>@<windows-address> "herdr --version"
ssh -p 22 <user>@<windows-address> "herdr session list --json"
```

Use your actual SSH port. A working local terminal does not prove that sshd
can find the same herdr executable. Resolve any `herdr`-not-found error here
before testing Heeler.

## 2. Prepare an isolated named session

You can use an existing session. For a separate test session, run this in a
native Windows terminal and leave the session running:

```powershell
herdr --session heeler-win-test
```

In another PowerShell window, run:

```powershell
herdr session list --json
herdr --session heeler-win-test agent list
herdr --session heeler-win-test pane list
herdr remote-api-bridge --check
```

Start one of your already configured agents in the test session from the
Windows herdr UI. Use a trusted project directory so the agent does not stop
at a first-use trust dialog. Keep at least one ordinary shell pane available
for the input tests.

Native Windows herdr resolves its configuration directory from
`XDG_CONFIG_HOME`, then `APPDATA`, then `USERPROFILE\AppData\Roaming`, with
additional fallbacks. Its displayed `.sock` paths identify local IPC endpoints;
the app must use the official bridge to reach them. See the
[herdr 0.9.3 configuration code](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/config/io.rs).

### Bridge smoke test

`remote-api-bridge --check` must print `herdr-api-bridge-v1`. To verify an
actual request, run the following in PowerShell. It keeps stdin open until
the response arrives and bounds the read to 15 seconds:

```powershell
$HeelerBridge = New-Object System.Diagnostics.Process
$HeelerBridge.StartInfo.FileName = (Get-Command herdr.exe).Source
$HeelerBridge.StartInfo.Arguments = '--session heeler-win-test remote-api-bridge'
$HeelerBridge.StartInfo.UseShellExecute = $false
$HeelerBridge.StartInfo.RedirectStandardInput = $true
$HeelerBridge.StartInfo.RedirectStandardOutput = $true
$HeelerBridge.StartInfo.RedirectStandardError = $true
[void]$HeelerBridge.Start()
$HeelerBridgeErrors = $HeelerBridge.StandardError.ReadToEndAsync()
try {
    $HeelerBridge.StandardInput.WriteLine('{"id":"windows-smoke","method":"ping","params":{}}')
    $HeelerBridge.StandardInput.Flush()
    $HeelerBridgeResponse = $HeelerBridge.StandardOutput.ReadLineAsync()
    if (-not $HeelerBridgeResponse.Wait(15000)) { throw 'Bridge ping timed out' }
    $HeelerBridgeResponse.Result
} finally {
    $HeelerBridge.StandardInput.Close()
    if (-not $HeelerBridge.WaitForExit(3000)) { $HeelerBridge.Kill() }
    $HeelerBridge.WaitForExit()
    $HeelerBridgeErrors.Result
    $HeelerBridge.Dispose()
}
```

Expected: one JSON response with `id: "windows-smoke"` and a `result`
containing the server version and protocol. Record an `error` response or
timeout. Use a fresh process for each ordinary API request.

Do not test with a pipeline that immediately closes stdin after the request:
the Windows bridge ends its output loop on stdin EOF and can exit before
printing the response. Session selection uses top-level `--session` or
`HERDR_SOCKET_PATH`; `remote-api-bridge` has no `--socket` option. See the
[official bridge arguments](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/remote.rs#L15-L39)
and [Windows bridge lifecycle](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/platform/windows.rs#L70-L101).

## 3. Test manual password authentication

1. In Heeler, open **Add Host** and enter the Windows address, SSH port, and
   SSH username.
2. Select **Password** and enter the account password. Leave **Session name**
   blank to test the default session first, if you have one running.
3. Save. Compare the first-connection SSH host key fingerprint with the key
   on Windows before trusting it.
4. Run the preflight checks. The remote environment step must pass without
   `The remote home directory could not be resolved`.
5. Select `heeler-win-test` from the discovered sessions, or enter that exact
   name in **Edit Host > Session name** and reconnect.
6. Confirm that Console shows that session's workspaces and agents. A newer
   protocol advisory may appear; it must not reject an otherwise compatible
   server.

To inspect the default Windows Ed25519 host key fingerprint:

```powershell
ssh-keygen -lf "$env:ProgramData\ssh\ssh_host_ed25519_key.pub"
```

Use the host key type shown by Heeler if the server negotiated another type.
Windows OpenSSH stores default host keys under `%ProgramData%\ssh`; see
[Microsoft's server configuration reference](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration#hostkey).

Expected result: authentication, Windows environment discovery, session
selection, API preflight, and the initial agent snapshot all succeed.

### PowerShell profile output

Repeat the connection while the SSH account's PowerShell 7 profile prints a
short startup banner to stdout. If the profile already prints output, use
that. Otherwise, save a copy of the applicable profile, temporarily add
`Write-Output 'heeler-profile-banner'`, and restore the profile after this
check. Confirm that the noninteractive SSH command from step 1 prints the
banner before testing the app.

Expected: preflight, session discovery, API responses, and terminal frames
still parse correctly. Startup text must not become a home path, a JSON
response, or remote terminal content.

## 4. Test Device Key authentication

1. In **Edit Host**, select **Device Key** and press **Copy authorized_keys
   Line**. Transfer only that public line to Windows.
2. Append the line to the authorized-keys file that your sshd configuration
   actually uses. Preserve the existing keys.
3. Save the Host and reconnect. The same named session must load without a
   password.

Under the default Windows OpenSSH configuration:

- A standard account uses `%USERPROFILE%\.ssh\authorized_keys`.
- An account in the Administrators group uses
  `%ProgramData%\ssh\administrators_authorized_keys` instead. Adding its key
  to the profile file alone does not authorize that account.

For an administrator account, run this from an elevated PowerShell window.
Replace the sample value with the complete public line copied from Heeler:

```powershell
$HeelerPublicKey = 'ssh-ed25519 <public-key-blob> heeler'
$HeelerKeysPath = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
Add-Content -LiteralPath $HeelerKeysPath -Value $HeelerPublicKey -Encoding ascii
icacls.exe $HeelerKeysPath /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F'
```

The SIDs make the ACL command work on localized Windows installations. Check
the resulting ACL and remove any unrelated explicit access entries before
using the file. For a standard account or custom `AuthorizedKeysFile`, follow
[Microsoft's key-management guide](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement#deploying-the-public-key).

Repeat with **RSA Key** if you use that authentication method. Windows SSH
keys must be registered manually in this test; the pairing plugin does not
perform enrollment on Windows.

## 5. Verify API updates and session isolation

With Heeler connected to `heeler-win-test`:

1. Rename a test workspace or tab in Windows herdr. Confirm the new label
   appears on the phone without removing and adding the Host.
2. Start an agent, send a short prompt, and wait for it to finish. Confirm the
   Console updates through the agent's working and completion states.
3. Create and close a disposable agent or tab. Confirm it appears and then
   disappears from Heeler.
4. Connect Heeler to a different running named session. Confirm it displays
   that session's content, then switch back and confirm no content leaked
   between sessions.
5. Put the app in the background, bring it back, and use **Reconnect**. Confirm
   the current snapshot loads and later changes still arrive.
6. Enable Live Activities in Heeler and keep the app in the foreground.
   Start and finish an agent prompt. Confirm the Host's Live Activity reflects
   the current eligible-agent counts and states. Foreground updates use the
   app's API events and do not require the Windows pairing plugin. This check
   does not cover background push updates or Agent Notifications.

Expected result: requests and the long-lived event subscription reach the
selected Windows session through `remote-api-bridge`. A successful `ping`
alone does not establish that subscription updates work.

### Inherited client socket override

Check that a legacy `HERDR_CLIENT_SOCKET_PATH` in the SSH shell cannot send
terminal control to a different session from the API. Start a second native
session in another Windows terminal:

```powershell
herdr --session heeler-win-other
```

Give the two sessions different workspace or tab labels in the Windows UI.
In an ordinary shell pane in each, print a distinct marker such as
`Write-Output 'heeler-session-A'` and `Write-Output 'heeler-session-B'`.

For the PowerShell 7 `DefaultShell` run, use the SSH account's local PowerShell
7 window to temporarily set the override in its applicable startup profile.
The following uses `CurrentUserAllHosts`, saves its original bytes, and restores
them when you finish. Keep this window open at the prompt while testing:

```powershell
$HeelerLegacySession = (herdr session list --json | ConvertFrom-Json).sessions |
    Where-Object { $_.name -eq 'heeler-win-other' -and $_.running } |
    Select-Object -First 1
if (-not $HeelerLegacySession) { throw 'Start heeler-win-other first' }
$HeelerLegacyClient = Join-Path $HeelerLegacySession.session_dir 'herdr-client.sock'
$HeelerProfilePath = $PROFILE.CurrentUserAllHosts
$HeelerProfileExisted = Test-Path -LiteralPath $HeelerProfilePath
$HeelerProfileBytes = if ($HeelerProfileExisted) {
    ,([System.IO.File]::ReadAllBytes($HeelerProfilePath))
} else { $null }
$HeelerProfileText = if ($HeelerProfileExisted) {
    [System.IO.File]::ReadAllText($HeelerProfilePath)
} else { '' }
$HeelerProfileDirectory = Split-Path -Parent $HeelerProfilePath
$HeelerProfileDirectoryExisted = Test-Path -LiteralPath $HeelerProfileDirectory
try {
    [void][System.IO.Directory]::CreateDirectory($HeelerProfileDirectory)
    $HeelerOverrideLine = "`n`$env:HERDR_CLIENT_SOCKET_PATH = '" +
        $HeelerLegacyClient.Replace("'", "''") + "'`n"
    [System.IO.File]::WriteAllText($HeelerProfilePath,
        $HeelerProfileText + $HeelerOverrideLine,
        [System.Text.UTF8Encoding]::new($false))
    $HeelerProbeScript = "[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(`$false); " +
        "[Console]::WriteLine('__HEELER_LEGACY_CLIENT__=' + `$env:HERDR_CLIENT_SOCKET_PATH)"
    $HeelerProbeEncoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($HeelerProbeScript))
    Write-Output "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand $HeelerProbeEncoded"
    [void](Read-Host 'Run the fresh SSH probe and Heeler checks, then press Enter to restore the profile')
} finally {
    if ($HeelerProfileExisted) {
        [System.IO.File]::WriteAllBytes($HeelerProfilePath, $HeelerProfileBytes)
    } else {
        Remove-Item -LiteralPath $HeelerProfilePath -ErrorAction SilentlyContinue
    }
    if (-not $HeelerProfileDirectoryExisted -and
        -not (Get-ChildItem -LiteralPath $HeelerProfileDirectory -Force)) {
        Remove-Item -LiteralPath $HeelerProfileDirectory
    }
}
```

From another machine, run a **fresh, non-PTY** SSH command with the printed
`powershell.exe ... -EncodedCommand ...` command:

```sh
ssh -T -p 22 <user>@<windows-address> "<paste-the-generated-command>"
```

The `__HEELER_LEGACY_CLIENT__=` line must contain the client path for
`heeler-win-other`. An empty or different value means this setup did not
inject the override into the SSH process, so mark this check **not tested**.
Do not count a local `$env` value as proof of SSH inheritance. For a cmd
`DefaultShell` run, use an override already inherited by that account's SSH
process, if available, and apply the same probe requirement.

After the probe confirms the override, reconnect Heeler to `heeler-win-test`.
Confirm that both its Console labels and terminal's `heeler-session-A` marker
belong to that session. Type `Write-Output 'heeler-selected-session-input'`
on the phone and confirm it appears only in that session's Windows pane.
Switch to `heeler-win-other`, repeat with another marker, and switch back.
If a default session is running, repeat with **Session name** blank while the
override still points to `heeler-win-other`.

Expected: API snapshots, event updates, terminal output, and terminal input
all follow the selected session; no other session receives the input. Finish
the prompt to restore the prior profile, then reconnect and recheck the SSH
probe against the account's original environment. See herdr's
[client socket precedence](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/server/socket_paths.rs#L15-L49).

## 6. Verify live terminal input and rendering

Open the test agent's terminal in Heeler, then test an ordinary shell pane.

1. Confirm that the existing screen is rendered and new output appears.
2. In the shell, type a harmless command and submit it. For PowerShell:

   ```powershell
   Write-Output 'heeler-windows-input-ok'
   ```

   For cmd:

   ```bat
   echo heeler-windows-input-ok
   ```

3. Confirm the command runs once and its output is visible on both Windows
   and Heeler. Test Enter, Backspace, arrow keys, and Ctrl+C at an idle shell.
4. Repeat with Chinese text and an emoji, for example
   `Write-Output '你好 Heeler 🐾'` in PowerShell or `echo 你好 Heeler 🐾` in cmd.
   Confirm input and output preserve the characters without replacement
   symbols or repeated bytes. Paste a harmless multiline block with distinct
   line markers and confirm that each line reaches the shell or agent once,
   preserving its line breaks and Unicode text.
5. In the agent terminal, send a short prompt and confirm it receives the
   text once. For an agent that supports terminal mouse input, scroll up and
   down on the phone. Confirm its own viewport moves and then returns to the
   latest output. Do not count an idle shell's local scrollback as proof of
   remote mouse scrolling.
6. Rotate the phone and show/hide its keyboard. Output must remain readable
   and the remote viewport must resize without corrupting the screen.
7. Leave the terminal and reopen it several times. Confirm input still works
   and the app does not remain stuck on a displaced controller.
8. If another client already controls the terminal, exercise the app's
   takeover flow, then reconnect from the other client. Confirm each client
   reports lost ownership or regains control as expected.

Expected result: the native Windows path works through
`herdr terminal session control`, whose streams carry JSON terminal frames
and input commands. Native `herdr terminal attach` is a separate command and
is unsupported on Windows. See the
[control protocol implementation](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/src/client/terminal_sessions.rs#L17-L215)
and [native Windows limitations](https://github.com/herdrdev/herdr/blob/7b116c05bfda646af39d2524c54e70c751f57ee8/docs/next/website/src/content/docs/windows-beta.mdx).

## 7. Repeat with cmd as OpenSSH DefaultShell

After the PowerShell 7 run passes, repeat the password and Device Key tests,
session selection, event updates, and terminal checks with cmd as the SSH
default shell. This change affects every new SSH connection to the machine;
keep a local elevated PowerShell window available and restore the original
value afterward.

Inspect and save the original `DefaultShell` registry value first. Configure
cmd using the steps in
[Microsoft's default-shell reference](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration#configuring-the-default-shell-for-openssh-in-windows),
restart sshd, and create a fresh Heeler connection. Do not rely on an existing
SSH connection to exercise the new shell.

Expected result: Windows discovery and the bridge commands work regardless
of whether the SSH account shell is PowerShell 7 or cmd.

## 8. Keep a macOS or Linux comparison

On a macOS or Linux Host, prepare a separate session with the same name,
`heeler-win-test`, and add that Host to the same Heeler build. Repeat preflight,
session selection, API updates, terminal input, resize, and reconnect. Use a
shell-appropriate harmless command such as `printf 'heeler-unix-input-ok\n'`.
Keep each Host's results separate even though the session names match.

Expected: the Unix Host continues to use its existing direct-streamlocal API
and PTY terminal path. Selecting the Windows Host must not change the Unix
Host's connection behavior or mix the two Hosts' snapshots.

## 9. Connect a herdr-core Host

These steps are for the herdr-core Host of
[#587](https://github.com/ZingerLittleBee/Heeler/issues/587), not the herdr
sessions above, and need herdr-core 0.1.16 or newer from its installer. No lane
runs them: the app's tests script the probe and the exec. Their first runs, on one
machine, are under [herdr-core Host results](#herdr-core-host-results).

If the Herdr desktop app runs on the machine, quit it before steps 6, 7, 34 and 35
and before step 36. By its 0.1.12 source, not run, it connects to the core that
`HC_SESSION` in its own environment names, retries every second, and its `connect`
starts a core when none runs, so a core you stop comes back within about a second.
By the same source it updates itself and then the core, which can move herdr-core off
the version under test.

1. Stop the core. On the phone, add the machine with Session left blank or a
   plain name. The form says to add the Device Key line to `~/.ssh/authorized_keys`.
   For an account in the Administrators group, Windows OpenSSH reads
   `%ProgramData%\ssh\administrators_authorized_keys` instead, with the access list
   in [section 4](#4-test-device-key-authentication). Server Kind detection also runs
   `herdr session list --json` there (by Heeler's source), so on a machine with a
   Herdr TUI server it reaches that server's sessions and reads Herdr TUI **Found**
   beside herdr-core. Confirm **herdr-core** with **Use herdr-core**. The Host reads
   **Reconnecting…** and **herdr-core is not running**, with a note naming the missing
   pipe. The start command is not in that status: it is in its own card below
   Preflight, and no Start button is offered. On the machine no `herdr-core` process
   appears.
2. In your desktop session, in PowerShell, not as administrator, run the command
   the Host shows. Within its retry, the Host connects by itself, and the core takes
   the Session's name: its state is `%LOCALAPPDATA%\herdr-core\<session>` and its pipe
   `\\.\pipe\herdr-core-<user>-<session>.sock`.
3. The Console lists the core's Terminals and Agents, each in a card named for
   its directory. Rename and Worktrees are not offered, and neither is Chat until
   a build lists a program (step 24). An Agent with a directory offers neither
   Changes nor Skills, under More, in the header or on its status line.
4. Open an Agent. Direct Input types into it and its output follows.
5. Open a Shell Terminal. Rotate or resize it, run a full-screen program, and
   scroll back.
6. Stop the core with `server stop` while the Host is connected. The Host reads
   **herdr-core is not running**, and leaving it through several reconnects
   starts no `herdr-core` process on the machine.
7. Start the core again in the desktop session. The Host reconnects by itself. To
   check Pins, pin an Agent, then end the core's own process by its pid: the one
   `server.status` names, a `herdr-core.exe` whose command line ends in `serve`, not
   its holder (a second `herdr-core.exe`) or a `connect`. For example, list them with
   `Get-CimInstance Win32_Process -Filter "Name='herdr-core.exe'" | Select-Object ProcessId, CommandLine`
   and run `Stop-Process -Id <pid> -Force`. With kept Terminals, as in the second
   run, the holder keeps them and their programs running and starts the core again by
   itself, so the Host reads **herdr-core is not running** for a few seconds,
   reconnects with nothing tapped, and the pinned row stays pinned. Starting the core
   in your desktop session after that finds it running and starts nothing. Step 6's `server stop` cannot show this
   on Windows: the Agents' programs end with the core, and once it starts again the
   kept Terminals come back as the core's own PowerShell, not as Agents. Heeler then
   keeps their Pins in its store while the Terminals' addresses exist, but there is
   no Agent row to show them, and no run has seen a pinned row on that path.
8. Start a Terminal with a `herdr.space` label the desktop app has not named, in a
   subfolder of a repository. Its card takes the repository's folder name, and
   Worktrees stay off. Outside a repository it takes its directory's. This exercises
   Heeler's PowerShell checkout read through sshd.
9. Edit the Host's Session to a name with a space. Below the field the form says
   Heeler cannot use that session name on native Windows, and Save stays off. A
   Host the app has not yet found on Windows takes the name; after Save it reads
   **Can't Connect** and **This session name can't be used**, with the same note
   and one closing period, and Rename and Worktrees are still not offered.
10. Install an agent the launch can find, with OpenCode too if you have it. New
    Agent lists what a Windows PowerShell session over SSH finds, and OpenCode's
    version reaches its launch (`-s ses_...` in the Terminal's argv on 2.1 or newer).
    An agent installed under a junction may be missing; note which.
11. Start one with an argument holding a space, a single quote and a non-ASCII
    character. It shows as an Agent of its kind, and the program receives the
    argument whole. Exit the agent: its Terminal ends and the Agent leaves the list.
    Note the exit code the core reports. Seen twice on one machine with herdr-core
    0.1.16: Grok Build 1.0.70 does not end on `/exit` under the core. It prints its
    resume line and `grok.exe` keeps running, Ctrl+C and Enter do not end it either,
    and its Terminal stays live until you close it. Check the exit with another
    agent, such as Claude Code. A `.ps1` shim blocked by the machine's execution
    policy shows as listed and ends at once; note that too. Start another with an argument holding a
    double quote and with an empty one (`''`), and note what the program receives:
    Windows PowerShell may not pass either whole.
12. New Terminal opens a Terminal in the directory you picked, in a shell, and it
    is not listed as an Agent. Exit it: the Terminal ends.
13. New Workspace at a picked directory, with the desktop app running on the
    machine. The space appears in the desktop app, and the form has no name field.
14. Add a small image in an Agent's Composer. The path inserted into the draft
    names a file in `%LOCALAPPDATA%\herdr-core\<session>\files\<address>\`, and
    a program in that Terminal reads it by that path with the same hash. Close the
    Terminal: the file stays (recorded for `terminal.kill`). Note what removes it
    on your machine: it goes with `terminal.rm` and, by the core's source and not
    yet run, about a day after the Terminal ended.
15. Add a 9 MiB file. Heeler says it is over the 8 MiB limit, the draft stays, and
    no file appears in that folder. Add one of exactly 8 MiB: it lands with the same
    hash, and the Host stays connected while it crosses on a slow link. While it
    crosses, type in Direct Input and tap Stop on a working Agent: both should go out at
    once, which nobody has seen yet on Windows, since the put's own SSH exec has to
    interleave with the link's. Note what you see.
16. In an Agent New Agent started, type a message and tap Send. It submits within
    about a second, and the draft empties. Claude Code 2.1.286's and 2.1.316's
    bracketed paste reached Heeler through the pseudo console on herdr-core 0.1.16, on
    the one machine run.
    If Send says **not accepting a paste** at the Agent's own input, note the program
    and its version: Send cannot work for it on this machine.
17. Add an image and Send the draft holding its path. The Agent reads the file by
    that path.
18. Leave a draft in an Agent's Composer, exit the Agent with Direct Input, and tap
    Send. Its Terminal has ended, so nothing runs anywhere, and the draft stays.
    **Known defect**, seen on herdr-core 0.1.16 with Claude Code 2.1.286 after `/exit`
    (exit code 0): nothing ran, but on an Agent that already reads **Agent Ended**
    every Send empties the draft at once, and a few seconds later the Composer says
    **The terminal did not connect in time, so nothing was sent. Retry when it
    shows.**, with **Retry** and **Edit Draft**. Only Edit Draft brings the text back,
    and Retry cannot help a Terminal that has ended.
19. From the Herdr desktop app, start an agent in a space. Herdr desktop app 0.1.12
    ran it as `powershell.exe -NoExit -Command "& '<agent>'"`, a shell that stays after
    the agent exits, where New Agent's form ends with it. Then in Heeler tap Send with a
    draft that leaves a mark if PowerShell runs it, such as
    `New-Item -ItemType File heeler-step19.txt`: the notice says the terminal
    **keeps a shell open**, nothing is written, and the draft stays. Exit that agent
    and tap Send again: the same notice, and PowerShell runs nothing, so no file
    appears. Heeler keeps that Terminal listed as an Agent after the agent exits,
    titled with a `C:\WINDOWS\System32\…` path, and the first notice stays shown, so
    judge the second Send by the screen and the missing file.
20. Start an agent by typing it in a PowerShell Terminal. It is not listed as an Agent,
    since the foreground stays PowerShell, so it has no Composer.
21. Tap Stop during a working turn. The turn stops, and the Agent stays listed. Stop
    an Agent that exits at the key: it leaves the list. Claude Code 2.1.286 reports no
    status, so it reads **Unknown** and offers no Stop.
22. Bring an Agent to a question and Send: the text lands in its input unsubmitted.
    The tools keyboard submits it. **Known defect**, seen on herdr-core 0.1.16 with
    Claude Code 2.1.316 at its permission dialog: Send empties the draft with no
    notice and the text never shows, as on Linux with that version. The tools
    keyboard's Enter then answers the dialog with its highlighted option (**1. Yes**,
    which ran the tool use) instead of submitting text. Ask for something harmless,
    such as a file in a scratch folder, so that approving it does no harm.
23. When an Agent leaves its Terminal to PowerShell before a Send's submit, Heeler
    sends one Ctrl+C and says the text **may still be in the terminal** (by its
    source): it does not count PowerShell among the shells that drop a pending paste
    on one Ctrl+C. To check yours, in a PowerShell Terminal send a bracketed paste of a
    harmless command, then one 0x03, then Enter, and record whether the command ran,
    with your PowerShell's and PSReadLine's versions. On the one machine run, on
    herdr-core 0.1.16, Windows PowerShell 5.1.26100.9711 with PSReadLine 2.0.0
    dropped the paste: that sequence ran nothing, with the profile, with
    `-NoProfile`, and with the 0x03 32 ms after the paste, while the same paste and
    Enter ran it. Earlier rounds on
    the same machine are in `docs/agents/herdr-compatibility.md`. PowerShell 7 has not
    been run. If yours drops it too, Send can say it is gone once you decide that in
    ADR 0035. If it keeps it, ADR 0035 needs your decision before Send ships on
    Windows.

These steps are for Chat ([#590](https://github.com/ZingerLittleBee/Heeler/issues/590)).
No lane runs them either. The Windows process read first ran on a Windows machine
in the run under [herdr-core Host results](#herdr-core-host-results), as Windows
PowerShell 5.1 through sshd. Sign in to each program yourself. Never open Claude
Code's `.key` files.

24. In a local build, put one program in
    `HostCapabilities.confirmedWindowsCoreChatPrograms`. Codex and OpenCode are not
    candidates, and stay off even if listed. The other programs still offer the
    terminal alone. On a native Windows Herdr TUI Host, no Agent offers Chat.
25. Start Claude Code from New Agent, reach its prompt, send one message and open
    Chat. It shows that conversation. On the machine, in PowerShell, compare
    `(Get-Process -Id <pid>).StartTime.ToFileTimeUtc()` of `claude.exe` with
    `procStart` in `%USERPROFILE%\.claude\sessions\<pid>.json`. Claude Code 2.1.286
    and 2.1.316 wrote it as a string of the creation FILETIME's decimal digits, and
    wrote no `procStartFt`. Record the field's name and form. If they differ, Chat
    says **Can't Tell the Conversation**, with no offer of the Helper.
26. Note how long Chat takes to bind. Each check is one PowerShell exec with an
    `Add-Type` compile, bounded at 20 seconds. Run it from an SSH session that is not
    elevated against a core that is, and the other way round: a process Heeler cannot
    read reads as **Can't Tell**, says the read failed, and offers no extension.
27. Repeat step 25 with an npm-installed Claude Code and through `npx`, and record
    each tree from `Get-CimInstance Win32_Process`. From npm, 2.1.316's `claude.cmd`
    runs the package's own `bin\claude.exe` under `cmd.exe`, so the Agent's image is
    `claude.exe`, not `node.exe`. Through `npx` the tree ran `powershell.exe`,
    `cmd.exe`, `node.exe` (`npx-cli.js`), `cmd.exe`, `claude.exe`. That 2.1.316
    reported its status and wrote a matching `sessions\<pid>.json`, but Heeler listed
    no Agent for it, so it had no Chat, Composer or Stop: **known defect**, the Agent
    rule does not look through `npx`. New Agent starts whichever `claude` a Terminal's
    PowerShell finds first. On the one machine that was the account's winget copy,
    even with the npm copy first on the core's own PATH, so the npm and `npx` copies
    were started over the core's pipe with `terminal.run` in New Agent's form.
28. Run `/clear` in the terminal. Chat follows at its next check. Seen once, on
    herdr-core 0.1.16 with Claude Code 2.1.286: after `/clear` Chat also showed a
    **Working for 0:18** row counting up while Claude Code sat idle, until the next
    turn. Note whether yours does.
29. Start Grok Build and send a message. Chat shows it, from the one row of
    `active_sessions.json` with that `pid` and `pid_start`. Record the row's fields and
    `pid_start`'s value beside the creation time: Heeler assumes they are equal. On the
    one machine run (herdr-core 0.1.16), Grok Build 1.0.70 wrote rows with only
    `session_id`, `pid`, `cwd` and `opened_at`, and Chat said it can't tell, also after
    **Check Again**. **Known defect**: Heeler's row reader requires `pid_start` (by its
    source), so no Grok Build 1.0.70 Agent can bind there. Run
    `/new`: two rows match, and Chat says it can't tell until Grok Build starts again.
30. Open Chat on a Pi Agent with no extension. It says it can't tell, and offers
    **Add Heeler's Extension…**. The sheet names the folders and has written nothing.
    Tap Add. `heeler-session.js` is in Pi's folder, `.omp\agent\extensions` and each
    profile's folder, and nowhere else.
31. Start Pi again and send a message. The Terminal's `heeler.session` label appears,
    with a `start` equal to its process's creation time, and Chat shows the
    conversation. Record Pi's image name, whether Pi loaded the file, and how long the
    label took, since it runs one hidden PowerShell. Repeat on Oh My Pi, with a profile.
32. Send from Chat in a Terminal New Agent started: the message submits. Stop a working
    turn. Answer a Blocked card. For a program whose bracketed paste does not cross the
    pseudo console (step 16), record that Chat's Send says the same. **Known defect**,
    seen on herdr-core 0.1.16 with Oh My Pi 18.13.3 (`omp.exe`, with a profile): Send
    from Chat said **Heeler can't find the Agent's input box on screen.** before and
    after a turn, while Direct Input submitted.
33. Record each program that passed as a versioned observation in
    `docs/agents/herdr-compatibility.md`, here, and by adding it to
    `HostCapabilities.confirmedWindowsCoreChatPrograms`. One that fails stays off, with
    its observation saying why.
34. Stop the core. In your desktop session run `$env:CLAUDECODE='1'; $env:HERDR_CHECK='1'`,
    then start the core there. Host detail shows **Core Environment** naming both, with
    no value. Start the core from a clean window and it goes. If nothing appears,
    record that here and in `docs/agents/herdr-compatibility.md`, since a read that
    failed also shows nothing. Pointing the Host's Session at a throwaway session for
    this clears that Host's Pins: a new core drops them, and they did not come back
    when the Session was set back. Note your Pins first.
35. Record this machine's `DefaultShell`
    (`Get-ItemProperty 'HKLM:\SOFTWARE\OpenSSH'`; no value means `cmd.exe`). Steps 1
    to 7 prove the link only under that shell: repeat connect, attach and reconnect
    under the other one, restoring the value after, with one run under PowerShell 7
    whose profile prints output and one whose profile also calls `Set-Location`.
    The value is machine-wide, and a shell that fails can shut SSH out, so from an
    elevated PowerShell before any change:
    - Export the key with `reg export HKLM\SOFTWARE\OpenSSH <backup>.reg` and keep
      the file's hash.
    - Register a one-off scheduled task that runs as SYSTEM with highest privileges
      some minutes ahead and puts `DefaultShell` and `DefaultShellCommandOption` back
      to what the export holds, removing them when it holds neither.
    - When you finish, put the values back yourself, export the key again and compare
      that file's hash with the backup's, check that a new SSH exec runs the original
      shell (under cmd, `echo %COMSPEC%` prints `C:\WINDOWS\system32\cmd.exe`), and
      delete the task.

    sshd runs the configured shell as `<shell> -c "<command>"` with no `-NoProfile`,
    so every exec, Heeler's probe and link included, runs the account's PowerShell
    profiles first, and Heeler's **Reconnect** runs its next execs under the new
    shell. sshd's `sftp` subsystem starts through that shell too: a profile that
    prints breaks SFTP and scp ("Received message too long", with a length read from
    the printed text), so write and remove a test profile through an exec such as
    `powershell -EncodedCommand`, not scp. Expected: the link's frames arrive whole,
    a killed link comes back, and the Host does not read
    **herdr-core is not installed**. The probe finds the core under
    `$env:USERPROFILE`, and the link runs `cd /d %USERPROFILE%` before `connect`, so
    a profile that calls `Set-Location` no longer moves either off the core. On the
    one machine run (herdr-core 0.1.16, OpenSSH_for_Windows_9.5p2), Windows
    PowerShell 5.1.26100.9711 and PowerShell 7.6.7 with a printing profile passed,
    and PowerShell 7.6.7 with `Set-Location` added read **herdr-core is not
    installed** with an older build, whose probe used a path relative to the folder
    an exec starts in. Record the result in `docs/agents/herdr-compatibility.md`.
36. Tear down. Some effects of these steps land in the account's own files and
    outlast the run:
    - Claude Code started under your account runs its 30-day cleanup and rotates
      `~\.claude.json` backups in `~\.claude\backups` (seen on herdr-core 0.1.16 in a
      stage that ran Claude Code 2.1.286 and 2.1.316; which of them ran it was not
      traced). In one run it deleted a
      folder under `~\.claude\projects` holding a month-old transcript, restored
      afterwards from a Volume Shadow Copy, and removed the account's two oldest
      backups. Before any step starts Claude Code, copy `~\.claude\projects`,
      `~\.claude\backups` and `~\.claude.json`. Writing the current UTC time into
      `~\.claude\.last-cleanup`, in the form it already holds, kept the cleanup from
      deleting it again later in that run, though the backup rotation ran anyway; put
      the file back after. Answering a trust dialog writes `~\.claude.json` too.
    - Claude Code applies the `env` of `~\.claude\settings.json` over the core's
      environment, so while that file sets an endpoint, model or token, one set for
      the core does not reach Claude Code: its turns use the account's own.
    - A device sign-in over SSH (`grok login --device-auth` here) opened the account's
      Chrome in session 0, on its default profile. It held that profile's lock for
      hours, until `Stop-Process -Force` ended it; a non-forced `taskkill` was
      refused. Sign in from the desktop session, or end that browser once the sign-in
      is done. Signing out locally does not show whether the provider revoked the
      device's authorization.
    - Some installers, Oh My Pi's and the desktop app's here, append to the user
      PATH. A PATH write made with a settings broadcast in the desktop session gives
      Explorer, and the programs it starts, whatever the value holds at that moment:
      put the final value back before any broadcast, and check Explorer's PATH at the
      end.
    - New Agent's discovery exec, every PowerShell Terminal and each kept Terminal the
      core restores run the account's PowerShell profile, which here left one
      `%LOCALAPPDATA%\fnm_multishells` link per start. Lines typed into a PowerShell
      Terminal join the PSReadLine history. Remove both.
    - `%LOCALAPPDATA%\herdr-core\<session>` and its `core.lock` stay after
      `server stop`. Delete them only for a session you started for the test.
    - Remove Host leaves the Host's trusted host key and its recent-workspace entry
      in the app's preferences. Remove your test key's line from the authorized-keys
      file, restore the file's access list, and check that the key is refused.
    - In helper scripts, never name a function after a built-in alias, which wins
      over it: `H` is `Get-History`, and a function named `H` made one cleanup skip
      its guard. Variable names ignore case, so `$r` is `$R`.

## Scope and results

The acceptance scope is manual SSH access to existing native Windows herdr
sessions, API/event synchronization, live terminal control, and foreground
Live Activity synchronization. Section 9 has its own scope: herdr-core Hosts.

The Windows pairing plugin, its Bootstrap Key forced command, and automatic
Device Key enrollment are excluded. The plugin manifest still excludes
Windows, so `heeler.pair` returning `platform_unsupported` is not a failure of
the manual connection path.

On a native Windows Herdr TUI Host, Changes, Skills, uploads/file staging, and
notification registration are explicitly unavailable in this implementation.
Their app guards must return an unavailable result instead of running POSIX remote scripts or
writing unsupported remote files. Agent Notifications and background Live
Activity push updates are unsupported because the Windows plugin is excluded.
Foreground Live Activity updates remain in scope through API events. A herdr-core
Host stages files through `terminal.put` (ADR 0032, section 9 steps 14 and 15).

As a final boundary check, try each unavailable feature on a Herdr TUI Host and
record its app message. It must fail promptly without disconnecting the Host or preventing
later Console refreshes and terminal input.

Record each result separately:

| Check | PowerShell 7 | cmd | macOS/Linux | Failure detail |
| --- | --- | --- | --- | --- |
| Password authentication and preflight | | | | |
| Device Key authentication | | | | |
| PowerShell startup banner | | N/A | N/A | |
| Named-session selection and isolation | | | | |
| Inherited client socket override isolation | | | N/A | |
| Initial workspace/agent snapshot | | | | |
| Event updates after connect/reconnect | | | | |
| Foreground Live Activity updates | | | | |
| Agent terminal output and input | | | | |
| Shell terminal output and input | | | | |
| Chinese/emoji and multiline paste | | | | |
| Remote mouse scrolling | | | | |
| Terminal resize and controller takeover | | | | |
| Windows unavailable-feature guards | | | N/A | |

For a failure, include the exact Heeler message, affected session name,
authentication method, and the command output from step 1. Note whether
ordinary noninteractive SSH commands still work. Omit passwords, private
keys, notification keys, and pairing-code seeds from the report.

### herdr-core Host results

Section 9 ran twice on one machine, the owner's, on 2026-11-03: Windows 11 25H2 build
26200.9711, Windows PowerShell 5.1.26100.9711 with PSReadLine 2.0.0,
OpenSSH_for_Windows_9.5p2 with no `DefaultShell` (so `cmd.exe`) outside step 35,
herdr-core 0.1.16 from its installer, and a herdr 0.9.3 Herdr TUI server beside it.
The second run added the Herdr desktop app 0.1.12 and a portable PowerShell 7.6.7. The
phone was a Heeler Debug 0.1.16 (37) Simulator build of `4521499c` on iOS 26.5, with a
Device Key for an administrator account, so the SSH token was elevated. Steps 24 to 33
ran on a local build of the same commit whose one changed line listed Claude Code, Grok
Build, Pi and Oh My Pi in `confirmedWindowsCoreChatPrograms`. The core ran
in the desktop session at medium integrity, started there by a one-off scheduled task
with the Host's command, not typed. Programs: Claude Code 2.1.286 (the account's
winget install) and 2.1.316 (npm), Grok Build 1.0.70 signed in by device code, Pi
1.4.0 and Oh My Pi 18.13.3 on an Anthropic-compatible endpoint the run set. Claude
Code answered through the endpoint and token in the account's own `settings.json`
(step 36), not the run's. Everything here was seen live, once, on this machine,
unless it says otherwise.

- [#587](https://github.com/ZingerLittleBee/Heeler/issues/587), steps 1 to 9, 34
  and 35:
  - Passed: step 1 in both runs, with no core started through 8 attempts; step 2,
    where the core took the name and the Host connected by itself 23 seconds after the
    start; step 3; step 4, Direct Input on Oh My Pi; step 5, rotation between 62x51
    and 117x23, Microsoft Edit full screen, and 300 lines of scrollback; step 6, with
    **herdr-core is not running** at 11 reads over more than 2 minutes and no core
    started; step 8, where the card took the repository's folder name (the exec
    itself was not captured); step 9; step 34, where Core Environment named
    `CLAUDECODE` and `HERDR_CHECK` with no value and went after a clean start.
  - Pins, step 7: passed only with the core ended by its pid. The holder started a
    new core in about 3 seconds, the Host read not running for about 4 seconds, and
    the pinned row stayed. The desktop start after it started nothing. After
    `server stop` and a start, the Pins stayed in the app's store with no row to show
    them. Neither run saw a pinned row after `server stop`.
  - Step 35: Windows PowerShell 5.1 and PowerShell 7.6.7 with a printing profile
    passed, with frames whole and a killed link back in 1.4 seconds. Preflight ran,
    all green, only under Windows PowerShell 5.1.
    PowerShell 7.6.7 with `Set-Location` added failed as the step's known defect
    says, and the printing profile broke scp. `DefaultShell` was put back and proved
    by the export's hash, and the safety task never ran.
  - Seen beside the steps: after Microsoft Edit quit across a rotation, PowerShell's
    screen held overlapping rows in Heeler and in the core's own `terminal.read`, so
    not from Heeler's renderer. Step 9's refusal read "This feature is unavailable on
    the Host", ended in a doubled period and came only after Save, and Core
    Environment explained `HERDR_CHECK` with `HERDR_PANE_ID`'s meaning (all changed
    since; not run again). Grok Build 1.0.70's first start stops at a
    "Help improve Grok" opt-in prompt, and Oh My Pi 18.13.3's at a setup wizard.
  - Not run: a blank Session (`default`).
- [#588](https://github.com/ZingerLittleBee/Heeler/issues/588), steps 10 to 15, second
  run:
  - Passed: New Agent listed Claude Code, Codex and Grok Build, what a plain SSH
    `Get-Command` found. An argument with a space, a single quote and Chinese reached
    Grok Build whole. Claude Code's exit ended its Terminal, with exit code 1 from its
    trust dialog's **No, exit**, and it left the list. New Terminal opened and ended
    with exit code 0. New Workspace showed in the desktop app 0.1.12, and the form had
    no name field. A Staged Image's file was read by its path with the same hash from
    the desktop session, and by Claude Code in step 17; it stayed after **Close Tab**
    and went with `terminal.rm`. 9 MiB was refused with the draft kept, and exactly
    8 MiB landed with the same hash.
  - Failed: Grok Build 1.0.70's exit, twice (step 11). Its Terminals ended only when
    closed from Heeler, with exit code 1 and reason `killed`.
  - Observed: a double quote and an empty argument did not pass through Windows
    PowerShell 5.1 whole. The core got both as typed, but `grok.exe`'s command line
    ended in `"say "hi"" ` with a trailing space, which standard parsing reads as
    `say hi` and no empty argument. What Grok Build itself read was not checked.
  - Not run: OpenCode, an agent under a junction, a `.ps1` shim blocked by policy
    (the machine's policy was Bypass), a slow link, Direct Input and Stop while a file
    crossed, and the removal about a day after a Terminal ends.
- [#589](https://github.com/ZingerLittleBee/Heeler/issues/589), steps 16 to 23, second
  run:
  - Passed: Send into a live Agent, Claude Code 2.1.286 from New Agent and 2.1.316
    started over the core's pipe in New Agent's form. A
    draft with a Staged Image's path reached Claude Code, which described the image.
    Step 19, before and after the desktop app's agent exited. Stop on Claude Code
    2.1.316, and on a stand-in that exits at Esc, since no installed agent does. Step
    20. No **not accepting a paste** notice appeared.
  - Failed: steps 18 and 22, as their known defects say. "Blocked pastes only" held
    only in that nothing was submitted.
  - Recorded: step 23 under Windows PowerShell 5.1. Not run: PowerShell 7 there.
- [#590](https://github.com/ZingerLittleBee/Heeler/issues/590), steps 24 to 33, second
  run, failed as a whole. New Agent listed only the account's Claude Code, Codex and
  Grok Build there, so npm Claude Code, Pi and Oh My Pi were started over the core's
  pipe in New Agent's form:
  - Passed: Claude Code 2.1.286 and 2.1.316 showed the conversation and sent from
    Chat, and Chat followed `/clear` on 2.1.286. 2.1.316 also stopped a turn and
    answered a Blocked card. Pi 1.4.0, whose image is `node.exe`, showed and sent and
    stopped a turn after **Add Heeler's Extension…** wrote exactly three copies, with
    its label's `start` equal to its process's creation time. Chat bound in about 3 to
    5 seconds, through an elevated SSH session against the core at medium integrity.
  - Failed: Oh My Pi 18.13.3, image `omp.exe`, label within 1.5 seconds with a profile
    and without. With the profile Chat showed the conversation (the Agent without one
    was not opened in Chat), but Send from Chat said
    **Heeler can't find the Agent's input box on screen.** before and after a turn,
    while Direct Input submitted. Grok Build 1.0.70 could not be told (step 29), and
    Claude Code through `npx` gave no Agent (step 27).
  - Seen: after `/clear`, Chat showed a **Working for 0:18** row counting up while
    Claude Code 2.1.286 sat idle, until the next turn. npm Claude Code's first check
    after its trust dialog said **Can't Tell the Conversation**, and the next, about 3
    seconds later, bound.
  - Not run: one program per build, since one build turned on all four; Codex and
    OpenCode; a Herdr TUI Host; a non-elevated SSH session against an elevated core;
    and step 33, as the run changed nothing in the repository, so
    `confirmedWindowsCoreChatPrograms` stayed empty at `4521499c`.
