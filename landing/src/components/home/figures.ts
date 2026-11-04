// Interactive figures in public/figures/. Each card fills its iframe, so the
// frame reproduces the card's own height from the drawing's viewBox ratio and
// the card's padding: wide, and below 560px with the narrow padding and, where
// the figure has one, its cropped viewBox. Pairing and the Call Board bleed 6%
// past each side of the card's padding when narrow, hence the 1.12.
//
// The card switches to narrow padding at 560px but to its narrow drawing
// later: the bleed figures at a 520px viewport, the cropping ones when the
// stage (frame minus 24px of padding) drops under 520px, that is 544px.
export interface FigureEmbed {
  slug: string;
  label: string;
  ratio: number;
  narrowRatio: number;
  narrowBottom: number;
  stageCrop: boolean;
}

export const figures = {
  callBoard: {
    slug: 'call-board',
    label: 'Interactive figure: the Console sorted by who needs you',
    ratio: 400 / 600,
    narrowRatio: (400 / 600) * 1.12,
    narrowBottom: 88,
    stageCrop: false,
  },
  pairing: {
    slug: 'pairing',
    label: 'Interactive figure: pairing a phone with a Host',
    ratio: 400 / 600,
    narrowRatio: (400 / 600) * 1.12,
    narrowBottom: 88,
    stageCrop: false,
  },
  routes: {
    slug: 'routes',
    label: 'Interactive figure: Heeler racing a Host’s Routes',
    ratio: 320 / 600,
    narrowRatio: 293.22 / 471.32,
    narrowBottom: 78,
    stageCrop: true,
  },
  compose: {
    slug: 'compose',
    label: 'Interactive figure: writing and sending a draft from the Composer',
    ratio: 320 / 600,
    narrowRatio: 211.47 / 281.47,
    narrowBottom: 78,
    stageCrop: true,
  },
  away: {
    slug: 'away',
    label: 'Interactive figure: sealed notifications while you are away',
    ratio: 400 / 600,
    narrowRatio: 315.09 / 392.44,
    narrowBottom: 78,
    stageCrop: true,
  },
  changes: {
    slug: 'changes',
    label: 'Interactive figure: reading a Checkout’s changes on the Host',
    ratio: 340 / 600,
    narrowRatio: 271.98 / 279.62,
    narrowBottom: 78,
    stageCrop: true,
  },
} satisfies Record<string, FigureEmbed>;
