# Privacy

Heeler is a native iOS console for [herdr](https://herdr.dev). It talks
to your own machines ("Hosts") over SSH. It has no analytics or account system.
Your SSH credentials and live agent sessions do not pass through a service we
operate. Agent Notifications use the limited-purpose Push Relay documented
below.

## Where data is stored

- **SSH credentials.** The Device Key's private half is generated on device,
  remains in the iOS Keychain, and never leaves your device. Host fingerprints
  are also stored locally.
- **Notification Keys.** Each per-Host Notification Key is generated on your
  device and stored in the shared Keychain. Heeler copies it over SSH to the
  corresponding Host so the plugin can encrypt notifications. The Push Relay
  never receives it.
- **Host list and settings.** Your Hosts and app settings are stored locally.
  Per-Host notification registration and delivery flags are stored on that Host.
- **Live agent activity.** Terminal output, prompts, and pane contents travel
  only over the direct SSH connection between your device and your Host. The
  limited Agent Notification metadata described below takes a separate,
  encrypted route.

## Agent Notifications and the Push Relay

Agent Notifications let you know when an agent becomes blocked (waiting on you)
or finishes while the app is backgrounded or closed. Delivering a push to an
iOS app requires Apple's push service (APNs), and reaching APNs requires an
APNs credential authorized to send notifications for this app's bundle ID. To
avoid asking every user to provision Apple credentials, notifications flow
through a **push relay**: a small, stateless, open-source forwarder the
developer hosts at
`https://heeler-apns.bybee.dev`.

It is a stateless push relay, not an account or message-storage service: it
keeps no accounts, database, queue, or message history. It holds the Apple push
key, signs each request to Apple, and forwards an already-encrypted notification.
The notification is encrypted on your Host with your per-Host Notification Key
— a key the relay never receives.

### What the push relay sees

- Your device's **Apple push token**, so Apple knows which device to notify.
- The **encrypted notification (ciphertext)**, which it forwards to Apple
  without decrypting.
- Your Host's **source IP address**, as with any network request.
- **When and how often** your Host sends notification requests.
- For lock-screen Live Activity updates only: the **status counts** (how many
  agents are working, blocked, or done) and the update/end signal. Apple
  renders these counts directly, so they cannot be encrypted; everything
  identifying — agent kind, task title, host name — stays inside the
  ciphertext and is decrypted on your device at render time.

### What the push relay cannot see

- The **notification content**: project name, task title, agent type, status,
  pane id, and timestamp. The relay never holds your Notification Key, so this
  content remains opaque to it. Your device decrypts the notification locally,
  inside a Notification Service Extension, and only then renders the real title
  and body.

If a notification cannot be decrypted (for example, a forged or corrupt push),
the app shows a generic fallback banner rather than any spoofed content.

### Turning it off

Removing a Host's Notification Registration deletes its entry from that Host
and stops its notifications immediately. Declining or revoking the iOS
notification permission stops all of them.

## Custom relay URL

Both the herdr plugin and this app accept a custom push relay base URL, so you
can run your own relay instead of the developer-hosted one. The relay's source
is public precisely so its behavior is verifiable rather than promised.

A custom relay **only works with an app you build and sign yourself**. It must
use APNs credentials authorized for that app's bundle ID. Only the
developer-hosted relay is configured to deliver notifications to this App Store
or TestFlight build. Setting a custom URL in a build you did not sign will point
your Hosts at a relay that Apple will not allow to deliver to this app.

## Contact

Questions about this document belong in the project's issue tracker at
<https://github.com/ZingerLittleBee/Heeler>.
