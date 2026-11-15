# VocabSwipe

The Student App is in `users/`. The independent Admin Web app is in `admin/admin_panel/` from the repository root; packages share content models, Firebase initialization, authentication and native offline-learning storage.

Phase 2 implements email/password and supported Google authentication, verification/reset, restored sessions, guest access, retryable server-owned profiles and a server-only first-admin bootstrap. Native student builds include Drift/SQLite downloads, English/Bengali search, all senses/examples, installed-voice pronunciation, swipe learning and sessions/outbox that survive restart. Windows is a required offline-first target.

Phase 3 implements the trusted publication API, manifest/feed/tombstones and audited idempotent writes. Remote progress synchronization, Admin content screens and user management are not implemented. A trusted versioned manifest and reviewed content are required for real downloads; guarded synthetic fixtures are available only in the demo emulator. No cloud deployment or real administrator provisioning was performed.

Read [specification](../docs/master_prompt.md), [architecture](../docs/architecture.md), [setup](../docs/setup.md), [Phase 2 handoff](../docs/phase2_handoff.md) and [Windows offline acceptance](../docs/windows_offline_acceptance.md).

Publication backend contracts, setup boundaries and tests: [publication API](../docs/publication_api.md) and [Phase 3 handoff](../docs/phase3_handoff.md). No publication deployment or production seed content is included.
