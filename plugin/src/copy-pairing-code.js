// Clipboard helper for the pairing popup's QR screen (#204).
//
// macOS: write the exact Pairing Code string to the pasteboard via pbcopy.
// Anywhere else, or if pbcopy is missing / fails: the caller prints the code
// so it can be selected by hand. No format change — the v1 envelope is copied
// as-is.

import { spawn } from "node:child_process";

/**
 * What a keypress on the QR screen should do. `c` copies and stays; every
 * other key (including ctrl+c, which the popup's global handler already
 * treats as quit) closes. `key` is a readline keypress object.
 *
 * @param {{name?: string, ctrl?: boolean} | null | undefined} key
 * @returns {"copy" | "close"}
 */
export function qrKeyAction(key) {
  if (key?.name === "c" && !key.ctrl) {
    return "copy";
  }
  return "close";
}

/**
 * Copy `code` to the macOS pasteboard.
 *
 * @param {string} code
 * @param {{spawnFn?: typeof spawn, platform?: string}} [deps]
 * @returns {Promise<{copied: boolean}>}
 */
export function copyPairingCode(code, { spawnFn = spawn, platform = process.platform } = {}) {
  if (typeof code !== "string" || code.length === 0 || platform !== "darwin") {
    return Promise.resolve({ copied: false });
  }
  return new Promise((resolve) => {
    let settled = false;
    const finish = (copied) => {
      if (settled) {
        return;
      }
      settled = true;
      resolve({ copied });
    };
    let child;
    try {
      child = spawnFn("pbcopy", [], { stdio: ["pipe", "ignore", "ignore"] });
    } catch {
      finish(false);
      return;
    }
    child.on("error", () => finish(false));
    child.on("close", (status) => finish(status === 0));
    child.stdin.on("error", () => finish(false));
    child.stdin.end(code);
  });
}
