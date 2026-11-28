import { readFileSync } from "node:fs";

import { normalizeRexStatus, rexAgentKind, rexPaneID } from "./turn-state.js";
import { connectUnixWebSocket } from "./websocket.js";

const TERMINAL_CREATOR = "com.superlogical.terminal";
const CONTROL_SUBPROTOCOL = "rex.control.v1";
const CONTROL_PATH = "/api/control";
const API_MIN_REVISION = 12;
const API_MAX_REVISION = 19;
const HANDSHAKE_TIMEOUT_MS = 10_000;
const REQUEST_TIMEOUT_MS = 20_000;

const { version: HELPER_VERSION } = JSON.parse(readFileSync(new URL("../version.json", import.meta.url), "utf8"));

const optionalText = (value) => (typeof value === "string" && value !== "" ? value : null);
const wholeNumber = (value) => (Number.isSafeInteger(value) && value >= 0 ? value : null);

function isTerminalBlock(block) {
  if (!block || typeof block !== "object") return false;
  if (block.creator_name === TERMINAL_CREATOR) return true;
  return block.creator_name === undefined && typeof block.flavor === "string" && block.flavor.startsWith(`${TERMINAL_CREATOR}.`);
}

function isDefaultLabel(label, prefix, id) {
  const afterColon = String(id).split(":").at(-1) ?? "";
  const digits = afterColon.replaceAll("-", "");
  return digits.length >= 8 && label === `${prefix} ${digits.slice(-8)}`;
}

function customBlockLabel(block) {
  const label = optionalText(block?.label);
  if (label === null) return null;
  if (typeof block?.flavor === "string") {
    const short = block.flavor.split(".").at(-1);
    if (short && label === short) return null;
  }
  return isDefaultLabel(label, "Block", block.block_id) ? null : label;
}

function customWindowLabel(window) {
  const label = optionalText(window?.label);
  if (label === null) return null;
  return isDefaultLabel(label, "Window", window.window_id) ? null : label;
}

function collectLayoutOrder(node, out) {
  if (!node || typeof node !== "object") return;
  if (typeof node.block_id === "string") {
    out.push(node.block_id);
  } else if (node.split && typeof node.split === "object") {
    collectLayoutOrder(node.split.before, out);
    collectLayoutOrder(node.split.after, out);
  }
}

function parseViewWindows(view) {
  if (!Array.isArray(view?.windows)) return [];
  const windows = [];
  for (const win of view.windows) {
    if (typeof win?.window_id !== "string") continue;
    const layers = Array.isArray(win.layers) ? win.layers : [];
    const orderedLayers = [
      ...layers.filter((layer) => layer?.kind !== "floating"),
      ...layers.filter((layer) => layer?.kind === "floating"),
    ];
    const blocks = [];
    const seen = new Set();
    for (const layer of orderedLayers) {
      const listed = Array.isArray(layer?.blocks) ? layer.blocks : [];
      const byID = new Map();
      for (const block of listed) {
        if (typeof block?.block_id === "string" && !byID.has(block.block_id)) {
          byID.set(block.block_id, block);
        }
      }
      const order = [];
      collectLayoutOrder(layer?.layout, order);
      for (const block of listed) {
        if (typeof block?.block_id === "string") order.push(block.block_id);
      }
      for (const blockID of order) {
        if (seen.has(blockID)) continue;
        const block = byID.get(blockID);
        if (!block || !isTerminalBlock(block)) continue;
        seen.add(blockID);
        blocks.push({
          blockID,
          label: customBlockLabel(block),
        });
      }
    }
    windows.push({
      windowID: win.window_id,
      label: customWindowLabel(win),
      blocks,
    });
  }
  return windows;
}

function parseListedTerminals(listing) {
  if (!Array.isArray(listing?.blocks)) return [];
  const result = [];
  for (const block of listing.blocks) {
    if (typeof block?.block_id !== "string" || !isTerminalBlock(block)) continue;
    result.push({
      blockID: block.block_id,
      label: customBlockLabel(block),
      windowID: block.placement === "placed" ? optionalText(block.window_id) : null,
    });
  }
  return result;
}

function parseRootStatus(result) {
  if (!Array.isArray(result?.records)) return null;
  const root = result.records.find((record) => record?.id === undefined || record?.id === null || record?.id === "");
  return root ? normalizeRexStatus(root) : null;
}

function isRootStatusId(id) {
  return id === undefined || id === null || id === "";
}

function parseProcess(result) {
  const foreground = result?.foreground && typeof result.foreground === "object" ? result.foreground : null;
  return {
    program: optionalText(foreground?.name),
    cwd: optionalText(foreground?.cwd),
    pid: wholeNumber(foreground?.pid),
    argv0: optionalText(foreground?.argv0),
    script: optionalText(foreground?.script),
    home: optionalText(result?.home),
  };
}

class RexConnection {
  instanceId = null;
  serverPid = null;
  closed;

  #ws = null;
  #listener;
  #signal;
  #handshakeTimeoutMs;
  #requestTimeoutMs;
  #pending = new Map();
  #nextRequest = 0;
  #welcomeWaiter = null;
  #lastSeq = 0;
  #ready = false;
  #ended = false;
  #finishClosed;

  #sessionOrder = [];
  #sessions = new Map();
  #details = new Map();
  #resyncTimer = null;
  #syncing = Promise.resolve();

  constructor({ listener = {}, signal, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS, requestTimeoutMs = REQUEST_TIMEOUT_MS }) {
    this.#listener = listener;
    this.#signal = signal;
    this.#handshakeTimeoutMs = handshakeTimeoutMs;
    this.#requestTimeoutMs = requestTimeoutMs;
    this.closed = new Promise((resolve) => {
      this.#finishClosed = resolve;
    });
  }

  async connect(socketPath) {
    const ws = await connectUnixWebSocket(socketPath, {
      path: CONTROL_PATH,
      subprotocol: CONTROL_SUBPROTOCOL,
      handshakeTimeoutMs: this.#handshakeTimeoutMs,
      signal: this.#signal,
      onText: (text) => this.#onMessage(text),
    });
    this.#ws = ws;
    ws.closed.then((reason) => this.#end(reason));

    try {
      const hello = JSON.stringify({
        type: "hello",
        client: {
          kind: "other",
          platform: process.platform === "darwin" ? "darwin" : "linux",
          name: "Heeler Helper",
          version: String(HELPER_VERSION ?? "0"),
          label: "Heeler Helper",
        },
        api_revision: API_MAX_REVISION,
        api_min_revision: API_MIN_REVISION,
      });
      const welcomePromise = this.#awaitWelcome();
      ws.sendText(hello);
      const welcome = await welcomePromise;
      const revision = wholeNumber(welcome?.api_revision);
      if (welcome?.protocol !== CONTROL_SUBPROTOCOL || revision === null || revision < API_MIN_REVISION || revision > API_MAX_REVISION) {
        throw new Error(`Unsupported Rex protocol or API revision (${welcome?.api_revision ?? "unknown"}).`);
      }

      const status = await this.#call("server.status");
      const instanceId = optionalText(status?.instance_id);
      if (instanceId === null) throw new Error("Rex server.status returned no instance_id.");
      this.instanceId = instanceId;
      const pid = wholeNumber(status?.pid);
      this.serverPid = pid !== null && pid > 0 ? pid : null;

      await this.#syncAll();
      this.#ready = true;
      this.#listener.connected?.({
        instanceId: this.instanceId,
        serverPid: this.serverPid,
        inventory: this.#buildInventory(),
      });
    } catch (error) {
      this.close();
      throw error;
    }
  }

  close() {
    this.#ws?.close(1000);
    this.#end(new Error("closed"));
    return this.closed;
  }

  #awaitWelcome() {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#welcomeWaiter = null;
        reject(new Error("Rex welcome timed out."));
      }, this.#handshakeTimeoutMs);
      timer.unref?.();
      this.#welcomeWaiter = {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      };
    });
  }

  #call(method, payload) {
    if (this.#ended || this.#ws === null) return Promise.reject(new Error("The Rex connection is closed."));
    this.#nextRequest += 1;
    const id = `hh${this.#nextRequest}`;
    const body = payload === undefined ? { type: "request", id, method } : { type: "request", id, method, payload };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`Rex request ${method} timed out.`));
      }, this.#requestTimeoutMs);
      timer.unref?.();
      this.#pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
      });
      try {
        this.#ws.sendText(JSON.stringify(body));
      } catch (error) {
        clearTimeout(timer);
        this.#pending.delete(id);
        reject(error);
      }
    });
  }

  #onMessage(text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    if (message?.type === "welcome") {
      const waiter = this.#welcomeWaiter;
      this.#welcomeWaiter = null;
      waiter?.resolve(message);
      return;
    }
    if (message?.type === "response" && typeof message.id === "string") {
      const entry = this.#pending.get(message.id);
      if (!entry) return;
      this.#pending.delete(message.id);
      if (message.error && message.error !== null) {
        entry.reject(new Error(message.error.message || message.error.code || "Rex request failed."));
      } else {
        entry.resolve(message.payload ?? {});
      }
      return;
    }
    if (message?.type === "event") {
      this.#handleEventMessage(message);
    }
  }

  #handleEventMessage(message) {
    const seq = wholeNumber(message.seq);
    if (seq === null) {
      this.#scheduleResync();
      return;
    }
    if (this.#lastSeq > 0 && seq !== this.#lastSeq + 1) {
      this.#lastSeq = seq;
      this.#scheduleResync();
      return;
    }
    this.#lastSeq = seq;
    const envelope = message.payload;
    const name = envelope?.type;
    if (typeof name !== "string") return;
    if (name !== "session_event") {
      this.#handleServerEvent(name, envelope.payload);
      return;
    }
    const sessionID = optionalText(envelope.payload?.session_id);
    const inner = envelope.payload?.event;
    if (sessionID === null || typeof inner?.type !== "string") return;
    this.#handleSessionEvent(sessionID, inner.type, inner.payload);
  }

  #handleServerEvent(name, fields) {
    if (name === "session_created") {
      const sessionID = optionalText(fields?.session?.session_id);
      if (sessionID === null) return;
      if (!this.#sessions.has(sessionID)) {
        this.#sessionOrder.push(sessionID);
        this.#sessions.set(sessionID, {
          id: sessionID,
          label: optionalText(fields?.session?.label) ?? "",
          windows: [],
          detached: [],
        });
      }
      this.#queueWork(() => this.#refreshSession(sessionID));
    } else if (name === "session_destroyed") {
      const sessionID = optionalText(fields?.session_id);
      if (sessionID === null) return;
      this.#forgetSession(sessionID);
      this.#publishUpdated();
    } else if (name === "session_moved") {
      const sessionID = optionalText(fields?.session_id);
      if (sessionID === null) return;
      const index = this.#sessionOrder.indexOf(sessionID);
      if (index === -1) return;
      this.#sessionOrder.splice(index, 1);
      const before = optionalText(fields?.before_session_id);
      const target = before !== null ? this.#sessionOrder.indexOf(before) : -1;
      if (target >= 0) this.#sessionOrder.splice(target, 0, sessionID);
      else this.#sessionOrder.push(sessionID);
      this.#publishUpdated();
    }
  }

  #handleSessionEvent(sessionID, name, fields) {
    if (!this.#sessions.has(sessionID)) {
      this.#sessionOrder.push(sessionID);
      this.#sessions.set(sessionID, { id: sessionID, label: "", windows: [], detached: [] });
      this.#queueWork(() => this.#refreshSession(sessionID));
    }
    if (name === "session_label_changed") {
      const session = this.#sessions.get(sessionID);
      if (session) {
        session.label = optionalText(fields?.label) ?? "";
        this.#publishUpdated();
      }
      return;
    }
    if (
      name === "session_view_changed" ||
      name === "window_created" ||
      name === "window_closed" ||
      name === "window_label_changed" ||
      name === "active_window_changed" ||
      name === "block_created"
    ) {
      this.#queueWork(() => this.#refreshSession(sessionID));
      return;
    }
    if (name === "block_closed") {
      const blockID = optionalText(fields?.block_id);
      if (blockID !== null) {
        this.#details.delete(rexPaneID(sessionID, blockID));
      }
      this.#queueWork(() => this.#refreshSession(sessionID));
      return;
    }
    if (name === "block_event") {
      const creator = optionalText(fields?.creator_name);
      if (creator !== null && creator !== TERMINAL_CREATOR) return;
      const blockID = optionalText(fields?.block_id);
      const eventName = optionalText(fields?.name);
      if (blockID === null || eventName === null) return;
      const paneID = rexPaneID(sessionID, blockID);
      let detail = this.#details.get(paneID);
      if (!detail) {
        detail = { title: null, program: null, cwd: null, pid: null, argv0: null, script: null, home: null, status: null };
        this.#details.set(paneID, detail);
      }
      const payload = fields?.payload;
      if (eventName === "title_changed") {
        detail.title = optionalText(payload?.title);
        this.#publishUpdated();
      } else if (eventName === "process_changed") {
        const proc = parseProcess(payload);
        detail.program = proc.program;
        detail.cwd = proc.cwd;
        detail.pid = proc.pid;
        detail.argv0 = proc.argv0;
        detail.script = proc.script;
        if (proc.home !== null) detail.home = proc.home;
        this.#publishUpdated();
      } else if (eventName === "program_status_changed" && isRootStatusId(payload?.id)) {
        detail.status = normalizeRexStatus(payload?.record);
        this.#publishUpdated();
      } else if (eventName === "program_status_removed" && Array.isArray(payload?.ids) && payload.ids.includes("")) {
        detail.status = null;
        this.#publishUpdated();
      }
    }
  }

  #forgetSession(sessionID) {
    this.#sessions.delete(sessionID);
    this.#sessionOrder = this.#sessionOrder.filter((id) => id !== sessionID);
    const prefix = `${rexPaneID(sessionID, "")}`;
    for (const paneID of [...this.#details.keys()]) {
      if (paneID.startsWith(prefix)) this.#details.delete(paneID);
    }
  }

  #scheduleResync() {
    if (this.#ended || this.#resyncTimer !== null) return;
    this.#resyncTimer = setTimeout(() => {
      this.#resyncTimer = null;
      this.#queueWork(async () => {
        await this.#syncAll();
        this.#publishUpdated();
      });
    }, 200);
    this.#resyncTimer.unref?.();
  }

  #queueWork(work) {
    this.#syncing = this.#syncing
      .then(() => (this.#ended ? undefined : work()))
      .catch(() => {});
  }

  async #syncAll() {
    const attached = await this.#call("session.attach_all", { event_scope: "all" });
    const entries = Array.isArray(attached?.sessions) ? attached.sessions : [];
    const wanted = new Set();
    const nextOrder = [];
    for (const entry of entries) {
      const id = optionalText(entry?.session_id);
      if (id === null || wanted.has(id)) continue;
      wanted.add(id);
      nextOrder.push(id);
      const existing = this.#sessions.get(id);
      if (existing) {
        existing.label = optionalText(entry?.label) ?? existing.label;
      } else {
        this.#sessions.set(id, { id, label: optionalText(entry?.label) ?? "", windows: [], detached: [] });
      }
    }
    for (const id of [...this.#sessions.keys()]) {
      if (!wanted.has(id)) this.#forgetSession(id);
    }
    this.#sessionOrder = nextOrder;
    for (const sessionID of this.#sessionOrder) {
      if (this.#ended) return;
      await this.#readSession(sessionID, { readAllDetails: true });
    }
  }

  async #refreshSession(sessionID) {
    if (!this.#sessions.has(sessionID) || this.#ended) return;
    await this.#readSession(sessionID, { readAllDetails: false });
    this.#publishUpdated();
  }

  async #readSession(sessionID, { readAllDetails }) {
    const session = this.#sessions.get(sessionID);
    if (!session) return;
    let view = null;
    let listing = null;
    try {
      view = await this.#call("session.view", { session_id: sessionID });
    } catch {}
    try {
      listing = await this.#call("session.list_blocks", { session_id: sessionID });
    } catch {}
    if (this.#ended || !this.#sessions.has(sessionID)) return;

    if (view !== null && typeof view.label === "string") {
      session.label = view.label;
    }
    const windows = view !== null ? parseViewWindows(view) : session.windows;
    const placedIDs = new Set(windows.flatMap((win) => win.blocks.map((block) => block.blockID)));
    const listedTerminals = listing !== null ? parseListedTerminals(listing) : [];
    const detached = listedTerminals
      .filter((block) => (block.windowID === null || view === null) && !placedIDs.has(block.blockID))
      .map((block) => ({ blockID: block.blockID, label: block.label }));

    session.windows = windows;
    session.detached = detached;

    const currentBlockIDs = new Set([...placedIDs, ...detached.map((block) => block.blockID)]);
    const prefix = rexPaneID(sessionID, "");
    for (const paneID of [...this.#details.keys()]) {
      if (!paneID.startsWith(prefix)) continue;
      let blockFound = false;
      for (const blockID of currentBlockIDs) {
        if (rexPaneID(sessionID, blockID) === paneID) {
          blockFound = true;
          break;
        }
      }
      if (!blockFound) this.#details.delete(paneID);
    }

    for (const blockID of currentBlockIDs) {
      if (this.#ended) return;
      const paneID = rexPaneID(sessionID, blockID);
      if (!readAllDetails && this.#details.has(paneID)) continue;
      await this.#readTerminalDetails(sessionID, blockID);
    }
  }

  async #readTerminalDetails(sessionID, blockID) {
    const target = { session_id: sessionID, block_id: blockID };
    const paneID = rexPaneID(sessionID, blockID);
    const existing = this.#details.get(paneID) ?? {
      title: null,
      program: null,
      cwd: null,
      pid: null,
      argv0: null,
      script: null,
      home: null,
      status: null,
    };
    const [titleRes, processRes, statusRes] = await Promise.all([
      this.#call(`${TERMINAL_CREATOR}.title`, target).catch(() => null),
      this.#call(`${TERMINAL_CREATOR}.process`, target).catch(() => null),
      this.#call(`${TERMINAL_CREATOR}.program_status`, target).catch(() => null),
    ]);
    if (this.#ended) return;
    if (titleRes !== null) existing.title = optionalText(titleRes.title);
    if (processRes !== null) {
      const proc = parseProcess(processRes);
      existing.program = proc.program;
      existing.cwd = proc.cwd;
      existing.pid = proc.pid;
      existing.argv0 = proc.argv0;
      existing.script = proc.script;
      if (proc.home !== null) existing.home = proc.home;
    }
    if (statusRes !== null) {
      existing.status = parseRootStatus(statusRes);
    }
    this.#details.set(paneID, existing);
  }

  #buildInventory() {
    const inventory = new Map();
    for (const sessionID of this.#sessionOrder) {
      const session = this.#sessions.get(sessionID);
      if (!session) continue;
      const tabs = session.windows.map((win) => ({
        windowID: win.windowID,
        windowLabel: win.label ?? "",
        blocks: win.blocks,
      }));
      if (session.detached.length > 0) {
        tabs.push({
          windowID: `${sessionID}/detached`,
          windowLabel: "Detached",
          blocks: session.detached,
        });
      }
      const tabCount = tabs.length;
      for (let tabIndex = 0; tabIndex < tabCount; tabIndex += 1) {
        const tab = tabs[tabIndex];
        for (const block of tab.blocks) {
          const paneID = rexPaneID(sessionID, block.blockID);
          const detail = this.#details.get(paneID);
          const pane = {
            paneID,
            sessionID,
            sessionLabel: session.label,
            windowID: tab.windowID,
            windowLabel: tab.windowLabel,
            windowPosition: tabIndex + 1,
            windowCount: tabCount,
            blockID: block.blockID,
            blockLabel: block.label,
            title: detail?.title ?? null,
            program: detail?.program ?? null,
            cwd: detail?.cwd ?? null,
            pid: detail?.pid ?? null,
            argv0: detail?.argv0 ?? null,
            script: detail?.script ?? null,
            home: detail?.home ?? null,
            status: detail?.status ?? null,
          };
          pane.agentKind = rexAgentKind(pane);
          inventory.set(paneID, pane);
        }
      }
    }
    return inventory;
  }

  #publishUpdated() {
    if (!this.#ready || this.#ended) return;
    this.#listener.updated?.({
      instanceId: this.instanceId,
      serverPid: this.serverPid,
      inventory: this.#buildInventory(),
    });
  }

  #end(reason) {
    if (this.#ended) return;
    this.#ended = true;
    clearTimeout(this.#resyncTimer);
    this.#resyncTimer = null;
    const waiter = this.#welcomeWaiter;
    this.#welcomeWaiter = null;
    waiter?.reject(reason);
    for (const entry of this.#pending.values()) entry.reject(reason);
    this.#pending.clear();
    this.#finishClosed(reason);
  }
}

export async function connectRex(
  socketPath,
  { listener, handshakeTimeoutMs = HANDSHAKE_TIMEOUT_MS, requestTimeoutMs = REQUEST_TIMEOUT_MS, signal } = {},
) {
  const connection = new RexConnection({ listener, signal, handshakeTimeoutMs, requestTimeoutMs });
  await connection.connect(socketPath);
  return connection;
}
