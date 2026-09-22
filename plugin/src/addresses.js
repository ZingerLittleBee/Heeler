// Candidate address enumeration for the Pairing Code (ADR 0007).
//
// The Pairing Code carries user-selected candidate addresses; this module
// enumerates them and pre-checks at most one default: a likely non-Docker
// candidate (private LAN, Tailscale CGNAT, ULA) on the platform's primary
// interface (en0 on macOS, eth0 on Linux), falling back to the best-ranked
// likely non-Docker candidate when the primary has none. Docker addresses
// remain available for manual selection at the end of the list.

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

// Interface names are only a hint, not proof of reachability. Keep these
// Docker/container addresses available for manual selection, but do not
// pre-check them or let them bury ordinary Host addresses. Generic bridges
// such as bridge0 can carry the Host's LAN address and are not classified.
const DOCKER_INTERFACE_PATTERNS = [
  /^docker\d*$/i, // docker0
  /^br-[0-9a-f]+$/i, // docker user-defined bridges
  /^veth/i, // container veth pairs
];

function isDockerInterface(interfaceName) {
  return DOCKER_INTERFACE_PATTERNS.some((pattern) => pattern.test(interfaceName));
}

/**
 * Enumerate candidate addresses for the Pairing Code.
 *
 * Skips loopback and link-local addresses. Pre-checks at most one likely
 * non-Docker address: prefer the platform's primary interface, then the
 * best-ranked likely candidate. Docker addresses follow all other candidates
 * and are never pre-checked. Within each group, likely addresses precede
 * unlikely ones, then IPv4 precedes IPv6, otherwise input order is preserved.
 *
 * @param {ReturnType<typeof os.networkInterfaces>} [interfaces]
 * @param {NodeJS.Platform} [platform]
 * @returns {{address: string, family: "IPv4"|"IPv6", interfaceName: string, preChecked: boolean}[]}
 */
export function candidateAddresses(
  interfaces = os.networkInterfaces(),
  platform = process.platform,
) {
  const candidates = [];

  for (const [interfaceName, entries] of Object.entries(interfaces)) {
    const docker = isDockerInterface(interfaceName);
    for (const entry of entries ?? []) {
      if (entry.internal) continue;
      const { family } = entry;
      // Zone ids (fe80::1%en0) are meaningless off-machine.
      const address = entry.address.split("%")[0];

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

      candidates.push({ address, family, interfaceName, likely, docker });
    }
  }

  const candidateRank = (c) =>
    (c.docker ? 4 : 0) + (c.likely ? 0 : 2) + (c.family === "IPv4" ? 0 : 1);
  // Sort before deduplicating so a Docker alias cannot hide an ordinary
  // interface carrying the same address. Stable sorting preserves input ties.
  const seen = new Set();
  const ordered = candidates
    .sort((a, b) => candidateRank(a) - candidateRank(b))
    .filter(({ address }) => {
      if (seen.has(address)) return false;
      seen.add(address);
      return true;
    });

  const primary = PRIMARY_INTERFACE_BY_PLATFORM[platform];
  const defaultCandidate =
    ordered.find((c) => !c.docker && c.likely && c.interfaceName === primary) ??
    ordered.find((c) => !c.docker && c.likely);

  return ordered
    .map(({ likely, docker, ...candidate }) => ({
      ...candidate,
      preChecked: defaultCandidate !== undefined &&
        candidate.address === defaultCandidate.address,
    }))
    .sort((a, b) => Number(b.preChecked) - Number(a.preChecked));
}
