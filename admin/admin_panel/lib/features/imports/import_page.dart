import 'dart:async';
import 'dart:convert';

import 'package:app_auth/app_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../words/models.dart';
import '../words/repository.dart';
import '../words/preview.dart';
import '../words/browser_guard_stub.dart'
    if (dart.library.js_interop) '../words/browser_guard_web.dart';
import 'client.dart';
import 'controller.dart';
import 'models.dart';
import 'platform.dart';

class ImportPage extends StatefulWidget {
  const ImportPage({
    super.key,
    required this.uid,
    required this.auth,
    required this.vocabulary,
    required this.client,
    this.session,
    this.picker,
  });
  final String uid;
  final AuthController auth;
  final VocabularyRepository vocabulary;
  final ImportClient client;
  final ImportSession? session;
  final Future<PickedJson?> Function()? picker;
  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  late final ImportController c;
  late final BrowserGuard browser;
  late final TextEditingController lookup;
  Timer? timer;
  bool allowPop = false, picking = false;
  int receiptPage = 0;
  bool get allowed =>
      widget.auth.canEnter && widget.auth.identity?.uid == widget.uid;
  @override
  void initState() {
    super.initState();
    c = ImportController(
      uid: widget.uid,
      client: widget.client,
      session:
          widget.session ??
          createImportSession('${widget.client.endpoint}', widget.uid),
    );
    lookup = TextEditingController(text: c.jobId ?? '');
    browser = BrowserGuard(() => c.mustWarn || picking);
    widget.auth.addListener(_authChanged);
    _authChanged();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c.nextRetry != null) setState(() {});
    });
  }

  void _authChanged() => c.setAvailable(
    allowed,
    clearPrivate: widget.auth.identity?.uid != widget.uid,
  );
  @override
  void dispose() {
    widget.auth.removeListener(_authChanged);
    timer?.cancel();
    browser.dispose();
    lookup.dispose();
    c.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;
  Future<bool> _leaveAllowed() async =>
      !(c.mustWarn || picking) ||
      await _confirm(
        'Leave unfinished import?',
        'Unsubmitted choices will be lost. A submitted request may still commit. Keep the job ID to resume; leaving does not cancel a server job. An unconfirmed creation is retained in this tab’s session storage.',
        'Leave imports',
      );
  Future<void> _leave() async {
    if (!await _leaveAllowed() || !mounted) return;
    setState(() => allowPop = true);
    Navigator.pop(context);
  }

  Future<void> _pick() async {
    if (c.mustWarn &&
        !await _confirm(
          'Replace this plan?',
          'The current unsubmitted file and choices will be replaced.',
          'Select another file',
        )) {
      return;
    }
    if (!mounted || !allowed) return;
    setState(() => picking = true);
    try {
      final picked = await (widget.picker ?? pickJsonFile)();
      if (picked != null && mounted && allowed) c.load(picked);
    } catch (e) {
      if (mounted) {
        c.error = PublicationFailure(
          'file',
          e is FormatException
              ? e.message.toString()
              : 'File selection failed. Retry.',
        );
        setState(() {});
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> _newPlan() async {
    if (!await _confirm(
          'Start a new import plan?',
          'Keep the current job ID. This does not cancel or roll back its successful or pending server items. To correct failures, reselect the source JSON, skip successful rows, explicitly choose fresh target revisions, then preview a new job.',
          'Start new plan',
        ) ||
        !mounted) {
      return;
    }
    c.newPlan();
    lookup.clear();
  }

  Future<void> _create() async {
    if (await _confirm(
          'Create immutable import job?',
          'Create choices always become drafts. Reviewed updates to published words take effect immediately. Decisions, payloads and revisions cannot be edited after submission. Each item commits independently.',
          'Create job',
        ) &&
        mounted &&
        allowed) {
      await c.create();
    }
  }

  Future<void> _review(int index) async {
    if (await _confirm(
          'Confirm published edit review?',
          'I reviewed every normalized meaning and ordered English/Bengali example for this row. This update replaces currently published content immediately if its revision still matches. A dry run is required again before job creation.',
          'I reviewed this edit',
        ) &&
        mounted &&
        allowed) {
      c.attest(index);
    }
  }

  Future<void> _editJson(int index) async {
    final text = TextEditingController(
      text: const JsonEncoder.withIndent('  ').convert(c.rows[index]),
    );
    String? problem;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      useRootNavigator: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Edit JSON for row ${index + 1}'),
          content: SizedBox(
            width: 680,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Preserve stable sense IDs and example order. Server validation remains authoritative. Any edit clears review confirmations.',
                  ),
                  TextField(
                    controller: text,
                    minLines: 8,
                    maxLines: 18,
                    decoration: InputDecoration(
                      labelText: 'Row JSON',
                      errorText: problem,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  Navigator.pop(context, jsonObject(jsonDecode(text.text)));
                } catch (_) {
                  update(() => problem = 'Enter a valid JSON object.');
                }
              },
              child: const Text('Apply JSON'),
            ),
          ],
        ),
      ),
    );
    // Let the dialog transition release its TextField before disposing controllers.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    text.dispose();
    if (result != null && mounted && allowed) c.changeRow(index, result);
  }

  Future<void> _choice(int index) async {
    final raw = c.rows[index];
    final row = raw is Map<String, dynamic>
        ? copyJson(raw)
        : <String, dynamic>{};
    final item = TextEditingController(
      text: row['itemId'] is String ? row['itemId'] as String : '',
    );
    final target = TextEditingController(
      text: row['wordId'] is String ? row['wordId'] as String : '',
    );
    final revision = TextEditingController(
      text: '${row['expectedRevision'] ?? 0}',
    );
    var decision = ['skip', 'create', 'update'].contains(row['decision'])
        ? row['decision'] as String
        : 'skip';
    AdminWord? current;
    String? problem;
    var reading = false;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      useRootNavigator: false,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Choose action for row ${index + 1}'),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: item,
                    decoration: const InputDecoration(labelText: 'Item ID'),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: decision,
                    decoration: const InputDecoration(labelText: 'Decision'),
                    items: ['skip', 'create', 'update']
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (s) => update(() {
                      decision = s!;
                      problem = null;
                    }),
                  ),
                  if (decision != 'skip') ...[
                    TextField(
                      controller: target,
                      decoration: const InputDecoration(
                        labelText: 'Target word ID',
                      ),
                      onChanged: (_) => update(() => current = null),
                    ),
                    if (decision == 'create')
                      const Text('New draft only; expected revision is 0.'),
                    if (decision == 'update') ...[
                      TextField(
                        controller: revision,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Expected revision',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: reading
                            ? null
                            : () async {
                                if (!validImportId(target.text)) {
                                  update(
                                    () => problem = 'Enter a valid target ID.',
                                  );
                                  return;
                                }
                                update(() {
                                  reading = true;
                                  problem = null;
                                });
                                try {
                                  final loaded = await widget.vocabulary.get(
                                    target.text,
                                  );
                                  if (context.mounted && allowed) {
                                    update(() => current = loaded);
                                  }
                                } catch (_) {
                                  if (context.mounted) {
                                    update(
                                      () => problem = 'Could not load current target. Check the ID/session and retry.',
                                    );
                                  }
                                } finally {
                                  if (context.mounted) {
                                    update(() => reading = false);
                                  }
                                }
                              },
                        child: Text(
                          reading ? 'Loading target…' : 'Load current target',
                        ),
                      ),
                      if (current != null) ...[
                        Text(
                          'Current revision ${current!.revision} · ${current!.status}',
                        ),
                        WordPreview(draft: current!.draft),
                        TextButton(
                          onPressed: () => update(
                            () => revision.text = '${current!.revision}',
                          ),
                          child: const Text('Use this displayed revision'),
                        ),
                      ],
                    ],
                  ],
                  if (problem != null)
                    Text(
                      problem!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: reading
                  ? null
                  : () {
                      if (!validImportId(item.text) ||
                          (decision != 'skip' &&
                              (!validImportId(target.text) ||
                                  (decision == 'update' &&
                                      (int.tryParse(revision.text) ?? 0) <=
                                          0)))) {
                        update(
                          () => problem = 'Valid item/target IDs and a positive update revision are required.',
                        );
                        return;
                      }
                      final next = decision == 'skip'
                          ? <String, dynamic>{
                              'itemId': item.text,
                              'decision': 'skip',
                            }
                          : <String, dynamic>{
                              ...row,
                              'itemId': item.text,
                              'decision': decision,
                              'wordId': target.text,
                              'expectedRevision': decision == 'create'
                                  ? 0
                                  : int.parse(revision.text),
                            };
                      next.remove('reviewed');
                      Navigator.pop(context, next);
                    },
              child: const Text('Apply choice'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    item.dispose();
    target.dispose();
    revision.dispose();
    if (result != null && mounted && allowed) c.changeRow(index, result);
  }

  Widget _row(int index, Object? raw) {
    final row = raw is Map ? raw : {};
    final preview = index < c.previews.length ? c.previews[index] : null;
    return Card(
      child: ExpansionTile(
        key: ValueKey('import-row-$index'),
        title: Text(
          'Row ${index + 1}: ${row['itemId'] ?? 'invalid ID'} · ${row['decision'] ?? 'choose action'}',
        ),
        subtitle: Text(
          preview == null
              ? 'Needs server dry run'
              : (preview['errors'] as List).isEmpty
              ? 'Validated · publishable: ${preview['publishable'] ?? 'not applicable'}'
              : 'Errors: ${(preview['errors'] as List).join(', ')}',
        ),
        childrenPadding: const EdgeInsets.all(16),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Target: ${row['wordId'] ?? 'none'} · expected revision: ${row['expectedRevision'] ?? 'none'}',
          ),
          if (preview != null) ...[
            Text(
              'Normalized spelling: ${preview['normalizedSpelling'] ?? 'unavailable'}',
            ),
            if (preview['duplicateWordId'] != null)
              SelectableText(
                'Duplicate target: ${preview['duplicateWordId']} — choose its ID explicitly and load its revision before update.',
              ),
            if (preview['existing'] != null)
              Text(
                'Existing revision ${preview['existing']['revision']} · published ${preview['existing']['isPublished']} · retired ${preview['existing']['isRetired']}',
              ),
            if (preview['content'] != null)
              WordPreview(
                draft: WordDraft.fromJson(jsonObject(preview['content'])),
              ),
          ],
          if (row['reviewed'] == true)
            const Text(
              'Published-edit review confirmed for this unchanged plan.',
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: c.editable ? () => _choice(index) : null,
                child: const Text('Choose action / target'),
              ),
              OutlinedButton(
                onPressed: c.editable ? () => _editJson(index) : null,
                child: const Text('Edit row JSON'),
              ),
              if (preview?['existing']?['isPublished'] == true &&
                  row['decision'] == 'update')
                FilledButton(
                  onPressed: c.editable ? () => _review(index) : null,
                  child: const Text('Confirm published review'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _job() {
    final job = c.job;
    final maxPage = c.receipts.isEmpty ? 0 : (c.receipts.length - 1) ~/ 25;
    final page = receiptPage > maxPage ? maxPage : receiptPage;
    final visible = c.receipts.skip(page * 25).take(25).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText('Job ID: ${c.jobId}'),
            Text(
              c.confirmed
                  ? 'Server job confirmed. Frozen decisions cannot be changed.'
                  : 'Creation/status unconfirmed. It may already exist; check status or retry the same creation.',
            ),
            if (job != null) ...[
              Text('Server status: ${job.status}'),
              Text(
                'Total ${job.counts['total']} · applied ${job.counts['applied']} · skipped ${job.counts['skipped']} · failed ${job.counts['failed']} · pending ${job.counts['pending']}',
              ),
              LinearProgressIndicator(
                value:
                    (job.counts['total']! - job.counts['pending']!) /
                    job.counts['total']!,
                semanticsLabel: 'Import items resolved',
              ),
              const Text(
                'Resolved includes failures and skips. Only applied means a vocabulary mutation succeeded. Status is live; refresh after concurrent work.',
              ),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: c.canRequest ? c.refresh : null,
                  child: const Text('Refresh job status'),
                ),
                if (c.frozenCreate != null)
                  FilledButton(
                    onPressed: c.canRequest ? c.create : null,
                    child: const Text('Retry unchanged creation'),
                  ),
                if (c.confirmed && job?.counts['pending'] != 0)
                  FilledButton(
                    onPressed: c.canRequest ? c.processNext : null,
                    child: const Text('Process next 5 pending'),
                  ),
              ],
            ),
            if (c.receipts.isNotEmpty)
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    'Receipts ${page * 25 + 1}–${page * 25 + visible.length} of ${c.receipts.length}',
                  ),
                  TextButton(
                    onPressed: page == 0
                        ? null
                        : () => setState(() => receiptPage = page - 1),
                    child: const Text('Previous receipts'),
                  ),
                  TextButton(
                    onPressed: page == maxPage
                        ? null
                        : () => setState(() => receiptPage = page + 1),
                    child: const Text('Next receipts'),
                  ),
                ],
              ),
            for (final item in visible)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${item.id} · ${item.decision} · ${item.state}'),
                subtitle: Text(
                  'Word ${item.wordId ?? 'none'}${item.errorCode == null ? '' : '\n${item.errorCode}: ${importMessage(item.errorCode!)}'}${item.result == null || item.state != 'applied' ? '' : '\nCommitted revision ${item.result!['revision']}'}',
                ),
              ),
            if (job?.counts['failed'] != 0 && job != null)
              const Text(
                'Failed items remain unchanged in this job. Start a new plan, reselect the original file, skip applied rows and explicitly correct the target/revision; nothing is silently rebased.',
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => PopScope<void>(
      canPop: allowPop || (!c.mustWarn && !picking),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back to workspace',
            onPressed: _leave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: const Text('JSON imports'),
          actions: [
            TextButton(
              onPressed: () async {
                if (await _leaveAllowed() && allowed) {
                  await widget.auth.signOut();
                }
              },
              child: const Text('Sign out'),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'JSON only · schema 1 · 1–50 items · 512 KiB including request envelope · 5 items per processing step. New words stay drafts.',
              ),
              const Text(
                'The server validates every mutation. File review flags are cleared; published edits need explicit review here. Recovery uses this account and environment in this tab’s session storage; unconfirmed creation payloads may contain draft text. Sign out on shared computers.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: c.editable && !picking ? _pick : null,
                    icon: const Icon(Icons.upload_file),
                    label: Text(
                      picking ? 'Selecting file…' : 'Select JSON file',
                    ),
                  ),
                  OutlinedButton(
                    onPressed: !c.busy && allowed ? _newPlan : null,
                    child: const Text('Start new plan'),
                  ),
                ],
              ),
              if (c.fileName != null) Text('Selected: ${c.fileName}'),
              if (c.busy)
                const LinearProgressIndicator(
                  semanticsLabel: 'Import request in progress',
                ),
              if (c.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '${c.error!.message}\nCode: ${c.error!.code}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (c.nextRetry != null && !c.canRequest)
                Text('Retry available after ${c.nextRetry!.toLocal()}'),
              const SizedBox(height: 16),
              TextField(
                controller: lookup,
                maxLength: 128,
                decoration: const InputDecoration(
                  labelText: 'Resume job ID',
                  helperText: 'Only jobs owned by this signed-in account can be resumed.',
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: c.canRequest
                      ? () async {
                          if (c.mustWarn &&
                              c.jobId != lookup.text.trim() &&
                              !await _confirm(
                                'Look up another job?',
                                'Unsubmitted choices will be replaced only if this lookup succeeds. A frozen unconfirmed request must be resolved first.',
                                'Look up job',
                              )) {
                            return;
                          }
                          if (mounted && allowed) {
                            await c.resume(lookup.text.trim());
                          }
                        }
                      : null,
                  child: const Text('Look up job'),
                ),
              ),
              if (c.jobId != null) _job(),
              if (c.rows.isNotEmpty) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: c.canRequest && c.editable ? c.preview : null,
                      child: const Text('Run server dry run'),
                    ),
                    FilledButton(
                      onPressed: c.canCreate && c.canRequest ? _create : null,
                      child: const Text('Create immutable job'),
                    ),
                  ],
                ),
                if (c.previews.isNotEmpty)
                  Text(
                    c.canCreate
                        ? 'Dry run valid. Review choices before creating the job.'
                        : 'Resolve every row error and run a fresh dry run. Incomplete drafts may be imported but cannot be published.',
                  ),
                for (final entry in c.rows.indexed) _row(entry.$1, entry.$2),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
