// Candidate address enumeration for the Pairing Code (ADR 0007).
//
// The Pairing Code carries user-selected candidate addresses; this module
// enumerates the routable ones and marks the likely candidates (private LAN,
// Tailscale CGNAT, ULA) as pre-checked so the common case is one confirmation.

import os from "node:os";

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

/**
 * Enumerate routable candidate addresses for the Pairing Code.
 *
 * Skips loopback and link-local addresses; marks likely candidates
 * (private IPv4, CGNAT IPv4, ULA IPv6) as pre-checked. Ordered pre-checked
 * first, IPv4 before IPv6 within each group, otherwise input order.
 *
 * @param {ReturnType<typeof os.networkInterfaces>} [interfaces]
 * @returns {{address: string, family: "IPv4"|"IPv6", interfaceName: string, preChecked: boolean}[]}
 */
export function candidateAddresses(interfaces = os.networkInterfaces()) {
  const seen = new Set();
  const candidates = [];

  for (const [interfaceName, entries] of Object.entries(interfaces)) {
    for (const entry of entries ?? []) {
      if (entry.internal) continue;
      const { family } = entry;
      // Zone ids (fe80::1%en0) are meaningless off-machine.
      const address = entry.address.split("%")[0];
      if (seen.has(address)) continue;

      let preChecked;
      if (family === "IPv4") {
        if (isIpv4LinkLocal(address)) continue;
        preChecked = isIpv4Likely(address);
      } else if (family === "IPv6") {
        if (isIpv6LinkLocal(address)) continue;
        preChecked = isIpv6Likely(address);
      } else {
        continue;
      }

      seen.add(address);
      candidates.push({ address, family, interfaceName, preChecked });
    }
  }

  const rank = (c) => (c.preChecked ? 0 : 2) + (c.family === "IPv4" ? 0 : 1);
  return candidates
    .map((candidate, index) => ({ candidate, index }))
    .sort((a, b) => rank(a.candidate) - rank(b.candidate) || a.index - b.index)
    .map(({ candidate }) => candidate);
}
