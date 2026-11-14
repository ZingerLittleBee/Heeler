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
const EXTENSIONS = join(HELPER, "extensions");
/** Runs inside Pi and Oh My Pi, not the Helper's process, and reads its own start on macOS (ADR 0033). */
const SESSION_EXTENSION = join(EXTENSIONS, "heeler-session.js");
/** Runs inside OpenCode, and reads its own start the same way (ADR 0033). */
const OPENCODE_PLUGIN = join(EXTENSIONS, "opencode", "tui.js");
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

/** What a module passes as the program to each start, as written. */
function programsStarted(source) {
  return [...source.matchAll(/(?<![.\w])(?:spawn|spawnSync|execFile|execFileSync|exec|execSync|fork)\(\s*([^,)]+)/g)].map((match) => match[1].trim());
}

/** The modules the long-running service loads, from main.js by relative imports. */
function serviceModules() {
  const seen = new Set();
  const pending = ["main.js"];
  while (pending.length > 0) {
    const path = pending.pop();
    if (seen.has(path)) continue;
    seen.add(path);
    for (const specifier of specifiersIn(readFileSync(join(HELPER, path), "utf8"))) {
      if (specifier.startsWith(".")) pending.push(relative(HELPER, resolve(HELPER, dirname(path), specifier)).split(sep).join("/"));
    }
  }
  return [...seen];
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

  test("the service runs nothing but /bin/ps and the stored tmux with -N, so it can never start a core or a tmux server", () => {
    // The Usage environment's read on macOS, a Usage lock's owner check there,
    // and a tmux Pane's foreground group on macOS (ADR 0046).
    const mayRunPs = new Set(["shared/usage/process-environment.js", "shared/usage/cache.js", "tmux/foreground.js"]);
    // The stored tmux, always with `-N` and `-S` (ADR 0046).
    const mayRunStoredTmux = new Set(["usage/tmux-environment.js", "tmux/client.js"]);
    for (const path of serviceModules()) {
      const source = readFileSync(join(HELPER, path), "utf8");
      if (mayRunPs.has(path)) {
        assert.deepEqual([...new Set(programsStarted(source))], ["\"/bin/ps\""], path);
      } else if (mayRunStoredTmux.has(path)) {
        assert.deepEqual([...new Set(programsStarted(source))], ["target.tmux"], path);
        assert.match(source, /\bexecFile\(\s*target\.tmux,\s*\["-N",\s*"-S",\s*target\.socket,/);
      } else {
        for (const specifier of specifiersIn(source)) {
          assert.notEqual(specifier.replace(/^node:/, ""), "child_process", `${path} imports ${specifier}`);
        }
      }
    }
  });

  test("the Usage query and worker start only recorded programs, so never a core", () => {
    // `executable` is a Usage Limits request's recorded program, or the zstd on the
    // recorded PATH. Naming a new program here is a decision, not a test to update.
    const started = new Set(helperModules().flatMap((path) => programsStarted(readFileSync(path, "utf8"))));
    // `powerShell` is the session extension's on native Windows, and
    // `target.tmux` the tmux the app stored, run inside a tmux Pane (ADR 0046);
    // both are pinned below.
    assert.deepEqual([...started].sort(), [
      '"/bin/ps"',
      '"security"',
      "executable",
      "powerShell",
      "runtime.claude",
      "runtime.node",
      "target.tmux",
    ]);
  });

  test("the Helper's own process never loads an extension", () => {
    for (const path of helperModules().filter((module) => !module.startsWith(`${EXTENSIONS}${sep}`))) {
      for (const specifier of specifiersIn(readFileSync(path, "utf8")).filter((name) => name.startsWith("."))) {
        const target = resolve(dirname(path), specifier);
        assert.equal(target.startsWith(`${EXTENSIONS}${sep}`), false, `${path} imports ${specifier}`);
      }
    }
  });

  // The session extension's are PowerShell's and `/bin/ps`'s, and in a tmux
  // Pane the stored tmux's and `/bin/ps`'s for the Pane's foreground.
  for (const [name, path, calls] of [
    ["session extension", SESSION_EXTENSION, 4],
    ["OpenCode plugin", OPENCODE_PLUGIN, 1],
  ]) {
    test(`the ${name} starts only what reads its own process start`, () => {
      const source = readFileSync(path, "utf8");
      // The lookbehind leaves RegExp's own `.exec` out.
      const named = [...source.matchAll(/(?<![.\w$])(?:exec|execSync|execFile|execFileSync|fork|spawn|spawnSync)\b/g)];
      assert.deepEqual(named.map((match) => match[0]), Array(calls + 1).fill("execFile"), "one import and its calls");
      const imports = specifiersIn(source).filter((name) => name.replace(/^node:/, "") === "child_process");
      assert.equal(imports.length, 1);
      assert.match(source, /^import \{ execFile \} from "node:child_process";$/m);
      assert.match(source, /\bexecFile\(\s*"\/bin\/ps",\s*\["-o", "lstart=", "-p", String\(pid\)\],/);
    });
  }

  test("in a tmux Pane the session extension starts the stored tmux, which never starts a server", () => {
    const source = readFileSync(SESSION_EXTENSION, "utf8");
    // Every tmux command goes through the one call, with `-N` and the Pane's server.
    assert.match(source, /\bexecFile\(target\.tmux, \["-N", "-S", target\.socket, \.\.\.args\]/);
    assert.equal([...source.matchAll(/\btarget\.tmux\b/g)].length, 1);
    assert.match(source, /\bexecFile\(\s*"\/bin\/ps",\s*\["-o", "pgid=,tpgid=,tty=", "-p", String\(process\.pid\)\],/);
  });

  test("on Windows the session extension starts PowerShell for that read and nothing else", () => {
    const source = readFileSync(SESSION_EXTENSION, "utf8");
    assert.match(source, /\bexecFile\(\s*powerShell,/);
    // By its full path: a bare name is looked for in the Agent's project first.
    assert.match(source, /`\$\{root\}\\\\System32\\\\WindowsPowerShell\\\\v1\.0\\\\powershell\.exe`/);
    // The whole command, with the pid a number: it is the only thing PowerShell runs.
    assert.match(source, /`\(Get-Process -Id \$\{Number\(pid\)\}\)\.StartTime\.ToFileTimeUtc\(\)`/);
    assert.equal([...source.matchAll(/powershell\.exe/gi)].length, 1);
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

  test("covers every file of the OpenCode plugin", () => {
    const listed = manifest().files.map((file) => file.path);
    for (const name of ["package.json", "index.js", "tui.js"]) {
      assert.ok(listed.includes(`extensions/opencode/${name}`), name);
    }
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
