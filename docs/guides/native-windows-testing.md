# Native Windows host testing

Use this checklist to validate the manual SSH connection work for
[#399](https://github.com/ZingerLittleBee/Heeler/issues/399) on Windows 11.
Run it against the Heeler build containing that change. These are acceptance
steps, not a record of a completed Windows test.

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
runs them: the app's tests script the probe and the exec, so this is the first
run of Heeler's own probe, its checkout read, its `cmd /d /c` `connect` line, its
agent discovery and launch, and its `terminal.put` through sshd.

1. Stop the core. On the phone, add the machine with Session left blank or a
   plain name, and confirm **herdr-core**. The Host reads
   **herdr-core is not running** with the start command, and on the machine no
   `herdr-core` process appears.
2. In your desktop session, in PowerShell, not as administrator, run the command
   the Host shows. Within its retry, the Host connects by itself. With a plain
   Session name this is the first run of `$env:HC_SESSION` with `server start` on
   Windows, which no observation has covered: record that the core took the name.
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
7. Start the core again in the desktop session. The Host reconnects, and Pins
   are kept.
8. Start a Terminal with a `herdr.space` label the desktop app has not named, in a
   subfolder of a repository. Its card takes the repository's folder name, and
   Worktrees stay off. Outside a repository it takes its directory's. This is the
   first run of Heeler's PowerShell checkout read through sshd.
9. Edit the Host's Session to a name with a space. The Host reads that the name is
   refused, and Rename and Worktrees are still not offered.
10. Install an agent the launch can find, with OpenCode too if you have it. New
    Agent lists what a Windows PowerShell session over SSH finds, and OpenCode's
    version reaches its launch (`-s ses_...` in the Terminal's argv on 2.1 or newer).
    An agent installed under a junction may be missing; note which.
11. Start one with an argument holding a space, a single quote and a non-ASCII
    character. It shows as an Agent of its kind, and the program receives the
    argument whole. Exit the agent: its Terminal ends and the Agent leaves the list.
    Note the exit code the core reports. A `.ps1` shim blocked by the machine's
    execution policy shows as listed and ends at once; note that too.
12. New Terminal opens a Terminal in the directory you picked, in a shell, and it
    is not listed as an Agent. Exit it: the Terminal ends.
13. New Workspace at a picked directory, with the desktop app running on the
    machine. The space appears in the desktop app, and the form has no name field.
14. Add a small image in an Agent's Composer. The path inserted into the draft
    names a file in `%LOCALAPPDATA%\herdr-core\<session>\files\<address>\`, and
    a program in that Terminal reads it by that path with the same hash. Close the
    Terminal: the file stays (recorded for `terminal.kill`). Note what removes it
    on your machine, since the file goes only with `terminal.rm`.
15. Add a 9 MiB file. Heeler says it is over the 8 MiB limit, the draft stays, and
    no file appears in that folder. Add one of exactly 8 MiB: it lands with the same
    hash, and the Host stays connected while it crosses on a slow link.
16. In an Agent New Agent started, type a message and tap Send. It submits within
    about a second, and the draft empties. Whether an Agent's bracketed paste reaches
    Heeler through the pseudo console has not been seen on any machine. If Send says
    **not accepting a paste** at the Agent's own input, note the program and its
    version: Send cannot work for it on this machine.
17. Add an image and Send the draft holding its path. The Agent reads the file by
    that path.
18. Leave a draft in an Agent's Composer, exit the Agent with Direct Input, and tap
    Send. Its Terminal has ended, so nothing runs anywhere, and the draft stays.
19. From the Herdr desktop app, start an agent (its `-NoExit` form), then in Heeler
    tap Send: the notice says the terminal **keeps a shell open**, nothing is
    written, and the draft stays. Exit that agent and tap Send again: the same notice,
    and PowerShell runs nothing.
20. Start an agent by typing it in a PowerShell Terminal. It is not listed as an Agent,
    since the foreground stays PowerShell, so it has no Composer.
21. Tap Stop during a working turn. The turn stops, and the Agent stays listed. Stop
    an Agent that exits at the key: it leaves the list.
22. Bring an Agent to a question and Send: the text lands in its input unsubmitted.
    The tools keyboard submits it.
23. Windows PowerShell 5.1 dropped a pending paste on one Ctrl+C in the runs recorded
    in `docs/agents/herdr-compatibility.md`, so Send says the text is **no longer in
    the terminal**. If your PowerShell or PSReadLine version keeps it, or PowerShell 7
    is installed and acts otherwise, record the versions there, and ADR 0035 needs your
    decision before Send ships on Windows.

These steps are for Chat ([#590](https://github.com/ZingerLittleBee/Heeler/issues/590)).
No lane runs them either. Nothing of the Windows process read has run on a Windows
machine: its body ran under PowerShell 7 on a Mac with its native calls stubbed, and
its C# only compiled there. Sign in to each program yourself. Never open Claude
Code's `.key` files.

24. In a local build, put one program in
    `HostCapabilities.confirmedWindowsCoreChatPrograms`. Codex and OpenCode are not
    candidates, and stay off even if listed. The other programs still offer the
    terminal alone. On a native Windows Herdr TUI Host, no Agent offers Chat.
25. Start Claude Code from New Agent, reach its prompt, send one message and open
    Chat. It shows that conversation. On the machine, in PowerShell, compare
    `(Get-Process -Id <pid>).StartTime.ToFileTimeUtc()` of `claude.exe` with
    `procStartFt` in `%USERPROFILE%\.claude\sessions\<pid>.json`. Record the field's
    name and form. If they differ, Chat says **Can't Tell the Conversation**, with no
    offer of the Helper.
26. Note how long Chat takes to bind. Each check is one PowerShell exec with an
    `Add-Type` compile, bounded at 20 seconds. Run it from an SSH session that is not
    elevated against a core that is, and the other way round: a process Heeler cannot
    read reads as **Can't Tell**, says the read failed, and offers no extension.
27. Repeat step 25 with an npm-installed Claude Code, where the Agent's image is
    `node.exe`, and through `npx`. Under `npx` Chat may say it can't tell. Record the
    tree from `Get-CimInstance Win32_Process`.
28. Run `/clear` in the terminal. Chat follows at its next check.
29. Start Grok Build and send a message. Chat shows it, from the one row of
    `active_sessions.json` with that `pid` and `pid_start`. Record `pid_start`'s value
    beside the creation time: Heeler assumes they are equal. Run `/new`: two rows
    match, and Chat says it can't tell until Grok Build starts again.
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
    pseudo console (step 16), record that Chat's Send says the same.
33. Record each program that passed as a versioned observation in
    `docs/agents/herdr-compatibility.md`, here, and by adding it to
    `HostCapabilities.confirmedWindowsCoreChatPrograms`. One that fails stays off, with
    its observation saying why.
34. Stop the core. In your desktop session run `$env:CLAUDECODE='1'; $env:HERDR_CHECK='1'`,
    then start the core there. Host detail shows **Core Environment** naming both, with
    no value. Start the core from a clean window and it goes. This is the first run of
    the check on Windows: if nothing appears, record that here and in
    `docs/agents/herdr-compatibility.md`, since a read that failed also shows nothing.
35. Record this machine's `DefaultShell`. Steps 1 to 7 prove the link only under that
    shell: repeat connect, attach and reconnect under the other one, restoring the value
    after, with one run under PowerShell 7 whose profile prints output and calls
    `Set-Location`. The link's frames arrive whole and the Host does not read
    **herdr-core is not installed**, since the probe finds the core from the folder an
    exec starts in. Record the result in `docs/agents/herdr-compatibility.md`.

## Scope and results

The acceptance scope is manual SSH access to existing native Windows herdr
sessions, API/event synchronization, live terminal control, and foreground
Live Activity synchronization.

The Windows pairing plugin, its Bootstrap Key forced command, and automatic
Device Key enrollment are excluded. The plugin manifest still excludes
Windows, so `heeler.pair` returning `platform_unsupported` is not a failure of
the manual connection path.

Changes, Skills, uploads/file staging, and notification registration are
explicitly unavailable on Windows in this implementation. Their app guards
must return an unavailable result instead of running POSIX remote scripts or
writing unsupported remote files. Agent Notifications and background Live
Activity push updates are unsupported because the Windows plugin is excluded.
Foreground Live Activity updates remain in scope through API events.

As a final boundary check, try each unavailable feature and record its app
message. It must fail promptly without disconnecting the Host or preventing
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
