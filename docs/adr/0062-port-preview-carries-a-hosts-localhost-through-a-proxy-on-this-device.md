---
status: proposed
---

# Port Preview carries a Host's localhost through a proxy on this device

An Agent starts a development server and says where to look:
`http://localhost:4100/`. On the phone that link opened the browser, which
looked for the page on the phone. The page is on the Host, on an interface
only the Host reaches, and the user already holds an SSH connection that
could carry it.

A prototype settled what a web view allows. A `WKWebsiteDataStore` takes a
SOCKS5 `ProxyConfiguration` and sends it the requests whose host matches
`matchDomains`. The name `localhost` is carried that way; `127.0.0.1` and
`[::1]` are not, whatever the configuration says, and go to the device's own
loopback interface. App Transport Security loads `http://localhost` and
refuses `http` to a subdomain of it. The maintainer chose the shape on
2026-11-22: a link opens the page at once, the page is a sheet, and without a
link the way in is **Ports** in the More menu.

## Decision

- **Port Preview belongs to the Host.** It opens from an Agent or a terminal,
  as Files does, and reaches any port on the Host's loopback interface that
  the Host's account can connect to. It never claims "this Agent's server":
  Ports lists the programs working in the Agent's directory first and says
  nothing about who started them.
- **A link to the loopback interface opens here.** An `http` or `https` link
  to `localhost`, `127.0.0.1`, `[::1]` or `0.0.0.0`, in a Chat message, in a
  terminal's Links or asked for by the terminal itself, opens the preview.
  Every other link keeps going to the browser, and so does a link inside a
  previewed page that leaves the loopback interface.
- **The page loads under the name `localhost`.** That is the one name the web
  view sends to a proxy, so a link written with an address is rewritten to
  it, and the address bar shows `localhost:4100` on the Host's name.
- **A SOCKS5 proxy on this device carries that name and nothing else.** It
  listens on the device's loopback interface, on a port the system picks,
  for as long as the sheet is open. A client must present a username and
  password made at random for that preview. It serves CONNECT to `localhost`,
  `127.0.0.1` or `::1` and refuses every other name, address and command, so
  it is not a way onto the Host's network. `matchDomains` is `localhost`
  alone: a page's requests to the public internet leave the device as any
  app's do.
- **The Host's SSH server resolves `localhost`.** Each connection is a
  `direct-tcpip` channel to the name, not to an address. OpenSSH tries the
  IPv6 and the IPv4 loopback address in turn, and a development server often
  listens on only one.
- **The preview dials an SSH connection of its own.** It uses the Host's
  route, credentials and known host key through the same settings the Console
  dials with, and it carries only the preview: pages and the Ports read. It
  is dialed when the first page or the first look at Ports needs it and
  closed when the sheet closes. The Host's own connection carries terminal
  output and a Server's link, where a page's assets and a live-reload socket
  that never closes would sit in front of them.
- **Nothing is cancelled inside a channel open.** A web view drops requests
  whenever a page navigates. Each proxy connection runs in a task that ends
  by closing, never by cancellation, and a dial runs in a task of its own.
  A channel open cancelled part-way keeps the session's open slot until the
  Host answers, and costs the whole SSH session when the answer takes more
  than two seconds (#824), which a slow link makes of every dropped request.
- **Website data lives as long as the sheet.** The store is not persistent.
  Every Host has a `localhost`, and a cookie one Host's page set must not go
  to another's.
- **A certificate for `localhost` is accepted.** A development server's
  certificate is its own, or from an authority only that machine trusts. The
  page arrived through an SSH connection whose host key this device checked,
  to that Host's own loopback interface. Every other name keeps the system's
  judgment.
- **A failure says which of three things happened.** Nothing listening on
  the port, the SSH server refusing to forward (`AllowTcpForwarding`), or the
  Host out of reach. The proxy remembers a port's last failure for 15 seconds
  so the page that failed can say it, since a SOCKS reply reaches the web
  view only as a generic error. A page that failed after its connection was
  made over `http` offers **Try HTTPS**: a port chosen by its number is tried
  over plain HTTP first.
- **A lost connection is dialed again.** A channel that fails because the
  connection is gone gets one silent redial. A refusal to forward drops the
  connection, because an SSH server reads its settings when a connection
  starts. When the connection under the pages ends, the page dims, the sheet
  says it is reconnecting, dials wait from one second up to fifteen, and the
  page reloads when the Host is back. The Console's own connection going
  away is a reason to ask the preview's one small question; its return is
  the moment to dial.
- **Ports is one bounded read.** A script prints `ss -ltnp` on Linux or
  `lsof` elsewhere, and the working directories of the listening processes,
  between markers; the device decides what it means. It runs on the
  preview's connection, with a 12 second deadline, 256 KiB of output and 200
  ports at most, when the list first shows and when asked. Only listeners a
  connection to `localhost` reaches are listed. Nothing is installed, and
  the read is the same on every Server Kind, a Rex Host included, where it
  is one more bounded read-only exec of the kind
  [ADR 0056](0056-rex-agents-open-the-agent-detail-with-chat.md) allows.
- **The sheet closes by its button.** While a page shows, pulling down
  scrolls the page and does not dismiss the sheet, which would throw away
  the page and its connection.
- **A picture of the page can go to the Agent.** Send Screenshot to Agent
  closes the sheet and stages the visible page as an image in the Agent's
  message. Nothing is sent until the user sends it. It is offered where the
  Composer takes images, not from a Shell Terminal or under Direct Input.
- **Offered on macOS and Linux Hosts.** Every Server Kind there. A native
  Windows Host is left out until it has been tried on one.

## Considered options

- **A listener on the same port of the phone, and the browser.** What
  `ssh -L` does. The origin stays `localhost:4100` in any browser, which
  keeps a sign-in redirect working. The port may be taken on the phone, iOS
  suspends Heeler while the browser is in front so the tunnel stops with no
  place to say so, and the Host's name is nowhere on screen. It can be added
  beside the preview later.
- **A proxy that serves the page under another port or name.** The origin
  changes, and with it absolute links, live-reload sockets, CORS rules and
  redirect addresses.
- **The Host's own SSH connection.** No second dial. Pages would hold the
  connection the terminal's output waits on, as Files measured for a
  download ([ADR 0059](0059-files-reads-a-hosts-folders-and-changes-nothing.md)),
  and a preview's failure could cost the Console its link.
- **A custom URL scheme handler.** `WKURLSchemeHandler` does not take `http`
  or `https`, and carries no WebSocket.
- **Sending everything through the Host.** The phone would browse from the
  Host's network. That is a different feature with a different risk.
- **Keeping sign-ins per Host.** A persistent store for each Host would
  survive the sheet. It needs a place to see and clear what is kept.
- **Asking each Server for its ports.** herdr, tmux and Rex do not report
  them, and one exec reads the same on all of them.

## Consequences

- Each open preview is a second authenticated SSH connection to the Host. It
  counts toward the server's connection limits, and a route through a Jump
  Host or an Overlay Network is dialed again.
- A Host whose SSH server forbids forwarding shows no pages. The sheet names
  the setting.
- Whoever holds the unlocked app reaches every program listening on the
  Host's loopback interface, a database's admin page as much as a
  development server. The same person could already type in a terminal
  there.
- Only the page's address is rewritten. A page that asks for
  `http://127.0.0.1:4100/api` by address from its own script asks the phone.
- A subdomain of `localhost` does not load, and a server bound only to a LAN
  address is neither listed nor reached.
- Sign-ins and other website data are gone when the sheet closes.
- A page's `alert`, `confirm` and `prompt` dialogs do not show.
- The check that a connection still answers waits four seconds. A Host
  slower than that gets a new connection it did not need.
- Ports shows what the account may see. On Linux a port another account's
  program holds is listed as an unknown program.
- iOS suspends the app in the background, and the proxy and the connection
  with it. Coming back within a few seconds kept the page; a longer absence
  is expected to end in the reconnect above and has not been tried.
- Tried in the Simulator on an iPhone (iOS 27.0) and an iPad (iOS 26.5)
  against a Herdr TUI Host on macOS. Not tried on a device, on iOS 18,
  against the other Server Kinds or a Linux Host's `ss`, whose output is
  covered by the parser's test only.
