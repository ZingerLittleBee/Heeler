import { REPORTED_APPS, agentIn } from "../core/agent-rule.js";
import { DONE_REPORTER_KINDS } from "../core/turn-state.js";
import { tmuxKindLabel } from "../tmux/turn-state.js";

const KNOWN_WORDS = new Set(["idle", "done", "working", "blocked", "error"]);

const escapePanePart = (id) => String(id).replaceAll("%", "%25").replaceAll("/", "%2F");

export function rexPaneID(sessionID, blockID) {
  return `${escapePanePart(sessionID)}/${escapePanePart(blockID)}`;
}

export function rexKindLabel(kind) {
  return tmuxKindLabel(kind);
}

const optionalText = (value) => (typeof value === "string" && value !== "" ? value : null);
const wholeNumber = (value) => (Number.isSafeInteger(value) && value >= 0 ? value : null);

function normalizeState(reported, app, message) {
  if (reported === "working" && app?.toLowerCase() === "claude-code" && typeof message === "string") {
    const words = message.trim().split(/\s+/);
    if (
      words.length >= 4 &&
      words[words.length - 2] === "still" &&
      words[words.length - 1] === "running" &&
      /^\d+$/.test(words[0])
    ) {
      return "done";
    }
  }
  return reported;
}

export function normalizeRexStatus(record) {
  if (!record || typeof record !== "object") return null;
  const rawState = optionalText(record.state);
  if (rawState === null) return null;
  const app = optionalText(record.app) ?? optionalText(record.effective_app);
  const message = optionalText(record.msg);
  const owner = record.owner && typeof record.owner === "object" ? record.owner : null;
  return {
    state: normalizeState(rawState, app, message),
    app,
    ownerPid: wholeNumber(owner?.pid),
    ownerName: optionalText(owner?.name),
    updatedAt: optionalText(record.updated_at),
  };
}

export function rexAgentKind(pane) {
  if (!pane || typeof pane.program !== "string" || pane.program === "") return null;
  const argv = [pane.argv0 || pane.program];
  if (typeof pane.script === "string" && pane.script !== "") argv.push(pane.script);
  const pid = Number.isSafeInteger(pane.pid) && pane.pid > 0 ? pane.pid : 1;
  const found = agentIn({
    state: "live",
    pid,
    foreground: {
      pid,
      name: pane.program,
      argv,
    },
  });
  return found?.known ? found.kind : null;
}

export function rexAgentReport(pane, kind) {
  const report = pane?.status ?? null;
  if (report === null || !Number.isSafeInteger(report.ownerPid)) return null;
  if (report.ownerPid !== pane.pid || report.ownerName !== pane.program) return null;
  const app = (report.app ?? "").trim().toLowerCase();
  if (Object.hasOwn(REPORTED_APPS, app) && REPORTED_APPS[app] !== kind) return null;
  return report;
}

function readMark(value) {
  if (!value || typeof value !== "object") return null;
  return {
    processID: wholeNumber(value.processID),
    program: optionalText(value.program),
    app: optionalText(value.app),
    updatedAt: optionalText(value.updatedAt),
  };
}

function sameProgram(left, right) {
  return left.processID === right.processID && left.program === right.program && left.app === right.app;
}

function sameReportMark(left, right) {
  return sameProgram(left, right) && left.updatedAt === right.updatedAt;
}

export class RexTurnState {
  last = null;
  endedMark = null;
  kind = null;
  hasReportedDone = false;
  currentStatus = null;

  noteSample(pane) {
    const kind = rexAgentKind(pane);
    this.kind = kind;
    const report = kind !== null ? rexAgentReport(pane, kind) : null;
    if (kind === null) {
      this.currentStatus = null;
      if (pane?.program !== null && pane?.program !== undefined) {
        this.endedMark = null;
      }
      return;
    }
    if (report === null) {
      this.currentStatus = "unknown";
      if (pane?.status !== null && pane?.status !== undefined) {
        this.endedMark = null;
      }
      return;
    }
    this.currentStatus =
      report.state === "idle" || report.state === "done"
        ? "idle"
        : KNOWN_WORDS.has(report.state)
          ? report.state
          : "unknown";
    const mark = {
      processID: report.ownerPid ?? null,
      program: report.ownerName ?? null,
      app: report.app ?? null,
      updatedAt: report.updatedAt ?? null,
    };
    const next = { state: report.state, mark };
    const previous = this.last;
    this.last = next;
    if (previous === null || !sameProgram(previous.mark, next.mark)) {
      this.hasReportedDone = next.state === "done";
      this.endedMark = next.state === "done" ? mark : null;
      return;
    }
    if (previous.state === next.state && sameReportMark(previous.mark, next.mark)) return;
    if (next.state === "done") this.hasReportedDone = true;
    if (next.state !== "idle" && next.state !== "done") {
      this.endedMark = null;
      return;
    }
    const reportsDone = this.hasReportedDone || DONE_REPORTER_KINDS.has(kind);
    const doneEndsTurn = next.state === "done" && (previous.state === "working" || previous.state === "blocked");
    const idleEndsTurn = next.state === "idle" && previous.state === "working" && !reportsDone;
    if (doneEndsTurn || idleEndsTurn) {
      this.endedMark = mark;
    }
  }

  get agentStatus() {
    if (this.kind === null) return null;
    return this.currentStatus ?? "unknown";
  }

  get ended() {
    if (this.endedMark === null) return null;
    return {
      turn: this.endedMark.processID ?? 0,
      word: this.endedMark.updatedAt ?? null,
    };
  }

  isDoneFor(seenMark) {
    const ended = this.ended;
    if (ended === null) return false;
    if (seenMark === null || seenMark === undefined) return true;
    if (seenMark.turn !== ended.turn) return true;
    if (seenMark.word === ended.word) return false;
    if (typeof seenMark.word === "string" && typeof ended.word === "string") {
      const seenMs = Date.parse(seenMark.word);
      const endedMs = Date.parse(ended.word);
      if (Number.isFinite(seenMs) && Number.isFinite(endedMs) && seenMs >= endedMs) return false;
    }
    return true;
  }

  toJSON() {
    return {
      last: this.last,
      endedMark: this.endedMark,
      kind: this.kind,
      hasReportedDone: this.hasReportedDone,
      currentStatus: this.currentStatus,
    };
  }

  static restore(value) {
    const state = new RexTurnState();
    if (value && typeof value === "object") {
      if (value.last && typeof value.last.state === "string") {
        const mark = readMark(value.last.mark);
        if (mark !== null) state.last = { state: value.last.state, mark };
      }
      state.endedMark = readMark(value.endedMark);
      state.kind = optionalText(value.kind);
      state.hasReportedDone = value.hasReportedDone === true;
      state.currentStatus = optionalText(value.currentStatus);
    }
    return state;
  }
}

export function foldRexPane(turns, pane) {
  turns.noteSample(pane);
}

export function rexDecisionSignature(pane, turns) {
  return JSON.stringify([
    turns.kind,
    turns.agentStatus,
    turns.ended?.turn ?? null,
    turns.ended?.word ?? null,
    pane.sessionLabel ?? "",
    pane.title ?? "",
  ]);
}
