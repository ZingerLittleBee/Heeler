---
status: proposed
---

# Plugin and Helper updates show on the Hosts tab and run together

Each Server Kind keeps something of Heeler's on the Host: a Herdr TUI Server
the Heeler plugin, a herdr-core or tmux Server the Host Helper. An app update
can carry a newer one, and the only place that said so was the Server's own
page, two taps under Host detail, read when that page opened. A Host nobody
opened stayed on the old version, and with several Hosts each update was its
own visit, its own sheet and its own tap.

## Decision

- **One read as a Server connects.** When a Server's connection comes up,
  Heeler asks it once what it holds, over the Console's connection: a Herdr
  TUI Server its plugin, and a Host its Helper through one of its herdr-core
  or tmux Servers. Servers already in reach at launch are asked then. The
  answer is kept in memory until the next read, and a Server's page that reads
  or changes its plugin or Helper passes that on. Nothing polls.
- **Where an older one shows.** A card above the Hosts list counts the updates
  and offers Update All, the Hosts tab carries the count as a badge (the
  sidebar's Hosts icon on iPad), and the Host's row carries a tag. The card
  and the tag open Updates, a page that lists every Host with something to
  update. Host detail lists the Host's plugins and Helper with their versions
  whether or not they are current, and the rows on a Server's page carry the
  same mark.
- **One prompt for each pair of versions.** After an app update whose bundled
  plugin or Helper version changed, Updates is put up once as a sheet, when
  Hosts read in the first half minute of that launch hold older ones. Once
  shown, it is not shown again for those versions, whatever the user did with
  it. A launch that found no Host behind leaves the question to the next. It
  waits for a window with nothing presented over it and only shows over a
  list or a tab's own page.
- **Update All runs without the sheet.** ADR 0027 made the tap the
  confirmation because the sheet shows the exact commands above it, and ADR
  0033 has the Helper's sheet list every file before any is written. Update
  All shows neither. It covers only what those sheets already put on the
  Host once: a plugin that is enabled, installed from this repository, with
  a version herdr read from its manifest and older than the app's, and a
  Helper whose reading offers Update. A first install, a disabled plugin, a
  linked checkout, a plugin under its former id and a missing Helper are
  never changed from here and stay with their sheets on the Server's page.
- **Each update works from the Host as it is then.** An update dials a
  connection of its own, rereads the plugin or Helper, and runs only if that
  reading still offers the update, so one another device already made is
  read back as done. The plugin install keeps ADR 0027's checks against a
  newer plugin and an unreadable branch. A Host key that still needs trusting
  is declined, not asked about. Hosts update side by side; one Host's updates
  run in turn.
- **A failure is said three ways and never retried unasked.** One failure
  stops no other update. What the Host reads afterwards has the last word:
  an update that reported a failure and left the Host current took.
  - *Nothing changed*: the update stopped before it wrote, and the row says
    why in the Host's or Heeler's own words.
  - *No answer*: the connection ended or the Host took too long. Heeler
    waits three seconds and reads the Host once more. Current reads as
    updated; older says the update may still finish there; unreadable says
    to try again once the Host is connected.
  - *Damaged*: a Helper update left files that do not stand. The row offers
    Repair, which installs over them without the file list, since the files
    are the ones the update was already writing.

  A failed row keeps Try Again, and its detail page shows what the Host said
  with Copy Details. The card and the badge then say that updates failed
  until the user retries or the Host reads current. Under a Host with a
  failed update, and on that update's detail page, a link opens the user
  guide's steps for updating on the Host itself (`docs/guides/updates.md`),
  in Simplified Chinese when the app shows that and in English otherwise.

## Why

- The versions an app carries change only with an app update, so the moment
  to ask is the first launch after one, and the moment to read is when a
  Server is connected anyway. A read costs one request on a connection that
  is already open.
- The count on the tab is what makes a Host nobody opens visible. The prompt
  alone would be missed by a Host that was offline at that launch, and the
  card alone by a user who lives on the Agents tab.
- The sheets guard the first write to a Host: which commands, which files,
  where. An update writes the same things to the same places under a newer
  version, and asking for a read of each across several Hosts is what kept
  them from being updated at all.
- An update whose answer never arrived may or may not have been applied.
  Calling it failed invites a second install over a running one, and calling
  it done hides a Host still behind. One more read usually settles it, and
  when it does not the row says which of the two is not known.

## Considered options

- **A badge on each Host row only.** No count where the user is, and no way
  to update several Hosts at once.
- **A row in Settings.** Out of sight until looked for, which is the problem
  this started from.
- **Polling the Hosts for their versions.** The versions change when the app
  does or when someone updates a Host, and both are covered by reading on
  connect and after each action.
- **Update All behind one confirmation that lists every command and file.**
  A long sheet nobody reads, for writes each Host's own sheet already
  showed.
- **Retrying a failed update on the next connect.** A Host that fails for a
  standing reason would be written to on every launch without being asked.

## Consequences

- An update from Updates or Update All shows no commands and no file list.
  The Server's page still does for the same update.
- Each connect of a Herdr TUI Server makes one `plugin.list` request more,
  and each connect of a herdr-core or tmux Server one Helper read more, one
  for the Host when its Servers connect together.
- A Host that is not connected at launch gets no prompt, only the card, the
  badge and its tag once it connects.
- What was read is not stored. After a launch the card and the badge are
  empty until the Servers have connected and answered.
- A Host whose plugin or Helper is missing, disabled or newer than the app
  is not counted as an update. Host detail lists it, and its Server's page
  explains it.
- An update that ends without an answer is concluded after one more read. A
  slow install that finishes later shows as current at the next read.
- Released apps link to headings of the updates guide by their anchors, so
  those headings keep their wording in both languages, and the guide has to
  be published before a build with the link reaches users.
