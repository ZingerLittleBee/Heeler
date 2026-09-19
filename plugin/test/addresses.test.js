import { test, suite } from "node:test";
import assert from "node:assert/strict";

import {
  candidateAddresses,
  parseCustomAddress,
  validateCustomAddress,
  MAX_CUSTOM_ADDRESS_LENGTH,
} from "../src/addresses.js";

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

  test("pre-checks only en0's likely address on macOS, listed first", () => {
    const candidates = candidateAddresses(
      {
        en1: [iface("10.0.0.7", "IPv4")],
        en0: [iface("192.168.1.42", "IPv4"), iface("2001:db8::7", "IPv6")],
        utun3: [iface("100.101.102.103", "IPv4"), iface("fd7a:115c:a1e0::1", "IPv6")],
        en2: [iface("203.0.113.9", "IPv4")],
      },
      "darwin",
    );
    const byAddress = Object.fromEntries(candidates.map((c) => [c.address, c.preChecked]));
    assert.deepEqual(byAddress, {
      "192.168.1.42": true,
      "10.0.0.7": false,
      "100.101.102.103": false,
      "fd7a:115c:a1e0::1": false,
      "2001:db8::7": false,
      "203.0.113.9": false,
    });
    assert.equal(candidates[0].address, "192.168.1.42");
  });

  test("pre-checks only eth0's likely address on Linux", () => {
    const candidates = candidateAddresses(
      {
        wlan0: [iface("192.168.0.5", "IPv4")],
        eth0: [iface("10.1.2.3", "IPv4")],
      },
      "linux",
    );
    const byAddress = Object.fromEntries(candidates.map((c) => [c.address, c.preChecked]));
    assert.deepEqual(byAddress, { "10.1.2.3": true, "192.168.0.5": false });
  });

  test("falls back to the best-ranked likely candidate when the primary interface is absent", () => {
    const candidates = candidateAddresses(
      {
        utun3: [iface("fd7a:115c:a1e0::1", "IPv6")],
        en5: [iface("192.168.1.42", "IPv4")],
      },
      "darwin",
    );
    const byAddress = Object.fromEntries(candidates.map((c) => [c.address, c.preChecked]));
    assert.deepEqual(byAddress, {
      "192.168.1.42": true,
      "fd7a:115c:a1e0::1": false,
    });
  });

  test("never pre-checks a public address, even on the primary interface", () => {
    const candidates = candidateAddresses(
      {
        en0: [iface("203.0.113.9", "IPv4")],
        en1: [iface("192.168.1.42", "IPv4")],
      },
      "darwin",
    );
    const byAddress = Object.fromEntries(candidates.map((c) => [c.address, c.preChecked]));
    assert.deepEqual(byAddress, {
      "192.168.1.42": true,
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

  test("orders the pre-checked default first, then likely IPv4/IPv6, then the rest", () => {
    const candidates = candidateAddresses(
      {
        en0: [iface("2001:db8::7", "IPv6"), iface("203.0.113.9", "IPv4")],
        utun3: [iface("fd7a:115c:a1e0::1", "IPv6"), iface("100.101.102.103", "IPv4")],
        en1: [iface("192.168.1.42", "IPv4")],
      },
      "linux",
    );
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

suite("parseCustomAddress", () => {
  test("classifies hostnames, IPv4, and IPv6 lexically", () => {
    assert.deepEqual(parseCustomAddress("login.example.ts.net"), {
      address: "login.example.ts.net",
      family: "hostname",
    });
    assert.deepEqual(parseCustomAddress("10.8.4.18"), { address: "10.8.4.18", family: "IPv4" });
    assert.deepEqual(parseCustomAddress("fd7a:115c:a1e0::1"), {
      address: "fd7a:115c:a1e0::1",
      family: "IPv6",
    });
  });

  test("trims surrounding whitespace and IPv6 brackets", () => {
    assert.deepEqual(parseCustomAddress("  host.example.com "), {
      address: "host.example.com",
      family: "hostname",
    });
    assert.deepEqual(parseCustomAddress("[fd7a:115c:a1e0::1]"), {
      address: "fd7a:115c:a1e0::1",
      family: "IPv6",
    });
  });

  test("rejects empty, whitespace, non-strings, and oversized input", () => {
    assert.ok(parseCustomAddress("").error);
    assert.ok(parseCustomAddress("   ").error);
    assert.ok(parseCustomAddress("host name").error);
    assert.ok(parseCustomAddress(null).error);
    assert.ok(parseCustomAddress(42).error);
    assert.ok(parseCustomAddress("a".repeat(MAX_CUSTOM_ADDRESS_LENGTH + 1)).error);
  });
});

suite("validateCustomAddress", () => {
  const candidates = [
    { address: "192.168.1.42", family: "IPv4", interfaceName: "en0", preChecked: true },
    { address: "FD7A:115c:A1E0::1", family: "IPv6", interfaceName: "utun3", preChecked: false },
  ];

  test("accepts a name not in the list", () => {
    assert.deepEqual(validateCustomAddress(candidates, "login.example.ts.net"), {
      address: "login.example.ts.net",
      family: "hostname",
    });
  });

  test("rejects duplicates case-insensitively", () => {
    assert.match(validateCustomAddress(candidates, "192.168.1.42").error, /already in the list/i);
    assert.match(
      validateCustomAddress(candidates, "fd7a:115c:a1e0::1").error,
      /already in the list/i,
    );
  });

  test("rejects invalid input with the parse error", () => {
    assert.match(validateCustomAddress(candidates, "two words").error, /whitespace/i);
    assert.match(validateCustomAddress(candidates, "").error, /empty/i);
  });
});

suite("candidateAddresses with custom entries", () => {
  test("lists custom addresses first, pre-checked, in input order", () => {
    const candidates = candidateAddresses(
      { en0: [iface("192.168.1.42", "IPv4")] },
      "darwin",
      ["slurm-login.example.ts.net", "10.8.4.18"],
    );
    assert.deepEqual(candidates, [
      {
        address: "slurm-login.example.ts.net",
        family: "hostname",
        interfaceName: "custom",
        preChecked: true,
      },
      { address: "10.8.4.18", family: "IPv4", interfaceName: "custom", preChecked: true },
      { address: "192.168.1.42", family: "IPv4", interfaceName: "en0", preChecked: true },
    ]);
  });

  test("drops custom entries that duplicate an interface address or each other", () => {
    const candidates = candidateAddresses(
      { en0: [iface("192.168.1.42", "IPv4")] },
      "darwin",
      ["192.168.1.42", "host.example.com", "HOST.EXAMPLE.COM", "10.8.4.18"],
    );
    assert.deepEqual(
      candidates.map((c) => c.address),
      ["host.example.com", "10.8.4.18", "192.168.1.42"],
    );
  });

  test("drops invalid custom entries without touching interface discovery", () => {
    const candidates = candidateAddresses(
      { en0: [iface("192.168.1.42", "IPv4")] },
      "darwin",
      ["", "two words", 7, null, "host.example.com"],
    );
    assert.deepEqual(
      candidates.map((c) => c.address),
      ["host.example.com", "192.168.1.42"],
    );
  });

  test("supplies a hostname candidate when no interface is routable", () => {
    const candidates = candidateAddresses(
      { lo0: [iface("127.0.0.1", "IPv4", true)] },
      "darwin",
      ["login.example.ts.net"],
    );
    assert.deepEqual(candidates, [
      {
        address: "login.example.ts.net",
        family: "hostname",
        interfaceName: "custom",
        preChecked: true,
      },
    ]);
  });

  test("unchanged default behavior when no custom addresses are given", () => {
    const plain = candidateAddresses({ en0: [iface("192.168.1.42", "IPv4")] }, "darwin");
    const withEmpty = candidateAddresses({ en0: [iface("192.168.1.42", "IPv4")] }, "darwin", []);
    assert.deepEqual(withEmpty, plain);
  });
});
