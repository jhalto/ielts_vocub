# Windows offline acceptance

## Implemented

Native Drift/SQLite in the current OS user's application-support directory; persistent downloaded public content, UID-scoped progress/queues/outbox, atomic full-snapshot download, local English/Bengali search and filters, all senses/examples, exact swipe status transitions, unique reinsertion queue, Try Again for one unknown, session restart, truthful local statistics and pending-sync indicators. No cloud progress sync exists yet.

## Demo test data and services

Use Java 21 and the project-local CLI (`node firebase/node_modules/firebase-tools/lib/bin/firebase.js`). Build Functions first with `npm.cmd --prefix firebase/functions run build`. Run from `users/`:

```
node firebase/node_modules/firebase-tools/lib/bin/firebase.js emulators:start --config firebase.test.json --project demo-vocabulary
```

This uses Auth 19099, Firestore 18080, Functions 15001, Storage 19199. If a global emulator cache is locked by another process, set FIREBASE_EMULATORS_PATH to an independent task directory; do not remove another instance's files.

In another PowerShell terminal set `$env:FIRESTORE_EMULATOR_HOST='127.0.0.1:18080'`, then run `node firebase/functions/test/seed-offline.cjs`. The script refuses non-loopback hosts and non-fixture existing content, and always selects demo-vocabulary. It writes four clearly synthetic test words, not production translations.

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

Full snapshots are capped at 10,000 words per download. Cancellation discards staging and retry restarts rather than resuming pages. Production downloads depend on the later trusted publication pipeline; there is no invented bundled production vocabulary. SQLite is not encrypted; records are strictly UID-scoped and cleared on explicit logout, but privileged local disk/backup access is outside that guarantee. No automatic remote removal while offline, remote progress backup, conflict resolution or account-deletion workflow is delivered here.

Verified local build prerequisites: Visual Studio C++ tools, NuGet 6.14.0 on PATH, Firebase C++ SDK 14.1.0 (the plugin-required version). The task used temporary C: directories to avoid E: space exhaustion. Keep NuGet installed/available and either sufficient workspace space or FIREBASE_CPP_SDK_DIR configured for subsequent builds. No global tool configuration was changed.

To reuse the build tools prepared during this task in a new PowerShell terminal:

```powershell
$env:FIREBASE_CPP_SDK_DIR = Join-Path $env:TEMP 'vocabulary-firebase-sdk-14.1.0/firebase_cpp_sdk_windows'
$taskNugetDirectory = Join-Path $env:TEMP 'vocabulary-build-tools'
$env:PATH = "$taskNugetDirectory;$env:PATH"
```

These settings affect that terminal only. If temporary files are removed, install matching tools in a durable location and update the paths. Then use the emulator launch command above or your explicitly selected development environment.
