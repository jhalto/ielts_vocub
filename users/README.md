# VocabSwipe

Phase 9 adds the trusted JSON import backend with validation/dry runs, explicit immutable decisions and safely resumable publication transactions. New words stay drafts. Admin import screens, CSV, exports, user management and deployment remain separate work. See [import API](../docs/import_api.md) and [Phase 9 handoff](../docs/phase9_handoff.md) for contracts, actual checks and limits; the native Student App is unchanged by Phase 9.

The Student App is in `users/`. The independent Admin Web app is in `admin/admin_panel/` from the repository root; packages share content models, Firebase initialization, authentication and native offline-learning storage.

Phase 2 implements email/password and supported Google authentication, verification/reset, restored sessions, guest access, retryable server-owned profiles and a server-only first-admin bootstrap. Native student builds include Drift/SQLite downloads, English/Bengali search, all senses/examples, installed-voice pronunciation, swipe learning and sessions/outbox that survive restart. Windows is a required offline-first target.

Phase 3 implements trusted publication/manifest/feed/tombstones. Phase 4 implements the separate Admin content UI. Phase 6 supplies the trusted progress API; Phase 7 connects the native Student outbox with safe retries, explicit conflicts and manual/opt-in synchronization. Phase 8 refreshes downloaded categories from the trusted incremental content feed with atomic checkpoints and verified snapshot recovery. Drift remains the learning source of truth. Imports, user management and deployment remain later work. A trusted versioned manifest and reviewed content are required for real downloads; synthetic fixtures are demo-only. No cloud deployment or real administrator provisioning was performed.

See [Phase 8 handoff](../docs/phase8_handoff.md) for actual tests/builds, schema-3 migration, safe demo setup and manual device acceptance. Automatic sync defaults off, including upgraded accounts; Sync Now explicitly uploads this account's saved pending work, reconciles progress, then refreshes previously downloaded content. Offline learning does not wait for network calls.

Read [specification](../docs/master_prompt.md), [architecture](../docs/architecture.md), [setup](../docs/setup.md), [Phase 2 handoff](../docs/phase2_handoff.md) and [Windows offline acceptance](../docs/windows_offline_acceptance.md).

Publication backend contracts, setup boundaries and tests: [publication API](../docs/publication_api.md) and [Phase 3 handoff](../docs/phase3_handoff.md). No publication deployment or production seed content is included.
