// Homepage copy shared by its sections. The FAQ also feeds the page's JSON-LD,
// so its answers are the exact HTML the page shows.

/** A step of the pinned story: one screenshot, one claim. The heading's second clause is dimmed. */
export const steps = [
  {
    screen: 'console',
    label: 'Console',
    lead: 'Sorted by',
    dim: 'who needs you.',
    body: 'Every Agent on every machine in one live list. Blocked comes first, so the one waiting on you is the first thing you see.',
  },
  {
    screen: 'chat',
    label: 'Chat',
    lead: 'Answer',
    dim: 'in one tap.',
    body: 'Read the conversation as native messages and answer a Blocked Agent with one tap. Works with Claude Code, Codex and five more.',
  },
  {
    screen: 'live-terminal',
    label: 'Terminal',
    lead: 'The real terminal',
    dim: 'when it matters.',
    body: 'Open the same Agent in its real terminal, rendered by libghostty, with a keyboard built for control keys. One switch.',
  },
  {
    screen: 'live-activity',
    label: 'Away',
    lead: 'Know the second',
    dim: 'it stops.',
    body: 'When an Agent goes Blocked or Done, you get an end-to-end encrypted push. A Live Activity keeps every Agent on your Lock Screen and in the Dynamic Island.',
    note: 'Notification bodies and Agent details stay end-to-end encrypted; Live Activity counts and delivery metadata pass through the relay.',
  },
  {
    screen: 'usage',
    label: 'Usage',
    lead: 'See the limit',
    dim: 'before you hit it.',
    body: 'Claude Code, Codex, and Antigravity CLI Usage Limits with reset times, 30-day tokens, and estimated API cost on macOS and Linux Hosts (herdr, herdr-core, tmux), plus Home and Lock Screen widgets.',
  },
] as const;

export type Screen = (typeof steps)[number]['screen'];

export const backends = [
  {
    name: 'Herdr TUI',
    body: 'Pair by QR code on macOS and Linux, or add a Windows machine manually.',
    runs: 'macOS, Linux, Windows',
    guide: { label: 'Pairing guide', slug: 'pairing' },
    windows: true,
  },
  {
    name: 'Herdr desktop',
    body: 'Follows your spaces and tabs.',
    runs: 'herdr-core on macOS, Linux, Windows',
    guide: { label: 'herdr-core guide', slug: 'herdr-core' },
    windows: true,
  },
  {
    name: 'tmux',
    body: 'Sessions, windows and panes, alongside your desktop terminal.',
    runs: '3.3 or newer on macOS and Linux',
    guide: { label: 'tmux guide', slug: 'tmux' },
    windows: false,
  },
  {
    name: 'Rex',
    body: 'Sessions, windows and terminals, in the same console.',
    runs: 'macOS, Linux, Windows',
    guide: { label: 'Rex guide', slug: 'rex' },
    windows: true,
  },
];

/** Agents whose conversations Chat can read. */
export const agents = ['Claude Code', 'Codex', 'Pi', 'Oh My Pi', 'Grok Build', 'OpenCode', 'Antigravity CLI'];

export const overlays = ['Tailscale', 'ZeroTier', 'EasyTier', 'tailcat'];
export const routes = ['Direct', 'Tailscale', 'Jump Host'];

export const privacy = [
  'Plain SSH, straight to your Host. Your code never passes through us.',
  'The Device Key is generated on your phone and stays in the Keychain.',
  'Notification bodies and per-Agent details stay end-to-end encrypted; the relay sees APNs and request routing metadata plus unencrypted Live Activity counts, events, and timestamps.',
  'Open source, Apache-2.0.',
];

/** The two commands that pair a Herdr TUI machine on macOS or Linux. */
export const pairCommands = ['herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes', 'herdr plugin action invoke heeler.pair'];

export const faq = [
  {
    q: 'What do I need on the machine?',
    a: 'SSH turned on, plus one of: herdr 0.7.5 or newer, the Herdr desktop app or herdr-core, tmux 3.3 or newer, or a running Rex server.',
  },
  {
    q: 'Do I have to switch to herdr?',
    a: 'No. If you live in tmux, Heeler connects to your running tmux server.',
  },
  {
    q: 'Does my code go through your servers?',
    a: 'No. Heeler talks to your machine over SSH. Notification bodies and per-Agent details stay end-to-end encrypted before reaching the push relay; the relay sees the APNs and request routing metadata needed for delivery, along with unencrypted Live Activity summary counts, events, and timestamps.',
  },
  {
    q: 'Which agents work?',
    a: 'Chat supports Claude Code, Codex, Pi, Oh My Pi, Grok Build, OpenCode and Antigravity CLI. The live terminal shows whatever your Agent runs.',
  },
  {
    q: 'Does it work on iPad?',
    a: 'Yes, with Magic Keyboard shortcuts, multiple windows, and drag and drop. <a href="/ipad">See the iPad screenshots</a>.',
  },
  {
    q: 'Is Heeler an official Claude Code, Codex, or herdr app?',
    a: 'No. Heeler is independent and open source. It is not affiliated with Anthropic, OpenAI, or the herdr project.',
  },
];
