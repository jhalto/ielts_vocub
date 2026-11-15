# Phase 1 handoff

## Completed

Root Student App preserved, including its working counter and original FlutterFire registrations. Separate Admin Web build, pure Dart shared content models, reusable Firebase initialization, explicit demo-project emulator wiring, TypeScript Functions runtime foundation (no endpoints), read-only Firestore/Storage rules, browse indexes and Admin Hosting configuration added. No deployment, auth product flow, privileged endpoint, Drift database, downloads, swipe learning or sync implemented.

## Actual verification

- Dart format: 9 files, zero remaining changes.
- Static analysis: root Student App, Admin Panel, shared_models and firebase_bootstrap all report no issues.
- Student widget test: 1 passed.
- Admin widget test: 1 passed after final Material import correction.
- Shared model tests: 3 passed, including actual Bengali Unicode code-point assertion, nested round trip and invalid values.
- Firestore/Storage Emulator Suite: 4 passed, 0 failed; demo project only. Expected permission-denied messages occur for negative tests.
- TypeScript build and no-emit check: passed.
- Final Admin Web build: passed.
- git diff --check: passed (Git prints line-ending conversion warnings).

Firebase CLI 14.15.2 warns about existing FlutterFire metadata and Storage runtime emits a shutdown-only NullPointerException after successful tests. Local Node 24.7 differs from Functions Node 22 target; deployment runtime not verified. No Android/iOS/Windows device build or live Firebase smoke test was performed. iOS is not registered. Student Web/Windows offline support is unverified.

## Files added or edited by this task

- Root: .gitignore, README.md, analysis_options.yaml, pubspec.yaml, pubspec.lock, firebase.json, lib/main.dart.
- Android: android/app/src/main/AndroidManifest.xml (Internet permission).
- Generated plugin registration refreshed by Flutter: macos/Flutter/GeneratedPluginRegistrant.swift, windows/flutter/generated_plugin_registrant.cc, windows/flutter/generated_plugins.cmake.
- apps/admin_panel: pubspec.yaml, pubspec.lock, analysis_options.yaml, lib/main.dart, lib/firebase_options.dart, web/index.html, test/app_test.dart.
- packages/shared_models: pubspec.yaml, pubspec.lock, analysis_options.yaml, lib/shared_models.dart, test/models_test.dart.
- packages/firebase_bootstrap: pubspec.yaml, pubspec.lock, analysis_options.yaml, lib/firebase_bootstrap.dart.
- firebase: firestore.rules, firestore.indexes.json, storage.rules, package.json, package-lock.json, test/firestore.test.mjs, test/storage.test.mjs.
- firebase/functions: package.json, package-lock.json, tsconfig.json, src/index.ts.
- docs: architecture.md, data_schema.md, sync_protocol.md, implementation_plan.md, setup.md, phase1_handoff.md.

Existing user changes preserved: Android Google Services Gradle configuration, android/app/google-services.json, root lib/firebase_options.dart and docs/master_prompt.md. Root firebase.json was extended without replacing FlutterFire metadata. Generated output and node_modules are ignored.

## Manual setup and next phase

See setup.md for commands and environment checklist. Confirm project environment, configure separate staging/production projects and Admin Web registration, iOS registration, Auth providers/OAuth/SHA/domain settings, region and App Check. Review then explicitly deploy rules/indexes/Hosting when authorized. No administrators were provisioned; secure server bootstrap and role lifecycle remain for the next approved task. All client writes intentionally remain denied until validated APIs exist.

Ready for the next approved phase: authentication/profile lifecycle and trusted role foundation, using these schema and security boundaries. Phase 1 stops here.

## Windows scope amendment

User requires Windows offline-first alongside Android/iOS. Specification, architecture, implementation plan, sync contract and setup now reflect this. Bootstrap avoids unsupported native Windows Functions emulator setup; the authenticated Windows HTTPS API transport is deferred to the relevant phase. This amendment does not claim Windows offline functionality or device acceptance is complete.

## Repository relocation note

The paths recorded above describe the original implementation layout. Current locations: Student `users/`, Admin `admin/admin_panel/`, shared packages `users/packages/`, backend `users/firebase/`. Firebase commands run from `users/`. Package/import names consistently use `vocab_swipe`; native app IDs and Firebase registrations were not renamed. See setup.md for current commands.
