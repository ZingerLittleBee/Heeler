# Privacy

herdr-mobile is a native iOS console for [herdr](https://herdr.dev). It talks
to your own machines ("Hosts") over SSH. It has no backend, no analytics, and
no account system. Your Hosts, credentials, and agent activity never pass
through any server we operate — with exactly one narrow exception, the Push
Relay, documented below.

## What stays on your device

- **Credentials.** The Device Key (an Ed25519 SSH key generated on device),
  Host fingerprints, and every Notification Key live in the iOS Keychain and
  never leave it.
- **Host list and settings.** Your Hosts, terminal theme, and notification
  preferences are stored locally.
- **Agent activity.** Terminal output, agent names, statuses, and pane
  contents travel only over the direct SSH connection between your device and
  your Host.

## Agent Notifications and the Push Relay

Agent Notifications let you know when an agent becomes blocked (waiting on you)
or finishes while the app is backgrounded or closed. Delivering a push to an
iOS app requires Apple's push service (APNs), and reaching APNs requires an
Apple push key bound to this app's bundle id. To avoid asking every user to
provision Apple credentials, notifications flow through a **push relay**: a
small, stateless, open-source forwarder the developer hosts at
`https://herdr-apns.bybee.dev`.

It is a push relay, not a server: it keeps no accounts, no database, and no
message history. It holds the Apple push key, signs each request to Apple, and
forwards an already-encrypted notification. The notification is encrypted on
your Host with your per-Host Notification Key — a key the relay never receives.

### What the push relay sees

- Your device's **Apple push token**, so Apple knows which device to notify.
- The **encrypted notification (ciphertext)**, which it forwards to Apple
  without decrypting.
- Your Host's **source IP address**, as with any network request.

### What the push relay cannot see

- The **decrypted notification content**: agent names, statuses, and pane ids.
- Anything about what your agents are doing. The relay never holds your
  Notification Key, so the ciphertext it forwards is opaque to it. Your device
  decrypts the notification locally, inside a Notification Service Extension,
  and only then renders the real title and body.

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

A custom relay is **only useful if you build the app yourself** with your own
bundle id and your own Apple push key. Apple push keys are bound to the app's
bundle id, so a relay you deploy cannot deliver notifications to an
App Store or TestFlight build of this app — only the developer-hosted relay
can reach those. Setting a custom URL in a build you did not sign will simply
point your Hosts at a relay that Apple will not let deliver to this bundle.

## Contact

Questions about this document belong in the project's issue tracker at
<https://github.com/ZingerLittleBee/Heeler>.
