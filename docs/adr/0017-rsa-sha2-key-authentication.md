---
status: accepted
---

# RSA-SHA2-512 authentication with one device RSA Key

This decision is tracked in [Issue #318](https://github.com/ZingerLittleBee/Heeler/issues/318).

Heeler adds **RSA Key** as an explicit Host authentication method alongside
Device Key and Password. The app generates one device-wide 3072-bit RSA
identity, persists its private PKCS#1 representation in the Keychain, and
exposes only its OpenSSH public-key line for registration. SSH user-auth
signatures use `rsa-sha2-512`; the app never falls back to the legacy
`ssh-rsa` signature algorithm with SHA-1.

The same RSA Key is used by every Host configured for this method. When a
Jump Host is configured, the current Host model applies one authentication
method to both hops, so both machines must authorize that public key. Replacing
a corrupt or intentionally rotated RSA Key is always an explicit user action
and warns that every affected Host must be updated.

## Rationale

Device Key remains the preferred default: Ed25519 is smaller, faster, and is
already enrolled by Pairing. Some SSH access systems instead require users to
register an RSA public key and accept modern RSA-SHA2 signatures. Password and
Bootstrap Key do not cover that setup, and changing the Device Key algorithm
would break existing enrolled Hosts.

One device-wide RSA Key mirrors Device Key's identity model and lets a user
register the same public key on multiple Hosts without accumulating private
keys. Per-Host RSA identities would reduce rotation blast radius, but would add
Keychain lifecycle, export, recovery, and Jump Host credential choices that the
current Host model does not otherwise have.

`HeelerSSH` already exposes public-key authentication as a public blob plus a
signing closure. RSA Key therefore stays in the app layer: Security.framework
generates and signs with the key, while the SSH package remains independent of
Keychain and product-specific authentication modes.

## Consequences

- Device Key remains the default and Pairing continues to enroll only Device
  Key. RSA Key setup is manual and never changes a Host automatically.
- The app-generated private RSA key is persisted only in the Keychain and is
  never copied, logged, or exported. Disposable tests generate a separate,
  throwaway RSA identity inside their isolated fixture.
- The public wire blob remains `ssh-rsa`, as required by RFC 4253, while the
  user-auth signature algorithm is `rsa-sha2-512` from RFC 8332.
- HeelerSSH pins `LIBSSH2_METHOD_SIGN_ALGO` to `rsa-sha2-512` instead of
  relying on libssh2's automatic RSA signature selection.
- libssh2 applies that preference only when the server advertises
  `server-sig-algs`; otherwise it keeps the `ssh-rsa` algorithm name. HeelerSSH
  therefore reads the algorithm from the data it is asked to sign and refuses to
  sign anything but `rsa-sha2-512`. A Host that offers no RSA-SHA2-512
  signature fails as an unsupported signature, not as a rejected key, so the
  user is not told to register a key the Host would never verify.
- Rotating the single RSA Key invalidates every RSA Key Host until its new
  public line is registered. The recovery UI states that blast radius before
  replacement.
- Product UI and domain language stay provider-neutral. A deployment-specific
  portal may be documented outside the authentication model.
- Direct and Jump Host disposable-sshd tests force the real callback signer
  through RSA-SHA2-512 without enabling a SHA-1 fallback.
