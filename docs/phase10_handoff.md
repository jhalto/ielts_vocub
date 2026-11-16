# Phase 10 handoff: Admin JSON import workflow

## Delivered scope

Added JSON imports to the existing role-gated responsive Admin workspace in admin/admin_panel/. The workflow uses the Phase 9 importApi for every job/vocabulary mutation. It reuses current Firebase credentials, the existing approved vocabulary read repository, WordPreview, server-side publication validation and the existing browser unload guard. No direct Firestore job/vocabulary writes, Admin SDK client code or parallel publication implementation was added.

The UI supports:

- Browser JSON selection with extension/MIME/UTF-8/size/schema checks. The 512 KiB limit includes the final API envelope; 1-50 rows/job, 192 KiB publication mutation validation/item, 5 processing items/request and 25 receipts/page remain the backend limits. Invalid file/container errors appear before API calls; valid containers with malformed rows go to server dry run for row errors.
- Server-normalized spelling and content, all bilingual senses/ordered examples, existing publication/revision metadata, duplicate target IDs, publishability and safe row codes. Incomplete drafts are permitted without claiming they are publishable.
- Explicit create/update/skip choices, target/item IDs and expected revisions. Load current target shows existing content/revision; adopting that displayed revision requires a separate click. Raw row JSON can be corrected without flattening senses/examples. No create-to-update conversion, target substitution or automatic rebase occurs.
- Fresh published-edit review confirmation. Uploaded reviewed flags are removed. Editing a row invalidates its preview and all review flags; attestations alone preserve other unchanged row attestations, and a fresh dry run is required. Job creation has a separate confirmation explaining draft creation, immediate reviewed published edits, immutable plans and partial commits.
- Immutable job creation, visible selectable job ID, unknown-outcome status, unchanged creation retry, job-ID lookup, bounded processing and accurate server counts. HTTP 200 is never equated with all items succeeding. Applied/skipped/failed/pending counts remain distinct. Receipts display committed revisions/errors in explicit next/previous pages of 25.
- Durable server job/item identity and best-effort owner/environment-scoped tab recovery. Before the first creation POST, exact request JSON/job ID is stored in sessionStorage; if storage fails the request is not sent. Retry bodies and item IDs never change. Confirmation removes cached draft text and retains only owner/schema/job ID. Reload does not automatically submit/process anything; the user checks status or retries the same creation.
- Bounded transport retries (at most three HTTP attempts, including at most one token refresh) with one/two-second backoff and unchanged bytes. HTTP/item quota failures wait at least 60 seconds in the active view; other transient failures use a short explicit retry cooldown. No background loop or worker is added. Each processing click first retrieves complete paginated receipts, then selects up to five pending items; old acknowledgements are reconciled before more work is selected.
- Deliberate correction via Start new plan: old successful/failed receipts remain on the server, users reselect the source JSON, skip successful rows and explicitly choose fresh revisions. A frozen request cannot be edited. New plan/leave/sign-out dialogs explain that outstanding requests may commit and are not cancelled or rolled back by navigation.

The native Student App, shared packages, Firebase registrations, backend production APIs, security rules, indexes and dependencies are unchanged. No CSV, export, user management, automatic publication, deployment or unrelated Admin feature is included.

## Lifecycle, recovery and privacy

HTTP calls check captured UID and active request generation around tokens, delays and responses. Auth revalidation suspends acceptance of in-flight results; same-UID work survives reauthorization. Logout/account replacement clears private state/checkpoints and prevents late replies from restoring an old job ID. The workspace also clears the previous owner's browser checkpoints after the import page has closed. Each route creates one client, disposed with its controller; rebuilds do not create extra clients. Authorization failure requests the existing role/session refresh. App Check setup errors remain visible as operator setup issues rather than being hidden by a successful role recheck.

Recovery keys include API endpoint/environment and owner UID. Tokens/passwords are never stored. An unconfirmed creation temporarily stores its frozen JSON, potentially including unpublished draft text. sessionStorage is unencrypted, tab-scoped and best effort; it is not backup or an import-job catalogue. Browser policy, tab closure, crash/session restoration or manual clearing can remove it. Keep job IDs independently when work must be resumed later; the server job survives local cache loss. Only the owner can resume through the API. Logout requests cleanup, but browser access restrictions can prevent storage operations; use isolated profiles and avoid shared browser sessions for private editorial files.

Status pagination is the backend's live view rather than a frozen snapshot under concurrent workers. The UI shows authoritative server counts, labels live status and permits refresh; receipt states can reflect different page read times. Processing is safe because server item receipts are immutable and each run refreshes status before selection. Whole jobs/process requests are not bulk atomic; earlier successes survive later failures. The client never rewrites terminal attempts to resolve a conflict.

Changing a row to skip removes content from that wire row as required by the backend. To restore that row's content later, reselect the source file or use Edit row JSON. Status lookup intentionally returns safe receipts rather than original uploaded content; correcting terminal failures requires the original source file/content. There is no automatic conflict-content reconstruction or all-user job listing.

## Actual verification

| Check | Actual result |
| --- | --- |
| Admin dependency resolution | Succeeded through the existing Flutter toolchain; no dependency/lockfile change introduced by Phase 10 |
| Admin static analysis | No issues found |
| Admin unit/widget suite | 50 passed: 24 previous tests + 17 new import client/controller tests + 9 new screen tests |
| Complete isolated Firebase emulator regression | 45 Node test checks passed: 44 previous checks + the new Admin client integration wrapper |
| Real Admin Flutter client integration | Its 2 actual HTTP/controller tests passed inside that wrapper; not counted again as extra Node checks |
| Focused real Admin probe before regression | Passed; repeated checks are not additional unique tests |
| Formatting / Node syntax / git diff --check | Passed; existing Git LF/CRLF notices remain |
| Final Admin Web build | Passed: admin/admin_panel/build/web; WebAssembly compatibility dry run also succeeded (no separate Wasm runtime test) |

New tests cover file/type/schema/UTF-8/size errors, normalized bilingual preview, decisions/revision adoption, review/create/leave confirmations, immutable retries after token refresh/network loss, browser-checkpoint reconstruction through injected memory storage, unavailable checkpoint storage before mutation, pagination interruption, unknown acknowledgement reconciliation, five-item bounds, partial/terminal outcomes, new-plan correction, cooldowns, owner isolation/late replies, attestation error display, role gating, receipt UI pagination and narrow layouts. Early test failures were corrected fixture issues (UTF-8 response headers and asynchronous demo-auth initialization); final suites pass.

The real probe creates disposable verified demo editor/student identities and synthetic reviewed content. It runs the production Admin HTTP client/controller against real import/publication functions, drops a committed create response and verifies unchanged retry bytes, injects a concurrent published edit, checks terminal conflict plus partial success, resumes from safe receipts and traverses a 28-row job's status pages. Node assertions verify new imports remain drafts, published counts remain correct and feed revisions/noops remain consistent. The complete suite also reruns both existing Student progress/content probes and backend permission/concurrency/rules checks.

Tests use only loopback demo-vocabulary emulators, temporary Student SQLite files and injected in-memory Admin recovery storage. Test tokens reach the Flutter child only through a test environment value and are not logged or placed in command arguments. No personal application/browser storage or live Firebase project was accessed, and no installed Student app was launched. No real Admin browser was launched for acceptance. Backend-only unit tests, Student analysis/tests and native platform builds were not rerun because their production code is unchanged; emulator regressions cover shared API compatibility. Local Node remains 24.7 while Functions target Node 22; deployed runtime/real attestation remain separate acceptance.

## Modified files in Phase 10

New Admin implementation files:

- admin/admin_panel/lib/features/imports/client.dart: authenticated bounded HTTPS, immutable request bytes, session guards and error classification.
- admin/admin_panel/lib/features/imports/models.dart: file/container and preview/job/receipt decoding/validation.
- admin/admin_panel/lib/features/imports/controller.dart: preview/decision lifecycle, frozen creation, recoverable jobs, staged status pagination, processing/cooldowns and UID isolation.
- admin/admin_panel/lib/features/imports/import_page.dart: selection, bilingual preview, choices/revision reads, confirmations, lookup/progress/receipt pages and leave warnings.
- admin/admin_panel/lib/features/imports/platform.dart, platform_types.dart, platform_stub.dart and platform_web.dart: conditional browser picker/session storage, injected test storage and owner cleanup without a new package.

Existing Admin integration files:

- admin/admin_panel/lib/main.dart and lib/app/admin_gate.dart: optional import-client factory injection through existing auth gate.
- admin/admin_panel/lib/app/workspace.dart: import navigation/client lifecycle and owner checkpoint cleanup; existing Words/Account flows retained.

Tests and documentation:

- admin/admin_panel/test/imports_test.dart, imports_widget_test.dart, support/fake_imports.dart and import_emulator_probe.dart (new).
- users/firebase/functions/test/admin_import_client.emulator.cjs (new) and test/run-emulators.cjs: guarded demo fixture and actual Flutter probe in the regression runner.
- docs/phase10_handoff.md (new), docs/implementation_plan.md, docs/import_api.md and docs/setup.md: scope, contracts, evidence, setup and acceptance.

Earlier uncommitted work remains intact and is not newly attributed to Phase 10. Generated builds/logs are ignored. No production backend or schema migration is needed.

## Manual setup and browser acceptance

No new Firebase Console registration, role type, package, rule or index is required. Live use still needs the existing account/publication/import APIs to be separately deployed under authorization; none was deployed. Configure supported real App Check providers/token forwarding before enabling REQUIRE_CONTENT_APP_CHECK. Existing claims must be current and email verified.

See setup.md for isolated emulator flags, project-local CLI/Java setup and VOCAB_DART_BIN plus VOCAB_FLUTTER_TOOLS_SNAPSHOT required by the integration runner. Use a separate browser profile and disposable demo data for manual steps:

1. Select valid/invalid JSON and cancel the actual picker. Check MIME/extension/size rejection, all senses/examples, Bengali rendering, keyboard access, zoom/large text and narrow layouts. The automated picker injection and Web build do not exercise the OS dialog.
2. Choose skip/create/update, load a target and deliberately adopt its displayed revision. Confirm that a file's reviewed flag cannot bypass review. Modify content after review and verify a new dry run/review is required. Confirm newly created words remain drafts.
3. Create a job, copy its ID, interrupt the browser/network during creation/processing, reload the same tab and use status/unchanged retry. Check storage permission failure prevents creation. Confirm job-ID lookup works without the source file and no processing starts automatically. Closing a tab can lose its local checkpoint; copied IDs remain resumable on the server.
4. Use competing demo editors to force a conflict. Check partial success/failed receipts, page controls and explicit new-plan correction without altering old receipts. Test quota cooldown and restored connectivity; only pending work should be selected.
5. Test back navigation, tab close/beforeunload, logout after leaving the import page, same-UID role refresh and account replacement while a request is outstanding. Inspect only the isolated profile to confirm owner checkpoint cleanup and no previous owner's file/status appears. Check real Chrome/Edge and any additional supported browser; browser-specific picker/cancel/storage behavior remains manual acceptance.

Foreground processing, tab recovery, per-job limits, indefinite server receipt retention and production deployment boundaries are intentional limits. This phase is complete. Stop here and await approval before any further phase.
