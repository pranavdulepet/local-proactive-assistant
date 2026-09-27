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
- one-to-one iMessage filtering with the control chat excluded;
- owner, known-external, and unknown-external trust labels.

An observation records source text and provenance. It does not represent a trusted fact, commitment, preference, or assistant policy. Those require deterministic routing or a later typed assertion step.

## Deliberately deferred

- EventKit and Contacts adapters;
- commitment extraction;
- materialized commitment and meeting views;
- model inference;
- proactive sending;
- Mail and embeddings.

## Next slice

Add read-only EventKit and Contacts adapters, then expose source coverage and a deterministic “What am I forgetting?” query over the local observation store.

Run a Messages catch-up manually with:

```bash
swift run assistantctl index-messages --control-chat-id <SELF_CHAT_ID>
```

The first run scans from the beginning of the current Messages database. Later runs resume from the persisted physical row cursor. Cursors belong to one `chat.db` instance and must be cleared if that database is replaced or restored.
