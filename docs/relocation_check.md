# Repository relocation check

Kept the user-selected layout: users/ Student App (Dart package vocab_swipe), admin/admin_panel/ Admin App, users/packages/ shared packages and users/firebase/ shared backend. Firebase registrations and feature behavior were not changed. No Phase 3 work or deployment was performed.

## Fixes

- Restored repository-wide .gitignore coverage for both apps, shared packages, backend generated output, emulator logs and local configuration.
- Added a repository-root navigation README and corrected Student README links to ../docs/.
- Updated architecture/setup/Windows commands for their actual working directories. Added current-layout notes to the specification and historical handoffs; corrected the AGENTS specification filename casing.
- Made the emulator runner resolve its working directory from its own path, so relocated test paths do not depend on the invoking shell directory.
- Removed the obsolete apps/ analyzer exclusion from the Student project.
- Removed only the generated users/build/windows cache: its CMake metadata still pointed to the pre-move source path. The next desktop build must regenerate it.
- Regenerated dependency resolution metadata for both apps and shared packages. Existing manual corrections to Admin dependencies, test imports, Hosting path and vocab_swipe naming were preserved.

## Verification

- Dependencies resolved for both apps and all four shared packages.
- Formatting: 21 Dart files checked, zero changes needed. git diff --check passed.
- Static analysis: both apps plus app_auth, local_learning, shared_models and firebase_bootstrap report no issues.
- Tests: Student 1, Admin 1, authentication 10, local SQLite 7, shared models 3, backend unit 2, emulator rules 4 and account/bootstrap integration 2: 30 passed in total.
- Emulator-only fixture command passed; all runs used demo-vocabulary and isolated ports/cache.
- Firebase source/rules/index paths resolve from users/. Hosting points to ../admin/admin_panel/build/web.
- Admin Web build passed from admin/admin_panel/; its output is at the configured Hosting path.

## Remaining limitations

Windows/Android/iOS native builds and physically disconnected learning/TTS were not rerun in this relocation task. Existing OAuth/iOS/App Check and later publication/progress-sync limitations are unchanged. No real admin bootstrap or cloud deployment was run. Git still represents the user's unstaged moves as deleted old paths and untracked new folders until staged; no staging or commit was performed.
