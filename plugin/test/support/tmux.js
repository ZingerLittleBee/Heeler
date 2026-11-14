// Shared tmux resolver for the plugin's real-tmux test suites. Uses
// `HEELER_TEST_TMUX` when set, otherwise `command -v tmux` on `PATH`. Locally,
// a missing tmux skips with a reason; under `CI`, a missing tmux never skips
// and fails loudly when the suite runs.

import { spawnSync } from "node:child_process";
import { accessSync, constants, statSync } from "node:fs";
import { delimiter, dirname } from "node:path";

function isExecutableFile(candidate) {
  if (!candidate || !candidate.startsWith("/")) return false;
  try {
    return statSync(candidate).isFile() && (accessSync(candidate, constants.X_OK), true);
  } catch {
    return false;
  }
}

function findTmuxOnPath(pathValue) {
  const found = spawnSync("/bin/sh", ["-c", "command -v tmux"], {
    encoding: "utf8",
    env: { PATH: pathValue ?? "" },
  });
  const candidate = found.stdout.trim();
  return found.status === 0 && isExecutableFile(candidate) ? candidate : null;
}

function prependTmuxDir(tmux, pathValue) {
  const base = pathValue ?? "";
  if (!tmux) return base;
  const dir = dirname(tmux);
  if (base === dir || base.startsWith(`${dir}${delimiter}`)) return base;
  return base ? `${dir}${delimiter}${base}` : dir;
}

function isContinuousIntegration(ciValue) {
  return Boolean(ciValue && ciValue !== "0" && ciValue !== "false");
}

export function resolveTestTmux(env = process.env) {
  const configured = env.HEELER_TEST_TMUX?.trim() ?? "";
  const inCI = isContinuousIntegration(env.CI);

  if (configured !== "") {
    if (!isExecutableFile(configured)) {
      const error = new Error(`HEELER_TEST_TMUX is not an executable file: ${configured}`);
      return {
        tmux: null,
        skip: false,
        pathWithTmux: env.PATH ?? "",
        requireTmux() {
          throw error;
        },
      };
    }
    return {
      tmux: configured,
      skip: false,
      pathWithTmux: prependTmuxDir(configured, env.PATH),
      requireTmux() {
        return configured;
      },
    };
  }

  const found = findTmuxOnPath(env.PATH);
  if (found) {
    return {
      tmux: found,
      skip: false,
      pathWithTmux: prependTmuxDir(found, env.PATH),
      requireTmux() {
        return found;
      },
    };
  }

  const error = new Error("tmux is not installed; install tmux or set HEELER_TEST_TMUX");
  return {
    tmux: null,
    skip: inCI ? false : "tmux is not installed",
    pathWithTmux: env.PATH ?? "",
    requireTmux() {
      throw error;
    },
  };
}
