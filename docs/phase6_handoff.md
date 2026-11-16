# Phase 6 handoff: trusted progress synchronization backend

## Delivered

progressApi provides authenticated HTTPS uploads (1-25 operations) and ID-ordered private retrieval (1-100 rows/page). Firebase token verification includes revoked/disabled checks and current verified-email enforcement. UID comes from the token, never a body/profile field. Optional App Check enforcement remains off until supported clients are configured.

Per-operation transactions enforce current word publication and exact progress revision, then atomically write progress, the UID counter and an immutable retry receipt. Concurrent device edits conflict instead of silently overwriting. Accepted and terminal-result retries replay original outcomes; mismatched payloads cannot reuse an ID. Publication races serialize on the current word. Pagination restarts explicitly when a concurrent update changes its snapshot revision. No direct client progress write permission was opened.

All request work is bounded. Validated batches may have mixed outcomes and independent commits; retrying a partly completed request with the same IDs is safe. There is a per-UID rate guard, payload/ID/status validation and fail-closed handling for incompatible stored state. No client clock decides ordering. Existing outbox sequence resets after logout remain compatible because sequences are metadata; revisions are authoritative. See progress_api.md for the precise wire mapping, conflict/rebase policy, retention and required future-client acknowledgement rules.

## Modified files in this task

- users/firebase/functions/src/progress.ts (new): HTTPS authorization, rate guard, transactional mutations/receipts and paginated retrieval.
- users/firebase/functions/src/progress_validation.ts (new): strict batch/operation validation and UID-bound cursors.
- users/firebase/functions/src/index.ts: exports progressApi alongside existing APIs.
- users/firebase/functions/test/progress.test.cjs (new): four validation/cursor unit tests.
- users/firebase/functions/test/progress.emulator.cjs (new): eleven real HTTP/Auth/Firestore/publication/rules integration tests.
- users/firebase/functions/test/run-emulators.cjs: appends the progress suite.
- docs/progress_api.md (new), phase6_handoff.md (new), sync_protocol.md, data_schema.md, implementation_plan.md and setup.md: current contracts, checks and manual boundaries.

Earlier uncommitted work is preserved. Student/Admin production code, Drift schema/outbox, package versions, Firebase registrations, publication logic, Firestore rules and indexes are unchanged. Existing rules already deny direct progress writes and private receipt/counter/rate access; emulator tests verify that baseline. Default document-ID indexing covers retrieval, so no composite indexes were added.

## Actual checks

- TypeScript build and npm run check (tsc --noEmit) passed.
- Backend unit tests: 12 passed (8 existing plus 4 new progress tests).
- Isolated emulator suite: 30 passed (4 rules, 2 account/bootstrap, 11 publication, 2 Admin query, 11 progress).
- Progress coverage includes UID injection, invalid/oversized batches, verification/disabled/revoked sessions, exact/concurrent retries, competing devices, linked rebase, partial-request recovery, private bounded pagination and restart, retained history, stale receipts after republish, publication races, rate limits, legacy/corrupt state and denied direct writes/private reads.
- New backend/test files formatted with temporary Prettier tooling; no formatter dependency added. Final format check and git diff --check passed.

The initial sandboxed TypeScript build could not overwrite existing generated lib output; rerunning with the required filesystem access passed. All integration runs used demo-vocabulary and isolated ports. No deployment, real role change, live content or Student outbox upload was performed. No native app builds/device acceptance were rerun because client code and dependencies did not change.

## Manual setup and limitations

Nothing new is deployed. An operator must explicitly authorize/review deployment to the intended environment before live calls, check existing-data migration needs, retain deny-direct-write rules, verify the email policy, and configure supported App Check providers/header forwarding before enabling REQUIRE_PROGRESS_APP_CHECK. No Firebase registration/provider change is needed for this service. The project targets Node 22 while local tests used Node 24.7.0; verify the deployment runtime separately.

Receipts are bounded records retained indefinitely; there is no unsafe TTL or pruning, so storage grows with operations. No progress/account deletion or reset endpoint is supplied. A trusted restore/migration must preserve counters, progress and receipts consistently; unmanaged/corrupt state is rejected. The per-UID counter intentionally serializes that user's writes and snapshot pages; high write rates may contend or force pagination restarts. Authorization and Auth account changes cannot be atomic across Auth and Firestore; already-authorized bounded requests may complete during revocation, and new requests recheck it.

The server preserves conflicts and returns authoritative information; it does not choose which conflicting user intent to discard or silently rebase it. The future client must persist/retry immutable requests, retain pending intent, avoid acknowledging newer local edits, stop on UID changes, stage complete remote pages and implement bounded conflict handling. The optional linked-rebase field needs durable client metadata if used; it is not a new connected client workflow.

Windows can use authenticated HTTPS without native callable support. Android's repaired registration remains intact. iOS registration/tooling, real OAuth, attestation, offline device acceptance and Windows/mobile multi-device client convergence remain manual/future-client work. No imports, user management, content delta consumption or deployment was implemented. Stop after Phase 6 and await approval.
