# Herdr Mobile Pairing plugin

A [herdr plugin](https://herdr.dev/docs/plugins/) that renders a **Pairing Code**
QR so the herdr-mobile app can add this machine as a Host by scanning it
(ADR 0007). The `pair` action opens a popup pane: confirm which of the
machine's addresses go into the code, then scan the QR with the app.

This stage ships the config-only Pairing Code (addresses, port, username, host
key fingerprint). The Bootstrap Key and automatic Enrollment land with the
follow-up tickets of the pairing spec.

## Requirements

- Node.js >= 20 on `PATH`
- herdr >= 0.7.5
- An OpenSSH server on this machine (the code pins its host key fingerprint)

## Install

```bash
herdr plugin install zinger-labs/herdr-mobile/plugin   # once this repo is public
```

For local development, link the working tree instead (build it yourself,
`plugin link` does not run build commands):

```bash
cd plugin && npm ci
herdr plugin link "$(pwd)"
herdr plugin action invoke herdr-mobile.pairing.pair
```

The popup checklist: arrows or `j`/`k` move, space toggles, `a` toggles all,
enter renders the QR, `q`/escape closes.

Known limitation: the advertised SSH port is currently fixed at 22.

## Pairing Code envelope (v1)

The Pairing Code is a single-line string; the QR image is just its rendering.

```
HERDR-PAIR:<version>:<base64url(JSON, no padding)>
```

- `HERDR-PAIR` is a literal prefix; anything else is rejected (`bad_prefix`).
- `<version>` is a decimal integer. This document specifies version `1`;
  any other value is rejected (`unsupported_version`).
- The body is the payload JSON, UTF-8, encoded as unpadded base64url
  (RFC 4648 `-`/`_` alphabet). Invalid base64url or JSON is rejected
  (`bad_encoding`).

### Payload fields

| Wire key | Type    | Required | Meaning |
| -------- | ------- | -------- | ------- |
| `addrs`  | string[]| yes      | Candidate addresses in the order the app should try them. Non-empty; each entry a non-empty string without whitespace. IPv6 literals carry no brackets and no zone id. |
| `port`   | integer | yes      | SSH port, `1..65535`. |
| `user`   | string  | yes      | SSH username. Non-empty, no whitespace. |
| `fp`     | string  | yes      | Host key fingerprint exactly as OpenSSH prints it: `SHA256:` + 43 chars of unpadded standard base64. The app pins this instead of showing a TOFU prompt. |
| `seed`   | string  | no       | Raw 32-byte Ed25519 seed of the Bootstrap Key, unpadded base64url. Present together with `exp` or not at all. |
| `exp`    | integer | no       | Unix-seconds expiry of the Bootstrap Key. Present together with `seed` or not at all. |

A payload violating these rules is rejected (`bad_payload`). A code without
`seed`/`exp` is a config-only Pairing Code: same ceremony minus the bootstrap
connection.

### Canonical encoding

Encoders emit the keys in the order of the table above with no JSON
whitespace, so a given payload has exactly one canonical code. Decoders do not
depend on key order.

### Compatibility rules

- Decoders ignore unknown payload fields; additive metadata may appear within
  v1.
- Any breaking change (removing, renaming, or re-typing a field, or changing
  the envelope framing) bumps `<version>`, and both implementations must be
  updated together.

### Shared test vectors

`test-vectors/pairing-code-v1.json` is the single source of truth for the
envelope, consumed by the Node tests here and the Swift tests in the app.
Valid vectors must decode to the given payload and (unless `decodeOnly`)
re-encode to the exact code; invalid vectors must fail with the given error
code (`bad_prefix`, `unsupported_version`, `bad_encoding`, `bad_payload` —
these map to the "parse" step of the pairing failure taxonomy).

## Tests

```bash
npm test
```

Uses Node's built-in test runner; no test dependencies.
