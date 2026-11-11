// Runs a command on a tmux server whose executable and socket the app stored
// (ADR 0042). Every invocation carries `-N` and `-S`, so it never starts a
// server (ADR 0044).

import { execFile } from "node:child_process";

const DEFAULT_TIMEOUT_MS = 3000;
const MAX_BUFFER_BYTES = 4 * 1024 * 1024;

export function runStoredTmux(target, args, { timeoutMs = DEFAULT_TIMEOUT_MS, signal, buffer = false } = {}) {
  return new Promise((resolve) => {
    execFile(
      target.tmux,
      ["-N", "-S", target.socket, ...args],
      {
        timeout: timeoutMs,
        killSignal: "SIGKILL",
        maxBuffer: MAX_BUFFER_BYTES,
        encoding: buffer ? "buffer" : "utf8",
        ...(signal ? { signal } : {}),
      },
      (error, stdout, stderr) =>
        resolve(
          error
            ? { ok: false, error, stderr: Buffer.isBuffer(stderr) ? stderr.toString("utf8") : (stderr ?? "") }
            : { ok: true, stdout },
        ),
    );
  });
}
