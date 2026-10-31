#!/usr/bin/env node
// Builds the Host Helper's tree (ADR 0033), which the app bundles and installs
// on a Host with no npm and no plugin checkout:
//
//   - plugin/helper/shared/ mirrors what Helper code imports of plugin/src, at
//     the same relative paths. Helper code imports "./shared/delivery/push.js",
//     and this copies plugin/src/delivery/push.js and what that reaches.
//   - plugin/helper/manifest.json holds the version and every other file's
//     SHA-256, which the app checks after an upload and whenever it reads a
//     Host's Helper.
//
// Usage: node scripts/generate-host-helper-manifest.mjs [--check] [--plugin <dir>]
// --check changes nothing and exits 1 when the tree is out of date.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { isBuiltin } from "node:module";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const MANIFEST = "manifest.json";
const SHARED = "shared";

// Static imports and re-exports start a line, so prose in comments cannot match;
// dynamic forms are matched wherever they appear.
const IMPORT_SPECIFIERS = [
  /^\s*(?:import|export)\b[^;"'`]*?\bfrom\s*["'`]([^"'`]+)["'`]/gm,
  /^\s*import\s*["'`]([^"'`]+)["'`]/gm,
  /\b(?:import|require)\s*\(\s*["'`]([^"'`]+)["'`]/g,
];

function specifiersIn(source) {
  return IMPORT_SPECIFIERS.flatMap((pattern) => [...source.matchAll(pattern)].map((match) => match[1]));
}

function filesUnder(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && !entry.name.startsWith("."))
    .map((entry) => relative(directory, join(entry.parentPath, entry.name)).split(sep).join("/"))
    .sort();
}

function isInside(parent, path) {
  const rest = relative(parent, path);
  return rest !== "" && !rest.startsWith("..");
}

class HelperTreeError extends Error {}

/**
 * The shared mirror the Helper's own modules need, as a map from path under
 * plugin/helper to contents. Refuses a package import or a herdr variable, here
 * rather than on the Host.
 */
function sharedMirror(helper, src) {
  const shared = join(helper, SHARED);
  const mirror = new Map();
  const seen = new Set();
  const own = filesUnder(helper).filter((path) => path.endsWith(".js") && !path.startsWith(`${SHARED}/`));
  const pending = own.map((path) => ({ path: join(helper, path), source: readFileSync(join(helper, path), "utf8") }));
  while (pending.length > 0) {
    const { path, source } = pending.pop();
    if (seen.has(path)) continue;
    seen.add(path);
    if (source.includes("HERDR_")) throw new HelperTreeError(`${relative(helper, path)} names a HERDR_ variable`);
    for (const specifier of specifiersIn(source)) {
      if (!specifier.startsWith(".")) {
        if (!isBuiltin(specifier)) throw new HelperTreeError(`${relative(helper, path)} imports the package ${specifier}`);
        continue;
      }
      const target = resolve(dirname(path), specifier);
      if (!isInside(helper, target)) {
        throw new HelperTreeError(`${relative(helper, path)} imports ${specifier}, outside the Helper; use ./${SHARED}/`);
      }
      if (!isInside(shared, target)) continue;
      const original = join(src, relative(shared, target));
      if (!existsSync(original)) throw new HelperTreeError(`${specifier} has no source in plugin/src`);
      const contents = readFileSync(original);
      mirror.set(relative(helper, target).split(sep).join("/"), contents);
      pending.push({ path: target, source: contents.toString("utf8") });
    }
  }
  return mirror;
}

function manifestText(helper, mirror) {
  const { version } = JSON.parse(readFileSync(join(helper, "version.json"), "utf8"));
  const own = filesUnder(helper).filter((path) => path !== MANIFEST && !path.startsWith(`${SHARED}/`));
  const contents = new Map(own.map((path) => [path, readFileSync(join(helper, path))]));
  for (const [path, bytes] of mirror) contents.set(path, bytes);
  const files = [...contents.keys()].sort().map((path) => ({
    path,
    sha256: createHash("sha256").update(contents.get(path)).digest("hex"),
  }));
  return `${JSON.stringify({ version, files }, null, 2)}\n`;
}

/** What differs between the tree on disk and what it should be. */
function drift(helper, mirror, text) {
  const problems = [];
  const present = filesUnder(join(helper, SHARED)).map((path) => `${SHARED}/${path}`);
  for (const path of present) {
    if (!mirror.has(path)) problems.push(`${path} is no longer imported`);
  }
  for (const [path, bytes] of mirror) {
    const full = join(helper, path);
    if (!existsSync(full) || !readFileSync(full).equals(bytes)) problems.push(`${path} differs from plugin/src`);
  }
  const manifest = join(helper, MANIFEST);
  if (!existsSync(manifest) || readFileSync(manifest, "utf8") !== text) problems.push(`${MANIFEST} is out of date`);
  return problems;
}

function write(helper, mirror, text) {
  rmSync(join(helper, SHARED), { recursive: true, force: true });
  for (const [path, bytes] of mirror) {
    mkdirSync(dirname(join(helper, path)), { recursive: true });
    writeFileSync(join(helper, path), bytes);
  }
  writeFileSync(join(helper, MANIFEST), text);
}

function main(argv) {
  let check = false;
  let plugin = fileURLToPath(new URL("../plugin", import.meta.url));
  for (let index = 0; index < argv.length; index += 1) {
    if (argv[index] === "--check") check = true;
    else if (argv[index] === "--plugin") plugin = resolve(argv[(index += 1)] ?? "");
    else throw new HelperTreeError(`unknown argument ${argv[index]}`);
  }
  const helper = join(plugin, "helper");
  if (!existsSync(helper) || !statSync(helper).isDirectory()) throw new HelperTreeError(`${helper} is not a directory`);
  const mirror = sharedMirror(helper, join(plugin, "src"));
  const text = manifestText(helper, mirror);
  if (check) {
    const problems = drift(helper, mirror, text);
    if (problems.length > 0) {
      throw new HelperTreeError(`${problems.join("\n")}\nrun scripts/generate-host-helper-manifest.mjs`);
    }
    return;
  }
  write(helper, mirror, text);
}

try {
  main(process.argv.slice(2));
} catch (error) {
  if (!(error instanceof HelperTreeError)) throw error;
  console.error(error.message);
  process.exit(1);
}
