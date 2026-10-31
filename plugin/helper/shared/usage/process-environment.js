// Reads named variables from a running process's initial environment. Nothing
// else of that environment is kept, and `/bin/ps` is the only program it runs.

import { execFile } from "node:child_process";
import { readFileSync } from "node:fs";

const ps = (flags, pid, deadline) => new Promise((resolve) => execFile("/bin/ps", [...flags, "-o", "command=", "-p", String(pid)], {
  timeout: Math.max(1, deadline - Date.now()), killSignal: "SIGKILL", maxBuffer: 1 << 20, encoding: "utf8",
}, (error, stdout) => resolve(error ? null : stdout.replace(/\n$/, ""))));

const escapedName = (name) => name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * `names`' values from process `pid`'s initial environment, leaving out those it
 * does not set. Null when it is unreadable: macOS shows no environment for Apple
 * platform binaries, Linux none for a process that is not dumpable.
 */
export async function readProcessEnvironment(pid, names, deadline) {
  if (process.platform === "linux") {
    let environment;
    try { environment = readFileSync(`/proc/${pid}/environ`, "utf8"); } catch { return null; }
    const entries = environment.split("\0");
    const values = {};
    for (const name of names) {
      const entry = entries.find((candidate) => candidate.startsWith(`${name}=`));
      if (entry !== undefined) values[name] = entry.slice(name.length + 1);
    }
    return values;
  }
  // `ps -E` appends the environment to the arguments, each `NAME=value`
  // after a space; the plain command tells where the arguments end.
  const [command, withEnvironment] = await Promise.all([["-ww"], ["-E", "-ww"]].map((flags) => ps(flags, pid, deadline)));
  if (command === null || withEnvironment === null || !withEnvironment.startsWith(command)) return null;
  const text = withEnvironment.slice(command.length);
  const values = {};
  for (const name of names) {
    // A value runs until the next ` NAME=` or the end. A name is anything up to
    // `=`: bash exports a function as `BASH_FUNC_name%%=`.
    const found = [...text.matchAll(new RegExp(` ${escapedName(name)}=(.*?)(?= [^\\s=]+=|$)`, "g"))];
    // Another value that names the variable leaves no telling which is real.
    if (found.length === 1) values[name] = found[0][1];
  }
  return values;
}
