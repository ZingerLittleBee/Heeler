// Host key fingerprint for the Pairing Code (ADR 0007).
//
// The app pins the Host's SSH fingerprint from the Pairing Code instead of
// showing a TOFU prompt, so the plugin must compute exactly what OpenSSH
// prints: SHA256 of the public key blob, base64 without padding.
//
// sshd does not have to serve the keys under /etc/ssh — a `HostKey` directive
// can point anywhere, and sshd presents that key while a stale
// /etc/ssh/ssh_host_ed25519_key.pub would pin the wrong fingerprint (Heeler
// then correctly rejects the connection). Discovery therefore reads the
// machine's effective sshd configuration first, in the order sshd itself
// would use, and falls back to the conventional /etc/ssh layout only when
// the configuration declares no HostKey at all. An explicit
// HEELER_SSH_HOST_KEY override wins over both, so exotic layouts (or a
// listener whose configuration file cannot be read) stay pairable.
//
// Unprivileged `sshd -T` refuses to print a config it cannot fully load
// (root-only host keys make it exit with "no hostkeys available"), so the
// config file is parsed directly instead of shelling out; the parser handles
// only the lines it needs and is best-effort. When a configuration declares
// HostKeys but none of their public halves can be read, discovery fails
// (null) rather than pinning a possibly stale /etc/ssh key — a wrong pin is
// exactly the failure this module exists to prevent.

import { createHash } from "node:crypto";
import { accessSync, constants, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

// Preference order mirrors the app's negotiation list (SessionDriver's
// ssh-ed25519-first preference), expressed as sshd default host-key basenames.
const HOST_KEY_FILES = [
  "ssh_host_ed25519_key.pub",
  "ssh_host_ecdsa_key.pub",
  "ssh_host_rsa_key.pub",
];

const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
const DEFAULT_SSH_DIR = "/etc/ssh";
const DEFAULT_SSHD_CONFIGS = ["/etc/ssh/sshd_config", "/etc/ssh/sshd_config.d"];
const OVERRIDE_ENV_VAR = "HEELER_SSH_HOST_KEY";

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

// Resolve a `HostKey` value to a candidate public key path: the .pub sibling
// of the private key, which is the public half sshd itself presents. Only that
// sibling is probed — falling back to /etc/ssh/<basename>.pub could pick up a
// stale decoy key there, which is exactly the wrong-pin failure this module
// prevents. Overrides that want the conventional layout point at that key
// directly. Only public halves are ever read.
function publicKeyCandidates(hostKeyPath) {
  return hostKeyPath.endsWith(".pub") ? [hostKeyPath] : [`${hostKeyPath}.pub`];
}

function readFirstPublicKey(candidates) {
  for (const path of candidates) {
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

function isFile(path) {
  try {
    accessSync(path, constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

// Expand one sshd_config include chain. `Include` values support relative
// paths (taken from the including file's directory) and glob(3) patterns; a
// literal path or directory is read as-is, and a glob is resolved only for
// the common sshd_config.d/*.conf shape (the /etc/ssh fallback still covers
// anything else). Returns the resolved HostKey values in config order.
function hostKeysFromConfig(configPath, seen, depth) {
  let text;
  try {
    text = readFileSync(configPath, "utf8");
  } catch {
    return [];
  }
  const hostKeys = [];
  const directory = dirnameOf(configPath);
  for (const rawLine of text.split("\n")) {
    const line = stripConfigComment(rawLine);
    if (line === "") {
      continue;
    }
    const keywordMatch = /^([A-Za-z0-9]+)\s*(.*)$/.exec(line);
    if (keywordMatch === null) {
      continue;
    }
    const keyword = keywordMatch[1].toLowerCase();
    const value = keywordMatch[2].trim();
    if (keyword === "hostkey") {
      if (value !== "") {
        hostKeys.push(value);
      }
    } else if (keyword === "include" && depth < 8) {
      const target = value.startsWith("/") ? value : join(directory, value);
      for (const included of configFilesUnder(target)) {
        if (!seen.has(included)) {
          seen.add(included);
          hostKeys.push(...hostKeysFromConfig(included, seen, depth + 1));
        }
      }
    }
  }
  return hostKeys;
}

function stripConfigComment(line) {
  const hash = line.indexOf("#");
  return (hash === -1 ? line : line.slice(0, hash)).trim();
}

function dirnameOf(path) {
  const index = path.lastIndexOf("/");
  return index === -1 ? "." : path.slice(0, index);
}

// sshd includes a directory only through its *.conf entries, lexically
// ordered; a literal file is included as itself. A glob value is expanded for
// the ubiquitous `Include /etc/ssh/sshd_config.d/*.conf` shape (one directory
// prefix plus a `*.conf` pattern); anything more exotic is skipped.
function globConfFiles(target) {
  const separator = target.lastIndexOf("/");
  const directory = separator === -1 ? "." : target.slice(0, separator);
  const pattern = separator === -1 ? target : target.slice(separator + 1);
  if (!/^\*\.conf$/.test(pattern)) {
    return [];
  }
  let names;
  try {
    names = readdirSync(directory);
  } catch {
    return [];
  }
  return names.sort().map((name) => join(directory, name));
}
function configFilesUnder(target) {
  if (target.includes("*")) {
    return globConfFiles(target);
  }
  if (!isFile(target)) {
    return [];
  }
  let stats;
  try {
    stats = statSync(target);
  } catch {
    return [];
  }
  if (!stats.isDirectory()) {
    return [target];
  }
  let names;
  try {
    names = readdirSync(target);
  } catch {
    return [];
  }
  return names
    .filter((name) => name.endsWith(".conf"))
    .sort()
    .map((name) => join(target, name));
}

/**
 * Collect the HostKey private-key paths sshd's effective configuration
 * declares, in declaration order (`/etc/ssh/sshd_config`, then
 * `/etc/ssh/sshd_config.d/*.conf` lexically — sshd's own Include semantics).
 *
 * @param {string[]} [configPaths]
 * @returns {string[]}
 */
export function configuredHostKeys(configPaths = DEFAULT_SSHD_CONFIGS) {
  const seen = new Set();
  const hostKeys = [];
  for (const path of configPaths) {
    for (const file of configFilesUnder(path)) {
      if (seen.has(file)) {
        continue;
      }
      seen.add(file);
      hostKeys.push(...hostKeysFromConfig(file, seen, 0));
    }
  }
  return hostKeys;
}

/**
 * The plugin's host-key pin for the Pairing Code: what the local sshd
 * actually presents, or null when it cannot be determined.
 *
 * Order: an explicit HEELER_SSH_HOST_KEY override (public or private key
 * path), then every HostKey the effective sshd configuration declares, then
 * — only when the configuration declares no HostKey at all — the conventional
 * /etc/ssh layout. Configured keys are probed in configuration order; which
 * one sshd offers the app depends on per-host negotiation, so no ordering
 * assumption is imposed on them beyond that. A configuration whose
 * HostKeys are all unreadable fails (null) instead of pinning a stale
 * /etc/ssh key; the HEELER_SSH_HOST_KEY override is the escape hatch.
 *
 * @param {string} [sshDir] conventional host-key directory
 * @param {{env?: object, sshdConfigs?: string[]}} [options]
 * @returns {{keyType: string, fingerprint: string, path: string} | null}
 */
export function readHostKeyFingerprint(
  sshDir = DEFAULT_SSH_DIR,
  { env = process.env, sshdConfigs = DEFAULT_SSHD_CONFIGS } = {},
) {
  const override = env[OVERRIDE_ENV_VAR];
  if (typeof override === "string" && override.trim() !== "") {
    return readFirstPublicKey(publicKeyCandidates(override.trim()));
  }

  const configured = configuredHostKeys(sshdConfigs);
  if (configured.length > 0) {
    for (const hostKeyPath of configured) {
      const found = readFirstPublicKey(publicKeyCandidates(hostKeyPath));
      if (found !== null) {
        return found;
      }
    }
    return null;
  }

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
