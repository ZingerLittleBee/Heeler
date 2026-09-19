// Candidate address enumeration for the Pairing Code (ADR 0007).
//
// The Pairing Code carries user-selected candidate addresses; this module
// enumerates the routable ones and pre-checks exactly one default: the likely
// candidate (private LAN, Tailscale CGNAT, ULA) on the platform's primary
// interface (en0 on macOS, eth0 on Linux), falling back to the best-ranked
// likely candidate when that interface is absent -- modern Linux often names
// interfaces enp3s0-style, so eth0 is a preference, not an assumption.
//
// Custom addresses extend the list for clients that must connect through a
// DNS name no local interface carries -- Tailscale MagicDNS, split-DNS, or
// ordinary hostnames. They persist in pairing.json inside the plugin config
// directory (see pairing-config.js) and can be added interactively in the
// popup; they lead the list, pre-checked, in configured order.

import os from "node:os";

// Longest legal DNS name (RFC 1035); IPv6 literals are far shorter, so one
// bound covers every form and keeps a stray paste from bloating the QR.
export const MAX_CUSTOM_ADDRESS_LENGTH = 253;

const IPV4_PATTERN = /^(?:\d{1,3}\.){3}\d{1,3}$/;

/**
 * Sanitize and validate one custom pairing address: a DNS name or IP literal.
 *
 * The same rules the pairing envelope enforces (non-empty, no whitespace)
 * plus a length bound. Surrounding whitespace and URL-style `[...]` IPv6
 * brackets are trimmed. Family is detected lexically: a colon means IPv6, a
 * dotted quad means IPv4, anything else is a hostname -- no DNS resolution,
 * so a name that only resolves inside the tailnet is still accepted.
 *
 * @param {unknown} input
 * @returns {{address: string, family: "IPv4"|"IPv6"|"hostname"}|{error: string}}
 */
export function parseCustomAddress(input) {
  if (typeof input !== "string") {
    return { error: "Address must be text." };
  }
  const address = input.trim().replace(/^\[(.*)\]$/, "$1");
  if (address.length === 0) {
    return { error: "Address must not be empty." };
  }
  if (/\s/.test(address)) {
    return { error: "Address must not contain whitespace." };
  }
  if (address.length > MAX_CUSTOM_ADDRESS_LENGTH) {
    return {
      error: `Address must be at most ${MAX_CUSTOM_ADDRESS_LENGTH} characters.`,
    };
  }
  const family = address.includes(":")
    ? "IPv6"
    : IPV4_PATTERN.test(address)
      ? "IPv4"
      : "hostname";
  return { address, family };
}

/**
 * Validate a custom address against the current candidate list: the parse
 * rules plus deduplication. Hostnames and IPv6 literals are case-insensitive,
 * matching how clients resolve them.
 *
 * @param {{address: string}[]} candidates
 * @param {unknown} input
 * @returns {{address: string, family: "IPv4"|"IPv6"|"hostname"}|{error: string}}
 */
export function validateCustomAddress(candidates, input) {
  const parsed = parseCustomAddress(input);
  if (parsed.error) {
    return parsed;
  }
  const key = parsed.address.toLowerCase();
  if (candidates.some((candidate) => candidate.address.toLowerCase() === key)) {
    return { error: "Already in the list." };
  }
  return parsed;
}

function ipv4Octets(address) {
  return address.split(".").map(Number);
}

function isIpv4LinkLocal(address) {
  const [a, b] = ipv4Octets(address);
  return a === 169 && b === 254;
}

function isIpv4Likely(address) {
  const [a, b] = ipv4Octets(address);
  if (a === 10) return true; // 10/8 private
  if (a === 172 && b >= 16 && b <= 31) return true; // 172.16/12 private
  if (a === 192 && b === 168) return true; // 192.168/16 private
  if (a === 100 && b >= 64 && b <= 127) return true; // 100.64/10 CGNAT (Tailscale)
  return false;
}

function isIpv6LinkLocal(address) {
  return /^fe[89ab]/i.test(address); // fe80::/10
}

function isIpv6Likely(address) {
  return /^f[cd]/i.test(address); // fc00::/7 ULA (includes Tailscale fd7a:...)
}

const PRIMARY_INTERFACE_BY_PLATFORM = { darwin: "en0", linux: "eth0" };

function interfaceCandidates(interfaces, platform) {
  const seen = new Set();
  const candidates = [];

  for (const [interfaceName, entries] of Object.entries(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.internal) continue;
      const { family } = entry;
      // Zone ids (fe80::1%en0) are meaningless off-machine.
      const address = entry.address.split("%")[0];
      if (seen.has(address)) continue;

      let likely;
      if (family === "IPv4") {
        if (isIpv4LinkLocal(address)) continue;
        likely = isIpv4Likely(address);
      } else if (family === "IPv6") {
        if (isIpv6LinkLocal(address)) continue;
        likely = isIpv6Likely(address);
      } else {
        continue;
      }

      seen.add(address);
      candidates.push({ address, family, interfaceName, likely });
    }
  }

  const likelyRank = (c) => (c.likely ? 0 : 2) + (c.family === "IPv4" ? 0 : 1);
  const ordered = candidates
    .map((candidate, index) => ({ candidate, index }))
    .sort((a, b) => likelyRank(a.candidate) - likelyRank(b.candidate) || a.index - b.index)
    .map(({ candidate }) => candidate);

  const primary = PRIMARY_INTERFACE_BY_PLATFORM[platform];
  const defaultCandidate =
    ordered.find((c) => c.likely && c.interfaceName === primary) ??
    ordered.find((c) => c.likely);

  return ordered
    .map(({ likely, ...candidate }) => ({
      ...candidate,
      preChecked: defaultCandidate !== undefined &&
        candidate.address === defaultCandidate.address,
    }))
    .sort((a, b) => Number(b.preChecked) - Number(a.preChecked));
}

/**
 * Enumerate routable candidate addresses for the Pairing Code.
 *
 * Skips loopback and link-local addresses. Exactly one interface candidate is
 * pre-checked: the likely one (private IPv4, CGNAT IPv4, ULA IPv6) on the
 * platform's primary interface, else the best-ranked likely one. Ordered
 * pre-checked first, then likely before unlikely, IPv4 before IPv6 within
 * each group, otherwise input order.
 *
 * Custom addresses, when given, lead the list in input order, each pre-checked
 * (they are deliberate configuration, so the app should try them first) and
 * labeled `interfaceName: "custom"` with a lexical `family`. Invalid entries
 * and duplicates of interface addresses or earlier customs are dropped.
 *
 * @param {ReturnType<typeof os.networkInterfaces>} [interfaces]
 * @param {NodeJS.Platform} [platform]
 * @param {unknown[]} [custom]
 * @returns {{address: string, family: "IPv4"|"IPv6"|"hostname",
 *             interfaceName: string, preChecked: boolean}[]}
 */
export function candidateAddresses(
  interfaces = os.networkInterfaces(),
  platform = process.platform,
  custom = [],
) {
  const candidates = interfaceCandidates(interfaces, platform);
  const seen = new Set(candidates.map((candidate) => candidate.address.toLowerCase()));
  const additions = [];
  for (const entry of custom) {
    const parsed = parseCustomAddress(entry);
    if (parsed.error) continue;
    const key = parsed.address.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    additions.push({
      address: parsed.address,
      family: parsed.family,
      interfaceName: "custom",
      preChecked: true,
    });
  }
  return [...additions, ...candidates];
}
