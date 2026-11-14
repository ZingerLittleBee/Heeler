// What the Helper keeps for Usage reads. A user service does not start with the
// core's environment, so it reads the named variables from the core process at
// the pid `server.status` reported, on every connection (ADR 0033). It never logs
// a value.

import { noteAgentDirectory } from "../shared/usage/agent-directories.js";
import { readProcessEnvironment } from "../shared/usage/process-environment.js";
import { ACCOUNT_PROGRAMS } from "../shared/usage/programs.js";
import { ENVIRONMENT_NAMES, writeUsageRuntime } from "../shared/usage/runtime-record.js";
import { accountAgentOf } from "./account-agent.js";
import { helperStateDirectory, sessionRuntimeDirectory, tmuxRuntimeDirectory } from "./layout.js";
import { readTmuxGlobalEnvironment } from "./tmux-environment.js";

const READ_TIME_LIMIT_MS = 3000;
// What can put an Agent in a Terminal the inventory already holds.
const AGENT_EVENTS = new Set(["created", "restarted", "foreground", "status"]);

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

  // One at a time, since each note rewrites the file the last one wrote.
  let notes = Promise.resolve();
  const noteAgent = (session, address, record) => {
    const agent = accountAgentOf(record);
    if (agent === null) return;
    const { program, pid } = agent;
    notes = notes
      .then(() => noteAgentDirectory({
        stateDir: helperStateDirectory(directory),
        session,
        // A new process in the same Terminal is a new Agent to look at.
        paneId: `${address}:${pid}`,
        program,
        pidOf: async () => pid,
      }))
      .catch(() => say(session, `could not note the ${program} directory of ${JSON.stringify(address)}`));
  };
  const noteAgents = (session, inventory) => {
    for (const [address, record] of inventory) noteAgent(session, address, record);
  };

  return {
    connected({ session, pid, inventory }) {
      currentPid.set(session, pid);
      recordRuntime(session, pid).catch(() => say(session, `could not save the Usage environment of core pid ${pid}`));
      noteAgents(session, inventory);
    },
    inventoryReplaced({ session, inventory }) {
      noteAgents(session, inventory);
    },
    event({ session, event, inventory }) {
      if (AGENT_EVENTS.has(event.type)) noteAgent(session, event.terminal, inventory.get(event.terminal));
    },
  };
}

/** A listener for `followTmuxServer`, recording under `tmux/<socket>/` (ADR 0046). */
export function tmuxUsageListener({ directory, log = () => {} }) {
  const currentInstance = new Map();
  const notedBySocket = new Map();
  const say = (socket, line) => log(`tmux socket ${JSON.stringify(socket)}: ${line}`);

  const recordRuntime = async (socket, instance, serverPid, paths) => {
    const environment = await readTmuxGlobalEnvironment(paths);
    if (currentInstance.get(socket) !== instance) return;
    if (typeof environment?.HOME !== "string") {
      say(socket, `cannot read the environment of tmux server pid ${serverPid}, so Usage keeps its last record`);
      return;
    }
    writeUsageRuntime(environment, {
      configDir: tmuxRuntimeDirectory(directory, socket),
      stateDir: helperStateDirectory(directory),
      node: process.execPath,
      herdr: null,
    });
    say(socket, `recorded the Usage environment of tmux server pid ${serverPid}`);
  };

  let notes = Promise.resolve();
  const notePanes = (socket, instance, panes) => {
    let seen = notedBySocket.get(socket);
    if (!seen || seen.instance !== instance) {
      seen = { instance, keys: new Set() };
      notedBySocket.set(socket, seen);
    }
    for (const pane of panes) {
      if (pane.isDead) continue;
      const program = pane.agentKind;
      if (!ACCOUNT_PROGRAMS.includes(program)) continue;
      const pid = pane.foregroundPid ?? pane.panePid;
      if (!Number.isSafeInteger(pid) || pid <= 0) continue;
      const key = `${pane.paneID}:${pid}:${program}`;
      if (seen.keys.has(key)) continue;
      seen.keys.add(key);
      notes = notes
        .then(() =>
          noteAgentDirectory({
            stateDir: helperStateDirectory(directory),
            session: `tmux/${socket}`,
            paneId: `${instance}:${pane.paneID}:${pid}`,
            program,
            pidOf: async () => pid,
          }),
        )
        .catch(() => say(socket, `could not note the ${program} directory of ${JSON.stringify(pane.paneID)}`));
    }
  };

  return {
    serverStarted({ socket, instance, serverPid, paths, panes }) {
      currentInstance.set(socket, instance);
      notedBySocket.set(socket, { instance, keys: new Set() });
      recordRuntime(socket, instance, serverPid, paths).catch(() =>
        say(socket, `could not save the Usage environment of tmux server pid ${serverPid}`),
      );
      notePanes(socket, instance, panes);
    },
    serverEnded({ socket, instance }) {
      if (currentInstance.get(socket) === instance) currentInstance.delete(socket);
      if (notedBySocket.get(socket)?.instance === instance) notedBySocket.delete(socket);
    },
    panesUpdated({ socket, instance, panes }) {
      notePanes(socket, instance, panes);
    },
  };
}
