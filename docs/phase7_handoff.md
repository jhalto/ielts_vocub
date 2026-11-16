# Phase 7 handoff: Student progress synchronization client

## Delivered and preserved

The native Student panel now connects its existing Drift outbox to the Phase 6 progressApi through authenticated HTTPS. Android, iOS and Windows use the same transport; native cloud_functions support is not required. Drift remains the operational source of truth. Swipes, sessions and local statistics do not await a Firebase request.

Sync Now explicitly uploads this account's saved pending learning and retrieves complete paginated progress. Automatic progress sync is off by default for every UID on this device, including upgraded databases. Enabling it opts into a check every 30 seconds while the panel exists and Dart execution is available, after local saves, and on app resume. This is not an OS background service or a connectivity guarantee. Permanent policy/schema failures stop automatic attempts until manual intervention; network failures use bounded retries and server rate limits retain their next-retry time.

The UI reports not-yet-synced/pending, syncing, offline, failed, conflict or up-to-date state, unresolved count and last successful sync time. That timestamp advances only after a complete remote reconciliation with no unresolved local work. A later offline swipe immediately makes the derived state pending again. Local save is never presented as a cloud acknowledgement.

Existing users/, admin/admin_panel/, users/packages/ and users/firebase/ structure, Firebase registrations, backend production APIs, security rules, indexes and stable word/sense IDs are preserved. No imports, user management, content delta consumer or deployment was implemented.

## Local schema and transaction boundaries

LearningStore schema version is now 2. The version-1-to-2 migration adds request_payload and supersedes_operation_id to pending_sync_operations, plus remote_progress, progress_staging, sync_status and an outbox word/sequence index. It preserves all existing content, progress, queue order, installation identity, operation IDs, sequences and original payload fields. Unsupported future versions still fail closed. Tests create a real version-1 SQLite fixture rather than relabeling a version-2 database.

Before transmission, the client atomically freezes an operation's exact JSON and marks it inflight. Retries/restarts reuse that stored payload and ID; they do not rewrite baseRevision or status under an old ID. Retry counts and error metadata are durable. A run sends at most 100 operations in batches up to 25, selecting the earliest unresolved operation per word. Conflicted/rejected words block later operations for that word while other words can proceed.

Acknowledgements validate schema, count, operation ID, word ID, status and revision against the exact persisted request. SQLite atomically marks matching operations applied and records authoritative progress. Newer pending swipes retain their local status and remain unresolved. If acknowledgement storage fails after the server saves, the unchanged inflight row safely replays on retry. Applied rows are retained as local history rather than silently discarded.

Remote pages stage separately until a complete revision-consistent snapshot is validated. Page order, IDs, cursor shape/repetition, response schema and revision bounds are checked. Snapshot changes restart from page one, at most three attempts. A run reads at most 200 pages of up to 100 rows. Interruption, invalid data, rollback or missing previously known remote records fails without partially materializing staged pages. Staging is cleared on database reopen; a persisted syncing phase becomes an explicit interrupted failure. The backend has no progress-deletion API, so unexplained loss of known remote records is not interpreted as permission to erase local history.

Remote progress for words not downloaded yet is retained without a word foreign key. Only downloaded words materialize into user_progress; later local refreshes attach their stored remote state when content becomes available. Materialization preserves unresolved local intent and removes remotely known/learned words from ordinary active queues. Explicit review queues retain their review filtering. No remote vocabulary payload or content change feed is fetched by progress sync.

## Conflicts, rejection and UID safety

Conflicts show local/server status and require confirmation. Keep latest local intent fetches fresh remote state and transactionally creates a new durable operation ID/base revision, linked to the original conflict. Earlier attempts become superseded history with original payloads intact. Use server progress explicitly replaces that word's pending intent after confirmation; superseded attempts remain in history. A confirmation bound to an older local operation cannot discard a swipe committed while the dialog/network request was outstanding.

Word-unavailable results keep rejected history and remove the local card from active content/queues, invalidating that group's completeness. Retrying the saved intent requires refreshing published content and an explicit fresh operation. If the server has no progress, an explicit server choice means unmarked, with the previous attempts retained locally. The client does not silently retry terminal receipts as new requests.

Single-flight work is scoped to UID and the shared store. Token acquisition, refreshed-token retries and replies are checked against the captured UID. Private epoch checks run inside SQLite transactions; logout increments the epoch before clearing progress, outbox/history, remote shadows, staging, preferences and sessions. An old in-flight server request may already have committed to its original UID, but its late reply cannot recreate cleared rows or modify an incoming account, even after rapid reuse of the same UID. HTTP clients/listeners/timers stop when the view is disposed. No old UID's rows are sent using a new UID's credentials.

## Actual verification

- Shared native SQLite tests: 30 passed (16 existing plus 14 synchronization/migration tests).
- Student tests: 7 passed (5 existing plus 2 opt-in/status/explicit-confirmation UI tests).
- Full isolated emulator suite: 31 passed (30 existing backend/rules tests plus the new real Dart HTTP/Drift client probe). The probe uses two disposable device databases, managed synthetic publication fixtures and verified demo accounts; it covers competing edits, explicit rebase across restart, lost acknowledgements, newer swipes, pagination restart/interruption, account isolation and logout during a real request.
- The final real-client probe was repeated separately against fresh demo emulators after the final client changes; it passed. Repeated runs are not counted as additional unique tests.
- Shared package and Student static analysis: no issues. Dart formatting, new emulator-fixture formatting/syntax and git diff --check passed.
- Android debug APK and Windows debug executable built successfully. Final artifacts use users/build/app/outputs/flutter-apk/app-debug.apk and users/build/windows/x64/runner/Debug/ielts_vocub.exe.
- iOS compilation/device checks were not run: this Windows host has no macOS/Xcode and the existing iOS Firebase registration/options remain missing.

The new fault tests initially exposed an attempt to mutate an immutable Drift result map; the preparation code now copies results before freezing requests, and the final suites pass. SQLite acknowledgement failure is injected by a test-only trigger. No personal application-support database was opened by these tests, no installed Student app was launched during this phase, and no existing personal outbox was uploaded.

E: storage was insufficient for regenerating Windows intermediates. Only users/build/windows generated output was copied and verified into C:/Users/zobay/AppData/Local/Temp/vocabulary-phase7-build/windows; the workspace path is a junction to that directory. Source/app-private data were not moved. Keep the temporary directory while using that local build; clean/regenerate generated output if those files are removed. No global Flutter configuration was changed. Existing Firebase C++ missing-debug-symbol and Android older-Kotlin-plugin advisories remain dependency warnings, not build failures.

## Modified files in Phase 7

- users/packages/local_learning/pubspec.yaml and pubspec.lock: reused http 1.6.0 directly in the shared pure-Dart transport; no existing package versions upgraded.
- users/packages/local_learning/lib/local_learning.dart: schema migration, private epochs, outbox count and cleanup coverage.
- users/packages/local_learning/lib/src/progress_store.dart (new): transactional freezing, acknowledgements, staged reconciliation and durable conflict decisions.
- users/packages/local_learning/lib/src/progress_sync.dart (new): HTTPS transport, bounded synchronizer, response validation and statuses.
- users/packages/local_learning/test/progress_sync_test.dart and test/support/fake_progress.dart (new): migration/fault tests and test-only transport.
- users/packages/local_learning/test/progress_emulator_probe.dart (new): actual HTTP/two-device temporary-database probe.
- users/packages/local_learning/test/offline_foundation_test.dart: unsupported-version fixture advances from 2 to 3 because 2 is now supported.
- users/lib/features/offline/progress_adapter.dart (new): Firebase credentials and environment-selected endpoint.
- users/lib/features/offline/offline_panel.dart: native sync lifecycle, opt-in, manual action/status, conflict confirmation and current-UID remote materialization.
- users/test/progress_sync_widget_test.dart (new): opt-in/manual sync and conflict-confirmation UI tests.
- users/firebase/functions/test/progress_client.emulator.cjs (new) and run-emulators.cjs: guarded demo fixture and real client probe in the integration runner.
- docs/phase7_handoff.md, sync_protocol.md, data_schema.md, implementation_plan.md, setup.md, windows_offline_acceptance.md, progress_api.md and users/README.md: current client contract, evidence and acceptance boundaries.

Earlier worktree changes are preserved and are not newly attributed to this phase. Admin code, backend production implementations and registrations were not changed by Phase 7.

## Manual setup and remaining acceptance

The existing progressApi/accountApi/publication services still require a separately authorized deployment before live use. No Firebase provider/registration change or new composite index is required by this client. Verify email and refresh the account token. App Check provider setup/token forwarding remains unimplemented; do not enable REQUIRE_PROGRESS_APP_CHECK until a supported client strategy exists, especially on Windows. The UI surfaces attestation failures instead of bypassing authorization.

Use only demo accounts and disposable OS/app data for manual acceptance; the same installed application's app-support database filename is shared by demo/live launches. See setup.md for isolated emulator flags and the Dart binary environment variable required by the integration runner. On Android emulator use host 10.0.2.2, not localhost. Real OAuth, revoked-session device behavior, physically disconnected installed builds, voice availability and Windows-to-mobile hardware convergence still need manual acceptance. Windows native Google sign-in remains unsupported by the selected plugin; email/password is the supported Windows flow.

SQLite remains unencrypted. Applied/superseded history and server receipts grow until an explicitly reviewed retention policy exists; explicit logout deletes this UID's local private data/history after the existing unsynced-loss warning. There is no silent compaction, expiry or cloud-account deletion. Cross-process desktop coordination and OS background jobs are not supplied; use one active app instance per device for acceptance. Per-run limits may require another Sync Now for large backlogs; continuous competing edits can prevent a stable snapshot and require attention.

Content updates still use verified full downloads. Incremental content changes/tombstones, imports, user management, deployment and release polish remain outside this task. Stop after Phase 7 and await approval.
