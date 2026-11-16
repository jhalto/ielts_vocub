# Windows offline acceptance

## Phase 8 incremental content acceptance

Use only disposable demo accounts and a separate test OS/app-data environment. Do not launch an existing personal Student installation with demo flags: the app-support database filename is shared between demo/live launches. Automated probes instead allocate temporary SQLite files and use the loopback-only demo-vocabulary project.

1. Download Basic and Intermediate in the isolated Student installation; leave Advanced undownloaded. Save swipes and a persisted queue, then disconnect/restart. Verify browsing, bilingual search, progress and the queue still work offline.
2. Reconnect and use the trusted Admin API/UI in the same demo environment to edit text/examples, change difficulty, move a word between downloaded categories and move it into/out of Advanced. Press Sync Now. Verify current content and queue membership update, IDs/history/pending intent survive and Advanced is not implicitly downloaded. Existing sessions are pruned; new cards enter through the existing session/restart behavior.
3. Unpublish and retire words, then restore and explicitly republish. Confirm hidden words leave browsing/queues; restore alone remains draft. Republish makes the same ID available and retains its learning history. Make a draft-only edit: a noop advances the checkpoint without caching any draft payload.
4. Interrupt networking or terminate the isolated process while reconciliation is reading. Reopen offline: the last committed cache/completeness survives and incomplete staging is discarded. Reconnect/retry; no partial category or premature cursor becomes visible.
5. Publish repeatedly during refresh. Verify bounded retry/failure preserves the previous complete snapshot, then retry after edits stop. A failed content refresh must not claim a newer successful sync time or resend already acknowledged progress as new operations.
6. Repeat on Android and, once its Firebase configuration exists, iOS. Check Windows-to-mobile progress isolation/conflicts continue to work and logout during content reads prevents late writes. Network-disabled installed builds, crash timing, voice availability and real-device acceptance remain manual; successful native builds do not establish those results.

Gap/retention-watermark/rollback injection is automated only in guarded demo emulators. Do not corrupt production feeds to repeat those tests. The actual verification and limits are recorded in phase8_handoff.md.

## Phase 7 progress acceptance

Progress sync is now implemented; older Phase 2/5 statements below about unimplemented progress upload are historical. Use a disposable demo account/database, then test Sync Now and the default-off automatic preference. With networking disabled, commit swipes and restart; inflight payloads, IDs and new local intent must remain. Reconnect and verify pending counts reach zero only after acknowledgement and a complete remote snapshot. No physical-device acceptance is claimed by the native build alone.

Use a second device/demo installation on the same UID, change the same word offline, then sync both. One operation must conflict rather than silently overwrite. Confirm Keep latest local intent or Use server progress; cancel must preserve the original pending work. Save another swipe during a sync/confirmation and verify an older result cannot replace it. Interrupt the process after server save but before local acknowledgement, then retry: the server revision must not increment twice. Switch/logout while a request is outstanding and verify no old progress appears under the incoming UID. Rejected unavailable words keep history and leave active queues. See phase7_handoff.md for automated equivalents and setup.md for safe demo ports.

Real Windows-to-Android/iOS hardware convergence, providers, attestation, installed offline voices, app data-at-rest/backup policy and iOS configuration remain manual. Do not use a valuable live installation for these destructive logout/interruption tests.

## Implemented

Native Drift/SQLite in the current OS user's application-support directory; persistent downloaded public content, UID-scoped progress/queues/outbox, atomic full-snapshot download, local English/Bengali search and filters, all senses/examples, exact swipe status transitions, unique reinsertion queue, Try Again for one unknown, session restart, truthful local statistics and pending-sync indicators. No cloud progress sync exists yet.

## Demo test data and services

Use Java 21 and the project-local CLI (`node firebase/node_modules/firebase-tools/lib/bin/firebase.js`). Build Functions first with `npm.cmd --prefix firebase/functions run build`. Run from `users/`:

```
node firebase/node_modules/firebase-tools/lib/bin/firebase.js emulators:start --config firebase.test.json --project demo-vocabulary
```

This uses Auth 19099, Firestore 18080, Functions 15001, Storage 19199. If a global emulator cache is locked by another process, set FIREBASE_EMULATORS_PATH to an independent task directory; do not remove another instance's files.

In another PowerShell terminal set `$env:FIRESTORE_EMULATOR_HOST='127.0.0.1:18080'`, then run `node firebase/functions/test/seed-offline.cjs`. The script refuses non-loopback hosts and non-fixture existing content, and always selects demo-vocabulary. It writes four clearly synthetic test words, not production translations.

That command is the historical Phase 2 standalone downloader fixture. Do not mix it with managed publication data or run it before testing Admin publication: its legacy manifest is intentionally not adopted by contentApi. For current end-to-end acceptance, use a fresh demo dataset, verified emulator editor claims and the Phase 4 Admin UI to create/review/publish test-only content through contentApi. Use a separate OS test account when switching the same installed Student App between demo/live mode, because its app-support database path is shared. Never overwrite valuable private local data for acceptance.

Run the Student App from `users/`:

```
flutter run -d windows --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_AUTH_EMULATOR_PORT=19099 --dart-define=FIRESTORE_EMULATOR_PORT=18080 --dart-define=FUNCTIONS_EMULATOR_PORT=15001
```

## Manual acceptance sequence

1. Register/sign in with an emulator email/password account. Check verification link in emulator output. No new login is promised offline. Native Windows Google sign-in is unavailable in the selected supported plugin stack.
2. Download Basic or All Published. Basic/easy contains four fixtures; the other fixture groups are empty and accurately counted. No group is marked complete before manifest/count validation and SQLite commit.
3. Close the app, stop emulators, and disconnect networking. Reopen the built app, using its restored session or guest entry. A profile retry warning must not block downloaded content.
4. Browse/search/filter, open all senses/examples, use Know It/Didn't Know, observe local statistics and pending-cloud-sync counts. A guest can browse but cannot save progress.
5. Leave an unfinished queue; terminate/reopen and verify its exact order. One remaining unknown requires Try Again. Right after Didn't Know yields learned.
6. Verify offline pronunciation with an installed compatible English system voice. Without a voice show an installation hint; do not claim every installed voice is offline-capable.
7. Check a second UID cannot see the first UID's private statistics/queue. Explicit logout warns about pending loss and clears private rows; public vocabulary stays.
8. Reconnect: profile setup can retry. Remote progress is still pending because synchronization is not implemented in this task.

Native file-backed SQLite tests run on Windows cover persistence, rollback, filtering and isolation. They do not prove packaged-app launch, installed speech voice, real Google flows or physical network-disconnection behavior. Windows SDK extraction originally exceeded workspace disk capacity; the debug build and hidden startup smoke subsequently passed. FIREBASE_CPP_SDK_DIR can point to a version-matching SDK on a drive with sufficient space without editing plugin sources.

## Limitations

Full snapshots are capped at 10,000 words per download. Cancellation discards staging and retry restarts rather than resuming pages. Production downloads use the Phase 3 trusted publication manifest; live endpoints/rules/indexes and reviewed content still require manual setup. There is no invented bundled production vocabulary. SQLite is not encrypted; records are strictly UID-scoped and cleared on explicit logout, but privileged local disk/backup access is outside that guarantee. No automatic remote removal while offline, remote progress backup, conflict resolution or account-deletion workflow is delivered here.

Verified local build prerequisites: Visual Studio C++ tools, NuGet 6.14.0 on PATH, Firebase C++ SDK 14.1.0 (the plugin-required version). The task used temporary C: directories to avoid E: space exhaustion. Keep NuGet installed/available and either sufficient workspace space or FIREBASE_CPP_SDK_DIR configured for subsequent builds. No global tool configuration was changed.

To reuse the build tools prepared during this task in a new PowerShell terminal:

```powershell
$env:FIREBASE_CPP_SDK_DIR = Join-Path $env:TEMP 'vocabulary-firebase-sdk-14.1.0/firebase_cpp_sdk_windows'
$taskNugetDirectory = Join-Path $env:TEMP 'vocabulary-build-tools'
$env:PATH = "$taskNugetDirectory;$env:PATH"
```

These settings affect that terminal only. If temporary files are removed, install matching tools in a durable location and update the paths. Then use the emulator launch command above or your explicitly selected development environment.

## Phase 5 cross-platform acceptance additions

Execute the sequence above independently on Windows, Android and iOS; a Windows native-store test does not verify mobile plugin integration. Windows debug compilation passed again in Phase 5. Android compilation was initially blocked in Phase 5 by applicationId versus google-services.json mismatch; the subsequent authorized repair aligns com.example.ielts_vocub and builds the debug APK successfully (see android_configuration_check.md). iOS requires macOS/Xcode plus its missing Firebase configuration. Native Windows Google sign-in remains unavailable; do not use that flow as the prerequisite for offline acceptance.

1. With managed test-only published content, Download All, record displayed revision/counts, make local progress and leave an unfinished queue. Include multiple senses, repeated parts of speech and ordered bilingual example pairs. Disconnect/restart and verify every field, Unicode search, progress, pending count and exact remaining queue.
2. Reconnect and change reviewed publication content through the Admin UI, then cancel a Student refresh midway. The previous snapshot must remain usable; cancelled pages must not change its completion marker. Retry restarts and commits one complete new snapshot. Changing content during a download must produce a retry message rather than a partially complete group.
3. Interrupt the process after some pages have downloaded, reopen without network and verify the last successful snapshot remains intact. Retry online. Staging is discarded on database open; it is never shown as published content. Automated tests simulate this boundary with file-backed close/reopen, rather than forcibly killing a physical device process.
4. Unpublish/retire a queued word through Admin, then refresh All Published. The word must disappear from browsing/active queues and published totals without deleting its historical progress/pending operation. Restore/re-publish the same ID and refresh; its saved learning status must remain. Category-only downloads are authoritative only for their selected scope.
5. Switch accounts while starting/replacing a session or committing a swipe. The old view must stop updating and no rows may be written under the incoming UID. Confirm logout's unsynced-loss warning. Guest entry must retain public downloads and show no private session/actions. Reopen as the other account and verify isolation.
6. Test an inaccessible/full disk and recovery on a disposable installation. Local commits must show an error and retain the prior queue/progress, with no falsely incremented outbox. The local-read Retry path must recover without an app restart. Do not edit a valuable database's schema version to test rejection; the automated temporary-file test already covers non-destructive unknown-version handling.
7. Verify offline installed English TTS, voice absence feedback, vertical scrolling versus horizontal swipe, buttons/keyboard navigation, large text and Bengali rendering on each target. Speech and real Firebase restoration are manual checks; no automated device acceptance is claimed.

No test here uploads remote progress. Reconnection only permits profile/content network work; local learning changes remain explicitly pending until a separately approved synchronization implementation.
