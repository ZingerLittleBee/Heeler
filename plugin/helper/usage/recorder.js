// What the Helper keeps for Usage reads. A user service does not start with the
// core's environment, so it reads the named variables from the core process at
// the pid `server.status` reported, on every connection (ADR 0033). It never logs
// a value.

import { readProcessEnvironment } from "../shared/usage/process-environment.js";
import { ENVIRONMENT_NAMES, writeUsageRuntime } from "../shared/usage/runtime-record.js";
import { helperStateDirectory, sessionRuntimeDirectory } from "./layout.js";

const READ_TIME_LIMIT_MS = 3000;

/** A listener for `followCoreSession`, recording under the Helper's `directory`. */
export function usageListener({ directory, log = () => {} }) {
  const currentPid = new Map();
  const say = (session, line) => log(`core session ${JSON.stringify(session)}: ${line}`);

  const recordRuntime = async (session, pid) => {
    const environment = await readProcessEnvironment(pid, ENVIRONMENT_NAMES, Date.now() + READ_TIME_LIMIT_MS);
    // A newer connection's read decides.
    if (currentPid.get(session) !== pid) return;
    if (typeof environment?.HOME !== "string") {
      say(session, `cannot read the environment of core pid ${pid}, so Usage keeps its last record`);
      return;
    }
    writeUsageRuntime(environment, {
      configDir: sessionRuntimeDirectory(directory, session),
      stateDir: helperStateDirectory(directory),
      node: process.execPath,
      herdr: null,
    });
    say(session, `recorded the Usage environment of core pid ${pid}`);
  };

  return {
    connected({ session, pid }) {
      currentPid.set(session, pid);
      recordRuntime(session, pid).catch(() => say(session, `could not save the Usage environment of core pid ${pid}`));
    },
  };
}
