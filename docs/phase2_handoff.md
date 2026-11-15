# Phase 2 handoff

## Scope and delivered behavior

The user confirmed ielts-vocubs is development, with Email/Password and Google providers enabled, and explicitly authorized expanding Phase 2 to Drift, downloads and offline learning for Windows.

- Shared app_auth package serves Student and Admin: email registration/login, supported Google sign-in, password reset, verification/resend cooldown, Firebase session restoration, guest entry (student only), profile retry/name editing, provider/verification/creation-date display and logout.
- Firebase accountApi uses authenticated HTTPS on all clients, including Windows: validates/rechecks bearer ID tokens, revocation/disabled state, payload allowlists and rate limits; derives profile UID/email from Auth. Admin access additionally requires verified email and matching current trusted custom claims. No client-controlled role authorization.
- Server-only first-super-admin CLI: explicit project/UID confirmation, verified enabled target, immutable Firestore UID reservation, crash-safe retry, existing-admin protection and one safe audit event. No public bootstrap or role-demotion endpoint. Real bootstrap has not been run.
- Native Drift/SQLite store: lossless nested bilingual content, indexed groups, manifests/staging, UID progress, persistent learning session/unique queue, atomic progress/session/outbox commits and persistent installation identity/sequence. Versioned schema hooks and constraints fail safely on unsupported changes.
- Offline student UI: bounded category/all downloads, consistent manifest validation and atomic snapshot commit, cancellation/retry, local search/POS/status/unmarked filters, all senses/examples, system TTS with installation hint, exact swipe transitions, unique repeat scheduling, Try Again, automatic session restore, local counts and explicit pending-cloud status.
- Explicit logout warns about losing unsynced changes and clears private rows while keeping public downloads. Account switches invalidate stale asynchronous results; per-UID access prevents cross-account progress reads.
- Existing counter implementation remains intact and separately regression-tested. No production content invented, no cloud deployment, no role grants to real users.

## Remaining boundaries

Remote progress upload/dedup/conflict resolution, content delta feed/publication backend, admin vocabulary/import/user management, provider linking, password change, account deletion, photo upload and release localization/polish remain later work. Downloads require a trusted schemaVersion=1 manifest with currentRevision and exact flat groupCounts; the production publication pipeline does not exist yet. An emulator-only fixture command enables local testing. Cancellation restarts on retry rather than resuming a staged page. Snapshot cap is 10,000 words.

Native Windows Google sign-in is unavailable in the selected Google plugin; email/password is implemented. iOS registration remains missing. Real Google flows, production token persistence/revocation behavior, installed offline speech voices and physically disconnected packaged-app acceptance require manual device/browser checks. SQLite is not encrypted; strict UID isolation/explicit clearing do not protect against privileged local filesystem or backup access. App Check provider activation/token forwarding is not configured; the API has an explicit optional enforcement hook and always requires authentication/authorization.

## Modified and added source files

- Root: .firebaserc, README.md, pubspec.yaml, pubspec.lock, lib/main.dart, test/widget_test.dart, firebase.test.json.
- Student offline: lib/features/offline/offline_panel.dart and offline_stub.dart.
- Windows: windows/CMakeLists.txt keeps generated runtime installation beside the executable, even when a plugin initializes CMake defaults.
- Shared authentication: packages/app_auth/{pubspec.yaml,pubspec.lock,analysis_options.yaml,lib/app_auth.dart,lib/src/auth_repository.dart,lib/src/auth_controller.dart,lib/src/firebase_auth_repository.dart,lib/src/auth_shell.dart,test/auth_controller_test.dart,test/auth_shell_test.dart,test/support/fake_repository.dart}.
- Shared local learning: packages/local_learning/{pubspec.yaml,pubspec.lock,analysis_options.yaml,lib/local_learning.dart,test/store_test.dart}.
- Firebase bootstrap: packages/firebase_bootstrap/lib/firebase_bootstrap.dart (configurable emulator ports).
- Admin: apps/admin_panel/{pubspec.yaml,pubspec.lock,lib/main.dart,test/app_test.dart}.
- Backend: firebase/functions/{package.json,src/index.ts,src/account.ts,src/bootstrap.ts,src/bootstrap_cli.ts,test/account.test.cjs,test/account.emulator.cjs,test/run-emulators.cjs,test/seed-offline.cjs}.
- Firebase tooling/indexes: firebase/{package.json,package-lock.json,firestore.indexes.json}. Existing deny-direct-write rules remain unchanged and are retested.
- Generated Flutter plugin registration refreshed under linux/flutter, macos/Flutter and windows/flutter as needed by the added plugins; these are generated, not hand-edited.
- Docs: architecture.md, data_schema.md, implementation_plan.md, sync_protocol.md, setup.md, windows_offline_acceptance.md, phase2_handoff.md.

Existing Firebase options, Google Services registration and Android Gradle integration were preserved. Test fixture credentials are confined to demo emulators; no service-account keys are committed.

## Verification recorded so far

- Student counter regression: 1 passed.
- Admin no-guest/no-registration bypass widget test: 1 passed.
- Authentication controller/UI tests: 10 passed, including registration callback-order cooldown and explicit logout cleanup.
- Native SQLite tests: 7 passed on Windows, including a file-backed close/reopen, download interruption/version mismatch, Unicode search/filters, exact transition matrix, unique queue, rollback and UID isolation.
- Backend unit tests: 2 passed; TypeScript build passed.
- Compatible Emulator Suite: 4 rule tests plus 2 account/bootstrap integration tests passed; guarded synthetic fixture command also succeeded in the combined run.
- Admin Web build passed. Static analysis: Student, Admin, app_auth, local_learning and firebase_bootstrap checked; final results recorded below.
- Original Windows build hit E: disk exhaustion extracting Firebase C++ SDK; generated Windows output was removed, without touching source. A version-matching SDK was placed in C: system temp via FIREBASE_CPP_SDK_DIR. The retry required a task-local NuGet binary for flutter_tts. Final desktop build outcome is recorded below.

Global Firebase CLI 14.15.2 cannot execute Functions SDK 7's removed config API. A pinned project-local CLI 15.36.0 and Java 21 passed the tests. Its cache uses a separate task directory when another running emulator locks the global JAR; default service ports were not disturbed. Temporary SDK/tool/cache paths are local build prerequisites, not production files or app data.

## Manual setup and next approved phase

See setup.md for the trusted bootstrap command, emulator ports, OAuth/iOS configuration, development deployment prerequisites, password policy and App Check limits. The user-enabled providers still require correct Android fingerprints, Web domains and iOS URL schemes. Deploy reviewed accountApi/rules/indexes explicitly before real profile setup; no deployment was performed here. For Windows ensure Visual Studio C++ tools, NuGet on PATH, sufficient build storage and a compatible English speech voice. Follow windows_offline_acceptance.md before claiming packaged offline support.

Ready for the next separately approved task: transactional publication/manifest/tombstone APIs, then verified production downloads; later progress sync consumes the durable outbox. No automatic continuation beyond this expanded Phase 2.

## Final build and acceptance evidence

Windows debug build passed: build/windows/x64/runner/Debug/ielts_vocub.exe. A hidden five-second startup smoke check passed and the process was stopped afterward; its only stderr output was the normal Impeller rendering-backend notice. Native dependencies required NuGet 6.14.0 on the build process PATH and Firebase C++ SDK 14.1.0 on C: via FIREBASE_CPP_SDK_DIR. The Windows CMake runtime prefix was corrected to the generated executable directory; no Program Files installation is required. Firebase SDK debug-symbol warnings are dependency linker warnings, not Dart/code errors. This smoke check does not replace physical offline/user-flow/TTS acceptance.

Final formatting: 19 Dart files, zero remaining changes; git diff --check passed. Static analysis reports no issues for Student, Admin, app_auth, local_learning and firebase_bootstrap. The final seven native-store tests passed after staging cleanup and snapshot validation refinement. The last Windows rebuild and Admin Web build passed. Nothing was deployed and no real admin role was granted. Phase 2 stops here.

## Repository relocation note

The paths recorded above describe the original implementation layout. Current locations: Student `users/`, Admin `admin/admin_panel/`, shared packages `users/packages/`, backend `users/firebase/`. Firebase commands run from `users/`. Package/import names consistently use `vocab_swipe`; native app IDs and Firebase registrations were not renamed. See setup.md for current commands.
