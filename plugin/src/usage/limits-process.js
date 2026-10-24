import { spawn } from "node:child_process";

const failed = reason => ({ state: "error", reason });
const missing = () => ({ state: "unavailable", reason: "programMissing" });
const exited = code => code === 126 || code === 127 ? missing() : failed("requestFailed");

/** Own one Unix program group and its bounded NDJSON exchange until the child is reaped. */
export function runLimitsRequest({ executable, args, env, directory }, protocol) {
  return new Promise(resolve => {
    const child = spawn(executable, args, {
      cwd: directory, env: Object.fromEntries(Object.entries(env).filter(([, value]) => typeof value === "string")),
      stdio: ["pipe", "pipe", "pipe"], detached: true,
    });
    let result;
    let buffer = "";
    let bytes = 0;
    let terminated = false;
    const terminateGroup = () => {
      if (terminated) return;
      terminated = true;
      // npm launchers pass their pipes to the native program. Killing only the
      // launcher leaves that program running and prevents the close event.
      if (child.pid) {
        try { process.kill(-child.pid, "SIGKILL"); }
        catch { child.kill("SIGKILL"); }
      }
    };
    const finish = value => {
      if (result) return;
      result = value;
      terminateGroup();
      // Stream closure must not depend on a descendant releasing inherited fds.
      child.stdin.destroy();
      child.stdout.destroy();
      child.stderr.destroy();
    };
    const timer = setTimeout(() => finish(failed("timeout")), 15_000);
    const send = message => child.stdin.write(JSON.stringify(message) + "\n");
    child.stdin.on("error", () => { /* Exit/error closes the request below. */ });
    child.stdout.on("error", () => finish(failed("requestFailed")));
    child.stderr.on("error", () => finish(failed("requestFailed")));
    child.stderr.resume();
    child.on("error", error => finish(error.code === "ENOENT" || error.code === "EACCES"
      ? missing() : failed("requestFailed")));
    // Reap an exited launcher's descendants, but still drain its final stdout.
    // The deadline remains active until close, including after an early exit.
    child.on("exit", terminateGroup);
    child.on("close", code => {
      clearTimeout(timer);
      resolve(result || exited(code));
    });
    const onMessage = protocol({ send, finish });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => {
      if (result) return;
      bytes += Buffer.byteLength(chunk);
      if (bytes > 1024 * 1024) { finish(failed("invalidResponse")); return; }
      buffer += chunk;
      let end;
      while (!result && (end = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        let message;
        try { message = JSON.parse(line); } catch { finish(failed("invalidResponse")); break; }
        onMessage(message);
      }
    });
  });
}
