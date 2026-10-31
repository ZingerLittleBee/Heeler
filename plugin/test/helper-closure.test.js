// The Host Helper installs from the app onto a Host with no npm (ADR 0033), so
// everything under plugin/helper runs from the files the manifest names.

import { suite, test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { isBuiltin } from "node:module";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HELPER = fileURLToPath(new URL("../helper", import.meta.url));
const SRC = fileURLToPath(new URL("../src", import.meta.url));
const MANIFEST = "manifest.json";
const GENERATOR = "scripts/generate-host-helper-manifest.mjs";

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
  return readdirSync(directory, { recursive: true, withFileTypes: true })
    .filter((entry) => entry.isFile() && !entry.name.startsWith("."))
    .map((entry) => relative(directory, join(entry.parentPath, entry.name)).split(sep).join("/"))
    .sort();
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

const helperModules = () =>
  filesUnder(HELPER)
    .filter((path) => path.endsWith(".js"))
    .map((path) => join(HELPER, path));

suite("Host Helper closure", () => {
  test("every import stays inside the Helper or names a Node built-in", () => {
    const files = filesUnder(HELPER);
    for (const path of helperModules()) {
      for (const specifier of specifiersIn(readFileSync(path, "utf8"))) {
        if (specifier.startsWith(".")) {
          const target = relative(HELPER, resolve(dirname(path), specifier)).split(sep).join("/");
          assert.ok(files.includes(target), `${path} imports ${specifier}, which the Helper does not hold`);
        } else {
          assert.ok(isBuiltin(specifier), `${path} imports the package ${specifier}`);
        }
      }
    }
  });

  test("names no herdr variable", () => {
    for (const path of helperModules()) {
      assert.equal(readFileSync(path, "utf8").includes("HERDR_"), false, `${path} names a HERDR_ variable`);
    }
  });

  test("can start no process, so it can never start a core", () => {
    for (const path of helperModules()) {
      for (const specifier of specifiersIn(readFileSync(path, "utf8"))) {
        assert.notEqual(specifier.replace(/^node:/, ""), "child_process", `${path} imports ${specifier}`);
      }
    }
  });

  test("a shared module is the plugin's own source, byte for byte", () => {
    for (const path of filesUnder(HELPER).filter((name) => name.startsWith("shared/"))) {
      assert.deepEqual(
        readFileSync(join(HELPER, path)),
        readFileSync(join(SRC, path.slice("shared/".length))),
        `${path} differs from plugin/src; run ${GENERATOR}`,
      );
    }
  });
});

suite("Host Helper manifest", () => {
  const manifest = () => JSON.parse(readFileSync(join(HELPER, MANIFEST), "utf8"));

  test("lists every file but itself", () => {
    const listed = manifest().files.map((file) => file.path);
    assert.deepEqual(listed, filesUnder(HELPER).filter((path) => path !== MANIFEST));
  });

  test("holds each file's SHA-256", () => {
    for (const { path, sha256: expected } of manifest().files) {
      assert.equal(sha256(join(HELPER, path)), expected, `${path} changed; run ${GENERATOR}`);
    }
  });

  test("covers the Pi and Oh My Pi extension and what finds its folders", () => {
    const listed = manifest().files.map((file) => file.path);
    assert.ok(listed.includes("extensions/heeler-session.js"));
    assert.ok(listed.includes("extensions/extension-folders.js"));
  });

  test("the shared version vector pins the Helper's version", () => {
    const shared = JSON.parse(
      readFileSync(new URL("../test-vectors/host-helper-version-v1.json", import.meta.url), "utf8"),
    );
    assert.equal(JSON.parse(readFileSync(join(HELPER, "version.json"), "utf8")).version, shared.version);
    assert.equal(manifest().version, shared.version);
  });
});

suite("Host Helper process", () => {
  /** Resolves with the first stdout line; rejects if the process exits first. */
  function firstLine(child) {
    return new Promise((done, fail) => {
      let text = "";
      child.stdout.on("data", (chunk) => {
        text += chunk;
        if (text.includes("\n")) done(text.split("\n")[0]);
      });
      child.once("exit", (code, signal) => fail(new Error(`exited ${code ?? signal}: ${text}`)));
    });
  }

  test("runs from a bare copy of its files and stays up until told to stop", async () => {
    const home = mkdtempSync(join(tmpdir(), "heeler-helper-"));
    try {
      const copy = join(home, "app");
      cpSync(HELPER, copy, { recursive: true });
      const child = spawn(process.execPath, [join(copy, "main.js")], { stdio: ["ignore", "pipe", "inherit"] });
      const version = JSON.parse(readFileSync(join(HELPER, "version.json"), "utf8")).version;
      assert.equal(await firstLine(child), `Heeler Host Helper ${version} started`);
      await new Promise((done) => setTimeout(done, 300));
      assert.equal(child.exitCode, null);
      const exit = new Promise((done) => child.on("exit", (code, signal) => done({ code, signal })));
      child.kill("SIGTERM");
      assert.deepEqual(await exit, { code: 0, signal: null });
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});
