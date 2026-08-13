// Candidate address enumeration for the Pairing Code (ADR 0007).
//
// The Pairing Code carries user-selected candidate addresses; this module
// enumerates the routable ones and pre-checks exactly one default: the likely
// candidate (private LAN, Tailscale CGNAT, ULA) on the platform's primary
// interface (en0 on macOS, eth0 on Linux), falling back to the best-ranked
// likely candidate when that interface is absent -- modern Linux often names
// interfaces enp3s0-style, so eth0 is a preference, not an assumption.

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

const PRIMARY_INTERFACE_BY_PLATFORM = { darwin: "en0", linux: "eth0" };

/**
 * Enumerate routable candidate addresses for the Pairing Code.
 *
 * Skips loopback and link-local addresses. Exactly one candidate is
 * pre-checked: the likely one (private IPv4, CGNAT IPv4, ULA IPv6) on the
 * platform's primary interface, else the best-ranked likely one. Ordered
 * pre-checked first, then likely before unlikely, IPv4 before IPv6 within
 * each group, otherwise input order.
 *
 * @param {ReturnType<typeof os.networkInterfaces>} [interfaces]
 * @param {NodeJS.Platform} [platform]
 * @returns {{address: string, family: "IPv4"|"IPv6", interfaceName: string, preChecked: boolean}[]}
 */
export function candidateAddresses(
  interfaces = os.networkInterfaces(),
  platform = process.platform,
) {
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
