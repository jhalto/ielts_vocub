# Foundation setup and verification

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

## Phase 3 publication backend

contentApi is implemented but not deployed. Read publication_api.md before creating content or planning deployment. It requires verified current editor custom claims, explicit reviewed publication, operation IDs and expected revisions. All direct writes stay denied. The isolated emulator runner now tests publication in a fresh synthetic dataset after earlier rule/account tests; production data is not seeded or migrated. The legacy offline fixture script is for download-only demo acceptance and does not create the trusted publisher registry. See phase3_handoff.md for actual results.
