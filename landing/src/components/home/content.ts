// Homepage copy shared by its sections. Copy changes should stay in sync
// with README.md at the repo root, where most of it comes from.

export const hero = {
  lede: 'Control Claude Code and Codex from your iPhone or iPad. Agents run on your own Hosts in <a class="text-link" href="https://herdr.dev">herdr</a>, <a class="text-link" href="https://docs.heeler.bybee.dev/herdr-core">herdr-core</a>, or <a class="text-link" href="https://docs.heeler.bybee.dev/tmux">tmux</a>; Heeler connects over SSH.',
};

export const consoleCopy = {
  body: 'Monitor multiple coding Agents across your machines in one live list, filterable by Host. Blocked Agents come first, so you can see who needs a reply without opening every terminal.',
};

export const steerCopy = {
  body: 'Send instructions to Claude Code or Codex from your iPhone or iPad, using the live terminal or <a class="text-link" href="https://docs.heeler.bybee.dev/chat">native Chat</a>. Draft locally with autocorrect, IME, or dictation, then send the complete message over SSH.',
};

export const connect = {
  lede: 'Heeler connects over SSH to Herdr TUI, the Herdr desktop app (<a class="text-link" href="https://docs.heeler.bybee.dev/herdr-core">herdr-core</a>), or a running <a class="text-link" href="https://docs.heeler.bybee.dev/tmux">tmux</a> server. SSH access plus your running server is the whole prerequisite.',
  pairNote:
    'The <span class="mono">pair</span> action opens a Pairing Code QR. Scan it and the machine is added as a Host. Nothing to type.',
};

export const path = [
  { node: 'Heeler.app', note: 'iPhone' },
  { node: 'jump host', note: 'optional · VPS loopback' },
  { node: 'sshd', note: 'stream-local forwarding' },
  { node: 'herdr.sock', note: 'ndjson rpc + events' },
  { node: 'agent pane', note: 'pty · takeover' },
];

export const pairLines = [
  '<span class="tk-comment"># on the machine running herdr</span>',
  '<span class="tk-fn">herdr</span> plugin install ZingerLittleBee/Heeler <span class="tk-string">--ref plugin --yes</span>',
  '<span class="tk-fn">herdr</span> plugin action invoke heeler.pair',
];

// The closing steps' commands, wrapped so every line fits a phone-width column.
export const addCommandLines = [
  '<span class="tk-fn">herdr</span> plugin install \\',
  '  ZingerLittleBee/Heeler \\',
  '  <span class="tk-string">--ref plugin --yes</span>',
  '<span class="tk-fn">herdr</span> plugin action invoke heeler.pair',
];

export const security = [
  {
    title: 'Device Key in the Keychain',
    body: 'An Ed25519 Device Key is generated on device during QR pairing; the private key stays in the Keychain, and the Pairing Code pins the host key fingerprint.',
  },
  {
    title: 'End-to-end encrypted notifications',
    body: 'The relay sees the device token, source IP, request timing, and ciphertext, but cannot read the notification.',
  },
  {
    title: 'Verified at both hops',
    body: 'Behind a Jump Host, host keys are verified independently at each hop.',
  },
  {
    title: 'No new surface area',
    body: 'No herdr server changes and no extra packages. The Host’s SSH server must permit stream-local forwarding, the OpenSSH default.',
  },
];

export const faq = [
  {
    q: 'What do I need on the machine?',
    a: 'An OpenSSH server enabled (on macOS: System Settings &gt; General &gt; Sharing &gt; Remote Login) plus herdr &gt;= 0.7.5 (with Node &gt;= 20 for pairing), herdr-core, or tmux &gt;= 3.3 on macOS or Linux.',
  },
  {
    q: 'Does it work on iPad?',
    a: 'Native iPad support is restored in 0.1.8, with Magic Keyboard shortcuts, multiple windows, and drag and drop. <a class="text-link" href="/ipad">See the iPad screenshots</a>.',
  },
  {
    q: 'What happens to the terminal I already had open?',
    a: 'On Herdr TUI, Attach and Reattach use takeover mode. On herdr-core and tmux Hosts, live terminals attach alongside your desktop terminal without disconnecting it.',
  },
  {
    q: 'Is Heeler an official Claude Code, Codex, or herdr app?',
    a: 'No. Heeler is an independent, open-source app on the App Store. It is not affiliated with Anthropic, OpenAI, or the herdr project.',
  },
  {
    q: 'Where can I read the design decisions?',
    a: 'In <span class="mono">docs/adr/</span>. The transport story in particular is not obvious.',
  },
];

export const source = {
  title: 'Open source, Apache-2.0.',
  lede: 'Heeler is built in public and shaped by daily driving. Clone it, run it on the simulator, and send back what breaks.',
  links: [
    { href: 'https://github.com/ZingerLittleBee/Heeler', label: 'Star on GitHub' },
    { href: 'https://github.com/ZingerLittleBee/Heeler/issues', label: 'Open an issue' },
    { href: 'https://github.com/ZingerLittleBee/Heeler/blob/main/CONTRIBUTING.md', label: 'Contributing guide' },
  ],
  buildLines: [
    '<span class="tk-comment"># run it on the simulator</span>',
    '<span class="tk-fn">brew</span> install xcodegen',
    '<span class="tk-fn">git</span> clone <span class="tk-string">https://github.com/ZingerLittleBee/Heeler</span>',
    '<span class="tk-fn">cd</span> Heeler &amp;&amp; <span class="tk-fn">make</span> sim',
  ],
};

export const links = {
  appStore: 'https://apps.apple.com/us/app/heeler-for-herdr/id6797263135',
  testFlight: 'https://testflight.apple.com/join/aXSxRn4r',
  setup: 'https://docs.heeler.bybee.dev/pairing',
};
