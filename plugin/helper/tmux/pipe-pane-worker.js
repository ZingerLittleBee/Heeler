// Runs under `tmux pipe-pane -O -t <pane>` for one Codex, Grok Build or
// OpenCode Pane (ADR 0044). Reads raw Pane output from stdin, writes OSC 7501
// status changes to `@heeler-status` continuing the Pane's counts, and clears
// its own `@heeler-pipe` mark when the pipe closes while leaving `@heeler-piped`
// on the Pane until the foreground program changes.

import { runStoredTmux } from "./client.js";
import { createOsc7501Parser } from "./osc7501.js";
import { continueHeelerStatus } from "./status.js";

function parseConfig(encoded) {
  try {
    const raw = JSON.parse(Buffer.from(encoded ?? "", "base64url").toString("utf8"));
    if (
      typeof raw?.tmux !== "string" ||
      typeof raw?.socket !== "string" ||
      !/^\d+$/.test(String(raw?.serverPid ?? "")) ||
      !/^%\d+$/.test(raw?.pane ?? "") ||
      typeof raw?.mark !== "string" ||
      raw.mark === ""
    ) {
      return null;
    }
    return {
      target: { tmux: raw.tmux, socket: raw.socket },
      serverPid: String(raw.serverPid),
      pane: raw.pane,
      mark: raw.mark,
    };
  } catch {
    return null;
  }
}

const config = parseConfig(process.argv[2]);
if (!config) process.exit(1);

let writes = Promise.resolve();
let closing = false;

function writeReport(report) {
  writes = writes
    .then(async () => {
      const read = await runStoredTmux(config.target, [
        "display-message",
        "-p",
        "-t",
        config.pane,
        "#{pid}\t#{@heeler-pipe}\t#{@heeler-status}",
      ]);
      if (!read.ok) return;
      const [pid = "", pipeMark = "", status = ""] = read.stdout.replace(/\n$/, "").split("\t");
      if (pid !== config.serverPid || pipeMark !== config.mark) return;
      const next = continueHeelerStatus(status, report);
      if (next === status) return;
      await runStoredTmux(config.target, ["set-option", "-p", "-t", config.pane, "@heeler-status", next]);
    })
    .catch(() => {});
}

function clearOwnMarkAndExit() {
  if (closing) return;
  closing = true;
  writes = writes
    .then(async () => {
      const read = await runStoredTmux(config.target, [
        "display-message",
        "-p",
        "-t",
        config.pane,
        "#{pid}\t#{@heeler-pipe}",
      ]);
      if (!read.ok) return;
      const [pid = "", pipeMark = ""] = read.stdout.replace(/\n$/, "").split("\t");
      if (pid !== config.serverPid || pipeMark !== config.mark) return;
      await runStoredTmux(config.target, ["set-option", "-p", "-u", "-t", config.pane, "@heeler-pipe"]);
    })
    .catch(() => {})
    .finally(() => {
      process.exit(0);
    });
}

const parser = createOsc7501Parser(writeReport);
process.stdin.on("data", (chunk) => parser.feed(chunk));
process.stdin.on("end", clearOwnMarkAndExit);
process.stdin.on("error", clearOwnMarkAndExit);
for (const signal of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(signal, clearOwnMarkAndExit);
}
