# MASTER IMPLEMENTATION PROMPT — Offline-First Bilingual Vocabulary Platform

## Role and execution mandate
Act as a senior Flutter architect, Firebase backend/security engineer, offline synchronization engineer, product designer, and test engineer. Build a production-quality English–Bengali vocabulary learning platform consisting of **two separate Flutter applications** in one monorepo: (1) an offline-first Student App for Android, iOS and Windows (with optional verified Web support) and (2) an online-only Flutter Web Admin Panel. Both use the **same Firebase project per environment** (separate development/staging/production Firebase projects). Implement working code, security rules, Cloud Functions, tests, configuration, and documentation—not only plans or mock screens. Inspect the repository, AGENTS.md, dependencies, existing conventions, auth, routes, tests, and Firebase setup first. Preserve existing working code. Ask only for genuinely blocking information; complete independent work.

## 1. Architecture and technologies
- Student: Flutter/Dart, Material 3, adaptive accessible bilingual UI, Firebase Authentication, Drift/SQLite as the **primary operational local source of truth**, a dedicated sync engine, flutter_tts with offline-capable installed voices where available. Use existing state management; Riverpod and GoRouter for a new project.
- Admin: **separate Flutter Web app**, Firebase Authentication, Cloud Firestore for approved content reads, Cloud Functions for privileged operations, Firebase Hosting. Online-only; no Drift needed.
- Shared: Dart models, enums, validation, serialization and repository contracts; Firebase Firestore, Storage (optional profile pictures/audio), App Check, Emulator Suite, Security Rules, composite indexes, Cloud Functions using Firebase Admin SDK on server only. Configure `firebase_core`, `firebase_auth`, `cloud_firestore`, `cloud_functions`, `google_sign_in`, `drift`, `sqlite3_flutter_libs` or current supported SQLite backend, `path_provider`, `flutter_tts`, and other compatible maintained packages as appropriate. Verify platform support and versions.
- No Django, DRF, PostgreSQL, custom JWT server, hardcoded credentials, or Firebase Admin SDK inside clients. Firebase Auth manages sessions/tokens. Firebase config is not secret; authorization must be enforced server-side.
- Offline learning and sync are **mandatory**; this supersedes any earlier exclusion of complex offline synchronization. Quizzes, streaks, leaderboards, subscriptions, chat, AI-generated translations and push marketing remain out of scope.

## 2. Monorepo and deployment
Suggested structure (adapt existing repository):
```
vocabulary_platform/
  apps/student_app/lib/{app,core,features/{auth,account,vocabulary,learning,progress,downloads,sync}}
  apps/student_app/test/
  apps/student_app/integration_test/
  apps/admin_panel/lib/{app,core,features/{auth,dashboard,users,words,imports,audit,settings}}
  apps/admin_panel/test/
  packages/shared_models/lib/
  firebase/functions/src/
  firebase/firestore.rules
  firebase/firestore.indexes.json
  firebase/storage.rules
  firebase/firebase.json
  docs/{architecture,data_schema,sync_protocol,security,operations,setup}
  README.md
```
Deploy Admin Panel to Firebase Hosting, e.g. `admin.example.com`; publish Student App independently. Document Android signing/SHA fingerprints, iOS configuration, Web OAuth domains, environment selection and build commands. Do not claim unsupported Windows or browser SQLite/TTS/auth behavior works without verification. For Web student support, implement a tested web-compatible local store or clearly scope offline-first guarantee to Android, iOS and Windows.

## 3. Authentication and account features
Student and admin use Firebase Authentication with **Google Sign-In** and **manually entered email/password**. Provide polished login, register (full name/email/password/confirm), Google button, forgot-password, email verification and resend with cooldown, sign-out, session restoration, account page, edit name/photo, linked providers, verification state, account creation date, change password (password-provider accounts with reauthentication), and delete account. Enforce configured password policy; handle wrong credentials, existing accounts, disabled users, rate limits, provider conflicts, cancelled Google login, network errors, stale auth callbacks. Never store plaintext passwords. Handle provider linking only after explicit secure authentication; do not auto-merge by email. Google and email sign-in must use platform-appropriate supported Firebase flows. Persist/retry user profile initialization after partial registration. Require verified email for protected student writes for password accounts if policy mandates it; enforce this in rules/backend, not only UI. Google accounts use Firebase's verified state. Do not promise new sign-in, password reset, or email verification offline. Previously authenticated users can access downloaded content offline subject to locally available session; **server authorization changes cannot be verified while offline**. Clearly explain this limitation.

Guest mode: browse bundled or downloaded published vocabulary, see cards and play supported offline pronunciation. No anonymous progress writes by default; trying to save progress prompts login. Do not silently retain guest progress. On account switch/logout, stop sync, cancel listeners, clear private in-memory state and **securely erase or strictly isolate** previous UID's local progress, pending operations and sessions. Prefer clearing on explicit logout, and per-UID encrypted storage where supported; document data-at-rest limitations. Never send one UID's pending changes using another UID's credentials. When a session is revoked remotely, deny protected online actions immediately upon detection and handle offline data according to documented policy.

## 4. Roles, authorization, and administration
Roles: `super_admin`, `content_manager`, `student`. Assign administrative roles **only through trusted Firebase Admin SDK custom claims** or equivalent privileged backend workflows. Maintain role display metadata separately; never authorize based on client-editable Firestore `role`. Provision the first super admin with a documented secure CLI/server-only bootstrap; never expose a 'make me admin' action. Enforce roles in Firestore rules and Cloud Functions; handle claim refresh/revocation and audit changes.
- Super admin: manage users/roles, content, publication, imports, and audit views.
- Content manager: create/edit/publish/unpublish/import words and view content metrics, **not** grant roles or manage privileged accounts.
- Student: own account, own progress, published content only.
Admin login must reject users without an appropriate claim even if authenticated. Hide controls according to role, but enforce server-side regardless of UI. Require confirmation and server-side authorization for destructive operations. Add least-privilege audit logs for privileged changes, with actor UID, target ID, action, timestamp and safe before/after metadata; do not store passwords/tokens or unnecessarily expose personal data.

## 5. Admin Panel: full functionality
Responsive desktop-first Flutter Web dashboard with sidebar, search, filters, pagination, loading/empty/error/retry states, accessible forms, light/dark themes, keyboard/mouse support.

### Dashboard
Show accurate totals: registered users (privileged aggregate), published words, drafts, archived/unpublished words, counts by category/difficulty, recent content updates and optionally aggregated learning activity if privacy policy permits. Use bounded server aggregates; no full user-progress scans on each visit. Display refresh timestamps and failures, never fabricated counts.

### Vocabulary CRUD
Create, read, update, preview, publish, unpublish and soft-delete/retire words; restore retired words if authorized. Hard deletion only through explicit privileged retention policy and double confirmation. Preserve stable IDs and existing student progress. Forms: spelling, textual pronunciation, category, difficulty, ordering, publication status, one or more senses with stable sense IDs and independent part of speech, English meaning, Bengali meaning, ordered bilingual English/Bengali example pairs. Allow adding/removing/reordering senses and examples, validate Unicode, required fields, duplicate spellings (define case/normalization policy), maximum sizes, invalid categories, and publication completeness. Support previews, dirty-form confirmation, concurrency detection (`revision`/preconditions), success/error notifications, and audit trail. Published content must be reviewed, never fabricate Bengali translations. Optional profile/content media must be validated and access-controlled.

### Categories and difficulty
Categories: `basic`, `intermediate`, `advanced`; difficulties: `easy`, `medium`, `advanced`, giving nine groups. Initial editorial target **20 published words per group = 180 total**, not a hardcoded actual count. Display real counts and empty groups. Part-of-speech values: `noun`, `verb`, `adjective`, `adverb`, `pronoun`, `preposition`, `conjunction`, `interjection`, `determiner`. Keep category `advanced` distinct from difficulty `advanced`. Do not allow admin to introduce unrecognized enum values without an explicit schema migration.

### Imports and exports
Admin import of validated JSON and optional CSV; JSON must preserve nested senses/example pairs, CSV needs documented multi-row format. Validate file type/size, required fields, normalization, duplicates within file and database, category/difficulty, nested examples, and publishability. Show preview, row-level errors, skip/update/create choices, dry-run and progress, partial failure/retry, bounded batches, idempotent import job IDs and audit logs. Perform privileged bulk imports in Cloud Functions or trusted backend (consider function timeouts and large-job chunking); do not expose Admin SDK in browser. Allow safe export of vocabulary, not unrestricted private user data. No silent overwrite.

### User management
Search and paginate user profiles, show display name/email/provider/verification/account status/created date and privacy-limited progress summaries. Do not query Firebase Auth Admin SDK from browser; expose narrowly scoped privileged callable Functions with pagination and validated filters. Super admin may disable/enable users, initiate deletion, and assign/revoke approved roles with confirmation, reason and audit log. Protect against removing the last super admin and against unauthorized self-elevation. Never show passwords or raw tokens. Deletion should remove Auth, Firestore nested progress/settings, Storage files and derived private data via an idempotent resumable server workflow; show pending/completed/error accurately. Students can request deletion of own account with reauthentication. Include account lifecycle and data-retention policy.

## 6. Firebase data model
Use server timestamps and stable IDs. Document complete schemas and validation. Example paths:
```
users/{uid}                           // private profile; no trusted role authorization from this doc
users/{uid}/settings/preferences      // theme, language, last group
users/{uid}/progress/{wordId}         // per-user word status and sync metadata
users/{uid}/syncOps/{operationId}     // optional bounded deduplication ledger
words/{wordId}                        // published/draft/retired content
contentManifest/current               // published version and revision metadata
contentChanges/{changeId}             // versioned publish/update/retire tombstones
adminAudit/{auditId}                  // privileged server-written log
importJobs/{jobId}                    // privileged import status
```
`words/{wordId}` includes `spelling`, `pronunciation` (text, not audio URL), `category`, `difficulty`, `ordering`, `isPublished`, `isRetired`, `revision`, `updatedAt`, ordered `senses:[{id,partOfSpeech,englishMeaning,bengaliMeaning,ordering,examples:[{english,bengali}]}]`. One word can have multiple noun/verb senses, including repeated same part of speech; preserve ordering and pairs. Use a subcollection if Firestore document-size limit is approached. Avoid claiming unpublished words are readable publicly; queries must include publish filter. Do not seed invented production vocabulary.
`users/{uid}/progress/{wordId}`: `wordId`, `status` (only `already_know`, `learned`, `didnt_know`), `createdAt`, `updatedAt`, `revision` or other trusted concurrency metadata, `lastOperationId`. Unmarked = absent document; `learning` is UI label for `didnt_know`, not fourth stored status. Server-side validation must ensure word exists and is published at time of online write, or define handling of retired words. User profile: UID, name, email display mirror, photo URL, preferred language, timestamps. Firebase Auth is identity authority. Use trusted claims for roles. Explicitly design and test read/write rules and indexes for every path.

## 7. Student navigation and UX
Primary destinations: Home, Vocabulary, My Learning, Account; add Downloads accessible from Vocabulary/Settings. Home: greeting, Continue Learning, nine groups, published vocabulary count, Already Know/Learned/Learning/Unmarked, progress, last group, sync/offline indicator. Guests see no private stats. Browse category then difficulty, searchable paginated word list, optional part-of-speech/status filters, full word detail, deep-link-by-ID with unpublished/removed handling. Show spelling, IPA/textual pronunciation, speaker, **all** separate senses with English/Bengali meanings and every bilingual example pair; do not flip/hide meanings. Card vertically scrolls with horizontal swipe recognition that does not block scrolling, selection or audio button. Large-text, screen-reader labels, Bengali font fallback, high contrast, dark mode, tablet and desktop adaptations. Search supports English and Bengali Unicode; offline search queries Drift. Online Firestore has no arbitrary full-text search; implement documented indexed/token search or download-first local search, not unsupported query promises. Online browsing uses cursor pagination (`orderBy`, `limit`, `startAfterDocument`) with stable tie-breaker and stale-request suppression. Avoid fetching all words just for decoration.

## 8. Swipe learning behavior and persisted sessions
Both swipe gestures and labeled accessible buttons: left **Didn't Know**, right **Know It**. State transitions:
| Current | Gesture | Persisted |
|---|---|---|
| New/unmarked | Right | `already_know` |
| New/unmarked | Left | `didnt_know` |
| Didn't know / Learning | Left | `didnt_know` |
| Didn't know / Learning | Right | `learned` |
| Learned or Already know in explicit review | Left | `didnt_know` |
| Learned in review | Right | preserve `learned` |
| Already know in review | Right | preserve `already_know` |
First left may show “Didn't know — we'll show it again”; subsequent appearances show “Learning”. No fake attempt counter unless stored explicitly. Build a unique queue of **published, locally available** word IDs for chosen group; include unmarked/`didnt_know`, exclude known/learned except deliberate review. Reinsert left-swiped word after up to three others; never duplicate waiting IDs. If only one unresolved word remains, show “Try Again” rather than endless auto-repeat. Fetch all relevant local downloaded words (and online pages when needed) before claiming session complete; do not declare completion with unknown words. Pause/exit, persist session ID, selected group, ordered pending IDs, current position and session outcomes in Drift; restore after process restart. If a word is retired during sync, gracefully remove it from active queue without losing historical progress. Commit swipe transition and pending sync operation **in one local SQLite transaction**; disable duplicate swipes during local commit, show retry on local failure. Do **not** block on Firebase when offline. Update shared local state immediately after successful local commit, mark cloud sync pending separately. Session results must reflect actual committed local outcomes, with sync status distinguished.

## 9. Mandatory offline-first local database
Drift/SQLite is the primary student UI read/write source on Android, iOS and Windows. Define normalized tables with foreign keys, indexes, migrations and stable IDs, including:
- `words`, `word_senses`, `sense_examples` (or lossless equivalent), publication/revision/tombstone metadata;
- `downloaded_groups`/download manifests, version, completeness and last sync;
- `user_progress` keyed by `(uid,wordId)`;
- `learning_sessions` and `learning_queue_items` keyed by UID/session;
- `pending_sync_operations` with `operationId`, UID, wordId, desired status, base revision, local logical sequence, createdAt, retry count, state and last error;
- `sync_cursors`/metadata keyed by dataset and UID;
- optional `settings` scoped by UID.
Use SQLite transactions for atomic word/sense/example downloads and for progress+outbox commits. Enforce unique constraints and foreign keys. Add migrations and tests. Cache only published content for students; never persist admin drafts into student database. Respect secure private-data storage policy. Downloaded vocabulary is available without network after first successful download or from an optional **reviewed, versioned bundled dataset**; never assume all remote vocabulary is available offline before download.

### Offline learning acceptance
With airplane mode on, users can browse all downloaded words, see every sense and paired example, search/filter locally, swipe both directions, save progress immediately, repeat unknown words, view locally computed statistics, pause and resume sessions after restart. Show accurate downloaded-only versus global totals; never label a partial download as complete. An offline pronunciation button works only with a locally installed compatible English TTS voice; explain missing voice without claiming guaranteed offline TTS. New Google/email login and password recovery require internet.

## 10. Vocabulary download and content versioning
Download controls: Basic, Intermediate, Advanced, or All Published; include all three difficulties, senses, translations, examples and stable IDs. Show per-group count, bytes if known, progress, pause/cancel/retry, downloaded status, last successful sync and version. Fetch in bounded pages, validate each record and use atomic staged download/commit so interrupted downloads never falsely mark a group complete. Ensure partially downloaded content is clearly labeled and only complete verified groups get “Available Offline”. Support initial reviewed bundled content with explicit schema/content version and later incremental updates.

**Critical:** A plain `updatedAt` query over current published documents cannot discover deleted/unpublished records. Implement a **trusted monotonic content revision and change feed with tombstones**, or a versioned published manifest/snapshot plus deletions. Every publish, edit, unpublish and retirement must update the feed atomically/consistently from privileged server operations. Student sync obtains changed words and removal IDs after a durable cursor, validates continuity, applies changes transactionally, and advances cursor **only after commit**. Handle missed history via full snapshot reconciliation; design retention and rollback. Prevent client access to draft payloads via public change feed. Handle admin edits while download is in progress. Validate complete group version before showing offline-ready.

## 11. Progress sync protocol and conflict resolution (mandatory)
Do not simply rely on Firestore's implicit offline cache: Drift owns the operational state and the app uses an explicit outbox. Define a documented **server-authoritative, idempotent, revision-aware** sync API via callable/HTTPS Cloud Functions or trusted transactional Firestore workflow. Preferred protocol:
1. Local swipe commits `(UID,wordID,status)` and an outbox operation with stable UUID and monotonic per-device sequence in the **same Drift transaction**.
2. On reconnect/auth availability, sync only the currently authenticated UID; acquire a single-flight sync lock; process queued operations in causal order per word, with bounded batches, backoff and retry.
3. Server validates auth, App Check where configured, UID, word publication, operation ID, payload and status; atomically deduplicates operation ID, checks the expected server revision, applies change, increments revision, and returns authoritative state/revision. Persist bounded idempotency records with documented retention and safe retry window.
4. On acknowledgement, atomically mark/remove matching outbox operation **only if its local version is still current**; never erase a newer offline edit. Do not drop unacknowledged operations. Reconcile remote progress updates and remote deletions with the pending local state.
5. **Conflict policy:** never blindly overwrite newer local unsynced state with an older remote snapshot. For a server revision mismatch across devices, preserve local pending operation, fetch authoritative state and surface/resolve conflict under a documented deterministic policy. Suggested policy: server revision ordering with explicit rebasing of the latest locally committed user intent for the same word; avoid using client wall-clock timestamps as authority. If a true semantic conflict cannot be resolved safely, show a conflict state and let user choose. Guarantee eventual convergence under retries; explain ordering semantics. For repeated same-word offline swipes, compact outbox only if preserving required ordering/intent and dedup semantics; retain latest local intent and audit-safe identifiers.
6. Fetch all pages of current UID's remote progress (or incremental server-side change feed) without per-word N+1 reads; reconcile after uploads, not before clobbering pending state. Maintain per-UID sync cursor and last successful sync time.
7. Download content changes and tombstones, apply locally with atomic transactions; handle retired words and progress references. Sync ordering: upload pending progress, reconcile remote progress, fetch content updates; if an operation targets retired content, return a typed permanent failure, preserve local history, remove from active queue and surface appropriate status.
8. Handle connectivity flapping, app termination mid-request, duplicate acknowledgement, 401/permission denied, revoked users, missing indexes, quota, 429, 5xx, schema mismatch and stale cursors. Connectivity detection is only a hint; actual network success determines sync state. No infinite retry loops.
9. Show sync status: `Offline`, `Changes pending`, `Syncing`, `Up to date`, `Sync failed`, `Conflict requires attention`; provide manual Sync Now and last successful sync time. Never equate local save with remote backup.
10. Test two-device concurrent edits and server dedup under retries. If implementation chooses a simpler last-write-wins rule, it must be server-defined, deterministic and explicitly acknowledge possible overwritten intent; do not claim conflict-free semantics without tests.

## 12. Dashboard and progress calculations
Student My Learning: counts of `already_know`, `learned`, `didnt_know` (UI Learning) and unmarked for **currently published, locally known** words; completion `((already_know+learned)/total_published)*100`, with zero denominator handled. Distinguish downloaded-group/offline counts from **global published totals** that may be stale offline. Provide Continue Learning, Review Learning, Review Learned, Review Already Known, Browse Unmarked. Progress for retired words may be retained historically but excluded from published totals. Do not count pending unsynced updates as cloud-backed; local UI can reflect them with pending badge. Never fabricate global totals or calculate them from a partial page. For large datasets use server-maintained trusted aggregates with privacy limits; avoid full scans on every view.

## 13. Firebase rules and security
Implement tested deny-by-default Firestore/Storage rules and Cloud Function authorization. Public/guest can read **only published, non-retired** word documents and safe public content manifest/change records. Queries must satisfy rules; rules are not filters. Only content_manager/super_admin may change vocabulary, preferably through audited server Functions; prevent direct bypass of change-feed/versioning. Users read/edit only permitted fields of own profile/settings, never role or trusted timestamps. Progress scoped by authenticated UID; enforce status enum, doc ID/word ID match, verified-email policy if enabled, published-word existence, schema/size limits, and server-controlled revisions. If using server-only progress writes, **deny all direct client progress writes** and expose the validated sync function instead. Protect privileged user lists, role changes, account disabling, deletion, imports, audit logs and aggregates with super-admin claims. Validate Storage MIME/size/owner. Use App Check as defense in depth, not as substitute for authorization. Prevent last super-admin removal, privilege escalation, cross-user writes, IDOR, excessive payloads, replay and leaked secrets. Rate-limit sensitive Functions, log safe structured errors, monitor abuse. Add Emulator tests for all allowed and denied cases.

## 14. Pronunciation and bilingual content
Use `flutter_tts` to speak English **spelling**, not phonetic text. Select supported English voice, stop prior speech on card changes/exit, expose speaking/unavailable/error state and accessibility label. Check whether installed voice works offline; if not, show an actionable offline-voice installation hint. Do not invent audio URLs or use paid TTS. Every sense has separate English and Bengali meanings and ordered example pairs. If reviewed Bengali translation is missing, explicitly show “Bengali translation unavailable” and prevent publication when editorial policy requires it. Preserve all senses and Unicode in local/remote serialization. No AI-generated production vocabulary without editorial approval.

## 15. Search, filtering and paging
Support category/difficulty, part of speech and authenticated progress-status filters. Use local Drift indexed search over downloaded words including Bengali Unicode and English spellings/meanings, with appropriate normalization. Debounce ~300ms, cancel/discard stale results, avoid duplicate IDs, maintain selection. For online discovery use supported Firestore indexed fields/tokenization or documented search backend; Firestore cannot do arbitrary substring/full-text queries. Cursor-based pagination with stable ordering, proper error handling and no fabricated page counts. Detail deep links fetch locally first and then remotely when available; handle 404/retired/unpublished gracefully. Offline status-filtered lists derive from current UID's local progress, not cross-account data.

## 16. UI, accessibility, localization
Material 3, polished cards, restrained color, clear typography, Bengali-friendly fonts, responsive mobile/tablet layouts and desktop admin, dark mode, semantic labels, high contrast, touch targets, keyboard support, text scaling, screen-reader announcements, progress indicators, empty/error/retry states, no accidental horizontal swipe during vertical card scroll. Student navigation Home/Vocabulary/My Learning/Account; Downloads and Sync Status accessible. Admin dashboard sidebar Dashboard/Words/Imports/Users/Audit/Settings, gated by role. Provide bilingual UI labels if existing localization supports it; otherwise establish extensible English/Bengali localization without inventing translations. Show explicit local save versus cloud sync feedback.

## 17. Operational behavior and data lifecycle
Use per-environment Firebase projects, secrets in server-managed configuration, Git-safe config and `.gitignore`, appropriate Android/iOS OAuth setup, Hosting domain and HTTPS, Firestore indexes, rules, App Check, function runtime/region and budget alerts (alerts are not hard caps). Set up monitoring for auth failures, function errors, sync retries, storage and read/write costs. Document backups/export and disaster recovery for vocabulary; ensure server publication revision history can be reconstructed. Admin unpublish/retire propagates as tombstones to downloaded clients at next sync; acknowledge that already-downloaded content cannot be remotely removed while a device stays offline. Define privacy notice, retention, deletion and recovery. Implement schema migration handling and version compatibility; clients must fail safely on unknown enum/schema versions.

## 18. Tests and acceptance scenarios
Use unit, widget, integration and Firebase Emulator Suite tests, including:
- Email registration/login, Google provider flow boundaries, verification, reset, account linking, profile edit, logout, deletion, revoked/disabled account, provider conflict, cross-account isolation.
- All nine groups, empty group, 20-per-group target not hardcoded, multiple senses (noun and verb, repeated POS), Unicode Bengali, bilingual example ordering, TTS and no installed offline voice.
- Guest browsing but no guest progress writes, protected student writes, published-only reads, retired 404, Firestore indexes and query behavior.
- Swipe transition matrix, repeated unknown scheduling after up to three others, unique queue IDs, one remaining unknown Try Again, pause/resume, no false completion, vertical scroll and button equivalence.
- **Airplane mode:** previously downloaded words remain browseable, searchable, pronounceable only with installed offline voice, swipes locally committed, progress and queue survive restart, dashboard reflects local state.
- Interrupted/partial downloads never marked complete, content version updates, tombstones/unpublishing, old manifest cursor recovery, admin concurrent edits.
- Outbox atomicity, app crash after upload before acknowledgement, duplicate operation ID, concurrent same-word swipes, two-device conflict/rebase, stale remote snapshot, out-of-order network replies, quota/network retry, manual sync, account switch mid-sync, logout while pending, rejected retired-word update.
- Admin role denial, super admin bootstrap, last super admin protection, content manager least privilege, CRUD, publication, import preview/errors/idempotency, user disable/delete, audit logs, no leaked private information.
- Drift schema migrations, foreign keys, UID isolation and deletion, Firestore rule tests, callable Function validation, Storage rules, accessibility, responsive UI.
- Run `dart format`, `flutter analyze`, `flutter test`, Firebase emulator tests, and relevant integration tests. Report real outputs and distinguish blocked external setup from code failures. Do not claim unrun tests passed.

## 19. Implementation phases
1. Inspect repository, document current architecture, agree supported platforms and set up monorepo/shared models.
2. Configure dev Firebase, Auth, claims bootstrap, Firestore schemas/rules/indexes, Functions and emulators.
3. Implement student email/password + Google auth, profiles, account lifecycle and guest flow.
4. Implement admin auth/roles, responsive shell, user management, word CRUD, publication, imports, audits.
5. Implement content manifest/revision/tombstone publication pipeline; tests before student sync.
6. Implement Drift tables/migrations, bundled-content import if supplied, downloads, local browse/detail/search and TTS.
7. Implement swipe deck, exact state transitions, local atomic progress+outbox, persistent learning queue and local dashboard.
8. Implement authenticated sync protocol, idempotency, conflict handling, remote progress merge, content delta reconciliation, statuses and retries.
9. Implement all UI polish, accessibility, localization, platform integrations, admin Hosting and app release config.
10. Test end-to-end offline/online, security, concurrency, migrations, performance, cost and documentation; fix defects.

## 20. Definition of done and required handoff
Deliver two independently buildable Flutter apps sharing one secure Firebase backend. Student must work with downloaded vocabulary in airplane mode, preserve local swipes and unfinished sessions across restart, and sync safely later without leaking users' data. Admin must securely manage vocabulary, bilingual senses/examples, publication, import, user status and roles, with privileged server operations and audit logs. Google and email/password sign-in must work on verified target platforms. Content revisions and tombstones must reach student devices when online; no draft content leaks. Rules, indexes, functions and migrations are checked in. Provide file/change summary, architecture diagram, schema and sync protocol, Firebase Console setup checklist, environment and deploy commands, security/bootstrap steps, test outputs, cost considerations and explicit remaining limitations. Never claim completed functionality without verified implementation. **Begin inspecting the repository and implementing now.**

## Windows scope clarification (user requirement)
Windows is a required offline-first Student App platform, alongside Android and iOS. Apply all offline acceptance scenarios to Windows with network disconnected, including downloaded content, local search, progress, session restart, outbox durability, UID isolation and reconnect/multi-device sync. Use native Drift/SQLite and an app-private application-support directory. Pronunciation requires an installed compatible English voice verified offline. Firebase registration alone does not verify desktop auth or sync. The current cloud_functions plugin lacks Windows support; implement and test an authenticated HTTPS transport using the same server validation/idempotency contract, including token refresh and applicable App Check policy, rather than assuming native callable support.

## Current repository layout (user-selected)
The suggested monorepo tree above is adapted to the existing folders: Student App `users/`, Admin App `admin/admin_panel/`, shared packages `users/packages/`, shared backend `users/firebase/`, Firebase CLI configuration `users/firebase.json`, and documentation `docs/` at repository root. Keep this layout and preserve Firebase registrations.
