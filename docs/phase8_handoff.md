# Phase 8 handoff: Student incremental content reconciliation

## Delivered scope

Implemented the Student content consumer for the existing trusted publication feed. The repository structure, Firebase registrations, Admin App, backend production functions, security rules, indexes and dependency versions are preserved. No deployment, production vocabulary, import, user management or unrelated UI feature is included.

Sync Now and the existing foreground automatic opt-in now run progress upload, complete progress retrieval, then content reconciliation. Drift remains the source for browsing and learning. Network reads do not hold a live-content transaction or prevent local swipes. The existing sync status records content failure/offline instead of claiming overall success; acknowledged progress remains acknowledged even if the content step fails. Automatic sync remains default off. Guests retain explicit full downloads and local public browsing; no guest private-progress synchronization is added.

The consumer refreshes only previously downloaded categories, each covering its three difficulty groups. It does not implicitly download a category the user never selected. A category checkpoint is trusted only when its three downloaded-group revisions match it. If categories have different verified baselines, the feed starts from the lowest cursor and validates every global revision through the opening manifest, including noops. Public content/checkpoints are shared across local accounts; private progress/outbox remain UID-scoped under the existing epoch/logout policy.

## Validation, atomicity and recovery

- Require manifest schema 1, publisher version 1, valid revision/retention bounds and all nine exact group counts. Read canonical 16-digit change IDs in increasing order, at most 100 records/page and a 10,000-revision window. Require contiguous revisions and known upsert/remove/noop actions. Noops cannot carry word IDs or draft fields.
- Collapse public changes by stable word ID, fetch final upserts in published/non-retired batches of at most 30, and validate payload schema, ID, publication state and exact upsert revision. Missing upsert data is unsafe; it is never accepted as an implicit tombstone. Public queries remain constrained even when the Student session has an editor role.
- Stage deltas separately. Require matching opening/closing revision, counts, publisher version and retention watermark. One Drift transaction checks the captured cache generation, updates content/search, checks exact selected-group counts, prunes removed/moved cards from queues, updates completeness/checkpoints, increments generation and deletes staging. Cursor/completeness never advances before this commit.
- Publication removal hides historical rows with published=0. Stable IDs, payload history, private progress, session outcomes, installation identity, local sequences and immutable outbox requests are retained. Republish restores visibility under the same ID. Existing active sessions are pruned rather than filled with new cards; new cards enter through the existing session/restart behavior.
- Manual full downloads and unavailable-word progress acknowledgements increment the public-cache generation. Staged older content work cannot overwrite those local changes. New swipes do not invalidate public content work and keep their current local status/pending intent.
- Missing checkpoints, expired cursors, excessive feed windows, gaps/invalid feed, missing upsert data, count mismatch or denied bounded public ID lookups use the existing verified ContentDownloader. It now stages the complete selected category set before one live replacement. Opening/closing metadata and counts must match, with a trusted publisher and a 10,000-word cap. A legacy manifest cannot downgrade a trusted recovery baseline.
- Concurrent manifest/local-generation changes retry incrementally up to three attempts. Failed/changing fallback snapshots preserve the prior committed cache and need a later retry; there is no unbounded loop. Global or per-word rollback fails closed. Unknown schema or malformed publication data cannot advance a cursor.
- Account epoch/cancellation checks run around network phases and inside final transactions. Logout/disposal cannot let a late content reply commit under a replaced session. Incomplete staging is discarded at restart. Content work is single-flight for the shared store; multiple concurrent desktop processes remain unsupported.

The emulator initially exposed permission denial for an explicit ID query naming a restored draft. The adapter now treats this as unsafe incremental lookup and uses a verified published-query snapshot. Rules were not loosened and no draft-read endpoint was added. Tests also cover an empty upsert lookup, closing-manifest races, failed multi-category recovery and late transaction cancellation.

## Migration

Drift schema is now 3. New tables:

| Table | Purpose |
| --- | --- |
| content_checkpoints | Per-category last committed trusted publication revision |
| content_cache_state | One generation counter for competing local content commits |
| content_delta_staging | Per-run stable word ID, revision and nullable payload; null represents removal |

Version 2 creates only these new tables/counter. Version 1 runs the existing progress migration first, then creates these tables transactionally. Tests use real previous table layouts. No old checkpoint is inferred from a legacy downloaded_groups revision: the first successful reconciliation establishes a verified snapshot for already downloaded scopes. Existing IDs, frozen request JSON and private history survive. Unsupported future versions fail instead of resetting the database. The existing version-1 migration test now verifies upgrade to 3, and the unsupported-version fixture advances to 4.

## Actual verification

| Check | Result |
| --- | --- |
| Shared native Dart/SQLite tests | 50 passed: 30 prior tests plus 20 content/recovery tests |
| Student Flutter tests | 7 passed, including existing opt-in/manual sync and explicit-conflict UI tests with an injected content source |
| Complete isolated Firebase emulator suite | 32 passed: 31 prior rules/backend/progress-client checks plus one real publication/feed/Drift content-client probe |
| Targeted content-client emulator rerun | Passed against fresh demo emulators after final recovery guards; repeated runs are not extra unique tests |
| Shared-package and Student static analysis | No issues found |
| Dart formatting / Node syntax / git diff --check | Passed; Git reports existing LF/CRLF conversion notices |
| Android debug build | Passed: users/build/app/outputs/flutter-apk/app-debug.apk |
| Windows debug build | Passed: users/build/windows/x64/runner/Debug/ielts_vocub.exe |
| iOS build/device acceptance | Not run: this Windows host has no macOS/Xcode; iOS Firebase registration/options remain outstanding |

The real content probe uses the production publication HTTPS API, public Firestore REST queries under the actual emulator rules and the production pure-Dart reconciler/Drift implementation. It exercises edits, group moves, noops/draft exclusion, unpublish/retire/restore/republish, interrupted closing reads/file reopen, concurrent publication, deleted feed records, advanced retention watermarks and server revision rollback. Separate native fault tests inject transaction failure/cancellation and newer swipes/manual downloads. The integration runner keeps the earlier real two-device progress probe.

Only loopback demo-vocabulary emulator endpoints, disposable demo credentials, synthetic reviewed fixtures and temporary SQLite databases were used. Tokens are passed to the child probe over stdin and are not printed. The owner bypass that alters feed/watermark fixtures exists only in test code. No personal application-support database was opened, no installed Student app was launched and no personal pending operations were uploaded.

Flutter target discovery found Android emulator-5554, Windows and browsers. No device installation/startup test was performed: those may open an existing personal app database. Native compilation and host/emulator protocol tests are automated evidence, not physical airplane-mode/device acceptance. The production FlutterFire content adapter compiles on Android/Windows; its device networking behavior still needs the isolated acceptance steps below.

The Windows build reuses the existing Phase 7 junction users/build/windows -> C:/Users/zobay/AppData/Local/Temp/vocabulary-phase7-build/windows. Generated output was not relocated again. Android retains com.example.ielts_vocub and its existing label/package setup. The existing Kotlin plugin migration advisory remains a dependency warning; no package upgrade was added. Local Node is 24.7; Functions still target Node 22, so deployed-runtime acceptance remains separate.

## Files changed in this phase

Earlier uncommitted work is preserved and is not newly attributed to Phase 8.

- users/packages/local_learning/lib/local_learning.dart: schema-3 migration, public generation/checkpoints, scoped atomic full recovery, stricter manifest equality.
- users/packages/local_learning/lib/src/content_sync.dart (new): validated bounded feed consumer, retry/fallback orchestration.
- users/packages/local_learning/lib/src/content_store.dart (new): staging, atomic content/count/queue/checkpoint commits.
- users/packages/local_learning/lib/src/progress_store.dart: unavailable-word handling increments content generation.
- users/packages/local_learning/lib/src/progress_sync.dart: guarded content callback after complete progress reconciliation.
- users/lib/features/offline/offline_panel.dart: published Firestore feed/ID queries and existing sync-lifecycle integration/error handling.
- users/packages/local_learning/test/content_sync_test.dart (new): 20 native content/migration/fault/ordering tests.
- users/packages/local_learning/test/content_emulator_probe.dart (new): real publication/feed/temporary-Drift acceptance probe.
- users/packages/local_learning/test/support/fake_content.dart (new): deterministic isolated feed fixtures.
- users/packages/local_learning/test/support/rest_content.dart (new): guarded public REST emulator adapter and test-only maintenance helpers.
- users/packages/local_learning/test/offline_foundation_test.dart: unsupported schema fixture uses version 4.
- users/packages/local_learning/test/progress_sync_test.dart: existing version-1 migration now expects version 3.
- users/test/progress_sync_widget_test.dart: isolated content-source injection for existing sync UI tests.
- users/firebase/functions/test/content_client.emulator.cjs (new): loopback/demo guarded fixture and real Dart probe runner.
- users/firebase/functions/test/run-emulators.cjs: includes the new content probe.
- docs/phase8_handoff.md (new), implementation_plan.md, sync_protocol.md, publication_api.md, data_schema.md, setup.md, windows_offline_acceptance.md and users/README.md: current contract, evidence, commands and acceptance boundaries.

No dependency, Firebase registration, production backend/rule/index, Admin screen or Android native configuration was changed by this phase.

## Manual setup, acceptance and remaining limits

No new Firebase Console setup is required specifically for Phase 8. Existing trusted APIs, rules/indexes and reviewed content must be present in the chosen environment for live use; any deployment requires separate authorization and was not performed. Verify existing published query indexes are actually deployed; emulator tests do not prove production index readiness. Do not reset the manifest revision or prune feed records outside a separately reviewed contiguous-prefix retention policy. Current production feed retention remains indefinite.

Follow setup.md for Java 21, project-local Firebase CLI, isolated firebase.test.json ports and VOCAB_DART_BIN. Follow windows_offline_acceptance.md's Phase 8 steps using only disposable OS/app data and demo accounts. Android emulators need host 10.0.2.2 for device-to-host traffic. Complete iOS Firebase/options/signing configuration on macOS and test mobile/Windows networking, offline process restart, real logout races, native Firestore behavior and installed TTS voices. Windows Google sign-in and App Check attestation limitations are unchanged; this phase adds no bypass.

An offline device cannot learn about unpublication until reconnecting. The last committed cache remains usable after a failed refresh; content errors are surfaced instead of claiming it is current. Continuous publication can prevent a stable snapshot, and very large recovery sets exceed the existing safety cap. Sync runs in the foreground through manual/opt-in flows; no OS background scheduler is added. SQLite remains unencrypted and historical rows/receipts remain retained under the existing policy. Account deletion, release operations and broader retention remain later scopes.

Phase 8 is complete. Stop here and await approval for any further phase.
