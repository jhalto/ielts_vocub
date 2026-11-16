# Phase 5: Student offline foundation audit and hardening

Follow-up: the user subsequently authorized aligning Android with the existing com.example.ielts_vocub Firebase registration. See android_configuration_check.md for the correction and new verification; the build failure below is the historical Phase 5 result.

## Existing foundation retained

Phase 2 already delivered native Drift/SQLite storage, staged full downloads, English/Bengali search and filters, all nested senses/examples, exact swipe transitions, a unique persistent session queue, local statistics and atomic progress/session/outbox commits. This task audits and strengthens that implementation rather than adding another database or learning flow. The current users/, admin/admin_panel/, users/packages/ and users/firebase/ structure is unchanged.

SQLite schema remains version 1. No table layout change, database reset or data migration is required. Existing stable word IDs, sense IDs, private progress, installation identity, queued operation IDs and session order are preserved. Unsupported database versions still fail closed without attempting destructive recovery. Reopen, integrity, foreign-key and version rejection tests now exercise this behavior explicitly. A future schema change must include a real versioned migration and preservation tests; rejecting unknown versions is not an implementation of arbitrary future migrations.

## Changes and evidence

- Strict manifest decoding validates schemaVersion=1, exactly nine known groups, integer nonnegative counts/revision, optional publisherVersion=1 and optional totalPublished equality. The Phase 3 publisher's extra metadata remains compatible, as does the original version-1 manifest without optional publisher fields. Counts are copied into an immutable snapshot. The closing manifest must retain both revision and counts.
- Staged constructor-created words are validated through the published wire decoder. Final commit rejects unpublished/retired records and revisions newer than the manifest. Strict increasing IDs across and within pages prevent cursor skips. The existing 100-document query bound and 10,000-word snapshot cap remain.
- Cancellation is checked at both ends of the SQLite commit transaction. Late cancellation rolls back words, completeness markers, queue pruning and staging removal together. Download failure discards staging; process interruption leaves staging that is discarded on reopen. Retry restarts the snapshot, preserving the previous completed content.
- Session creation and Try Again now use the same transactional account-change checks as swipes. Real AuthController-to-SQLite tests verify logout/account-switch cleanup deletes only the previous UID's private rows and keeps public downloads and the incoming UID's data.
- Database opening forces initialization, closes failed handles and resets the cached opening future so Retry can succeed. Debounced/paginated local read failures show a retry state instead of escaping as unhandled futures. Disposed/unauthorized views avoid further reads/actions. Widget tests cover guest read-only access, database-open retry and mobile dropdown layout.
- Firestore manifest/page reads have 30-second deadlines. These deadlines stop awaiting a failed read; they do not cancel the underlying SDK request. No late result stages data after a timed-out awaited call.
- Android main manifest now includes Internet permission for release authentication/downloads and the installed flutter_tts plugin's Android 11+ TTS service visibility query. MainActivity's package typo is corrected to match the existing Gradle namespace; applicationId and Firebase registrations are unchanged.

No dependency or package version was added or upgraded. No production vocabulary, Firebase deployment, remote progress uploader, delta-feed consumer, import or user-management feature was introduced.

## Actual checks

- Native local_learning tests: 16 passed, including all seven original cases. Added coverage includes rejected drafts/retired records/future revisions, late cancellation, malformed manifests, unsorted pages, same-revision count changes, interrupted staging/reopen, stable outbox IDs, unsupported schema versions, account changes during session writes, injected SQLite write failure and group moves/revision rollback.
- Student tests: 5 passed (existing counter regression, two real SQLite/auth cleanup tests and two offline UI tests).
- Isolated demo Firebase Emulator Suite: 19 passed (4 rules, 2 account/bootstrap, 11 publication, 2 Admin queries). No live project was targeted.
- Fresh server-exported demo snapshot passed the updated Dart manifest decoder, shared models and actual Drift downloader, preserving bilingual payloads and all nine complete groups.
- Student/repository and local_learning static analysis: no issues. Final Dart formatting and git diff --check passed.
- Windows debug build passed: users/build/windows/x64/runner/Debug/ielts_vocub.exe. Existing Firebase C++ dependency LNK4099 debug-symbol warnings remain. The build used the previously prepared Firebase C++ SDK 14.1.0 and NuGet temporary tool paths documented in windows_offline_acceptance.md.
- Android debug build was attempted and failed at processDebugGoogleServices: no matching client for com.jhaltoLab.VocabSwipe. Checked-in google-services.json registers com.example.ielts_vocub. This existing registration/applicationId mismatch is not a Drift/Dart failure. Firebase registrations and Gradle applicationId were preserved. The Flutter tool also warns that selected plugins still apply Kotlin Gradle Plugin; no dependency migration was attempted.
- iOS build/device checks were not run: this host is Windows, and the existing Firebase options do not configure iOS. macOS/Xcode, the final iOS Firebase registration and device acceptance are required.

The initial new Student test harness had an invalid await on a void test-view method; it was corrected before the passing run. New style warnings were corrected before final clean analysis. The passing automated SQLite tests are native Windows executions, not evidence of Android/iOS execution or physical airplane-mode acceptance.

## Files changed in Phase 5

- users/packages/local_learning/lib/local_learning.dart
- users/packages/local_learning/test/offline_foundation_test.dart (new)
- users/packages/local_learning/test/publication_contract_probe.dart
- users/lib/features/offline/offline_panel.dart
- users/test/offline_foundation_test.dart (new)
- users/android/app/src/main/AndroidManifest.xml
- users/android/app/src/main/kotlin/com/example/ielts_vocub/MainActivity.kt
- docs/phase5_handoff.md (new), implementation_plan.md, data_schema.md and windows_offline_acceptance.md

Phase 4 changes already present in the working tree were preserved and are not counted as new Phase 5 work. The Admin application and backend runtime/rules/indexes were not changed by Phase 5.

## Manual acceptance and remaining limitations

Use the cross-platform sequence in windows_offline_acceptance.md on Windows, Android and iOS after each platform's setup is ready. First download approved managed publication content online, then physically disconnect, restart, browse/search all senses/examples, swipe, resume a queue, check guest restrictions and switch/logout accounts. Verify a compatible installed English voice with networking disabled. Automated tests mock speech; a compiled executable does not establish offline TTS, OAuth or restored Firebase sessions on a device.

For Android, deliberately reconcile the existing package-name mismatch before claiming a working APK: choose the intended applicationId, then use the matching registered Firebase Android configuration and OAuth fingerprints. Do not manually rewrite google-services.json IDs or silently rename the app to bypass the check. MainActivity now matches the current com.jhaltoLab.VocabSwipe namespace. For iOS configure the intended bundle ID, Firebase options/plist, URL schemes and platform tooling. Native Windows Google sign-in remains unavailable in the selected plugin; email/password remains the supported Windows path.

No new Firebase Console change is needed for the stricter downloader itself. Existing account/publication endpoints, deployed rules/indexes and reviewed content are still prerequisites for live use. Legacy unmanaged fixtures cannot be adopted into the publication pipeline automatically. Use fresh demo emulators for managed publication acceptance. Integration tests clear their demo dataset and must not share an acceptance session.

SQLite is unencrypted; UID filtering, transactional guards, secure_delete and logout clearing are application isolation, not protection from privileged disk/backup access. Isolate demo acceptance from valuable real app data (for example with a separate OS test account); the current app-support database filename is shared by launches of the same installed application. No private database files were opened or altered by this task's tests, which use temporary/in-memory databases.

Full snapshots reconcile removals only within the selected download scope; All Published reconciles all local groups. Other groups become explicitly incomplete when a newer global revision is downloaded. Devices receive no automatic unpublication while disconnected. Remote progress synchronization, conflict resolution, incremental content feeds, backup/encryption policy and release UX remain separate work. Outbox records are durable pending local intent, not a cloud backup. No delta cursor or pretend sync state was added.

Stop after Phase 5 and await approval. Do not repeat the already implemented Drift/download/learning phases; select a bounded next task against the remaining synchronization and platform-acceptance gaps.
