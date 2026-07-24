// Pure state for the popup's address checklist. The TUI in pair-popup.js is
// a thin render loop over these transitions, so selection behavior stays
// testable without a terminal.

/** @param {{address: string, preChecked: boolean}[]} candidates */
export function createSelection(candidates) {
  return {
    items: candidates.map((candidate) => ({ ...candidate, checked: candidate.preChecked })),
    cursor: 0,
  };
}

export function moveCursor(state, delta) {
  const cursor = Math.min(Math.max(state.cursor + delta, 0), state.items.length - 1);
  return { ...state, cursor };
}

export function toggleCurrent(state) {
  const items = state.items.map((item, index) =>
    index === state.cursor ? { ...item, checked: !item.checked } : item,
  );
  return { ...state, items };
}

export function toggleAll(state) {
  const checked = !state.items.every((item) => item.checked);
  return { ...state, items: state.items.map((item) => ({ ...item, checked })) };
}

export function selectedAddresses(state) {
  return state.items.filter((item) => item.checked).map((item) => item.address);
}
