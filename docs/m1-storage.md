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

An observation records source text and provenance. It does not represent a trusted fact, commitment, preference, or assistant policy. Those require deterministic routing or a later typed assertion step.

## Deliberately deferred

- Calendar deletion reconciliation and coverage outside the bounded scan window;
- commitment extraction;
- materialized commitment and meeting views;
- model inference;
- proactive sending;
- Mail and embeddings.

## Next slice

Expose source coverage and a deterministic “What am I forgetting?” query over the local observation store.

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
