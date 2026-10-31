// Which folders Pi and Oh My Pi load extensions from under one home, and whether
// each holds Heeler's already. The app runs this file's text on a Host before the
// Helper is there, as `node --input-type=module -e <text> <home>`, and lists what
// it finds on the install sheet. See herdr compatibility for the profile layout.

import { existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const EXTENSION = "heeler-session.js";
const PROFILE_NAME = /^[a-z0-9][a-z0-9._-]{0,63}$/;

const home = process.argv.at(-1);
const profilesFolder = join(home, ".omp", "profiles");

function isFolder(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function profileNames() {
  let names;
  try {
    names = readdirSync(profilesFolder);
  } catch {
    return [];
  }
  return names
    .filter((name) => PROFILE_NAME.test(name) && !name.endsWith(".") && name !== "default")
    .filter((name) => isFolder(join(profilesFolder, name)))
    .sort();
}

const folders = [
  join(home, ".pi", "agent", "extensions"),
  join(home, ".omp", "agent", "extensions"),
  ...profileNames().map((name) => join(profilesFolder, name, "agent", "extensions")),
];

console.log(JSON.stringify({ folders: folders.map((path) => ({ path, installed: existsSync(join(path, EXTENSION)) })) }));
