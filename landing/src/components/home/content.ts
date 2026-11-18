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
    note: 'The relay only ever sees ciphertext.',
  },
  {
    screen: 'usage',
    label: 'Usage',
    lead: 'See the limit',
    dim: 'before you hit it.',
    body: 'Claude Code and Codex Usage Limits with their reset times, plus 30 days of tokens and estimated API cost across every Host. Widgets keep them on your Home and Lock Screen.',
  },
] as const;

export type Screen = (typeof steps)[number]['screen'];

export const backends = [
  { name: 'Herdr TUI', body: 'Pair by scanning a QR code.', runs: 'macOS, Linux, Windows' },
  { name: 'Herdr desktop', body: 'Follows your spaces and tabs.', runs: 'herdr-core on macOS, Linux, Windows' },
  { name: 'tmux', body: 'Sessions, windows and panes, alongside your desktop terminal.', runs: '3.3 or newer on macOS and Linux' },
];

/** Agents whose conversations Chat can read. */
export const agents = ['Claude Code', 'Codex', 'Pi', 'Oh My Pi', 'Grok Build', 'OpenCode', 'Antigravity CLI'];

export const overlays = ['Tailscale', 'ZeroTier', 'EasyTier'];
export const routes = ['Direct', 'Tailscale', 'Jump Host'];

export const privacy = [
  'Plain SSH, straight to your Host. Your code never passes through us.',
  'The Device Key is generated on your phone and stays in the Keychain.',
  'Notifications are end-to-end encrypted. The relay sees ciphertext.',
  'Open source, Apache-2.0.',
];

/** The two commands that pair a Herdr TUI machine. */
export const pairCommands = ['herdr plugin install ZingerLittleBee/Heeler --ref plugin --yes', 'herdr plugin action invoke heeler.pair'];

export const faq = [
  {
    q: 'What do I need on the machine?',
    a: 'SSH turned on, plus one of: herdr 0.7.5 or newer, the Herdr desktop app or herdr-core, or tmux 3.3 or newer.',
  },
  {
    q: 'Do I have to switch to herdr?',
    a: 'No. If you live in tmux, Heeler connects to your running tmux server.',
  },
  {
    q: 'Does my code go through your servers?',
    a: 'No. Heeler talks to your machine over SSH. Notifications pass through a relay as ciphertext it cannot read.',
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
