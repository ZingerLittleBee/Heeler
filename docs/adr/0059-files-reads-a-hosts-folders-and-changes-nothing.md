---
status: proposed
---

# Files reads a Host's folders over SFTP and changes nothing

An Agent leaves things behind that the phone could not look at: a report, a
chart, a screen recording, a log. Changes shows only a Checkout's uncommitted
difference, Chat shows an image when a transcript names its path, and the
terminal shows text. Issue #772 asked for a read-only view of the Host's files
through the SFTP the Host already serves.

The reads existed. `HostServices` has `fileStatus`, `listFiles`,
`readHostFileRange` and `hostHomeDirectory` for Chat's transcripts, and every
Server Kind reaches them through `ConsoleStore.chatHostFiles(for:)`. The
maintainer chose the container on 2026-11-19: a sheet over the Agent detail,
one page per folder, previews full screen.

## Decision

- **Files belongs to the Host.** It opens from an Agent, in the Agent's
  directory, as Changes opens from an Agent and belongs to the Checkout. Any
  folder the Host's account can read is reachable from there. It never claims
  "the files this Agent made": an item changed in the last ten minutes is
  marked, and nothing says who changed it.
- **Read-only, through the reads Chat has.** Files stats, lists and reads
  ranges through `ChatHostFiles`. It adds no transport call, runs nothing on
  the Host, installs nothing, and never writes, renames or deletes there.
  A Rex Host stays inside the reads [ADR 0056](0056-rex-agents-open-the-agent-detail-with-chat.md)
  allows.
- **One listing a folder, sorted on the device.** A page asks once for up to
  1,000 entries from a scan of up to 20,000, the most the reader gives, and
  sorts, filters and hides dot files from that. A folder that holds more says
  so. Nothing is searched below the folder showing.
- **A failed read is never repeated on its own.** A pull, Try Again and Check
  Again are the only repeats. On a Host without SFTP each attempt costs the
  Host's connection (#596), so the page says Files Unavailable and waits to
  be asked.
- **A reconnect reads the folder showing, once.** While the Host's connection
  is down a page keeps what it read, dimmed, and opens nothing; a pull does
  nothing, and a page opened then waits unread. When the connection returns,
  the folder on top is read: for the first time if it never was, again if it
  was showing a listing. Each listing that lands earns one such read, so a
  read that costs the connection is not what the next reconnect repeats. A
  failed page is left alone, Files Unavailable above all: its refused read is
  what replaced the connection.
- **Text is read in place.** A megabyte at a time, with Show End for a longer
  file. A file with no viewer of its own is text when its start reads as
  text.
- **Everything else is copied first, and the copy is kept.** The system's
  viewers and the share sheet read local files, so an image (up to 20 MiB,
  as Chat's preview), a video, a sound or a document (up to 64 MiB, as an
  upload) is copied to this device, and so is any file the user shares or
  saves. A text file read whole is kept the same way. Amended 2026-11-26:
  each copy used to go when its preview closed, so a video closed and opened
  again downloaded again.
- **A copy is found by what the Host says the file is.** `HostFileCache`
  keeps copies in `Caches/HostFiles`, by Host, path, and the size and
  modification time the Host reports. Opening a file still asks the Host for
  its status, and opens the copy when both match; a file written again
  downloads again, and its copy replaces the older one of that path. A copy
  not opened for 7 days goes, the least recently opened go past 500 MB, a
  Host's go when the Host is removed, and Settings shows their size with
  Clear Downloaded Files. A Host that reports no modification time keeps
  nothing: that copy goes when its preview closes. Chat's image reads, its
  thumbnails' included, and its video preview keep their copies in the same
  cache. A download that never finished goes when a later run of the app
  first prunes the cache.
- **A copy belongs to the Agents that opened it.** Each Host's
  `openers.json` names, by path, the terminal ids of the Agents whose Files
  or Chat opened the copy. Closing an Agent in Heeler (its pane or its tab)
  or removing its saved Chat takes its id away, and a copy no other Agent
  opened goes with it. Clear Chat Cache also clears every copy. An Agent
  that ends on the Host leaves its copies to the age and size limits, since
  its Chat may still be saved. Amended 2026-11-26.
- **A request that was asked is finished.** Cancelling stops Files between
  requests, never inside one. The Host's SFTP channel is shared, and a request
  dropped before the Host answers leaves its answer for the next request of
  its kind: with a throttled link, cancelling a download and opening another
  file showed the first file's size on the second.
- **A file comes in pieces sized to the link.** The Host has one connection,
  and a piece's bytes hold it while they cross: the terminal's output waits
  behind them, and a piece that needs longer than a request's 15 seconds never
  arrives. So a piece is what the link carried in about a second, as the
  pieces before it measured, between 32 KiB and 256 KiB. The first is 64 KiB,
  a faster link is believed a doubling at a time, and a piece that times out
  sends the next try back to 32 KiB. One piece measures roughly, so the pace
  moves halfway to each measure, except that a link found carrying under half
  of it is believed at once. The pace is kept while Files is open, so a second
  file starts where the first got to. It goes back to a first piece when the
  Host's connection is a new one, and a file that opens with round trips
  several times slower than the quickest seen starts no larger than that.
  Text past its first piece shows how far the read is, and a file that is not
  text is told from its first piece.
- **Offered on macOS and Linux Hosts.** Every Server Kind there. A native
  Windows Host is left out until Files has been tried on one.
- **A path can go back to the Agent.** Add Path to Message closes Files and
  puts the file's path in the message, from the Agent's directory when the
  file is under it.

## Considered options

- **A page pushed inside Agent detail.** It keeps the Agent's header in view
  and loses the Composer behind it for as long as the user browses. The
  maintainer chose the sheet, which closes back to where the user was typing.
- **Playing video from ranged reads without a copy.** A resource loader could
  feed the player as it seeks. Each seek would cost several round trips, and
  the code would be a second reader to keep. Under a 64 MiB limit the copy is
  simpler, and Share needs it anyway.
- **Listing with a command on the Host.** `ls` or `find` would sort and
  search there. It needs quoting, differs by platform and shell, and is an
  exec where SFTP already answers.
- **Watching a folder.** A timer would keep the list current while an Agent
  writes. It would poll a Host for as long as a sheet is open. Pull to
  refresh is asked for.
- **Retrying when SFTP is refused.** That is the loop #596 describes.
- **Removing each copy when its preview closes.** Nothing a user looked at
  stayed on the device, but every open downloaded the file again, however
  recently it had been shown. The cache bounds what stays by age and size,
  by the Agents that opened it, and Settings clears it.
- **Removing a copy with any Agent that opened it.** A file two Agents
  opened would download again for the one still open.
- **Fixing the dropped request in the transport.** A cancelled read could
  retire the SFTP channel, or the driver could drain the answer. That changes
  Chat's reads too and belongs to a change of its own. Files finishes its own
  requests in the meantime.

## Consequences

- A folder with more than 1,000 entries shows the first 1,000 by name of what
  the scan reached. Sorting by date or size orders those, not the folder.
- A large file over a slow link takes long. Each piece is a stat, an open,
  the read and a close of its own, about four round trips besides its bytes,
  and a slow link's small pieces pay them more often: at 15 kB/s with 200 ms
  each way a 539 kB video took 52 seconds. There is no resume: Cancel discards
  what arrived.
- The terminal still waits while a piece crosses: under a second at 250 kB/s,
  up to about two at 50 kB/s and at 15 kB/s, and nearly five for the first
  piece at 15 kB/s, before the link is known. A link too slow to carry 32 KiB
  within a request's deadline opens nothing larger than that.
- A request cancelled on a stalled link keeps the shared SFTP channel busy
  until it answers or its deadline passes. Chat's reads on that Host wait
  behind it.
- Chat still cancels its own reads mid-request. One dropped that way can hand
  its answer to a Files request, as it can to a later Chat read. Files' check
  that a file's length holds across its pieces catches a wrong size, not a
  wrong file.
- Files a user opened stay on the device after Files closes, for up to 7
  days since last opened and within 500 MB, and until the Agents that opened
  them are closed or removed in Heeler. They are excluded from backup
  and protected complete unless open: a download goes on as the device
  locks, and a finished copy cannot be opened again until it unlocks. A file
  shared or saved leaves a copy wherever the user sent it, which Heeler does
  not manage.
- SFTP reports whole seconds. A file written again within the same second
  at the same length opens as the copy of the one before.
- Reopening a file still costs one status request, so it does not open
  while the Host is offline.
- A file of an image's name over 20 MiB has no preview and can still be
  shared or saved. A file over 64 MiB can only have its path copied.
- A path with a control character, or longer than 4,096 bytes, is listed and
  does not open (`RemoteFilePath.isAcceptable`).
- Go to Folder works a typed `..` out by name, as a shell's `cd` does, so it
  can differ from the Host's answer across a symbolic link.
- Each Check Again on a Host without SFTP replaces the Host's connection
  once. Opening Files there again does not: the Host's refusal stands for
  every connection to it until it is asked again (`HostSFTPRefusal`, #596).
- After a reconnect only the folder showing is current. The pages under it
  keep the listing they had until they are pulled, and a read that was in
  flight when the connection went ends as a failure with Try Again.
