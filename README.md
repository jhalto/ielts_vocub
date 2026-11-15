# VocabSwipe repository

- `users/`: Student Flutter app (`vocab_swipe`).
- `admin/admin_panel/`: independent Flutter Web Admin app.
- `users/packages/`: shared Dart/Flutter packages.
- `users/firebase/`: shared backend, security rules and tests.
- `users/firebase.json`: Firebase/Hosting configuration; run Firebase commands from `users/`.

See [setup](docs/setup.md), [architecture](docs/architecture.md), [Phase 2 handoff](docs/phase2_handoff.md) and [Windows offline acceptance](docs/windows_offline_acceptance.md). From each app directory run `flutter pub get`, `flutter analyze`, and `flutter test`. No feature phase is implemented by the folder relocation.
