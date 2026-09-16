---
status: accepted
---

# Workspace terminals share a bounded attach lifetime

Issue #333 makes every Pane discoverable as a Workspace Terminal, including
panes running Agents. Agent detail has a floating Workspace menu over the
terminal, so navigation costs the output neither width nor height.
The Console's Agents / Terminals control switches between the existing Agent
list and a Host, then Workspace, grouped terminal inventory. Agent panes route
to Agent detail, preserving Composer, notification and Agent actions; ordinary
panes route to the interactive Shell Terminal. Listing never opens a PTY.

The authoritative inventory comes from `session.snapshot.panes`, joined with
its tabs and workspaces. Membership events refresh it; `pane.updated` applies
title and directory changes locally instead of making terminal-title traffic
an RPC resnapshot loop. A reconnect discards the old inventory and reconciles
against a snapshot from the new connection. Pane ids remain opaque.

## Three retained terminals per Host

The user explicitly requested lazy connections that survive switching, with
a five-minute idle expiry and at most three terminal connections per Host.
This supersedes ADR 0011 and ADR 0015's single live terminal constraint.

Agent and shell owners share one retention budget, keyed by Host and terminal
id. Admission evicts the least recently viewed idle terminal and awaits its
channel teardown before opening the next. A terminal displayed in a window
is protected from eviction; if all three are displayed, opening another fails
with an actionable message. Idle expiry only detaches the client. It never
closes the remote Pane or terminates its processes.

Each retained connection keeps its Ghostty surface, so output arriving while
offscreen updates the same emulator and scrollback. Deselecting clears input,
paste and view callbacks; showing it again rebinds them. A replacement feed
gets a new surface. Suspension, Host removal and obsolete connection
generations reclaim retained work. UI ownership prevents one UIKit surface
being displayed in two windows simultaneously.

The SSH session admission budget allows three attach PTYs and six ordinary
exec/SFTP sessions, leaving headroom under sshd's default ten session channels.
Forwarding retains its separate eight ordinary channels plus one events
channel. EventsSession serializes attaches to the same target but admits
different targets concurrently. The SSH driver and its native continuation
serialization remain unchanged.

## Existing terminals and explicit takeover

Open Terminal prefers existing shell panes in the Agent's Workspace: one
opens directly, multiple offer a choice, and creation is the fallback. A
successful creation is remembered before inventory refresh, so a failed
refresh retries discovery without creating another tab.

Existing ordinary terminals attach without `--takeover`. If an attach ends,
the user can reattach or explicitly Take Over another client's attachment.
Agent attaches preserve their existing takeover behavior. Back detaches only
after retention expires or admission evicts the idle connection. Close Terminal
is a separate confirmed `pane.close` action, affecting that Pane, not its
siblings in the same tab.

## Verification boundary

Behavior tests cover inventory convergence, lazy admission, mixed Agent/shell
LRU eviction, cancellation, idle expiry and renderer reuse. UI hosting tests
cover the menu and list controls. Real SSH and physical-device behavior require
their own runs; these tests do not constitute live herdr or device evidence.
