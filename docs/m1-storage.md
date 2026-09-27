# Milestone 1 storage slice

The first Milestone 1 slice establishes one local evidence path for Messages, Calendar, and Contacts before adding source adapters or model inference.

## Included

- append-only, versioned observations;
- idempotency by source, external ID, and version hash;
- monotonic source revisions so delayed older versions cannot become current;
- a current-version head for each source record;
- tombstones that remove deleted records from current search results;
- SQLite FTS5 lexical search with optional source filtering;
- WAL mode and owner-only filesystem permissions for file-backed stores.

An observation records source text and provenance. It does not represent a trusted fact, commitment, preference, or assistant policy. Those require deterministic routing or a later typed assertion step.

## Deliberately deferred

- Messages history ingestion;
- EventKit and Contacts adapters;
- commitment extraction;
- materialized commitment and meeting views;
- model inference;
- proactive sending;
- Mail and embeddings.

## Next slice

Add a read-only Messages history adapter that converts one-on-one text messages into observations with stable GUID-based external IDs and explicit owner/external trust labels. It will write through `ObservationStore` and expose source coverage rather than querying the transport layer as a history database.
