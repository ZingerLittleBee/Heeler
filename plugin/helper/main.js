// The Host Helper's entry point: Heeler's background service on a herdr-core
// or tmux Host (ADRs 0033 and 0046). The user service keeps this process running.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { combineListeners, followRegisteredSessions } from "./core/follower.js";
import { liveActivityListener, tmuxLiveActivityListener } from "./notifications/activity.js";
import { notificationListener, tmuxNotificationListener } from "./notifications/notifier.js";
import { combineTmuxListeners, followStoredTmuxServers } from "./tmux/follower.js";
import { tmuxPipeReaderListener } from "./tmux/pipe-reader.js";
import { tmuxTranscriptListener } from "./tmux/transcript-watcher.js";
import { usageSessions } from "./usage/layout.js";
import { tmuxUsageListener, usageListener } from "./usage/recorder.js";

const { version } = JSON.parse(readFileSync(new URL("./version.json", import.meta.url), "utf8"));

console.log(`Heeler Host Helper ${version} started`);

// This file is in the Helper directory's `app` folder, which an update replaces.
// The registrations sit beside that folder.
const directory = fileURLToPath(new URL("..", import.meta.url));
const log = (line) => console.log(line);
followRegisteredSessions({
  directory,
  log,
  alsoFollow: () => usageSessions(directory),
  listener: combineListeners(
    usageListener({ directory, log }),
    notificationListener({ directory, log }),
    liveActivityListener({ directory, log }),
  ),
});
followStoredTmuxServers({
  directory,
  log,
  listener: combineTmuxListeners(
    tmuxUsageListener({ directory, log }),
    tmuxPipeReaderListener({ log }),
    tmuxTranscriptListener(),
    tmuxNotificationListener({ directory, log }),
    tmuxLiveActivityListener({ directory, log }),
  ),
});

// A stop asked for is a clean exit, so the service's result stays success.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => process.exit(0));
}
