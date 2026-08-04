#!/usr/bin/env python3
"""Print the base64 raw Ed25519 seed of an unencrypted OpenSSH private key.

The real-sshd fixture generates a throwaway Device Key per run with
`ssh-keygen`, so no long-lived key committed to this repository ever authorizes
a login on a developer machine. The Swift suites need that same key as the
32-byte seed `CryptoKit`'s `Curve25519.Signing.PrivateKey` accepts, and
`ssh-keygen` has no flag that prints one, so read it out of the standard
`openssh-key-v1` container instead.

Format reference: PROTOCOL.key in the OpenSSH source tree.
"""

import base64
import struct
import sys

MAGIC = b"openssh-key-v1\x00"


def read_string(blob: bytes, offset: int) -> tuple[bytes, int]:
    (length,) = struct.unpack_from(">I", blob, offset)
    start = offset + 4
    return blob[start : start + length], start + length


def seed(path: str) -> bytes:
    lines = []
    inside = False
    with open(path, "r", encoding="ascii") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("-----BEGIN "):
                inside = True
            elif line.startswith("-----END "):
                inside = False
            elif inside:
                lines.append(line)
    blob = base64.b64decode("".join(lines))

    if not blob.startswith(MAGIC):
        raise SystemExit(f"{path} is not an openssh-key-v1 private key")
    offset = len(MAGIC)
    cipher, offset = read_string(blob, offset)
    kdf, offset = read_string(blob, offset)
    _kdf_options, offset = read_string(blob, offset)
    if cipher != b"none" or kdf != b"none":
        raise SystemExit(f"{path} is encrypted; the fixture key must not be")
    (key_count,) = struct.unpack_from(">I", blob, offset)
    offset += 4
    if key_count != 1:
        raise SystemExit(f"{path} holds {key_count} keys; expected exactly one")
    _public, offset = read_string(blob, offset)
    private, _ = read_string(blob, offset)

    # check1 || check2 || keytype || public || private || comment
    offset = 8
    keytype, offset = read_string(private, offset)
    if keytype != b"ssh-ed25519":
        raise SystemExit(f"{path} is a {keytype.decode()} key; expected ssh-ed25519")
    _public_half, offset = read_string(private, offset)
    material, _ = read_string(private, offset)
    if len(material) != 64:
        raise SystemExit(f"{path} has a {len(material)}-byte scalar; expected 64")
    return material[:32]


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: openssh-ed25519-seed.py <private-key-path>")
    print(base64.b64encode(seed(sys.argv[1])).decode("ascii"))
