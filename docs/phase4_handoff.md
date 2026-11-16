# Phase 4 handoff: Admin vocabulary management

## Delivered

The existing Admin Flutter Web application now has responsive Words/Account navigation, theme switching, verified server-role gating, cursor pagination, spelling-prefix search and publication/category/difficulty filters. Listing uses online Firestore reads with 25 visible documents plus one lookahead, ordered by spelling and document ID. Search is case-sensitive and matches the beginning of spelling only; it is not substring, meaning or arbitrary full-text search. No collection scan or invented total count is used.

Create/edit supports every sense, repeated parts of speech, stable sense IDs, ordered English/Bengali examples, pronunciation, category, difficulty and ordering. Incomplete drafts are supported through a separate editor DTO; published content still follows the strict shared schema. Preview shows all senses/examples. Publication and changes to published content require explicit editorial review, which resets after edits. Published edits become public immediately after saving; a separate unpublished working-copy workflow is not included.

Publish/unpublish, retire and restore require confirmation. Restore returns content to draft. Dirty forms warn before internal navigation and register a browser beforeunload handler. Revision conflicts preserve local edits and offer an explicit comparison with the latest server version, followed by discard or deliberate rebase. Acknowledged operations whose follow-up read fails require reload before another edit; they are not resent.

Every vocabulary mutation uses the existing trusted contentApi. The client never writes vocabulary directly to Firestore. Requests freeze UID, operation ID and serialized payload; uncertain network results, token refresh and user retries preserve those bytes. Editing is locked while a request is pending. Same-UID authorization rechecks hide the entire workspace and preserve its dirty form; account changes destroy that workspace. Server authorization remains authoritative on every mutation. App Check is still an unconfigured optional deployment feature.

## Modified files

- admin/admin_panel/lib/main.dart: app theme, authentication and workspace composition.
- admin/admin_panel/lib/app/admin_gate.dart: shared authorization controller and UID-isolated nested navigation.
- admin/admin_panel/lib/app/workspace.dart: responsive navigation, indexed list, filters, pagination, loading/error/retry states.
- admin/admin_panel/lib/features/words/models.dart: draft DTOs, validation, cursors, immutable pending commands and responses.
- admin/admin_panel/lib/features/words/repository.dart: online Firestore reads and authenticated publication HTTP transport.
- admin/admin_panel/lib/features/words/controllers.dart: list/editor state, retries and revision conflict resolution.
- admin/admin_panel/lib/features/words/editor_page.dart: nested forms, review, state actions and confirmations.
- admin/admin_panel/lib/features/words/preview.dart: complete bilingual preview.
- admin/admin_panel/lib/features/words/browser_guard_stub.dart and browser_guard_web.dart: conditional browser exit protection.
- admin/admin_panel/pubspec.yaml and pubspec.lock: explicit Firebase Auth, Firestore and HTTP dependencies already present transitively; no package version upgrades.
- admin/admin_panel/lib/firebase_options.dart: formatter-only changes; Firebase registration values preserved.
- admin/admin_panel/test/words_test.dart, publication_client_test.dart, words_widget_test.dart and support/fake_vocabulary.dart: controller, transport, role and UI regression tests; fixtures are test-only.
- users/packages/app_auth/lib/src/auth_shell.dart: optional externally owned controller; default Student behavior preserved.
- users/firebase/firestore.indexes.json: eleven Admin list composite indexes added, existing indexes preserved.
- users/firebase/functions/test/admin_queries.emulator.cjs and run-emulators.cjs: real SDK query/pagination/permission coverage added to the isolated suite.
- docs/phase4_handoff.md and implementation_plan.md: current delivery, checks and operational limitations.

The existing users/, admin/admin_panel/, users/packages/ and users/firebase/ structure and Firebase registrations are preserved. Backend production functions and security rules were not changed. Imports, user management, audit viewer, remote progress sync and deployment are excluded.

## Actual verification

- Admin dependency resolution succeeded, without package upgrades.
- Dart formatting completed; final format verification and git diff --check passed.
- Admin flutter analyze: no issues. Shared app_auth analysis: no issues.
- Admin flutter test: 24 passed, including frozen retries, lost acknowledgements, conflicts, dirty navigation, publication confirmation, role denial, same-UID recheck retention and mobile layout.
- Shared app_auth flutter test: 10 passed. Student flutter test: 1 passed.
- Isolated Auth/Firestore/Functions/Storage emulator suite: 19 passed (4 rules, 2 account/bootstrap, 11 publication, 2 Admin query tests). Publication tests cover concurrent edits, idempotency, denied direct writes, manifest counts, tombstones and download compatibility.
- Admin flutter build web --no-wasm-dry-run succeeded; output is admin/admin_panel/build/web. This compiles the browser exit handler but does not prove a browser will display its native prompt.

The final checks used the installed Flutter SDK, pinned local Firebase CLI and Java 21. Emulator logs are ignored local artifacts. Index enforcement in production is not reproduced by the emulator, so these passing query tests do not prove the new indexes are deployed.

## Manual setup and local acceptance

ielts-vocubs was confirmed by the user as development, with Email/Password and Google enabled. This task did not inspect or alter the live Firebase console. Before live use, an operator must provide the existing accountApi/contentApi endpoints, review/apply the checked-in security rules and indexes, wait for indexes to become ready, and grant the intended verified account an approved server claim using the documented trusted bootstrap. See setup.md and publication_api.md. Refresh the session after claim changes. Never put Admin SDK credentials in the Web application.

No deployment or real role change was performed. A fresh managed dataset initializes on its first trusted mutation. Legacy/unmanaged word datasets require the reviewed migration described in publication_api.md; do not use the older offline seed fixture as a managed publication dataset.

For local manual acceptance, start a fresh demo emulator dataset. From users/:

```powershell
npm.cmd --prefix firebase/functions run build
node firebase/node_modules/firebase-tools/lib/bin/firebase.js emulators:start --config firebase.test.json --project demo-vocabulary
```

Then, from admin/admin_panel/:

```powershell
flutter pub get
flutter run -d chrome --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_AUTH_EMULATOR_PORT=19099 --dart-define=FIRESTORE_EMULATOR_PORT=18080 --dart-define=FUNCTIONS_EMULATOR_PORT=15001
```

Demo mode uses demo-vocabulary rather than the development project. Create and verify an emulator user using the existing Student authentication flow/Auth emulator, then use the existing server bootstrap CLI with both FIREBASE_AUTH_EMULATOR_HOST and FIRESTORE_EMULATOR_HOST set to the isolated ports and demo-vocabulary as the project/confirmation. See setup.md for bootstrap syntax. The integration test runner clears demo data and must not run against a manual acceptance session whose data should be retained.

Verify real Google OAuth in a browser with the correct authorized domains, native tab close/reload prompts after user interaction, keyboard operation and Bengali text rendering. Firebase Hosting still points to ../admin/admin_panel/build/web relative to users/firebase.json; Hosting has not been deployed. Enabling App Check enforcement requires client provider/token forwarding work first.

## Remaining limitations and next boundary

Pending operation IDs are retained in memory in the current editor/tab, including temporary same-UID authorization checks; they are not persisted across reloads or crashes. Browser warnings reduce accidental loss but cannot guarantee retention. After abandoning an uncertain operation, reload the authoritative word/list before starting new work. Cursor pages reflect live data and may shift when other editors change records; Refresh restarts pagination. The editor is online-only and does not add a second offline store.

Real OAuth/browser acceptance, deployed-index verification and production runtime checks remain manual. No later phase was implemented. The next task can build on the tested Admin workflow and existing publication contract, but the implementation order must account for the Windows offline functionality already delivered in the expanded Phase 2. Stop here and await approval.
