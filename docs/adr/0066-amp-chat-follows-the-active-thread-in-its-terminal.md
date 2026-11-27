---
status: accepted
---

# Amp Chat follows the active thread in its terminal

One Amp CLI can run several threads in the same working directory. The most
recently updated thread can be running in the background. Herdr TUI
identifies the foreground process, while Amp's plugin API identifies the
thread currently selected inside it.

## Decision

On a macOS or Linux Herdr TUI or Rex Host, Chat binds to exactly one foreground Amp CLI.
Heeler checks its PID, process start and configuration directory over SSH.
An Amp plugin publishes a private per-process record with its protocol
version and a fresh instance identifier. It serves requests on an
account-private Unix socket. The SSH server must allow Unix socket forwarding.
The thread ID comes from `amp.activeThread`. A terminal with no selected
thread stays unbound. Historical Chat data cannot authorize a send.

The app bundles the plugin and offers to install it in the running Amp
account's configuration after the user confirms the Host and path. An
identical installation can be repeated safely. Chat offers an update for a
known earlier bundle, checks its bytes again before replacing it, and leaves
custom files and symlinks for the user to inspect. The user reloads plugins
in running terminals.

Chat reads bounded pages from the selected thread. Each page keeps the
complete text of a mobile prompt so Chat can confirm delivery. Tool results
carry a small preview. Expanding one reads that call from the same message
and binding, up to 1,000 lines or 64 KiB. The
plugin checks the selection before and after asynchronous reads. Each load
has its own instance and each change of selection advances a revision,
including a switch away and back. On a Herdr TUI Host the Composer sends ordinary text with
Amp's `appendUserMessage` on the displayed thread after checking the screen
and binding. When Chat cannot recognize the input box, **Send Anyway** reads
the screen and checks the binding again. A visible terminal draft, an open
menu or a Blocked Agent still holds the message. A submission carries the
Composer's message ID, so repeating that request within the binding appends
it at most once. A lost reply leaves the outcome unknown. Commands,
attachments and approval dialogs use Terminal.

On macOS and Linux Rex, Chat rechecks the same server instance, session, block and foreground process before and after a plugin read. Its plugin transport accepts only binding and page requests. All input goes through the regular Rex terminal. Plugin installation and updates use the same user confirmation and exact-byte checks as Herdr TUI. If the plugin unloads or the process changes, Chat drops the displayed binding and asks the user to reconnect the plugin.

## Consequences

No Host-wide transcript search or Amp service credentials are needed.
The app can receive completed messages and updated tool output on its next
poll. The integration depends on the local CLI's plugin lifecycle and on
the Server Kind’s foreground process reporting. Amp Chat on native Windows
and other Server Kinds needs its own verified way to identify and reach the plugin.

See the [Amp plugin API](https://ampcode.com/docs/plugin-api) and
[plugin installation and lifecycle](https://ampcode.com/docs/customize/plugins).
