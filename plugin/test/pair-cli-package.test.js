// `heeler-pair` is published to npm as plugin/pair-cli's manifest over a
// subset of plugin/src (ADR 0057), so the manifest has to name every module
// the command loads: one it misses is a command that cannot start.

import { suite, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isBuiltin } from "node:module";
import { fileURLToPath } from "node:url";
import { join } from "node:path";

const SRC = fileURLToPath(new URL("../src", import.meta.url));
const manifest = JSON.parse(readFileSync(new URL("../pair-cli/package.json", import.meta.url), "utf8"));
const plugin = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8"));

// Static imports start a line, so prose in comments cannot match. A forced
// command is started by path, which is how pair-accept.js is reached.
const SPECIFIERS = [
  /^\s*(?:import|export)\b[^;"'`]*?\bfrom\s*["'`]([^"'`]+)["'`]/gm,
  /^\s*import\s*["'`]([^"'`]+)["'`]/gm,
  /\bimport\s*\(\s*["'`]([^"'`]+)["'`]/g,
  /new URL\(\s*["'`]([^"'`]+)["'`]\s*,\s*import\.meta\.url/g,
];

/** The modules the command loads from `entry`, and the packages they import. */
function closure(entry) {
  const modules = new Set();
  const packages = new Set();
  const pending = [entry];
  while (pending.length > 0) {
    const name = pending.pop();
    if (modules.has(name)) continue;
    modules.add(name);
    const source = readFileSync(join(SRC, name), "utf8");
    for (const pattern of SPECIFIERS) {
      for (const [, specifier] of source.matchAll(pattern)) {
        if (specifier.startsWith("./")) pending.push(specifier.slice(2));
        else if (!specifier.startsWith("../") && !isBuiltin(specifier)) packages.add(specifier);
      }
    }
  }
  return { modules: [...modules].sort(), packages: [...packages].sort() };
}

suite("heeler-pair package", () => {
  const entry = manifest.bin["heeler-pair"];
  const loaded = closure(entry.replace(/^src\//, ""));

  test("its files are exactly the modules the command loads", () => {
    assert.deepEqual(
      [...manifest.files].sort(),
      loaded.modules.map((name) => `src/${name}`),
    );
  });

  test("its dependencies are the packages those modules import, at the plugin's versions", () => {
    assert.deepEqual(Object.keys(manifest.dependencies).sort(), loaded.packages);
    for (const name of loaded.packages) {
      assert.equal(manifest.dependencies[name], plugin.dependencies[name], name);
    }
  });

  test("it runs on the Node.js the plugin requires", () => {
    assert.equal(manifest.engines.node, plugin.engines.node);
    assert.equal(manifest.type, "module");
  });
});
