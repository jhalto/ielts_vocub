# Firestore contract, schema version 1

## Phase 11 managed administration schema

serverControl/userAdministration serializes one pending security operation and counts only confirmed enabled/verified managed super admins; pending reductions reserve their count decrement before Auth writes and grants increment only after confirmation. managedAccounts/{uid} contains schemaVersion/uid, role, disabled, emailVerified, monotonic revision, minAuthTime and pendingOperation. Protected rules/APIs require matching claims/version and a sufficiently fresh auth_time for enrolled users. Bootstrap adoption uses version 0 without Auth writes; later mutations bind custom claim adminRevision and require a post-revocation sign-in.

userAdminOperations/{sha256(canonical([actorUid,operationId]))} freezes the validated intent/reason/preconditions and security-only Auth before/after snapshots; it tracks worker ownership/start time, state/phase, safe errors and result. userAdminRateLimits/{uid} bounds authorized requests. All these paths are denied to direct clients under the existing catch-all. Safe initialization/reservation/completion/recovery audits use adminAudit; full recovery claims never enter public feeds/directory responses/audits. Nothing writes or migrates user progress, content or Drift. No new index is needed. No expiry/pruning, public unlock or automatic account deletion is implemented; see user_admin_api.md for exact contracts and guarded IAM recovery.

## Phase 9 trusted import schema

New importApi uses importJobs/{sha256(canonical([uid,jobId]))}: schemaVersion=1, owner uid, immutable jobId/plan fingerprint, status, counts(total/pending/applied/skipped/failed), createdAt/updatedAt. Its items/{itemId} subcollection stores immutable index/decision/mutation/mutationHash and durable state/attempts/result/lastError/timestamps. Jobs contain at most 50 rows; raw normalized content lives only in server-written nested items, never the public feed or parent summary. Parent metadata keeps its existing editor-read policy; nested reads and all direct writes remain denied. The authorized owner HTTP API supplies paginated safe receipts, not uploaded content.

importRateLimits/{uid} is a denied server-only 60-request/minute counter. Successful mutations reuse contentOperations and the existing atomic word/spelling/manifest/feed/audit path; a server-only transaction participant also commits item outcome, job counters and import audit. New imported words create payload-free noops and remain drafts. Safe import_job_created/import_item_applied/import_item_skipped/import_item_failed audit events add to the existing word audit stream. No progress, Drift, publication schema, security rule or index migration is needed. Jobs/items/receipts/audit have no automatic pruning; see import_api.md for exact bounds, access and retry contracts.

## Phase 8 local schema version 3

Firestore schemas remain unchanged. Drift version 3 adds content_checkpoints(category PRIMARY KEY, revision), content_cache_state(id=1, generation), and content_delta_staging(run_id, word_id, revision, nullable payload; composite primary key run_id/word_id). A null staged payload is a removal; noops advance the verified revision window without staging a word. These public-cache tables contain no UID, tokens or private learning data.

Version 2 upgrades by creating only these tables and an initial generation row. Version 1 first applies the existing progress migration, then adds the content tables in the same migration transaction. Existing word/progress/session/device/operation IDs and frozen request bytes survive. Checkpoints start empty for old installations; old downloaded_groups revisions alone do not prove that a feed baseline was verified. The first reconciliation stages a trusted snapshot for previously downloaded categories. No database reset, destructive compaction or synthetic cursor assignment occurs. Tests exercise actual version-1 and version-2 table layouts; unsupported future versions still fail closed.

Content commits atomically update words/search/group metadata, prune stale queue entries, validate manifest counts, write category checkpoints and increment cache generation. Generation preconditions prevent a staged delta/fallback from overwriting a newer manual download or unavailable-word progress result. Historical words are hidden with published=0, retaining their stable IDs and all progress/outbox references; no learning history is deleted by publication changes. Download/progress/delta staging is discarded on restart. See sync_protocol.md and phase8_handoff.md for consistency and retry limits.

## Phase 7 local schema version 2

Firestore protocol schema remains 1. Drift schema 2 migrates from local schema 1 without resetting data: pending_sync_operations adds request_payload and supersedes_operation_id; remote_progress stores UID-scoped server status/revision/operation IDs without requiring downloaded content; progress_staging isolates incomplete snapshots; sync_status stores phase, complete remote revision, last successful sync, error, rate retry time and automatic-sync preference (default off). Applied and explicitly superseded operations are retained as history and excluded from pending counts. Logout clears all these private tables for that UID.

Pending/inflight/conflict/rejected rows protect the user's local status from remote materialization. Frozen JSON is never edited after dispatch. Acknowledgements and conflict decisions are SQLite transactions with current-UID/private-epoch guards. The version-1 fixture migration, restart, lost acknowledgement and newer-local-edit cases are tested; future unsupported versions still fail without resetting data. See phase7_handoff.md for actual checks and retention limits. Earlier schema-1 delivery notes remain historical.

## Phase 6 progress paths

users/{uid}/progress/{wordId} is server-written by progressApi: schemaVersion=1, wordId, status, trusted revision, lastOperationId, lastDeviceId/lastSequence metadata and createdAt/updatedAt server timestamps. Each accepted operation obtains the next users/{uid}/syncState/progress revision; this is distinct from content publication revision. Only the owner retains the existing direct read permission; all direct client writes remain denied.

users/{uid}/syncOps/{sha256(operationId)} stores schemaVersion, canonical operation fingerprint, validated operation, original result and server creation time, including terminal conflict/unavailable results. users/{uid}/syncState/progress and progressRateLimits/{sha256(uid)} are also server-only under catch-all denial. No TTL, deletion or pruning is enabled. Default document-ID indexing suffices for progressApi pagination. Exact schemas, error/retention policy and existing-outbox mapping are in progress_api.md. Earlier planned progress metadata below is superseded by this explicit implemented contract; client synchronization remains disconnected.

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

## Phase 5 local validation and preservation

The native database remains schema version 1 with no layout migration or reset. File-backed reopen tests preserve committed bilingual payloads, installation/outbox IDs, progress and session order while deleting only incomplete download staging. Unknown database versions throw without dropping data. Future schema changes must supply a tested versioned migration.

The Student manifest decoder requires all nine known group counts as nonnegative integers and validates optional publisherVersion/totalPublished. Download opening/closing counts and revision must match. Cancellation and account guards run inside local transactions, so failed commits do not partially update completeness, progress or queues. Historical word rows remain addressable when a refreshed snapshot excludes them; their local published flag hides them from active browsing/queues while stable-ID progress/outbox references survive. See phase5_handoff.md for exact verification and limits.
