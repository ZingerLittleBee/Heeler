import { test, suite } from "node:test";
import assert from "node:assert/strict";

import { candidateAddresses } from "../src/addresses.js";

function iface(address, family, internal = false) {
  return { address, family, internal };
}

suite("candidateAddresses", () => {
  test("skips loopback and link-local, keeps routable addresses", () => {
    const candidates = candidateAddresses({
      lo0: [iface("127.0.0.1", "IPv4", true), iface("::1", "IPv6", true)],
      en0: [
        iface("192.168.1.42", "IPv4"),
        iface("169.254.10.20", "IPv4"),
        iface("fe80::1c2d:3e4f:5a6b:7c8d", "IPv6"),
        iface("2001:db8:85a3::8a2e:370:7334", "IPv6"),
      ],
    });
    assert.deepEqual(
      candidates.map((c) => c.address),
      ["192.168.1.42", "2001:db8:85a3::8a2e:370:7334"],
    );
  });

  test("pre-checks private LAN, Tailscale CGNAT, and ULA addresses", () => {
    const candidates = candidateAddresses({
      en0: [iface("192.168.1.42", "IPv4"), iface("2001:db8::7", "IPv6")],
      en1: [iface("10.0.0.7", "IPv4"), iface("172.20.0.3", "IPv4")],
      utun3: [iface("100.101.102.103", "IPv4"), iface("fd7a:115c:a1e0::1", "IPv6")],
      en2: [iface("203.0.113.9", "IPv4")],
    });
    const byAddress = Object.fromEntries(candidates.map((c) => [c.address, c.preChecked]));
    assert.deepEqual(byAddress, {
      "192.168.1.42": true,
      "10.0.0.7": true,
      "172.20.0.3": true,
      "100.101.102.103": true,
      "fd7a:115c:a1e0::1": true,
      "2001:db8::7": false,
      "203.0.113.9": false,
    });
  });

  test("does not pre-check IPv4 outside private/CGNAT ranges", () => {
    const candidates = candidateAddresses({
      en0: [
        iface("172.15.0.1", "IPv4"),
        iface("172.32.0.1", "IPv4"),
        iface("100.63.255.255", "IPv4"),
        iface("100.128.0.1", "IPv4"),
      ],
    });
    assert.deepEqual(
      candidates.map((c) => c.preChecked),
      [false, false, false, false],
    );
  });

  test("orders pre-checked first, IPv4 before IPv6 within each group", () => {
    const candidates = candidateAddresses({
      en0: [iface("2001:db8::7", "IPv6"), iface("203.0.113.9", "IPv4")],
      utun3: [iface("fd7a:115c:a1e0::1", "IPv6"), iface("100.101.102.103", "IPv4")],
      en1: [iface("192.168.1.42", "IPv4")],
    });
    assert.deepEqual(
      candidates.map((c) => c.address),
      [
        "100.101.102.103",
        "192.168.1.42",
        "fd7a:115c:a1e0::1",
        "203.0.113.9",
        "2001:db8::7",
      ],
    );
  });

  test("strips IPv6 zone ids and deduplicates repeated addresses", () => {
    const candidates = candidateAddresses({
      utun0: [iface("fd7a:115c:a1e0::1%utun0", "IPv6")],
      utun1: [iface("fd7a:115c:a1e0::1", "IPv6")],
    });
    assert.deepEqual(candidates.map((c) => c.address), ["fd7a:115c:a1e0::1"]);
  });

  test("reports the owning interface name", () => {
    const candidates = candidateAddresses({
      en0: [iface("192.168.1.42", "IPv4")],
    });
    assert.deepEqual(candidates, [
      { address: "192.168.1.42", family: "IPv4", interfaceName: "en0", preChecked: true },
    ]);
  });

  test("returns an empty list when nothing is routable", () => {
    assert.deepEqual(candidateAddresses({ lo0: [iface("127.0.0.1", "IPv4", true)] }), []);
  });
});
