# Bounded implementation plan

The user-defined Phase 1 combines project foundation and Firebase architecture from the earlier planning conversation. It establishes `users/` Student App, independent Admin Web app, shared models/bootstrap, schema, read-only security baseline, indexes and emulators. It does not deliver product workflows.

Next tasks, independently tested: (2) secure auth/profile lifecycle and trusted role bootstrap; (3) transactional content publication/feed APIs; (4) admin content UI; (5) Drift schema/migrations and private isolation; (6) atomic downloads/local browsing/search/TTS; (7) offline swipe/session/outbox; (8) idempotent server progress API and multi-device tests; (9) student sync; (10) imports/user administration/deletion; (11) release acceptance/accessibility/localization/operations. See MASTER_PROMPT for authoritative feature requirements and architecture/data_schema/sync_protocol for contracts. Stop after each approved task and record actual checks; add packages only when used.

Windows is a required offline-first Student platform. Include Windows in Drift/migration/private-storage tests, downloads/search/TTS, offline session/outbox restart tests, reconnect and cross-device conflict tests. The auth/API phases must verify desktop providers and implement an authenticated HTTPS transport because cloud_functions does not support native Windows. Release gates include Windows build/packaging and network-disconnected acceptance; Web student remains optional. No later phase is implemented by this scope amendment.

## Phase 2 authorized scope and completion boundary

User confirmed the Firebase project is development with Email/Password and Google enabled, and explicitly expanded Phase 2 to include Drift, downloads and offline learning for Windows. Shared native implementation also supports intended mobile targets but their device integrations remain unverified. Authentication/profiles/trusted bootstrap and native offline learning are implemented; reviewed production content and transactional publication backend are not fabricated. Progress remains local with a durable pending outbox: remote upload/reconciliation/conflict resolution and content delta feeds remain later work. Download cancellation preserves old completed content; retry restarts a full snapshot. See phase2_handoff.md and windows_offline_acceptance.md for actual evidence and limitations.

## Phase 3 scope

Trusted content create/edit/publish/unpublish/retire/restore, validation/uniqueness, expected revisions, atomic manifest/feed/tombstones/audit and idempotent retries are implemented in the shared backend. This phase adds no Admin CRUD screens, imports, user administration or remote progress sync. Publication API and deployment/migration boundaries are documented in publication_api.md; actual checks and handoff are in phase3_handoff.md. Stop after this phase.
