import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { rmSync, writeFileSync } from "node:fs";
import { basename, isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";

import { AGY_READING, AGY_REQUEST, agyAtOrBefore, keychainUsable } from "../shared/usage/agy-limits.js";
import { readJSON, writeJSON } from "../shared/usage/cache.js";
import { failed } from "../shared/usage/claude-limits.js";
import { agyExecutable } from "../shared/usage/runtime-record.js";

const READER = fileURLToPath(new URL("../usage-agy-reader.js", import.meta.url));
const JOB_PLIST = "agy-reader.plist";
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

const xml = value => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");

function jobPlist(label, programArguments) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${xml(label)}</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>ProgramArguments</key>
  <array>${programArguments.map(value => `<string>${xml(value)}</string>`).join("")}</array>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
`;
}

function launchctl(args) {
  return new Promise(resolve => execFile("/bin/launchctl", args, {
    timeout: 5_000, killSignal: "SIGKILL", maxBuffer: 64 * 1024,
  }, error => resolve(!error)));
}

export async function readAgyLimitsInDesktop(runtime, directory, version, { configDirectory, wait = () => sleep(100) }) {
  if (typeof configDirectory !== "string" || !isAbsolute(configDirectory) || !isAbsolute(runtime.node)
      || !agyExecutable(runtime) || !Array.isArray(version) || agyAtOrBefore(version)) return null;
  const uid = process.getuid?.();
  if (!Number.isInteger(uid) || await keychainUsable(runtime, directory)) return null;
  const domain = `gui/${uid}`;
  const label = `dev.bybee.heeler.usage-agy.${basename(directory)}`;
  const service = `${domain}/${label}`;
  const plist = join(directory, JOB_PLIST);
  const request = join(directory, AGY_REQUEST);
  const token = randomUUID();
  writeJSON(request, { token, version });
  writeFileSync(plist, jobPlist(label, [runtime.node, READER, "--config", configDirectory]), { mode: 0o600 });
  try {
    await launchctl(["bootout", service]);
    if (!await launchctl(["bootstrap", domain, plist])) return null;
    for (let attempt = 0; attempt < 250; attempt++) {
      const answer = readJSON(join(directory, AGY_READING));
      if (answer?.token === token && typeof answer.reading?.state === "string") return answer.reading;
      await wait();
    }
    return failed("timeout");
  } finally {
    await launchctl(["bootout", service]);
    rmSync(plist, { force: true });
    rmSync(request, { force: true });
  }
}
