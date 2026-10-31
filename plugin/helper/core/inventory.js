// The Terminals a core reports, by address: built from a snapshot, kept current
// by events. A federated address belongs to another machine and stays out.

const isFederated = (address) => address.includes("/");

/** Throws on a snapshot the protocol does not allow, so its connection ends. */
export function buildInventory(terminals) {
  if (!Array.isArray(terminals)) throw new Error("A snapshot holds no terminals.");
  const inventory = new Map();
  for (const record of terminals) {
    if (typeof record?.address !== "string" || record.address === "") {
      throw new Error("A snapshot's Terminal has no address.");
    }
    if (!isFederated(record.address)) inventory.set(record.address, record);
  }
  return inventory;
}

export function isLocalTerminal(address) {
  return !isFederated(address);
}

/** What an event changes in a Terminal's record, as the core's own record would hold it. */
function patchFor(type, data) {
  switch (type) {
    case "size":
      return { cols: data.cols, rows: data.rows };
    case "title":
      return { title: data.title };
    case "foreground":
      return { foreground: data };
    case "status":
      return { status: data.status, records: data.records, reported: data.reported };
    case "turn":
      return { turn: data.turn };
    case "labels":
      return { labels: data.labels };
    case "keep":
      return { keep: data.keep };
    case "lost":
      return { pid: null, foreground: null, reason: data.reason ?? "lost" };
    case "finished":
      return {
        state: "finished",
        pid: null,
        foreground: null,
        reason: data.reason,
        exit_code: data.exit_code,
        signal: data.signal,
        finished_ms: data.finished_ms,
      };
    default:
      // A kind this Helper does not know changes nothing it reads.
      return null;
  }
}

export function applyEvent(inventory, { type, terminal, data }) {
  if (type === "created" || type === "restarted") {
    inventory.set(terminal, data);
  } else if (type === "removed") {
    inventory.delete(terminal);
  } else {
    const record = inventory.get(terminal);
    const patch = patchFor(type, data);
    if (record !== undefined && patch !== null) inventory.set(terminal, { ...record, ...patch });
  }
}
