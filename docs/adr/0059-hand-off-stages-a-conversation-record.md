---
status: proposed
---

# Hand Off stages a conversation record for the user to send

Issue #766 asks for a way to give one Agent's work to another: to take it
over or to be consulted about it, in a new Agent or one already running. Its
two references, herdr-catchup and Orca, do the same thing underneath: they
condense the first Agent's conversation and make it the other Agent's first
input.

Three routes were open.

1. **Invoke herdr-catchup's plugin action.** herdr's `plugin.action.invoke`
   takes an action id and a context, and no arguments, so a target picked on
   the phone cannot reach it, and its own picker opens in the TUI.
2. **Run the `catchup` command on the Host.** The feature would exist only
   on a herdr Host where the user installed a third-party binary.
3. **Build it in Heeler.** Chat already reads the Transcript of every
   program it supports ([ADR 0024](0024-native-chat-from-agent-transcripts.md)),
   and the Composer already stages a file on the Host and puts its path in a
   draft ([ADR 0006](0006-stage-images-over-sftp.md)).

The maintainer chose the third on 2026-11-19.

## Decision

- **Hand Off writes a conversation record.** It is a Markdown file rendered
  from what Chat read of the Transcript: the user's messages, the Agent's
  replies, plans, questions with their answers, the tool calls that changed a
  file, and the ones that failed, were declined or were interrupted. Tool
  output and reasoning are left out. The record names the Agent, its
  directory and the Transcript's path, so the Agent that gets it can read
  what the record leaves out, and it says of itself that it is a record and
  not a list of instructions.
  - It keeps the newest 120,000 characters and says so when earlier messages
    are missing.
  - Chat opens on a conversation's tail. Before the record is written, the
    Agent's Chat reads earlier pages the way an open Chat does, until they
    fill a record, the conversation's start is reached, or twelve seconds
    pass. Those pages stay loaded in that Chat.
- **The record reaches the other Agent as a Staged File.** Heeler writes it
  into protected temporary storage on the device and hands it to the
  receiving Agent's Composer staging, the seam **Add File** uses, which
  uploads it to that Host and inserts its path. Nothing new writes on a Host.
  What is new is the file: until now Heeler staged only a file the user
  picked, and this one Heeler generates, each time the user asks for it by
  choosing a target.
- **Nothing is sent.** A message that asks the Agent to read the record goes
  into its Composer, below any draft already there, and the record's path
  follows it. The user reads it, rewords it, and sends it or does not, which
  is ADR 0006's rule that the app never presses Send for the user.
- **Take Over and Second Opinion differ only in that message.** One asks the
  Agent to carry the work on, the other to say what it would challenge and
  do differently. The message is read by a program, so it is English and not
  localized ([ADR 0041](0041-localize-display-text-where-it-is-created.md)).
- **A target is another Agent on the same Server, or a new one.** The record
  names paths on its Host, and a new Agent starts beside the one handed off,
  in its directory, through the New Agent form where the Server starts
  Agents. The record is written before that form opens, so a conversation
  that cannot be handed off says so before an Agent is started for it.
- **It is offered where it can work:** for a live Agent whose program Chat
  reads, on a Host that takes uploads, from the Agent's row menu and the
  More menu at the top of its detail.

## Consequences

- Hand Off works on every Server Kind that has Chat and uploads, with
  nothing installed on the Host. A record is as good as Chat's reading of
  that program's Transcript.
- A record holds whatever the conversation said, in a file under the
  Host's temporary directory with the permissions and lifetime of any Staged
  File: Heeler does not remove it. On the device, records older than an
  hour are removed when the next one is written.
- Staging copies the inserted path to the clipboard, as it does for a file
  the user adds, replacing what was there.
- A Second Opinion stays in the Agent that gave it. Heeler does not carry an
  answer back to the first Agent; the user hands that conversation off in
  turn, or copies from it.

## Considered Options

- **Put only the Transcript's path in the draft.** Nothing would be written
  on the Host, but a raw Transcript is large, full of tool output, and in a
  format that belongs to the first Agent's program.
- **Send the message at once.** Rejected for ADR 0006's reason, and because
  the user should see what one Agent is about to be told about another's
  work.
- **Offer Agents on other Hosts.** The upload would reach them, but the
  directory and Transcript the record names would not exist there.
