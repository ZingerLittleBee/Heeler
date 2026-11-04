// The table of contents beside each page, built from the headings Astro's
// render() reports. Step headings get Fumadocs' numbered TOC circles.

import type { TOCItemType } from 'fumadocs-core/toc';

/** A heading as Astro's `render()` reports it. */
export interface RenderedHeading {
  depth: number;
  slug: string;
  text: string;
}

/** The "1. ", "Step 1: ", "Phase 1: ", "步骤 1：", or "阶段 1：" that starts a numbered step heading. */
const stepPrefix = /^(?:(?:(?:Step|Phase)\s+)?\d+[.:]\s+|(?:步骤|阶段)\s*\d+(?:[.:]\s+|：\s*))/;

/**
 * The step number of each step heading, keyed by heading id, from a guide's
 * `frontmatter.steps` (set by the Markdown pipeline). Anything else is ignored.
 */
export function stepNumbers(value: unknown): ReadonlyMap<string, number> {
  const steps = new Map<string, number>();
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return steps;
  for (const [id, step] of Object.entries(value)) {
    if (typeof step === 'number' && Number.isInteger(step) && step > 0) steps.set(id, step);
  }
  return steps;
}

/**
 * TOC entries for every heading below the page title. A step heading shows its
 * number in a circle, so its title drops the number written in the text.
 */
export function tableOfContents(
  headings: readonly RenderedHeading[],
  steps: ReadonlyMap<string, number> = new Map(),
): TOCItemType[] {
  return headings
    .filter((heading) => heading.depth > 1)
    .map((heading) => {
      const item = { depth: heading.depth, url: `#${heading.slug}`, title: heading.text };
      const step = steps.get(heading.slug);
      return step === undefined ? item : { ...item, title: heading.text.replace(stepPrefix, ''), _step: step };
    });
}
