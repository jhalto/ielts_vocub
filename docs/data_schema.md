# Firestore contract, schema version 1

All direct Firestore writes remain denied to clients. Phase 2 accountApi initializes/updates own profiles using authenticated server-derived identity. Rules permit only the reads below. Future trusted Functions must enforce exact field allowlists, enums, payload bounds, authentication, authorization and timestamps; Admin SDK bypasses rules. Models validate decoding, not server authorization. Constructor-created values still require server validation.

| Path | Contract | Client reads |
| --- | --- | --- |
| `words/{wordId}` | spelling, pronunciation (text), category, difficulty, ordering, isPublished, isRetired, revision, updatedAt (server timestamp), ordered senses with stable unique IDs, POS, meanings, ordering and ordered bilingual example pairs | Published and non-retired for guests/students; all for editor claims |
| `users/{uid}` | uid, name, email display mirror, photoUrl, preferredLanguage, createdAt, updatedAt; Auth is identity authority | Owner document only; no directory listing |
| `users/{uid}/settings/preferences` | theme, language, lastGroup, updatedAt | Owner |
| `users/{uid}/progress/{wordId}` | wordId, status, createdAt, updatedAt, revision, lastOperationId | Owner |
| `users/{uid}/syncOps/{operationId}` | UID-scoped immutable payload hash, result revision, expiry; future dedup ledger | None |
| `contentManifest/current` | schemaVersion, currentRevision, oldestRetainedRevision, groupCounts (flat map keyed category/difficulty), updatedAt | Public safe metadata only |
| `contentChanges/{changeId}` | monotonic revision, wordId, action upsert/remove, publication-safe metadata | Public; never draft payloads or private audit data |
| `adminAudit/{auditId}` | actor UID, action, target ID, server timestamp, minimal safe metadata | Super admin |
| `importJobs/{jobId}` | actor UID, bounded progress/error summary, state, timestamps | Content manager and super admin; never private user data |

Categories: basic/intermediate/advanced. Difficulty: easy/medium/advanced. POS: noun/verb/adjective/adverb/pronoun/preposition/conjunction/interjection/determiner. Status: already_know/learned/didnt_know; unmarked is absent. `learning` is a display label only. Unknown values fail safely. Content transport uses document ID as model `id`; future Firestore adapters convert timestamps without lossy string conversion. Nested model lists are immutable and preserve source order and repeated POS.

Proposed validation bounds: 1?100 senses/examples, nonempty text up to 4000 code units, nonnegative integer revisions/order. Final editor/backend-specific spelling, ID and byte limits must be agreed before publication. Duplicate policy: English spelling trimmed and lowercased; preserve display spelling and Bengali Unicode. Explicit Unicode normalization policy remains to be selected consistently for Dart and server before CRUD.

Indexes cover published/non-retired browsing globally, by category and by category+difficulty, ordered by ordering and document ID. Senses are excluded from automatic indexing. Add new query indexes with the feature that needs them. Emulator tests do not establish production composite-index deployment readiness. No production vocabulary or fabricated counts are seeded.

## Phase 2 server-only paths

`serverControl/adminBootstrap` reserves one bootstrap UID with pending/complete state. `accountRateLimits/{uid}` tracks a bounded per-minute account-API quota. Both are denied by catch-all rules. Bootstrap emits a safe server-only audit record. No role mutation or demotion endpoint is exposed.

Native Drift schema version 1: words (lossless nested payload plus indexed group/search metadata), downloaded_groups, download_staging, user_progress, local_sequences, local_metadata (installation device ID), pending_sync_operations, learning_sessions and learning_queue_items. Progress and outbox include stable word references; retired content is retained with published=0 so history survives. Unsupported migration versions fail instead of resetting data.

## Phase 3 publication contract

See publication_api.md for exact request, word, manifest and feed schemas. `wordSpellings/{hash}`, `contentOperations/{hash}` and `contentRateLimits/{uid}` are server-only and denied by existing catch-all rules. Words now include server-derived normalizedSpelling. Manifest retains schemaVersion=1 and the existing nine groupCounts while adding publisherVersion=1/totalPublished. Global revisions also cover private edits via payload-free noop feed records; no draft word ID or text enters a public noop. Audit entries contain actorUid, stable targetId, operation ID, revision, action, server time and small before/after state metadata. No retention deletion or legacy-data adoption occurs automatically.
