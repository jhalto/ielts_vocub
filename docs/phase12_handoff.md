# Phase 12 handoff: Admin user-management workflow

## Delivered scope

The existing Admin app now provides a super-admin-only user-management route. It uses userAdminApi for every directory, status and mutation request. No role, managed-account or operation record is read/written directly through Firestore. Backend production code, rules, registrations, Student code, package dependencies and database schemas are unchanged by this phase.

- Exact UID/email lookup, 25-record native pages and supported role/status/verification/provider filters. Filters apply to a bounded native page, so an empty matching page still offers Next when a cursor exists. No full-text search, totals or stable snapshot pagination are promised.
- Safe identity/provider/verification/status/role details with observed pending state and explicit stale-read warnings. Revision zero is ambiguous between legacy and initial managed state and is labelled accordingly. Raw claims, credentials and learning records are neither modelled nor rendered.
- Enable/disable and the three approved role choices, including student to revoke administration. Changes require a 5–500-character reason and explicit confirmation showing the target, previous state and revision. Administrative grants require an enabled, verified target. Self changes are disabled; the backend remains authoritative for last-super-admin protection.
- Frozen operation IDs, reason, body and revision/Auth-state preconditions. Confirmation is bound to the displayed target snapshot. Conflicts never rebase automatically: the operator explicitly reviews the rejected operation, requests a fresh account read and confirms a new operation/ID.
- Single-flight, bounded retries/backoff, status-by-key lookup and explicit same-key resumption of settled pending work. HTTP 200 can mean pending or recovery required. Known active workers cannot be resumed; uncertain workers direct the operator to the documented trusted IAM recovery process without browser unlock/force/bypass controls.
- Clear loading/error/cooldown, historical completion receipts and fresh-sign-in-after UTC guidance. Local timers only redraw cooldowns; there is no background polling or automatic mutation on reload.
- Dirty/unfinished-work warnings for navigation/signout and the existing browser unload guard. UID/role guards discard late responses and clear private state/recovery on signout, account switch or loss of super-admin access.

## Recovery and consistency

The existing guarded ImportClient transport is reused without import-job semantics. Requests are limited to 16 KiB; three total HTTP attempts include at most one token refresh, with 1/2-second transport delays. The controller then requires explicit retry, with 60-second quota cooldown, 5-second administration-busy cooldown and a bounded transient cooldown. Authentication/attestation failures show operator guidance and do not bypass server checks.

Before mutation, the exact immutable request is saved in the existing session abstraction, namespaced by endpoint and owner UID. A storage failure prevents a new submission. After validating an authoritative view against the frozen ID, actor, target, action, revision and intended effect, only the operation key/owner remains cached; the reason/body is removed. Malformed, mismatched or unexpected-effect responses do not clear unconfirmed intent. Read failures cannot mark an uncertain mutation rejected. A reload reads the checkpoint but sends nothing until the operator acts.

Tab recovery is unencrypted and best-effort. Until acknowledgement it contains the target, reason and preconditions, never tokens or credentials. Signing out or losing the role clears it; this does not cancel server work. Keep IDs/keys outside the tab when needed for trusted recovery. Another current managed super admin can inspect/resume the same server intent by key. No changed payload, automatic takeover, worker expiry or registry initialization is offered. The trusted process and cross-service consistency limitations remain in user_admin_api.md.

Completed receipts describe the original operation even if a later change updated the account. Current details require an explicit fresh read. Managed targets must sign in anew strictly after the returned timestamp; refreshing an old token alone is insufficient. Backend Auth/Firestore are not represented as atomic.

## Actual verification

| Check | Actual result |
| --- | --- |
| Admin full Flutter test suite | 82 passed: 50 prior tests plus 21 new model/controller and 11 new widget tests |
| Admin static analysis | Passed, no issues |
| Focused Dart formatting | Checked for the changed Admin source/tests |
| Complete isolated Firebase emulator regression | 61 Node checks passed, zero failures: prior 60 plus the new Admin client wrapper |
| New wrapper's real Flutter HTTP probe | 2 tests passed inside that wrapper; not counted as extra Node checks |
| Final Admin Web build | Passed, build/web generated; Wasm dry-run advisory appeared, build exit successful |

Model/controller tests cover safe projections, exact lookup, empty filtered pages, cursor/error preservation, confirmation preconditions, reason/self/grant guards, storage-before-send, immutable lost-ack retries, restart recovery without automatic requests, duplicate receipts, deliberate conflict correction, last-super-admin refusal, read-error isolation, malformed/mismatched acknowledgements, bounded cooldowns, owner isolation and historical receipts. Widgets cover role/navigation gating, one client across rebuilds, confirmations/cancellation, privacy, pending/resume/recovery messaging, continuation pages, unfinished-work warnings, role loss and narrow layouts.

The real HTTP probe uses the existing demo endpoint, a seeded settled pending operation and competing revisions. It traverses empty filtered pages, resumes the same key, verifies content-manager denial, rejects stale preconditions and drops a committed acknowledgement before asserting byte-identical retries. Server assertions verify final roles/status/revisions, preserved unrelated claims, registry count/released reservation and zero vocabulary changes. The complete suite also reruns existing rules, publication/import/progress/backend-administration tests and Student/Admin probes.

All emulator fixtures are synthetic and guarded to loopback demo-vocabulary. The test-only wrapper resets that demo Auth/Firestore namespace and invokes the existing trusted initializer only for isolated fixtures. No development/live Firebase initialization, real-user changes, personal browser/app storage, service-account keys or deployment were used. No real browser/device acceptance is claimed. Local Node is 24.7; deployed Node 22/runtime/IAM remain unverified.

## Modified files in this phase

New production files:

- admin/admin_panel/lib/features/users/models.dart
- admin/admin_panel/lib/features/users/client.dart
- admin/admin_panel/lib/features/users/controller.dart
- admin/admin_panel/lib/features/users/user_page.dart

Existing integration/recovery files:

- admin/admin_panel/lib/main.dart
- admin/admin_panel/lib/app/admin_gate.dart
- admin/admin_panel/lib/app/workspace.dart
- admin/admin_panel/lib/features/imports/platform_stub.dart
- admin/admin_panel/lib/features/imports/platform_web.dart

The session cleanup extension removes only user-admin checkpoints when an editor remains authorized for imports; existing import recovery remains intact.

New tests/fixtures and runner update:

- admin/admin_panel/test/support/fake_user_admin.dart
- admin/admin_panel/test/user_admin_test.dart
- admin/admin_panel/test/user_admin_widget_test.dart
- admin/admin_panel/test/user_admin_emulator_probe.dart
- users/firebase/functions/test/admin_user_client.emulator.cjs
- users/firebase/functions/test/run-emulators.cjs

Documentation:

- docs/phase12_handoff.md (new)
- docs/user_admin_api.md
- docs/implementation_plan.md
- docs/setup.md

Earlier uncommitted files remain intact and are not newly attributed to this phase. Generated builds/emulator logs are ignored. No new package or Firebase registration was introduced.

## Reproduction and manual setup

From admin/admin_panel/, use flutter analyze, flutter test and flutter build web. Use dart format --output=none --set-exit-if-changed on the listed changed Dart files. For the complete backend regression, from users/ run the existing project-local CLI:

```powershell
node firebase/node_modules/firebase-tools/lib/bin/firebase.js emulators:exec --config firebase.test.json --project demo-vocabulary --only auth,firestore,functions,storage "node firebase/functions/test/run-emulators.cjs"
```

Use Java 21 and the installed pinned CLI/dependencies. Set VOCAB_DART_BIN to the actual Dart executable if unavailable on PATH. This environment used C:/flutter/bin/cache/dart-sdk/bin/dart.exe and VOCAB_FLUTTER_TOOLS_SNAPSHOT=C:/flutter/bin/cache/flutter_tools.snapshot to avoid SDK launcher/cache locking. The new probe is explicitly named *_probe.dart so normal Flutter tests never contact Firebase. The full emulator command is destructive only to its guarded disposable demo namespace; never point fixtures at a real project.

There is no new Firebase setup for this UI. Before a separately authorized rollout, the existing Phase 11 gates/rules/userAdminApi and coherent managed registry must be in place. Initialization remains a separate trusted operator process; it was not executed on development/live accounts. Existing authentication, Web authorized domains, Functions region and App Check prerequisites remain. Valid App Check token forwarding is not added here; do not enable enforcement without supported callers.

## Remaining manual acceptance and scope boundary

Use disposable demo accounts for browser acceptance. Verify actual sessionStorage survival across same-tab reload, private/blocked-storage errors, unload prompt behavior, responsive keyboard/focus access, signout/account switch and role loss with a closed user route. Check real-provider fresh sign-in after the returned barrier and backend/IAM errors in the intended runtime. Widget tests use memory recovery storage; compiling Web does not prove browser lifecycle behavior.

With isolated emulators, manually inspect a known settled pending operation and confirm resume; inspect worker-owned/recovery-required states and verify the browser offers no unlock/force controls. Actual runtime termination and uncertain Auth settlement require the existing trusted operator process, never age-only browser recovery. No live operation is required for development checks.

No deletion, exports, browser registry initialization, deployment or unrelated feature was added. Backend and UI user administration are delivered; release acceptance and any further scope require separate approval. Phase 12 is complete. Stop and await approval.
