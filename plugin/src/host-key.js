// Host key fingerprint for the Pairing Code (ADR 0007).
//
// The app pins the Host's SSH fingerprint from the Pairing Code instead of
// showing a TOFU prompt, so the plugin must compute exactly what OpenSSH
// prints: SHA256 of the public key blob, base64 without padding.

import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Preference order mirrors what modern clients negotiate first.
const HOST_KEY_FILES = [
  "ssh_host_ed25519_key.pub",
  "ssh_host_ecdsa_key.pub",
  "ssh_host_rsa_key.pub",
];

const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;

/**
 * Compute the OpenSSH SHA256 fingerprint of a public key line
 * ("<type> <base64 blob> [comment]"), as printed by `ssh-keygen -lf`.
 *
 * @returns {{keyType: string, fingerprint: string}}
 */
export function fingerprintPublicKeyLine(line) {
  const [keyType, blob] = line.trim().split(/\s+/);
  if (!keyType?.startsWith("ssh-") && !keyType?.startsWith("ecdsa-")) {
    throw new Error(`not an SSH public key line: ${JSON.stringify(line)}`);
  }
  if (!blob || !BASE64_PATTERN.test(blob)) {
    throw new Error("SSH public key line has no base64 key blob");
  }
  const digest = createHash("sha256").update(Buffer.from(blob, "base64")).digest("base64");
  return { keyType, fingerprint: `SHA256:${digest.replace(/=+$/, "")}` };
}

/**
 * Read the machine's preferred SSH host key fingerprint from `sshDir`.
 * Public halves are world-readable, so no privileges are needed.
 *
 * @returns {{keyType: string, fingerprint: string, path: string} | null}
 */
export function readHostKeyFingerprint(sshDir = "/etc/ssh") {
  for (const file of HOST_KEY_FILES) {
    const path = join(sshDir, file);
    let line;
    try {
      line = readFileSync(path, "utf8");
    } catch {
      continue;
    }
    return { ...fingerprintPublicKeyLine(line), path };
  }
  return null;
}
