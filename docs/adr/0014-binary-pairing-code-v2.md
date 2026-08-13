# Encode Pairing Code v2 as raw binary

The Pairing Code v1 envelope is an ASCII prefix plus base64url JSON. A typical
308-character payload requires a version 11 QR, which is too large for the
pairing popup's terminal cell budget.

## Decision

The plugin emits Pairing Code v2 as a compact binary envelope and passes its
bytes directly to the QR encoder's byte-mode segment. Fixed-width binary fields
carry the port, SHA-256 host-key digest, Bootstrap Key seed, and expiry. IP
addresses use their packed representation; usernames and hostnames remain
length-prefixed UTF-8. Shared Node and Swift vectors define the exact bytes and
IPv6 canonical text.

The app accepts both v1 and v2 during migration. The plugin emits only v2.

## Rejected alternative

Base45 in QR alphanumeric mode was rejected. As measured in
`docs/research/terminal-qr-rendering.md`, a 130-byte payload costs 1,086 QR data
bits with Base45 versus 1,052 bits in raw byte mode. Both reach version 6 at
error correction L, but Base45 leaves only two bits of capacity and becomes
version 9 if a reader or encoder treats it as byte-mode text. It adds encoding
without improving density or compatibility inside Heeler's controlled scanner.

## Consequences

Pairing Code v2 is small enough to fit the popup at a materially lower QR
version. It is an opaque binary protocol rather than copyable text, so the
shared vectors are the compatibility contract and breaking changes require a
new envelope version.
