// A tmux Pane's turn folding from `@heeler-status` (ADR 0044), shared with
// `TmuxTurnState.swift` and `plugin/test-vectors/tmux-heeler-status-v1.json`.

import { readHeelerStatus, wordForTmuxAgent } from "./status.js";

const KNOWN_WORDS = new Set(["idle", "done", "working", "blocked", "error"]);

const KIND_LABELS = {
  pi: "Pi",
  claude: "Claude",
  codex: "Codex",
  gemini: "Gemini CLI",
  cursor: "Cursor Agent",
  devin: "Devin CLI",
  agy: "Antigravity",
  cline: "Cline",
  omp: "OMP",
  mastracode: "Mastra Code",
  opencode: "OpenCode",
  copilot: "GitHub Copilot CLI",
  kimi: "Kimi CLI",
  kiro: "Kiro CLI",
  droid: "Droid",
  amp: "Amp",
  grok: "Grok Build",
  hermes: "Hermes Agent",
  kilo: "Kilo Code",
  qodercli: "Qoder CLI",
  maki: "Maki",
  muse: "Muse",
  qwen: "Qwen Code",
};

const wholeNumber = (value) => (Number.isSafeInteger(value) && value >= 0 ? value : 0);

/** Display label of an Agent kind, matching `AgentNotificationIdentity.kindLabel`. */
export function tmuxKindLabel(kind) {
  if (typeof kind !== "string" || kind.trim() === "") return "Unknown";
  const lowered = kind.trim().toLowerCase();
  return Object.hasOwn(KIND_LABELS, lowered) ? KIND_LABELS[lowered] : kind.trim();
}

export class TmuxTurnState {
  last = null;
  kind = null;
  departedTurn = null;
  blockedCount = 0;

  noteSample(statusOption, agentKind) {
    const parsed = readHeelerStatus(statusOption);
    this.blockedCount = parsed.blocked;
    if (!agentKind) {
      this.departedTurn = parsed.turn;
      this.kind = null;
      this.last = null;
      return;
    }
    if (this.kind !== null && this.kind !== agentKind && this.last !== null) {
      this.departedTurn = this.last.turn;
    }
    this.kind = agentKind;
    this.last = { turn: parsed.turn, word: wordForTmuxAgent(parsed, agentKind) };
  }

  /** Agent Status before per-device Done (`idle`, `working`, `blocked`, `error`, `unknown`), or null. */
  get agentStatus() {
    if (this.kind === null || this.last === null) return null;
    if (this.last.word === "idle" || this.last.word === "done") return "idle";
    return KNOWN_WORDS.has(this.last.word) ? this.last.word : "unknown";
  }

  /**
   * The finished turn while the Agent reads `idle` or `done` above `departedTurn`.
   * Normalized to `word: "done"` so `done -> idle` at the same count is one turn.
   */
  get ended() {
    if (this.kind === null || this.last === null) return null;
    if (this.last.word !== "idle" && this.last.word !== "done") return null;
    if (this.last.turn <= (this.departedTurn ?? 0)) return null;
    return { turn: this.last.turn, word: "done" };
  }

  isDoneFor(seenMark) {
    if (this.ended === null) return false;
    const seenTurn = seenMark !== null && Number.isSafeInteger(seenMark?.turn) ? seenMark.turn : 0;
    return this.last.turn > Math.max(seenTurn, this.departedTurn ?? 0);
  }

  toJSON() {
    return {
      last: this.last,
      kind: this.kind,
      departedTurn: this.departedTurn,
      blockedCount: this.blockedCount,
    };
  }

  static restore(value) {
    const state = new TmuxTurnState();
    if (value && typeof value === "object") {
      if (value.last && Number.isSafeInteger(value.last.turn) && value.last.turn >= 0) {
        state.last = {
          turn: value.last.turn,
          word: typeof value.last.word === "string" ? value.last.word : null,
        };
      }
      state.kind = typeof value.kind === "string" ? value.kind : null;
      state.departedTurn = Number.isSafeInteger(value.departedTurn) && value.departedTurn >= 0 ? value.departedTurn : null;
      state.blockedCount = wholeNumber(value.blockedCount);
    }
    return state;
  }
}

export function foldTmuxPane(turns, pane) {
  turns.noteSample(pane.status, pane.isDead ? null : pane.agentKind);
}

export function tmuxDecisionSignature(pane, turns) {
  const status = turns.agentStatus;
  return JSON.stringify([
    turns.kind,
    status,
    status === "blocked" ? turns.blockedCount : 0,
    turns.last?.turn ?? 0,
    turns.ended?.turn ?? null,
    pane.sessionName ?? "",
  ]);
}

export function tmuxPaneInventory(panes) {
  const inventory = new Map();
  for (const pane of panes) inventory.set(pane.paneID, pane);
  return inventory;
}
