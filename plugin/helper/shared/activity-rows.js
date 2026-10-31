// Per-device Agent List Fields, resolved by the app before registration.
import { optionalText } from "./display-text.js";

const BUILTINS = new Set([
  "state_icon", "state_text", "workspace", "tab", "pane", "agent",
  "terminal_title", "terminal_title_stripped", "host", "status", "directory",
]);
const GRAPHEMES = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const COLOR = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

/** Malformed layouts leave older senders' identity rendering intact. */
export function parseActivityRowLayout(value) {
  if (!value || !Array.isArray(value.rows) || value.rows.length > 3) return null;
  const rows = [];
  for (const row of value.rows) {
    if (!Array.isArray(row) || row.length > 16) return null;
    const fields = [];
    for (const field of row) {
      if (!field || typeof field.token !== "string") return null;
      if (!BUILTINS.has(field.token) && !/^\$[A-Za-z0-9_-]{1,32}$/.test(field.token)) return null;
      const entry = { token: field.token };
      if (field.fg != null) {
        if (typeof field.fg !== "string" || !COLOR.test(field.fg)) return null;
        entry.fg = field.fg;
      }
      for (const key of ["bold", "dim"]) {
        if (field[key] != null) {
          if (typeof field[key] !== "boolean") return null;
          entry[key] = field[key];
        }
      }
      fields.push(entry);
    }
    rows.push(fields);
  }
  return { rows };
}

/** Same single-glyph fallback as Agent.strippedSidebarTitle. */
function strippedSidebarTitle(raw) {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  const [first] = [...trimmed];
  if (!first) return trimmed;
  const scalar = first.codePointAt(0);
  if (!(scalar >= 0x2800 && scalar <= 0x28ff) && !"·✢✳✶✻✽◐◓◑◒".includes(first)) return trimmed;
  const rest = trimmed.slice(first.length);
  return rest.length === 0 || /^\s/u.test(rest) ? rest.trim() : trimmed;
}

function rowText(text) {
  return Array.from(GRAPHEMES.segment(text), ({ segment }) => segment).slice(0, 80).join("");
}

export function renderActivityRows(layout, agent, { hostName, workspaceLabels, tabs, panes }) {
  if (layout === null) return null;
  const tab = tabs.get(agent.tab_id);
  const pane = panes.get(agent.pane_id);
  const matchingTab = tab?.workspace_id === agent.workspace_id ? tab : null;
  const matchingPane = pane?.workspace_id === agent.workspace_id && pane?.tab_id === agent.tab_id ? pane : null;
  const value = (token) => {
    switch (token) {
      case "workspace": return workspaceLabels.get(agent.workspace_id);
      case "tab": return matchingTab && (matchingTab.count > 1 || matchingTab.label !== String(matchingTab.position)) ? matchingTab.label : null;
      case "pane": return agent.title ?? matchingPane?.label;
      case "agent": return optionalText(agent.display_agent) ?? optionalText(agent.name) ?? agent.agent ?? "unknown";
      case "terminal_title": return agent.terminal_title;
      case "terminal_title_stripped": return agent.terminal_title_stripped ?? strippedSidebarTitle(agent.terminal_title);
      case "host": return hostName.trim();
      case "status": {
        const status = agent.agent_status.toLowerCase();
        return status.charAt(0).toUpperCase() + status.slice(1);
      }
      case "directory": return typeof agent.cwd === "string" ? agent.cwd.trim() : null;
      default: return token.startsWith("$") ? agent.tokens?.[token.slice(1)] : null;
    }
  };
  return layout.rows.map((row) => {
    const spans = [];
    for (const field of row) {
      const raw = value(field.token);
      if (typeof raw !== "string" || !raw.trim()) continue;
      if (spans.length > 0) spans.push({ text: " · " });
      const span = { text: rowText(raw) };
      for (const key of ["fg", "bold", "dim"]) {
        if (field[key] !== undefined) span[key] = field[key];
      }
      spans.push(span);
    }
    return spans;
  }).filter((row) => row.length > 0);
}
