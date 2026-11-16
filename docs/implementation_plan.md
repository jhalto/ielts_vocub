# Bounded implementation plan

## Phase 12 authorized scope and completion boundary

Admin user management is implemented in admin/admin_panel/ against the existing trusted userAdminApi. It includes super-admin-only navigation, exact lookup, bounded directory pages/page-local filters (including empty pages with continuations), safe details, confirmed/reasoned role/status changes, immutable revision/Auth-state preconditions, account/environment-scoped recovery, status lookup and deliberate same-key resume. Pending, complete, worker-owned and recovery-required results remain distinct; HTTP 200 is not completion. Conflicts require explicit review and a fresh read/new operation, never automatic rebasing.

See phase12_handoff.md for the file inventory, actual checks and manual browser acceptance. Existing publication/import/Student behavior and backend contracts are preserved. No browser initialization/unlock/force controls, deletion, export, deployment or live-user changes are included. User-administration backend and UI are now delivered; do not repeat them. Release/device/browser acceptance and any further feature require separate approval. Stop after Phase 12 and await approval. Earlier phase boundaries below are historical.

## Phase 11 authorized scope and completion boundary

Trusted user administration is implemented through a super-admin-only HTTPS API: exact UID/email lookup, bounded native Auth pagination with explicit page-local filters, safe account details, enable/disable, approved role grants/revocation, current token/claim checks, revision/Auth-state preconditions, confirmation/reasons, quotas and audits. A server-owned registry serializes immutable resumable operations, excludes pending admins from the active count and protects the last managed active super admin. Managed token-version/fresh-sign-in gates cover existing APIs and Firestore rules. Auth/Firestore are not claimed atomic; uncertain writers stay locked for explicit IAM-only settled-worker recovery. See user_admin_api.md and phase11_handoff.md for adoption, guarantees and actual checks.

No Admin user-management screens, deletion, export, deployment or real-user changes are included. A separately approved next phase can build Admin user lookup/details/role/status UI against this contract. Account deletion needs its own resumable multi-service design and approval. Existing vocabulary/import/offline/sync work is preserved. Stop after Phase 11 and await approval; earlier phase sections are historical.

## Phase 10 authorized scope and completion boundary

Admin JSON imports are implemented against the existing importApi: bounded JSON selection, server-normalized bilingual dry runs/errors, explicit create/update/skip and target revisions, published-edit review confirmation, immutable job creation, account/environment-scoped tab recovery, bounded processing/backoff, paginated receipts and job-ID lookup. Terminal corrections require a new plan; no frozen payload is rewritten. See phase10_handoff.md for actual checks, file inventory and manual browser acceptance.

Phase 10 preserves the Student App and backend contracts. It adds no CSV/export, user management, automatic publication, deployment or unrelated Admin screens. The import backend and its Admin client are now delivered; do not reimplement them. User administration/account deletion, broader release acceptance and deployment remain separately approved scopes. Stop after Phase 10 and await approval. Earlier boundaries below are historical.

## Phase 9 authorized scope and completion boundary

The trusted JSON import backend is implemented: strict bounded JSON validation/dry runs, normalized duplicate checks, explicit create/update/skip plans, immutable UID-scoped jobs/items, revision/review preconditions, paginated status, atomic item/publication receipts, resumable partial processing and safe audits. New words remain drafts. The existing publication transaction/validation supplies all vocabulary mutations; no direct-write route or second feed pipeline is introduced. See import_api.md and phase9_handoff.md for contracts, actual checks and limitations.

Phase 9 does not add Admin import screens, CSV, export, user administration, deployment or Student changes. The next separately approved feature can build Admin JSON preview/decision/job-progress screens against this API. User management/deletion and release/device acceptance remain distinct scopes. Preserve the already delivered offline/progress/content features; do not repeat them. Stop after Phase 9 and await approval. Earlier phase boundaries below describe their historical delivery.

## Phase 8 authorized scope and completion boundary

Student incremental content reconciliation is implemented after progress upload/retrieval. It consumes the trusted contiguous publication feed, including payload-free noops and removals, and atomically commits downloaded-category content, queue pruning, exact completeness counts and per-category checkpoints in Drift schema 3. Missing/expired baselines, feed gaps and unsafe public lookups recover through the existing verified full downloader, staging all selected categories before one commit. Stable IDs, historical progress and immutable pending operations are preserved. See phase8_handoff.md for migration details, actual checks, manual acceptance and remaining platform limits.

Expanded Phase 2 plus Phases 5, 7 and 8 now deliver the local database/download/learning foundation, progress client and incremental content consumer. Do not reimplement those original planning steps. Imports, user administration, deployment and release/device acceptance remain separate approvals. Stop after Phase 8 and await approval. The earlier phase boundaries below describe what each phase delivered at that time.

## Phase 7 authorized scope and completion boundary

Student progress synchronization is implemented against the existing trusted HTTPS API on the native shared foundation. Schema-2 migration, durable immutable requests, single-flight bounded upload/retrieval, safe acknowledgements, explicit conflict choices, UID/logout guards and opt-in/manual status UI are tested with temporary SQLite databases and real demo emulators. See phase7_handoff.md for exact file inventory, test/build evidence and manual platform limits. No content delta consumption, import, user management or deployment is included. Stop after Phase 7 and await approval; incremental content reconciliation is a separate next scope.

## Phase 6 authorized scope and completion boundary

The trusted progress synchronization backend is implemented independently of the Student client: authenticated bounded HTTPS upload/list, immutable retry receipts, server revision preconditions, explicit conflict/rebase contract, atomic publication checks, private snapshot pagination and emulator concurrency/permission tests. See progress_api.md and phase6_handoff.md for actual checks, file inventory, retention and manual setup. No Student sync connection, content delta consumption, import, user management or deployment is included. Stop after Phase 6 and await approval; the next separately approved task can connect the existing Drift outbox under this contract.

The user-defined Phase 1 combines project foundation and Firebase architecture from the earlier planning conversation. It establishes `users/` Student App, independent Admin Web app, shared models/bootstrap, schema, read-only security baseline, indexes and emulators. It does not deliver product workflows.

Next tasks, independently tested: (2) secure auth/profile lifecycle and trusted role bootstrap; (3) transactional content publication/feed APIs; (4) admin content UI; (5) Drift schema/migrations and private isolation; (6) atomic downloads/local browsing/search/TTS; (7) offline swipe/session/outbox; (8) idempotent server progress API and multi-device tests; (9) student sync; (10) imports/user administration/deletion; (11) release acceptance/accessibility/localization/operations. See MASTER_PROMPT for authoritative feature requirements and architecture/data_schema/sync_protocol for contracts. Stop after each approved task and record actual checks; add packages only when used.

Windows is a required offline-first Student platform. Include Windows in Drift/migration/private-storage tests, downloads/search/TTS, offline session/outbox restart tests, reconnect and cross-device conflict tests. The auth/API phases must verify desktop providers and implement an authenticated HTTPS transport because cloud_functions does not support native Windows. Release gates include Windows build/packaging and network-disconnected acceptance; Web student remains optional. No later phase is implemented by this scope amendment.

## Phase 2 authorized scope and completion boundary

User confirmed the Firebase project is development with Email/Password and Google enabled, and explicitly expanded Phase 2 to include Drift, downloads and offline learning for Windows. Shared native implementation also supports intended mobile targets but their device integrations remain unverified. Authentication/profiles/trusted bootstrap and native offline learning are implemented; reviewed production content and transactional publication backend are not fabricated. Progress remains local with a durable pending outbox: remote upload/reconciliation/conflict resolution and content delta feeds remain later work. Download cancellation preserves old completed content; retry restarts a full snapshot. See phase2_handoff.md and windows_offline_acceptance.md for actual evidence and limitations.

## Phase 3 scope

Trusted content create/edit/publish/unpublish/retire/restore, validation/uniqueness, expected revisions, atomic manifest/feed/tombstones/audit and idempotent retries are implemented in the shared backend. This phase adds no Admin CRUD screens, imports, user administration or remote progress sync. Publication API and deployment/migration boundaries are documented in publication_api.md; actual checks and handoff are in phase3_handoff.md. Stop after this phase.

## Phase 4 scope

Admin vocabulary management is implemented in admin/admin_panel/: role-gated responsive navigation, bounded indexed spelling-prefix queries and filters, complete bilingual forms/preview, explicit review and publication lifecycle actions, dirty warnings, immutable operation retries and deliberate conflict resolution. The existing trusted publication API performs every mutation. Eleven composite indexes are checked in but not deployed. See phase4_handoff.md for the file inventory, actual tests, manual setup and browser limitations. No imports, user management, remote progress sync or deployment is included. Stop after Phase 4 and await approval; plan the next task against Phase 2's already implemented Windows offline features rather than duplicating them.

## Phase 5 authorized scope and current implementation order

Phase 5 audited and hardened the expanded Phase 2 offline foundation: strict publication manifest validation, atomic late cancellation, session account-change guards, recoverable database opening/read errors, Android network/TTS prerequisites and native persistence/isolation/version tests. Schema version 1 and existing progress/operation IDs remain intact; no replacement database or duplicate download/learning feature was added. See phase5_handoff.md for actual results, Android registration mismatch and iOS/device acceptance requirements.

The original planned Drift/download/offline-learning steps (5-7 above) are substantially delivered by expanded Phase 2 plus Phase 5 hardening. Remaining work should be separately approved and bounded: platform registration/device acceptance; trusted idempotent progress API and concurrency policy; client progress upload/reconciliation; incremental content feed/recovery; then imports/user administration and release acceptance. None of those is implemented by this audit. Remote progress is still local pending intent, never cloud-backed. Stop after Phase 5 and await approval.
