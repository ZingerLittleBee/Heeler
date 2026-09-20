import { suite, test } from "node:test";
import assert from "node:assert/strict";

import {
  detectTailscaleSSH,
  isTailscaleAddress,
  tailscaleSSHConflict,
} from "../src/tailscale-ssh.js";

function fakeRun(responses) {
  const calls = [];
  const run = (args) => {
    calls.push(args.join(" "));
    return responses[args.join(" ")] ?? null;
  };
  return { run, calls };
}

suite("tailscale addresses", () => {
  test("recognizes the CGNAT range Tailscale assigns from", () => {
    assert.equal(isTailscaleAddress("100.64.0.1"), true);
    assert.equal(isTailscaleAddress("100.127.255.254"), true);
    assert.equal(isTailscaleAddress("100.101.102.103"), true);
  });

  test("leaves neighbouring IPv4 ranges alone", () => {
    assert.equal(isTailscaleAddress("100.63.255.255"), false);
    assert.equal(isTailscaleAddress("100.128.0.1"), false);
    assert.equal(isTailscaleAddress("192.168.1.10"), false);
    assert.equal(isTailscaleAddress("10.0.0.4"), false);
  });

  test("recognizes the Tailscale ULA prefix only", () => {
    assert.equal(isTailscaleAddress("fd7a:115c:a1e0::1"), true);
    assert.equal(isTailscaleAddress("FD7A:115C:A1E0:AB12::4"), true);
    assert.equal(isTailscaleAddress("fd00:1234::1"), false);
    assert.equal(isTailscaleAddress("2001:db8::1"), false);
  });

  test("survives a non-string address", () => {
    assert.equal(isTailscaleAddress(undefined), false);
    assert.equal(isTailscaleAddress(null), false);
  });
});

suite("tailscale SSH detection", () => {
  test("reads this node's own SSH host keys from status", () => {
    const { run, calls } = fakeRun({
      "status --json": JSON.stringify({ Self: { sshHostKeys: ["ssh-ed25519 AAAA"] } }),
    });

    assert.equal(detectTailscaleSSH({ run }), true);
    assert.deepEqual(calls, ["status --json"], "a yes from status needs no second opinion");
  });

  test("falls back to prefs when status does not say", () => {
    const { run, calls } = fakeRun({
      "status --json": JSON.stringify({ Self: { sshHostKeys: [] } }),
      "debug prefs": JSON.stringify({ RunSSH: true }),
    });

    assert.equal(detectTailscaleSSH({ run }), true);
    assert.deepEqual(calls, ["status --json", "debug prefs"]);
  });

  test("reports not enabled when both probes say so", () => {
    const { run } = fakeRun({
      "status --json": JSON.stringify({ Self: { HostName: "host" } }),
      "debug prefs": JSON.stringify({ RunSSH: false }),
    });

    assert.equal(detectTailscaleSSH({ run }), false);
  });

  test("stays quiet when tailscale is absent or unreadable", () => {
    for (const responses of [
      {},
      { "status --json": "not json", "debug prefs": "not json" },
      { "status --json": "null", "debug prefs": "[]" },
      { "status --json": JSON.stringify({ Self: null }) },
    ]) {
      const { run } = fakeRun(responses);
      assert.equal(detectTailscaleSSH({ run }), false);
    }
  });
});

suite("tailscale SSH conflict", () => {
  const enabled = { sshPort: 22, tailscaleSSHEnabled: true };

  test("names the selected addresses tailscaled would answer for", () => {
    const warning = tailscaleSSHConflict({
      ...enabled,
      addresses: ["192.168.1.10", "100.101.102.103", "fd7a:115c:a1e0::2"],
    });

    assert.match(warning, /100\.101\.102\.103/);
    assert.match(warning, /fd7a:115c:a1e0::2/);
    assert.doesNotMatch(warning, /192\.168\.1\.10/);
    assert.match(warning, /ssh_port/);
  });

  test("says nothing once the code advertises another port", () => {
    assert.equal(
      tailscaleSSHConflict({ ...enabled, sshPort: 2222, addresses: ["100.101.102.103"] }),
      null,
    );
  });

  test("says nothing without a tailnet address in the selection", () => {
    assert.equal(
      tailscaleSSHConflict({ ...enabled, addresses: ["192.168.1.10"] }),
      null,
    );
  });

  test("says nothing when Tailscale SSH is not serving", () => {
    assert.equal(
      tailscaleSSHConflict({
        sshPort: 22,
        tailscaleSSHEnabled: false,
        addresses: ["100.101.102.103"],
      }),
      null,
    );
  });

  test("survives an empty or missing selection", () => {
    assert.equal(tailscaleSSHConflict({ ...enabled, addresses: [] }), null);
    assert.equal(tailscaleSSHConflict({ ...enabled, addresses: undefined }), null);
  });
});
