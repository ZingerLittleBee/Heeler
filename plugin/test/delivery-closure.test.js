// The delivery modules join the Host Helper's dependency-free import closure
// (ADR 0033): the Helper runs without the plugin's node_modules and outside
// herdr, so nothing they reach may import a package or read a herdr variable.

import { suite, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { isBuiltin } from "node:module";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const SRC = fileURLToPath(new URL("../src", import.meta.url));
const DELIVERY = join(SRC, "delivery");

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

/** Every file a delivery module reaches, and each one's non-relative imports. */
function walkClosure() {
  const closure = new Map();
  const pending = readdirSync(DELIVERY)
    .filter((name) => name.endsWith(".js"))
    .map((name) => join(DELIVERY, name));
  while (pending.length > 0) {
    const path = pending.pop();
    if (closure.has(path)) continue;
    const source = readFileSync(path, "utf8");
    const specifiers = specifiersIn(source);
    closure.set(path, { source, external: specifiers.filter((s) => !s.startsWith(".")) });
    for (const specifier of specifiers) {
      if (specifier.startsWith(".")) pending.push(resolve(dirname(path), specifier));
    }
  }
  return closure;
}

suite("delivery module closure", () => {
  test("the walker sees all three modules and what they import", () => {
    const names = [...walkClosure().keys()].map((path) => relative(SRC, path)).sort();
    for (const name of [
      "delivery/activity-seal.js",
      "delivery/push.js",
      "delivery/registrations.js",
      "seal-envelope.js",
    ]) {
      assert.ok(names.includes(name), `${name} missing from ${names.join(", ")}`);
    }
  });

  test("imports only relative paths and Node built-ins", () => {
    for (const [path, { external }] of walkClosure()) {
      for (const specifier of external) {
        assert.ok(isBuiltin(specifier), `${relative(SRC, path)} imports ${specifier}`);
      }
    }
  });

  test("references no herdr variable and reads no environment", () => {
    for (const [path, { source }] of walkClosure()) {
      assert.equal(source.includes("HERDR_"), false, `${relative(SRC, path)} names a HERDR_ variable`);
      assert.equal(source.includes("process.env"), false, `${relative(SRC, path)} reads the environment`);
    }
  });
});
