# Foundation setup and verification

## Phase 11 trusted user administration setup

Read user_admin_api.md and phase11_handoff.md before live adoption. No new Firebase registration, package or index is required. This phase changes Firestore rules and adds managed checks to existing account/content/import/progress APIs. A separately authorized rollout must deploy those compatible gates/rules with userAdminApi BEFORE initializing the registry or changing roles. No deployment, live bootstrap/adoption or real-user mutation was performed. Verify least-privilege server IAM for Auth get/list/update/revocation and Firestore transactions; emulator success does not prove deployed IAM or Node 22 runtime readiness.

Initialize only in a maintenance window with the existing sole completed bootstrap UID, after all bootstrap invocations and other Auth/registry writers have stopped. Use trusted operator IAM/Application Default Credentials, never client code/service-account keys in the app. From users/firebase/functions/ after `npm.cmd run build`:

```text
node lib/user_admin_cli.js ielts-vocubs initialize BOOTSTRAP_UID CONFIRM:ielts-vocubs:BOOTSTRAP_UID
```

This is a future operator command, not an action executed here. Initialization adopts the existing verified/enabled bootstrap member at version 0; it refuses additional existing super-admin claims/incompatible records. Projects with multiple unmanaged super admins need separate reviewed migration. Do not delete users/registry records or rerun old bootstrap to bypass that refusal. After adoption use only the managed API for role/status changes. Targets must sign in again after the returned reauthenticateAfter time; stale/new-claims-but-old-session tokens cannot bypass the managed gates.

If a worker is retained, do NOT assume its age means it stopped. Establish from runtime/provider state that the old invocation terminated AND unknown Auth writes settled. The helper also requires a minimum 120-second age and compatible frozen Auth state. Only then, under trusted IAM:

```text
node lib/user_admin_cli.js ielts-vocubs unlock OPERATION_KEY CONFIRM:ielts-vocubs:TERMINATED_AND_AUTH_SETTLED:OPERATION_KEY
```

This clears the worker only; resume the immutable operation through userAdminApi and inspect completion. A different current managed super admin may resume. No automatic takeover, rollback, public force/unlock, background worker or deletion workflow exists. Unexpected Auth drift requires operator diagnosis, not changed retry payloads or reset counters.

REQUIRE_USER_ADMIN_APP_CHECK optionally enforces caller attestation. Configure valid providers/token forwarding before enabling it; current Admin clients do not yet include user-management screens. Existing HTTP gates can return account-change-pending/session-stale for managed accounts; callers must preserve local intent and obtain a fresh eligible sign-in rather than retry stale tokens indefinitely. Public/offline vocabulary stays usable; server changes cannot erase offline caches.

From users/firebase/functions/: `npm.cmd run check` and `npm.cmd test`. From users/: the existing complete demo emulators:exec command now runs user_admin.emulator.cjs LAST, after prior Admin/Student probes. Keep Java 21, project-local CLI, VOCAB_DART_BIN and VOCAB_FLUTTER_TOOLS_SNAPSHOT as documented above. This guarded suite resets ONLY its hardcoded loopback demo Auth/Firestore namespace; never use it with manual acceptance data or a real project. Targeted invocation uses `node --test firebase/functions/test/user_admin.emulator.cjs` as the emulators:exec command. No user-management UI or native build is part of Phase 11.

## Phase 10 Admin JSON import workflow

The Admin navigation now includes JSON imports. Read import_api.md for the schema and phase10_handoff.md for the tested workflow and manual browser acceptance. No new Firebase registration/provider, dependency, index or rule is required. importApi and the existing publication/account infrastructure must be present for live use; they are not deployed by this phase. Existing valid App Check provider/token forwarding remains manual setup before enforcement. No CSV/export or automatic publication is added.

From admin/admin_panel/ run `flutter pub get`, `dart format lib test`, `flutter analyze`, `flutter test` and `flutter build web`. The guarded real HTTP/controller probe is deliberately named test/import_emulator_probe.dart so ordinary tests do not contact Firebase. The demo integration runner invokes it explicitly and never opens browser session storage or personal application data.

The complete emulator runner now also needs the installed Flutter tools snapshot for this probe. On this Windows host set `$env:VOCAB_DART_BIN='C:/flutter/bin/cache/dart-sdk/bin/dart.exe'` and `$env:VOCAB_FLUTTER_TOOLS_SNAPSHOT='C:/flutter/bin/cache/flutter_tools.snapshot'`, then run the existing users/ emulators:exec command with firebase.test.json and demo-vocabulary. On other hosts use the corresponding paths inside the installed Flutter SDK. Have Java 21 and the project-local Firebase CLI available. Targeted execution uses `node --test firebase/functions/test/admin_import_client.emulator.cjs` as the command passed to emulators:exec. Credentials reach the Flutter child through a test-only environment value, not command arguments/logs.

For manual browser acceptance start a separate demo emulator session (not the resetting integration runner), provision only disposable verified demo editors through trusted emulator tooling, and use an isolated browser profile. From admin/admin_panel/: `flutter run -d chrome --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=localhost --dart-define=FIREBASE_AUTH_EMULATOR_PORT=19099 --dart-define=FIRESTORE_EMULATOR_PORT=18080 --dart-define=FUNCTIONS_EMULATOR_PORT=15001`. Existing Firebase bootstrap selects demo-vocabulary when emulators are enabled; no Firebase registration change is needed. Do not use personal accounts, application data or production imports for these checks.

Allow browser sessionStorage to retain an unconfirmed frozen create request across reload; this can temporarily contain draft text. Confirmation removes the text and retains only the job ID. Logout/account replacement clears that owner's checkpoints, including after leaving the import page; role refresh preserves same-UID work. Session storage is unencrypted and may be unavailable/cleared by browser policy or tab closure. If it cannot save a recovery checkpoint, creation stops before making a mutating request. Keep the visible job ID for server-side lookup. Browser picker/cancel, reload/beforeunload behavior, storage cleanup and real attestation still require manual acceptance; a Web build alone does not verify them.

## Phase 7 Student progress sync

The native Student client now supports Sync Now and opt-in automatic progress sync; see phase7_handoff.md. Upgraded installations do not upload until the user explicitly requests sync or enables it. No installed personal app was launched during development checks. Test only with demo accounts/disposable data and keep demo/live application-support storage separate, for example through a separate OS test account.

The integration runner now runs a real Dart HTTP/Drift probe in temporary databases. Have Dart available on PATH or set VOCAB_DART_BIN to the Dart SDK executable. From users/ on this Windows environment, use `$env:VOCAB_DART_BIN='C:/flutter/bin/cache/dart-sdk/bin/dart.exe'` before the existing isolated emulator command. The runner creates verified synthetic demo accounts and clears its demo Firestore dataset; never share it with manual acceptance data.

For manual isolated Android-emulator acceptance use `flutter run -d emulator-5554 --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=10.0.2.2 --dart-define=FIREBASE_AUTH_EMULATOR_PORT=19099 --dart-define=FIRESTORE_EMULATOR_PORT=18080 --dart-define=FUNCTIONS_EMULATOR_PORT=15001` (replace emulator-5554 with the actual device ID if needed). Windows uses localhost and the same port flags. iOS needs its existing missing Firebase/platform setup first. Sync uses direct authenticated HTTPS; it does not depend on native cloud_functions support.

Final Windows verification uses a local generated-output junction: users/build/windows points to the task temporary vocabulary-phase7-build/windows directory on C: to avoid E: disk exhaustion. Source structure and global tool settings are unchanged. Keep that target while using the artifact or regenerate generated output when cleaning builds. Neither native build was launched for personal-data acceptance. Real providers, attestation and device/network-disconnected checks remain manual.

## Phase 6 progress backend

progressApi is implemented but not deployed or connected to the Student App. See progress_api.md and phase6_handoff.md for the HTTPS envelope, verified-email policy, Windows compatibility, retention and actual tests. Existing project-local emulator commands below include the new progress integration suite. No new package, provider registration, composite index or direct client-write permission is required. Before separately authorized deployment review existing remote progress, backups, quotas and client attestation; REQUIRE_PROGRESS_APP_CHECK must not be enabled until supported providers and token forwarding exist. Never reset progress counters or prune receipts independently of progress data. Client outbox changes remain pending locally until a separate client task.

## Current Student Android identity

The selected existing Firebase Android registration, Gradle applicationId/namespace and MainActivity package are com.example.ielts_vocub. The app label remains VocabSwipe; the Flutter package remains vocab_swipe. Keep google-services.json and FirebaseOptions aligned with that existing registration. See android_configuration_check.md for the repair and actual build/startup evidence.

From users/, run flutter analyze, flutter test and flutter build apk --debug. The APK is build/app/outputs/flutter-apk/app-debug.apk. Verify debug/release signing certificate fingerprints on the existing Firebase registration before Google sign-in acceptance. Release signing is still the existing debug fallback and must be configured before distribution. A previous installation using a different Android applicationId has its own sandbox; this correction does not migrate or clear that installation's data.

Run commands from `users/` unless stated otherwise. The repository root contains both `users/` and `admin/`. Existing Firebase project: `ielts-vocubs`. No cloud resources were created or deployed by Phase 1.

## Dependencies

- `flutter pub get`
- `flutter pub get` in `../admin/admin_panel` and `packages/firebase_bootstrap`
- `dart pub get` in `packages/shared_models`
- `npm.cmd ci` in `firebase` and `firebase/functions` on Windows (`npm ci` elsewhere)

## Local emulators

Use an installed Firebase CLI and compatible Java runtime (current Firestore emulator may require Java 21+; check CLI output). `users/firebase.json` retains FlutterFire metadata and configures Auth 9099, Firestore 8080, Functions 5001, Storage 9199, UI 4000.

1. Build Functions: `npm.cmd --prefix firebase/functions run build`.
2. `firebase emulators:start --project demo-vocabulary`
3. Student: `flutter run --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=10.0.2.2` for Android emulator; use localhost for desktop/browser, LAN host for physical devices.
4. Admin, in `../admin/admin_panel`: `flutter run -d chrome --dart-define=USE_FIREBASE_EMULATORS=true`.

Emulator mode uses a demo project and dummy Firebase options, not live resources. All wired Auth/Firestore/Functions clients must connect before use. Storage SDK is deliberately absent; media remains denied. Phase 2 exposes the authenticated accountApi endpoint. Emulator mode is explicit; normal launches use the existing project.

## Checks

- `dart format lib test packages ../admin/admin_panel/lib ../admin/admin_panel/test`
- `flutter analyze` and `flutter test` in `users/` and `admin/admin_panel/`
- `dart analyze` and `dart test` in shared_models
- `flutter analyze` in firebase_bootstrap
- `npm.cmd --prefix firebase/functions run check`
- `firebase emulators:exec --project demo-vocabulary --only firestore,storage "npm.cmd --prefix firebase test"`
- `flutter build web` in admin app

Rules tests seed test-only data through rules-disabled emulator contexts. Do not run them against the live project. No authentication provider integration or device acceptance is claimed by unit tests.

## Manual Firebase setup before later phases/releases

Confirm whether existing project is development; create independent staging/production projects and generate their configurations before using them. Register separate Admin Web app and generate its options. Register iOS with final bundle ID (Mac/Xcode needed for verification). Confirm final Android application ID before changing registration. Enable Email/Password and Google providers, configure password policy, support email, authorized Web domains and Android SHA fingerprints. Select Firestore region and align Functions region (`us-central1` currently); the client accepts FIREBASE_FUNCTIONS_REGION.

Review and explicitly deploy rules/indexes to the chosen environment when authorized; nothing auto-deploys. The baseline denies all writes, including profile/settings, pending validated feature APIs. Do not enable open test-mode rules. Storage is optional; its rules deny all access. Configure App Check and monitoring before real privileged endpoints launch. Never commit server credentials. Firebase client config is public identification, not authorization.

A secure server-only first-super-admin bootstrap is implemented in Phase 2; it has not been run against a real account. Admin Hosting deployment, role mutation/demotion workflows, deletion, app signing and production release remain later work. No role-removal API exists in this phase.

References: [FlutterFire setup](https://firebase.google.com/docs/flutter/setup), [Emulator setup](https://firebase.google.com/docs/emulator-suite/install_and_configure).

## Verified tooling notes

Verification used Flutter 3.50.0 / Dart 3.14.0, Firebase CLI 14.15.2 and Java 17. The CLI recognizes FlutterFire metadata only as an unknown-property warning; metadata is intentionally preserved. All four rules tests passed; Storage rules runtime printed a shutdown-only NullPointerException after the successful test exit. Local Node is 24.7.0; Functions deployment targets Node 22, so production runtime verification remains required. Test dependency majors are bounded to versions compatible with local Node.

Hosting configuration points to `../admin/admin_panel/build/web` (relative to `users/firebase.json`) with a single-page-app rewrite. Build from the admin directory before any explicitly authorized Hosting deployment. This configuration does not select a separate Hosting site or provision a domain.

## Required Windows target

Windows offline storage/download/learning code is implemented in Phase 2; see windows_offline_acceptance.md for verification and limits. Use `flutter run -d windows --dart-define=USE_FIREBASE_EMULATORS=true` for foundation checks and `flutter build windows` for build verification when the Visual Studio C++ toolchain is installed. Native Functions emulator wiring is skipped on Windows because the plugin is unsupported; Windows HTTPS API transport remains required. Verify Firebase desktop auth/provider support separately. Run every offline acceptance scenario with networking disabled: downloaded browse/search, swipes, persisted queue/progress after process restart, per-UID isolation, installed English voice and later reconnect sync. Verify SQLite packaging, writable app-private storage and migration upgrades in an installed Windows build. Phase 1 did not deliver offline features; the user authorized their implementation in Phase 2.

## Phase 2 account and role setup

The user confirmed `ielts-vocubs` is development and Email/Password plus Google are enabled. `.firebaserc` adds only a dev alias; there is no implicit default or production alias. No live configuration was changed by this task.

The account HTTPS API validates bearer ID tokens with revocation checks, derives UID/email from Firebase Auth, validates profile names, rate-limits per UID and refuses client role fields. All direct Firestore profile/progress/content writes remain denied. Deploy the tested accountApi function to the development project before expecting real profile setup to succeed; otherwise the app preserves its login and shows retryable profile setup. Firebase Auth sign-in itself uses the SDK independently.

Use `npm.cmd --prefix firebase ci` for the pinned project-local Firebase CLI (15.36.0); global CLI 14.15.2 is incompatible with Functions SDK 7 runtime interception. Use Java 21. `firebase.test.json` isolates test ports so an existing development emulator is unaffected. Run `npm.cmd --prefix firebase/functions test` for server unit checks and `node firebase/node_modules/firebase-tools/lib/bin/firebase.js emulators:exec --config firebase.test.json --project demo-vocabulary --only auth,firestore,functions,storage "node firebase/functions/test/run-emulators.cjs"` for integration checks. The runner seeds demo-only fixtures, tests rules, then tests account API/bootstrap. Use an isolated FIREBASE_EMULATORS_PATH if the global cache contains JARs used by another running emulator.

For real first-admin provisioning, use trusted operator IAM/Application Default Credentials outside the clients:

```
npm.cmd --prefix firebase/functions run build
node firebase/functions/lib/bootstrap_cli.js ielts-vocubs TARGET_UID CONFIRM:ielts-vocubs:TARGET_UID
```

Inspect the exact UID in Firebase Authentication first; it must be enabled and email verified. The immutable serverControl reservation permits retry for the same UID after a crash, refuses another UID and writes one audit record. No public bootstrap endpoint exists. Refresh the admin session afterward. No general role mutation/demotion is implemented; future role workflows must protect the last super admin transactionally. Do not commit service-account keys. The bootstrap was tested only in demo emulators, not executed on your development account.

Verify Android OAuth SHA fingerprints and updated Google Services configuration, iOS registration/bundle/URL scheme setup, and Web authorized domains (including localhost for local testing). Windows supports the selected Firebase Auth email/password SDK; native Google sign-in remains unavailable with the selected Google plugin. No client auto-merges accounts by email. Firebase's own trusted-provider behavior still applies. Real Google/provider flows require device/browser acceptance and cannot be proved by emulator tests.

App Check remains an explicit additional deployment step. accountApi can enforce REQUIRE_ACCOUNT_APP_CHECK=true, but no production attestation provider/token forwarding is configured yet, especially for Windows. Do not enable enforcement before a supported client attestation strategy exists; authentication/UID/role validation always applies. Remote authorization cannot be verified while offline.

See windows_offline_acceptance.md for local SQLite, fixture seeding, ports, privacy and disconnected-learning checks. Session restoration uses Firebase Auth's platform persistence, with no passwords stored by the app. Logout clears private local learning state; OS filesystem/backup access is not protected by SQLite encryption in this version.

## Phase 12 Admin user-management acceptance

The existing Admin app now exposes User management only to current super admins. No new Firebase registration, dependency, index or environment flag is required. The Phase 11 managed registry, compatible API gates/rules and userAdminApi remain prerequisites for a separately authorized rollout. This task did not deploy or initialize development/live Firebase. No browser registry initialization or worker unlock/force control is provided.

Use exact UID/email lookup or explicit 25-record native directory pages. Filters can produce empty matching pages with Next still available. Confirm reasons and target revisions before changes; do not rebase conflicts automatically. HTTP 200 is not completion: inspect pending/complete/recovery-required and worker ownership. Keep operation IDs/keys for trusted recovery; signing out clears local checkpoints without cancelling server work. Managed targets need a fresh sign-in after the receipt timestamp.

Run flutter analyze, flutter test and flutter build web from admin/admin_panel/. The existing full demo-emulator runner now also executes admin_user_client.emulator.cjs, which spawns the explicitly named user_admin_emulator_probe.dart. Set VOCAB_DART_BIN and optionally VOCAB_FLUTTER_TOOLS_SNAPSHOT to installed SDK paths as described in phase12_handoff.md. Fixtures refuse non-loopback/non-demo endpoints and reset only their disposable demo namespace; never run them against real accounts.

Manual browser acceptance remains: same-tab recovery/reload, blocked storage, unload/navigation prompts, responsive keyboard/focus, account/role transitions, real provider fresh-sign-in and supported App Check configuration. No valid attestation forwarding is newly configured. Follow user_admin_api.md for trusted worker recovery; time alone cannot prove uncertain Auth calls settled. See phase12_handoff.md for actual test/build results and file inventory.

## Phase 8 content reconciliation setup

No new Firebase registration, provider, dependency, function, security rule, composite index or environment flag is needed for this phase. Live use still requires the previously implemented trusted APIs/rules/indexes and reviewed content to be separately deployed under explicit authorization. No deployment is performed here. Keep the existing Firebase Android registration com.example.ielts_vocub. Complete the existing iOS registration/options/platform setup on macOS before iOS acceptance.

Sync Now now refreshes previously downloaded public categories after progress synchronization. Automatic sync remains the existing per-account/device opt-in, default off; guest downloads remain explicit full downloads. Upgraded databases establish verified content checkpoints on their first successful refresh, without resetting private data. Never use personal application data for development checks.

From users/packages/local_learning/, run `dart pub get`, `dart analyze` and `dart test`. From users/, run `flutter pub get`, `flutter analyze` and `flutter test`. Native builds are `flutter build apk --debug` and `flutter build windows --debug`; iOS requires macOS/Xcode. Windows generated build output may use the existing Phase 7 C: temporary junction documented in phase7_handoff.md; keep its target until rebuilding/cleaning generated output deliberately.

For emulators, use Java 21 and the project-local Firebase CLI as described above. Set VOCAB_DART_BIN to the actual Dart executable if dart is absent from the child process PATH. The existing complete command `node firebase/node_modules/firebase-tools/lib/bin/firebase.js emulators:exec --config firebase.test.json --project demo-vocabulary --only auth,firestore,functions,storage "node firebase/functions/test/run-emulators.cjs"` now includes content_client.emulator.cjs. It uses isolated demo credentials, synthetic reviewed words and temporary SQLite files, and refuses non-loopback/non-demo endpoints. Gap/retention/rollback manipulation uses a test-only emulator owner bypass; it is not application code. Do not point fixture scripts at a live project.

See phase8_handoff.md for actual results and windows_offline_acceptance.md for device steps. Existing App Check/client attestation and Windows Google-provider limitations remain unchanged; no authorization bypass is added.

## Phase 9 JSON import backend setup

importApi is exported alongside existing functions and has not been deployed. No new package, Firebase registration, security rule or composite index is needed. It uses the same current verified editor claims and optional REQUIRE_CONTENT_APP_CHECK enforcement as contentApi. A future explicitly authorized development deployment must include importApi and the existing trusted publication infrastructure; this phase performs no live writes/provisioning/deployment. Admin import screens are not implemented.

Read import_api.md before constructing files or retries. From users/firebase/functions/, run `npm.cmd run check` and `npm.cmd test`. From users/, the complete isolated emulator command documented above now includes import.emulator.cjs; targeted checks use `node --test firebase/functions/test/import.emulator.cjs` as the emulators:exec command. Keep project demo-vocabulary, firebase.test.json, loopback emulator hosts, Java 21 and VOCAB_DART_BIN for the existing Dart probes. The import suite refuses non-demo/non-loopback configuration and uses only synthetic disposable editor/student accounts and word fixtures. Never run test resets against a live Firebase project.

New jobs are request-driven (at most 50 items/job, 5/process request); a future Admin client must keep IDs, poll safe paginated receipts, inspect per-item failures and retry transient pending items with bounded backoff. There is no background job runner or automatic retention pruning. Review published edits explicitly and create new jobs for corrected conflicts. Manual production-like acceptance, valid App Check attestation, Node 22 runtime and deployment remain later authorized checks. See phase9_handoff.md for actual results.

## Phase 3 publication backend

contentApi is implemented but not deployed. Read publication_api.md before creating content or planning deployment. It requires verified current editor custom claims, explicit reviewed publication, operation IDs and expected revisions. All direct writes stay denied. The isolated emulator runner now tests publication in a fresh synthetic dataset after earlier rule/account tests; production data is not seeded or migrated. The legacy offline fixture script is for download-only demo acceptance and does not create the trusted publisher registry. See phase3_handoff.md for actual results.
