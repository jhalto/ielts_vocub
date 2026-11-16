# Phase 9 handoff: trusted vocabulary JSON import backend

## Completed scope

Added importApi with verified current editor authorization, strict JSON validation, dry-run previews, explicit create/update/skip decisions, immutable UID-scoped jobs/items, bounded resumable processing and paginated safe status. New words remain drafts. Published updates require the existing explicit reviewed=true attestation and complete bilingual content; no import automatically publishes/unpublishes/restores anything.

Reused the existing publication validators and transaction. applyContentMutation now accepts an optional trusted server-only transaction participant: read the import job/item before writes, then commit item outcome/counters/import audit with word, spelling registry, manifest/counts, feed, publication audit and immutable content-operation receipt. HTTP clients cannot supply the participant. Existing contentApi requests/responses and normal publication behavior are unchanged.

Limits: 512 KiB raw request, 50 items/job, existing 192 KiB mutation validation per item, 5 items/process call, 25 status rows/page, 60 import requests/editor/minute plus existing content mutation quotas. No additional package or bulk-processing framework was introduced. Jobs advance on explicit authenticated process requests; no background worker or automatic retry loop is claimed.

Dry runs report safe row codes, normalized content, completeness/publishability, current target metadata and conflicting spelling IDs. Duplicate item IDs, target IDs and normalized spellings flag every colliding row. Database checks are advisory; each mutation revalidates uniqueness, revision and publication state transactionally. Job creation validates the entire plan and atomically persists all items or none. Per-item commits allow earlier successes to survive later conflicts/timeouts. Lost replies and concurrent workers replay committed receipts without duplicating revisions/audits. Transient failures retain pending items; terminal conflicts preserve their recorded failure and require a new job with corrected intent/fresh revision.

The existing users/, admin/admin_panel/, users/packages/ and users/firebase/ structure and Firebase registrations are preserved. No Admin import screens, CSV, exports, user management, Student changes, deployment or production vocabulary were added.

## Schema, API and compatibility

See import_api.md for the complete JSON format, action/response/error contracts, limits, review policy, partial-failure semantics and retry rules. New server records are importJobs/{hash(uid/jobId)}, its items/{itemId} subcollection, importRateLimits/{uid}, and safe import audit actions. Jobs/items/operation payloads are immutable; server timestamps and counters change with state. Stable word/sense IDs and historical progress remain intact. Imported new drafts emit payload-free noops through the existing publication feed. Reviewed published edits atomically update the existing counts and upsert feed.

No Drift migration, existing publication schema migration, security rule change or composite index is needed. Existing client writes remain denied. Nested import items are denied to direct client reads; the owner API exposes safe receipts. Existing parent-job editor metadata reads remain unchanged and contain no uploaded content. Audit access remains super-admin only. Jobs/items/receipts/audits are retained indefinitely; automatic pruning, cancellation and job deletion are not implemented.

## Actual checks

| Check | Actual result |
| --- | --- |
| npm.cmd run check | Passed, TypeScript strict/no-unused checks |
| npm.cmd test | 20 passed: 12 prior tests plus 8 import unit tests; includes TypeScript build |
| Complete isolated Firebase emulator suite | 44 passed: 32 prior checks plus 12 import integration tests |
| Final targeted import suite | 12 passed against fresh demo emulators after final strict-action/byte-bound and authorization test changes; repeats are not additional unique tests |
| Focused Prettier formatting, Node syntax, git diff --check | Passed; existing Git LF/CRLF conversion notices remain |

The import integration cases cover missing/student/unverified/disabled/revoked/stale/demoted identities, owner isolation, malformed shape/media/schema/limits, normalized within-file/database duplicates, published review requirements, durable skip/draft isolation, denied direct writes/nested reads, concurrent same-item retries, conflicting jobs, stale edits, interrupted/resumed jobs, lost-response replay, paginated status, preserved progress/IDs, counts/feed continuity, retirement/restoration and quota handling.

A test-only deterministic audit collision forces a failure inside the shared publication transaction. It verifies no word, manifest or content-operation receipt commits without its import outcome; the item stays pending, and retry with the same IDs succeeds after the injected fault is removed. Request interruption/lost acknowledgement is simulated by resuming after a committed bounded request and ignoring its result; an actual deployed Functions process kill was not performed.

The first targeted run had 11 passes and one fixture failure: an Admin SDK Timestamp was passed to the browser SDK before the intended rules check. The fixture now uses browser-serializable data; final suites pass. The final malformed-action checks include prototype-property names, and the final authorization run explicitly verifies stale/revoked sessions and public job-read denial.

The complete suite also reran the existing real Dart HTTP/Drift progress and content client probes against production backend contracts. No Dart/native application source changed; Flutter analysis/widget tests and Android/Windows/iOS builds were not rerun in Phase 9. Phase 8 build results remain historical evidence, not newly claimed checks. No installed application was launched.

All checks used loopback demo-vocabulary emulators, synthetic content, disposable accounts and temporary databases. The new import suite refuses non-demo/non-loopback configuration before initialization/reset. No personal app database, live Firebase data, service-account key or real administrator account was accessed. No test token/password was logged. Existing uncommitted changes from earlier phases are preserved.

## Modified files in Phase 9

- users/firebase/functions/src/imports.ts (new): authenticated HTTPS API, preview/database checks, immutable jobs, atomic item receipts, bounded processing/status and safe errors.
- users/firebase/functions/src/import_validation.ts (new): strict file/row decisions, shared content validation, duplicate checks, deterministic identities and bounds.
- users/firebase/functions/src/content.ts: optional server-only transaction participant; existing publication path retained.
- users/firebase/functions/src/index.ts: exports importApi; preserves prior exports.
- users/firebase/functions/test/import.test.cjs (new): 8 validation/normalization/immutability/bounds unit tests.
- users/firebase/functions/test/import.emulator.cjs (new): 12 guarded real HTTP/transaction/rules integration tests.
- users/firebase/functions/test/run-emulators.cjs: adds the import suite to the existing sequential regression runner.
- docs/import_api.md and docs/phase9_handoff.md (new): full contracts, evidence, file inventory and limits.
- docs/implementation_plan.md, docs/data_schema.md, docs/publication_api.md, docs/setup.md and users/README.md: Phase 9 scope, schema/integration and setup references.

Compiled functions/lib output and logs are generated/ignored. No dependency/lockfile, rule/index, Firebase registration, Admin screen or Student code was changed by this phase.

## Manual setup and remaining limits

importApi is exported and emulator-tested but not deployed. Live use requires a separately authorized function deployment and the existing trusted publication infrastructure. No new Firebase Console registration/provider/index setup is needed. Use current verified content_manager/super_admin claims and refresh stale tokens. REQUIRE_CONTENT_APP_CHECK is shared with contentApi; successful real attestation/provider setup was not tested here and must precede enabling enforcement in clients.

Local verification used Node 24.7, project-local Firebase CLI 15.36 and Java 21. Functions target Node 22; deployed runtime, real attestation and production index readiness remain manual acceptance. From users/firebase/functions/ run npm.cmd run check and npm.cmd test. From users/ use the complete demo emulator command in setup.md; retain VOCAB_DART_BIN for existing client probes. Never point reset scripts at a live project.

A future Admin import screen must retain job/item IDs, show normalized previews/error rows, obtain explicit choices and published-edit review, inspect per-item outcomes, paginate status and back off transient retries. It must not treat HTTP 200 or a dry run as a completed import. The API does not support files larger than one bounded job, cross-item atomic bulk updates, automatic conflict rebasing, all-owner job listing, background execution or automatic retention cleanup. Status pagination is a live view under concurrent processing; refetch final counts.

Phase 9 is complete. Stop here and await approval before Admin import screens or any further phase.
