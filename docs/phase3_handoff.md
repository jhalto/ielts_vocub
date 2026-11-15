# Phase 3 handoff: trusted vocabulary publication backend

## Delivered

contentApi provides server-authorized create/edit/publish/unpublish/retire/restore with full nested bilingual validation, explicit editorial review before publication, normalized duplicate spelling reservations, stable IDs, revision preconditions and per-UID request limits. It verifies Firebase bearer tokens including revocation/disabled status and current approved editor claims. No client profile field authorizes actions.

One Firestore transaction updates the word, private uniqueness registry, schema-version-1 manifest/nine published group counts, contiguous revision feed with safe upsert/remove/noop records, private audit and idempotency result. Retry IDs are UID-scoped and bound to canonical payloads. Conflicting edits and duplicate spelling races fail rather than overwrite. Retired words remain addressable to trusted editors; restore returns them unpublished and never modifies user progress.

The existing Student download contract and production app code are unchanged. The manifest adds publisherVersion=1/totalPublished while preserving schemaVersion=1, currentRevision and nine groupCounts. Word revisions come from the same global counter, including draft operations. Public noop records expose no draft IDs or text. Rules continue to deny direct client writes, including admin claims; new registry/operation/rate records are denied by the existing catch-all.

## Files changed/added in this task

- users/firebase/functions/src/index.ts: exports contentApi alongside accountApi.
- users/firebase/functions/src/content.ts: HTTPS authorization and atomic mutation service.
- users/firebase/functions/src/content_validation.ts: schema, normalization, editorial completeness and fingerprint helpers.
- users/firebase/functions/test/content.test.cjs: unit validation/normalization tests.
- users/firebase/functions/test/content.emulator.cjs: HTTP, concurrency, permissions, counts, tombstones, retry, corruption and public-snapshot tests.
- users/firebase/functions/test/run-emulators.cjs: includes the new publication suite.
- users/packages/local_learning/test/publication_contract_probe.dart: passes real server-produced synthetic public data through existing Dart models and the unchanged Drift downloader.
- docs/publication_api.md: complete request/response, schema, errors, revision/retry/feed and operations contract.
- docs/data_schema.md, sync_protocol.md, architecture.md, implementation_plan.md, setup.md: current backend and integration boundaries.
- users/README.md and docs/phase3_handoff.md: current delivery/handoff.

No Firebase registrations, package dependencies, application screens, Firestore rules or indexes were changed. Existing rules and indexes already cover the required access/query patterns; the actual allowed/denied behavior is retested in emulators. The repository's user-selected users/, admin/admin_panel/, users/packages/ and users/firebase/ structure remains intact.

## Checks

Backend unit tests: 8 passed (6 publication validation tests plus 2 existing auth tests). TypeScript build and tsc --noEmit passed. Prettier formatting checks passed for the new publication TypeScript/JavaScript files; the formatter was run from temporary tooling cache without adding a project dependency. The Dart probe was formatted and local_learning analysis reports no issues. Seven native SQLite regression tests passed. git diff --check passed.

The real server-produced public snapshot passed the shared Dart model decoder and unchanged Drift downloader: bilingual data preserved, both published fixture words stored and all nine groups correctly complete. Final isolated Emulator Suite: 17 passed (4 existing rule tests, 2 existing account/bootstrap tests, 11 publication tests), including authentication/claims/revocation, retries, concurrent edits/uniqueness/publications, counts, tombstones, corruption/rate limits and denied direct writes. Together with 8 backend unit tests and 7 native SQLite tests, 32 tests passed. The real-Dart download probe also passed separately. One negative-test setup used a slash-containing update field path; that fixture was corrected without changing the publication implementation.

## Explicit limitations / manual work

No deployment, production seed content or real role changes were performed. Test vocabulary is synthetic and confined to demo emulators/ignored .dart_tool output. No Admin CRUD screens, imports, user management or remote progress sync were implemented. Student full-snapshot downloads remain the integration path; incremental noop/upsert/remove feed consumption is later work.

A fresh managed dataset initializes safely on first mutation. Existing unmanaged/legacy fixture datasets require an explicitly reviewed migration: the API refuses to invent zero totals, adopt old data or silently rebuild reservations. Before a separately authorized deployment review environment, editor claims, backup/export, rules/indexes, attestation policy and migration needs. App Check enforcement remains opt-in until client providers are configured.

Feed, operation ledger and audits are retained indefinitely in this phase. No TTL/pruning is enabled; storage grows with editorial mutations. The single manifest counter intentionally serializes low-volume editorial writes and may contend at higher scale. See publication_api.md for bounded retries and full-snapshot fallback/watermark requirements before introducing retention.

Editorial review is an authorized human attestation, not automated translation verification. Published edits require review and immediately update the public projection; an unpublished working-copy workflow is not included. Audit/feed store action/state metadata, not prior full text: historical payload recovery requires consistent backups. Never reset revisions or restore the manifest alone.

Native builds and real OAuth/device/voice acceptance were not rerun because production app code/dependencies did not change. Emulator composite-index behavior is not proof that production indexes have been deployed. Stop after Phase 3 and await approval before the next task.
