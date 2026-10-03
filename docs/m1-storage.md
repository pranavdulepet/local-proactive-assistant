# Milestone 1 storage slice

Milestone 1 establishes one local evidence path for Messages, Calendar, and Contacts before adding model inference.

## Included

- append-only, versioned observations;
- idempotency by source, external ID, and version hash;
- monotonic source revisions so delayed older versions cannot become current;
- a current-version head for each source record;
- tombstones that remove deleted records from current search results;
- SQLite FTS5 lexical search with optional source filtering;
- WAL mode and owner-only filesystem permissions for file-backed stores;
- resumable, read-only Messages catch-up through `imsg messages.after`;
- atomic observation and source-cursor commits, including empty pages;
- one-to-one iMessage and SMS filtering with groups and the control chat excluded;
- owner, known-external, and unknown-external trust labels.
- read-only EventKit ingestion for events from 90 days ago through 365 days ahead;
- Calendar titles, times, calendar names, locations, organizers, attendee identifiers,
  recurrence descriptions, status, and notes normalized as structured-source observations;
- stable per-occurrence IDs and deterministic recurrence serialization across refreshes;
- read-only unified Contacts snapshots with normalized names, phone numbers, emails,
  organizations, and roles;
- deletion tombstones for full-access Contacts snapshots, without treating hidden contacts
  as deleted when access is partial.
- normalized phone/email handles attached to current observations for exact cross-source joins;
- persisted source coverage with status, time bounds, last successful sync, cursor, and
  limitations;
- deterministic exact contact resolution and upcoming meeting-context evidence.
- typed commitment assertions with source-observation evidence links;
- a materialized open-commitment view with explicit completion and extractor-revision
  reconciliation state.

An observation records source text and provenance. It does not represent a trusted fact, commitment, preference, or assistant policy. Those require deterministic routing or a later typed assertion step.

## Deliberately deferred

- Calendar deletion reconciliation and coverage outside the bounded scan window;
- model-based commitment extraction and automatic completion detection;
- model inference;
- Mail and embeddings.

## Host checkpoint

The owner-control routes, opt-in proactive rule and automatic refresh are implemented.
The deterministic commitment path remains separate from meeting-context evidence. The next
planned slice is Mac local-model evaluation, not new source scaffolding. See [m1-host.md](m1-host.md).

Run a Messages catch-up manually with:

```bash
swift run assistantctl index-messages --control-chat-id <SELF_CHAT_ID>
```

The first run scans from the beginning of the current Messages database. Later runs resume from the persisted physical row cursor. Cursors belong to one `chat.db` instance and must be cleared if that database is replaced or restored.

Refresh the bounded Calendar window manually with:

```bash
swift run assistantctl index-calendar
```

The first run asks macOS for Calendar full access. Calendar notes are indexed as untrusted
source data, never as instructions. A refresh is idempotent for unchanged events and commits
the refreshed observations and scan cursor atomically. Deleted events are not tombstoned yet.

Refresh Contacts manually with:

```bash
swift run assistantctl index-contacts
```

The first run asks macOS for Contacts access. Later full-access snapshots tombstone contacts
that disappeared from the address book. Partial access is reported explicitly and never uses
absence as deletion evidence.

Inspect what each source can currently support:

```bash
swift run assistantctl source-status
```

Get the first deterministic meeting-context evidence bundle by exact contact name, nickname,
phone number, or email address:

```bash
swift run assistantctl meeting-context --person "Alex Rivera"
```

The command stops on ambiguous names rather than merging people or guessing. It returns the
next matching Calendar event and up to ten direct messages from the preceding 90 days. It does
not generate a model-written answer.

Extract the first deliberately narrow commitment schema from recent owner-authored messages:

```bash
swift run assistantctl index-commitments --days 30
swift run assistantctl forgetting
```

The rule matches only actionable `I'll`/`I’ll`/`I will` statements containing `today`,
`tonight`, `tomorrow`, or `this morning/afternoon/evening` in the committed clause.
Questions, negated statements, incoming messages, availability statements, hedged intent,
and statements without a supported time cue are excluded. This favors precision over recall
and does not claim to detect completion automatically. Extractor revisions are versioned; a
refresh atomically supersedes active results in the scanned window that the current revision
no longer emits, while preserving explicit completion state and immutable evidence.

Every listed item includes a stable ID. Inspect its source evidence or mark it complete with:

```bash
swift run assistantctl why --commitment <ID>
swift run assistantctl complete-commitment --commitment <ID>
```

Serve the same deterministic paths through the configured owner self-chat:

```bash
swift run assistantctl serve --control-chat-id <SELF_CHAT_ID>
```

The control chat accepts `/forgetting`, the exact natural-language question “What am I
forgetting?”, `/why <ID>`, `/done <ID>`, `/meeting <exact person>`, `/pause`, `/resume`,
`/status`, and `/help`. `/why` formats the stored assertion,
source excerpt, timestamp, conversation handle, locator, and current Messages coverage. It
does not ask a model to invent an explanation. Messages that are not commands advance the
durable cursor without receiving a reply.

`serve` also refreshes Messages/commitments every minute and Calendar/Contacts every 15 minutes.
Reminders are paused on first use. Coverage failures preserve the last successful sync time;
failed Messages refreshes suppress proactive dispatch. These are supervised foreground loops,
not boot-time services. Stop the host before running manual indexers or maintenance SQL.

Existing Messages observations predate handle provenance. After upgrading, clear only the
Messages source cursor and run the indexer once to append handle-aware versions while keeping
the old observations:

```bash
DB="$HOME/Library/Application Support/LocalProactiveAssistant/assistant.sqlite"
sqlite3 "$DB" "DELETE FROM source_cursors WHERE source = 'messages';"
swift run assistantctl index-messages --control-chat-id <SELF_CHAT_ID>
swift run assistantctl index-calendar
swift run assistantctl index-contacts
```
