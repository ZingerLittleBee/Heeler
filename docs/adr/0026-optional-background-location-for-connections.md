---
status: proposed
---

# Optional background location for Host connections

Settings > Connections > Background Connections adds an opt-in, disabled by
default. With When In Use location authorization and an active or connecting
Host, `BackgroundConnectionKeeper` starts standard Core Location updates in
the foreground. It uses three-kilometer accuracy, disables automatic pausing,
and requests the visible background location indicator. `UIBackgroundModes`
declares `location`. It requests no Always authorization and discards every
coordinate without logging, storing, or transmitting it.

While the location service is running, `AppActivityCoordinator` does not start
the 15-second Background Grace Period or emit a deliberate suspension. This
keeps both SSH connections and in-process Overlay Networks running. SSH
keepalive still belongs to EventsSession; location supplies an opportunity to
execute, not evidence that the network or connection is healthy. Every
foreground return retains the existing connection probes and terminal recovery.

In-app notification banners follow the actual aggregate scene phase, not the
effective connection phase. Leaving the active scene cancels pending holds and
dismisses the current banner. Background events still advance the status
baseline silently; foregrounding consumes the latest Console value before
allowing new announcements, so deferred observations do not replay an alert.
Background APNs delivery remains independent.

Removing the last connection, opting out, losing authorization, a non-transient
location error, or a location pause stops location updates. If already in the
background, the coordinator requests the normal UIKit grace assertion and
suspends after its deadline, or immediately if the assertion is refused. It
never starts location updates or requests permission in the background. A
foreground return retries an enabled service that previously failed.

The setting is not a guarantee of indefinite execution: iOS can terminate the
process, and network changes can still break SSH. APNs remains the independent
notification path. Using background location solely for connection continuity
needs App Store review against the app's actual purpose; this local change does
not establish distribution approval.

## Evidence (2026-10-22)

[Termius' iOS FAQ](https://docs.termius.com/help-center/faq/how-can-i-keep-termius-sessions-alive-in-the-background-on-ios-ipados)
documents location tracking for session maps and improved background connection
survival as a side effect. It does not document its private implementation.
This is real location tracking, not injection of simulated GPS coordinates.

[Apple's CLLocationManager documentation](https://developer.apple.com/documentation/corelocation/cllocationmanager/allowsbackgroundlocationupdates)
describes continued background execution when standard updates start in the
foreground with background location enabled. Its
[automatic-pausing documentation](https://developer.apple.com/documentation/corelocation/cllocationmanager/pauseslocationupdatesautomatically)
recommends low accuracy when disabling pauses for continued delivery.

Termius Android 7.11.2 (988), package `com.server.auditor.ssh.client`, was
downloaded separately and statically inspected. Its manifest declares
`SessionStorageService` with a `specialUse` foreground service type, and its
session service calls `startForeground` while sessions exist. It requests no
location permission. This Android evidence is not evidence of iOS internals.

## Verification

Focused suites: `BackgroundConnectionKeeperTests`, `AppActivityCoordinatorTests`,
and `AppModelActivityDriverTests`. Real-device acceptance must cover the opt-in
prompt, approximate location, a stationary locked device beyond 15 seconds,
permission revocation, opt-out, the last Host disconnecting, and foreground
recovery after a network change. Simulator tests alone do not prove that iOS
will continue scheduling the app on a locked physical device.
