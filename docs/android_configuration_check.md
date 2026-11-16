# Student Android configuration repair

## Scope and changes

The user explicitly selected the existing Firebase Android identity com.example.ielts_vocub. Student Gradle namespace/applicationId and MainActivity's Kotlin package now match that identity and the existing source directory. No Firebase Android registration was created or edited. The visible Android label remains VocabSwipe and the Flutter package remains vocab_swipe.

Files changed in this task:

- users/android/app/build.gradle.kts: namespace/applicationId aligned with the existing registration; replaced the obsolete application-ID TODO with the registration constraint.
- users/android/app/src/main/kotlin/com/example/ielts_vocub/MainActivity.kt: matching Kotlin package.
- users/android/gradle.properties: disables Kotlin incremental compilation to avoid the diagnosed Windows cross-drive cache failure.
- docs/android_configuration_check.md: this report.
- docs/setup.md: current Android identity and verification commands.
- docs/phase5_handoff.md: follow-up link resolving the historical configuration blocker.
- docs/windows_offline_acceptance.md: updates the Android build status without changing device acceptance requirements.

Existing worktree changes from earlier phases were preserved. The repository structure, app functionality, dependency versions and backend were not changed. No sync, deployment or cloud configuration work was performed.

## Verification

Student Dart formatting: six files checked, zero changes. Student static analysis: no issues. Student regression tests: five passed, covering the existing counter plus offline guest/retry and real SQLite account/logout isolation tests. No new tests were added for these identifier-only corrections.

The generated Google Services debug resource selects the existing Android app ID 1:545371482714:android:00256cac61214ca30b4663. Firebase source configurations are unchanged; their SHA-256 checksums were recorded during inspection:

- users/android/app/google-services.json: 8C4724DBC908C6286DC029FAC31DA4ACEF7C70ABBD1EEB4D2DF5AACFD449152C
- users/lib/firebase_options.dart: 88A1C3A3FE2E375DE4EC403E64EFFD1938FE33818288E403093F95A8F8143B6B

The generated merged debug manifest at users/build/app/intermediates/merged_manifests/debug/processDebugManifest/AndroidManifest.xml was parsed and checked: package com.example.ielts_vocub, launch activity com.example.ielts_vocub.MainActivity, application label VocabSwipe, android.permission.INTERNET and the android.intent.action.TTS_SERVICE visibility query are all present.

Final flutter build apk --debug succeeded. The artifact is users/build/app/outputs/flutter-apk/app-debug.apk (176,449,649 bytes). aapt also verifies the packaged APK's identity, label and launchable activity, rather than relying only on source declarations. git diff --check passed.

The available emulator-5554 (sdk_gphone16k_x86_64) accepted the APK with adb install -r: Success. The first cold am start -W timed out after approximately 101 seconds while native class verification/resource extraction continued. The app process remained alive, FirebaseInitProvider reported successful initialization and the Dart VM started. After waking/dismissing the emulator keyguard, a repeat launch returned Status: ok and delivered the intent to the running com.example.ielts_vocub.MainActivity (PID 25779). No fatal Android/Dart exception was found in the inspected app startup logs. This slow cold start is not recorded as a fast or clean cold-start acceptance pass.

Visual startup was verified by inspecting the screenshot at users/.dart_tool/android-configuration-startup.png: VocabSwipe renders the Welcome back screen with email/password, Sign in, Continue with Google, Forgot password, Create an account and Continue as guest controls. UI Automator exited 137 and screenshot capture was slow, but the screenshot ultimately completed without terminating a client. The app remained running as PID 25779. Installation, repeat launch and login-screen rendering are verified; real authentication, offline learning and TTS were not exercised. No sign-in or content mutation was performed.

The initial build passed Google Services selection but failed in flutter_tts, firebase_core and google_sign_in_android incremental Kotlin compilation. A targeted stack trace showed `this and base files have different roots`: Pub plugin sources on C: versus the repository on E:. The project now sets kotlin.incremental=false, using full Kotlin compilation without changing plugin versions, clearing global caches or editing developer-wide settings. This can increase Kotlin compile time.

After compilation succeeded, packaging initially exhausted E: disk space. The task reclaimed 663 MB of reproducible Windows compiler intermediates/debug symbols (.ilk/.pdb/.lib/.obj/.pch/.exp) only inside the verified users/build/windows directory. The existing Windows executable and runtime assets were retained; a future Windows rebuild regenerates these intermediates/symbols. Source and private app data were untouched.

## Manual setup and boundaries

For Google sign-in, verify this existing Firebase Android registration includes the actual debug/release signing certificate SHA fingerprints and corresponding OAuth configuration. This task does not verify real Google or email/password sign-in. Do not modify IDs inside google-services.json to force a match. Release signing still uses the existing debug-signing fallback and needs a proper release configuration before distribution.

Installing com.example.ielts_vocub does not migrate private Android app data from a separately installed com.jhaltoLab.VocabSwipe application. Those are distinct Android sandboxes; no old app was uninstalled and no private data was cleared or transferred by this repair. The current registration is preserved as authorized.

Physical-device offline learning/TTS and production endpoint acceptance remain manual. The selected plugins still trigger Flutter's advisory about older Kotlin Gradle Plugin application; dependency migration is outside this repair. No new Firebase registration, provider change, backend deployment or remote synchronization was performed. Stop after this task and await approval.
