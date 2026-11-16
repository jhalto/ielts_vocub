import 'package:material_ui/material_ui.dart';
import 'package:app_auth/app_auth.dart';

import 'models.dart';
import 'repository.dart';
import 'controllers.dart';
import 'preview.dart';
import 'browser_guard_stub.dart'
    if (dart.library.js_interop) 'browser_guard_web.dart';

class WordEditorPage extends StatefulWidget {
  const WordEditorPage({
    super.key,
    required this.repository,
    required this.auth,
    required this.uid,
    this.word,
  });
  final VocabularyRepository repository;
  final AuthController auth;
  final String uid;
  final AdminWord? word;
  @override
  State<WordEditorPage> createState() => _WordEditorPageState();
}

class _WordEditorPageState extends State<WordEditorPage> {
  late final WordEditorController c;
  late final BrowserGuard browser;
  bool allowPop = false;
  @override
  void initState() {
    super.initState();
    c = WordEditorController(
      repository: widget.repository,
      uid: widget.uid,
      word: widget.word,
    );
    browser = BrowserGuard(() => c.mustWarn);
  }

  @override
  void dispose() {
    browser.dispose();
    c.dispose();
    super.dispose();
  }

  Future<bool> _confirm(
    String title,
    String message, {
    String confirm = 'Confirm',
  }) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirm),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _leave() async {
    if (c.busy) return;
    if (c.mustWarn &&
        !await _confirm(
          c.pending != null
              ? 'Unconfirmed operation'
              : 'Discard unsaved changes?',
          c.pending != null
              ? 'This operation may have completed. Retry it before leaving if possible. Leaving discards its local retry ID; reload server state before starting a new operation.'
              : 'Your unsaved edits will be discarded.',
          confirm: 'Leave editor',
        )) {
      return;
    }
    if (!mounted) return;
    setState(() => allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context, true);
    });
  }

  Future<void> _action(String action) async {
    if (['unpublish', 'retire', 'restore'].contains(action)) {
      if (!await _confirm(
        '${action[0].toUpperCase()}${action.substring(1)} this word?',
        switch (action) {
          'unpublish' => 'Downloaded copies are removed only when students update. Existing progress is retained.',
          'retire' => 'This hides the word from students while preserving its ID and history.',
          'restore' => 'This restores an unpublished draft; it will not publish automatically.',
          _ => '',
        },
        confirm: action,
      )) {
        return;
      }
    }
    await c.apply(action);
  }

  Widget _text(
    String label,
    String value,
    void Function(String) update, {
    int max = 4000,
    int lines = 1,
    String? fieldKey,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      key: ValueKey('${c.formGeneration}:${fieldKey ?? label}'),
      initialValue: value,
      enabled: !c.locked,
      decoration: InputDecoration(labelText: label, alignLabelWithHint: true),
      maxLength: max,
      maxLines: lines,
      onChanged: (v) {
        if (c.locked) return;
        update(v);
        c.changed();
      },
    ),
  );
  Widget _move(String label, int index, int length, void Function(int) move) =>
      Wrap(
        children: [
          IconButton(
            tooltip: 'Move $label up',
            onPressed: c.locked || index == 0 ? null : () => move(index - 1),
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: 'Move $label down',
            onPressed: c.locked || index >= length - 1
                ? null
                : () => move(index + 1),
            icon: const Icon(Icons.arrow_downward),
          ),
        ],
      );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => PopScope<bool>(
      canPop: allowPop || !c.mustWarn && !c.busy,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back to words',
            onPressed: c.busy ? null : _leave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(
            c.word == null
                ? 'Create vocabulary'
                : 'Edit ${c.word!.draft.spelling}',
          ),
          actions: [
            TextButton(
              onPressed: () => showWordPreview(context, c.draft),
              child: const Text('Preview'),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Stable ID: ${c.id}'),
                    Text(
                      'Revision ${c.word?.revision ?? 0} - ${c.word?.status ?? 'New draft'}',
                    ),
                    if (c.busy)
                      const LinearProgressIndicator(
                        semanticsLabel: 'Saving or loading server version',
                      ),
                    if (c.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            c.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ),
                    if (c.notice != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(c.notice!),
                        ),
                      ),
                    if (c.pending != null && !c.busy) ...[
                      const Text(
                        'An operation is unconfirmed. Editing is locked so the exact request can be retried safely.',
                      ),
                      FilledButton(
                        onPressed: c.retry,
                        child: const Text('Retry same operation'),
                      ),
                    ],
                    if (c.conflict) ...[
                      OutlinedButton(
                        onPressed: c.busy ? null : c.compare,
                        child: const Text(
                          'Fetch server version for comparison',
                        ),
                      ),
                      if (c.remote != null) ...[
                        Text(
                          'Server revision ${c.remote!.revision} - ${c.remote!.status}',
                        ),
                        TextButton(
                          onPressed: () => showWordPreview(
                            context,
                            c.remote!.draft,
                            title: 'Current server version',
                          ),
                          child: const Text('Preview server version'),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            if (await _confirm(
                              'Discard local edits?',
                              'Load the latest server content and discard your local draft.',
                            )) {
                              c.resolve(keepDraft: false);
                            }
                          },
                          child: const Text('Use server version'),
                        ),
                        OutlinedButton(
                          onPressed: () async {
                            if (await _confirm(
                              'Keep local draft on latest revision?',
                              'Compare both versions first. Saving afterward may replace the edits made by another editor. Editorial review must be confirmed again.',
                            )) {
                              c.resolve(keepDraft: true);
                            }
                          },
                          child: const Text(
                            'Keep local draft on latest revision',
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 20),
                    _text(
                      'Spelling',
                      c.draft.spelling,
                      (v) => c.draft.spelling = v,
                      max: 128,
                    ),
                    _text(
                      'Pronunciation (text)',
                      c.draft.pronunciation,
                      (v) => c.draft.pronunciation = v,
                      max: 256,
                    ),
                    Wrap(
                      spacing: 20,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: 220,
                          child: DropdownButtonFormField<Category>(
                            isExpanded: true,
                            key: ValueKey('category-${c.formGeneration}'),
                            initialValue: c.draft.category,
                            decoration: const InputDecoration(
                              labelText: 'Category',
                            ),
                            items: Category.values
                                .map(
                                  (v) => DropdownMenuItem(
                                    value: v,
                                    child: Text(v.name),
                                  ),
                                )
                                .toList(),
                            onChanged: c.locked
                                ? null
                                : (v) {
                                    c.draft.category = v!;
                                    c.changed();
                                  },
                          ),
                        ),
                        SizedBox(
                          width: 220,
                          child: DropdownButtonFormField<Difficulty>(
                            isExpanded: true,
                            key: ValueKey('difficulty-${c.formGeneration}'),
                            initialValue: c.draft.difficulty,
                            decoration: const InputDecoration(
                              labelText: 'Difficulty',
                            ),
                            items: Difficulty.values
                                .map(
                                  (v) => DropdownMenuItem(
                                    value: v,
                                    child: Text(v.name),
                                  ),
                                )
                                .toList(),
                            onChanged: c.locked
                                ? null
                                : (v) {
                                    c.draft.difficulty = v!;
                                    c.changed();
                                  },
                          ),
                        ),
                        SizedBox(
                          width: 220,
                          child: TextFormField(
                            key: ValueKey('ordering-${c.formGeneration}'),
                            initialValue: c.draft.ordering.toString(),
                            enabled: !c.locked,
                            decoration: const InputDecoration(
                              labelText: 'Ordering',
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (v) {
                              c.draft.ordering = int.tryParse(v) ?? -1;
                              c.changed();
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Senses and bilingual examples',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Text(
                      'Incomplete drafts may be saved. Every meaning/example must be reviewed before publication. Duplicate spellings are checked authoritatively by the server.',
                    ),
                    for (var i = 0; i < c.draft.senses.length; i++) _sense(i),
                    OutlinedButton.icon(
                      onPressed: c.locked || c.draft.senses.length >= 100
                          ? null
                          : () {
                              c.draft.senses.add(SenseDraft());
                              c.changed();
                            },
                      icon: const Icon(Icons.add),
                      label: const Text('Add sense'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'I reviewed all English/Bengali meanings and examples for publication.',
                      ),
                      value: c.reviewed,
                      onChanged: c.locked ? null : (v) => c.review(v!),
                    ),
                    if (c.word?.published == true)
                      const Text(
                        'Saving this published word updates student content immediately. Explicit editorial review is required.',
                      ),
                    if (c.word?.retired == true)
                      const Text(
                        'Retired content is read-only. Restore it as an unpublished draft to edit.',
                      ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        FilledButton(
                          onPressed: c.locked
                              ? null
                              : () =>
                                    _action(c.word == null ? 'create' : 'edit'),
                          child: Text(
                            c.word == null ? 'Create draft' : 'Save changes',
                          ),
                        ),
                        if (c.word != null && !c.word!.retired) ...[
                          OutlinedButton(
                            onPressed:
                                c.busy ||
                                    c.pending != null ||
                                    c.conflict ||
                                    c.needsReload ||
                                    c.dirty
                                ? null
                                : () => _action(
                                    c.word!.published ? 'unpublish' : 'publish',
                                  ),
                            child: Text(
                              c.word!.published ? 'Unpublish' : 'Publish',
                            ),
                          ),
                          OutlinedButton(
                            onPressed:
                                c.busy ||
                                    c.pending != null ||
                                    c.conflict ||
                                    c.needsReload ||
                                    c.dirty
                                ? null
                                : () => _action('retire'),
                            child: const Text('Retire'),
                          ),
                        ],
                        if (c.word?.retired == true)
                          FilledButton(
                            onPressed:
                                c.busy ||
                                    c.pending != null ||
                                    c.conflict ||
                                    c.needsReload
                                ? null
                                : () => _action('restore'),
                            child: const Text('Restore as draft'),
                          ),
                        TextButton(
                          onPressed:
                              c.busy || c.pending != null || c.word == null
                              ? null
                              : () async {
                                  if (!c.mustWarn ||
                                      await _confirm(
                                        'Reload and discard edits?',
                                        'Your unsaved changes will be replaced by the current server version.',
                                      )) {
                                    await c.reload();
                                  }
                                },
                          child: const Text('Reload server version'),
                        ),
                      ],
                    ),
                    if (c.dirty)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: Text(
                          'Unsaved changes. Save before changing publication status.',
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  Widget _sense(int index) {
    final sense = c.draft.senses[index];
    return Card(
      key: ValueKey(sense.id),
      margin: const EdgeInsets.symmetric(vertical: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Sense ${index + 1}'),
                _move('sense ${index + 1}', index, c.draft.senses.length, (
                  target,
                ) {
                  final s = c.draft.senses.removeAt(index);
                  c.draft.senses.insert(target, s);
                  c.changed();
                }),
                IconButton(
                  tooltip: 'Remove sense ${index + 1}',
                  onPressed: c.locked
                      ? null
                      : () {
                          c.draft.senses.removeAt(index);
                          c.changed();
                        },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            Text('Sense ID: ${sense.id}'),
            DropdownButtonFormField<PartOfSpeech>(
              isExpanded: true,
              key: ValueKey('pos-${sense.id}-${c.formGeneration}'),
              initialValue: sense.partOfSpeech,
              decoration: const InputDecoration(labelText: 'Part of speech'),
              items: PartOfSpeech.values
                  .map((p) => DropdownMenuItem(value: p, child: Text(p.name)))
                  .toList(),
              onChanged: c.locked
                  ? null
                  : (v) {
                      sense.partOfSpeech = v!;
                      c.changed();
                    },
            ),
            const SizedBox(height: 12),
            _text(
              'English meaning',
              sense.englishMeaning,
              (v) => sense.englishMeaning = v,
              lines: 3,
              fieldKey: '${sense.id}-en',
            ),
            _text(
              'Bengali meaning',
              sense.bengaliMeaning,
              (v) => sense.bengaliMeaning = v,
              lines: 3,
              fieldKey: '${sense.id}-bn',
            ),
            for (var j = 0; j < sense.examples.length; j++) _example(sense, j),
            TextButton.icon(
              onPressed: c.locked || sense.examples.length >= 100
                  ? null
                  : () {
                      sense.examples.add(ExampleDraft());
                      c.changed();
                    },
              icon: const Icon(Icons.add),
              label: const Text('Add bilingual example'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _example(SenseDraft sense, int index) {
    final example = sense.examples[index];
    // Object identity preserves text fields while pairs are reordered.
    return Container(
      key: ObjectKey(example),
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Example ${index + 1}'),
              _move('example ${index + 1}', index, sense.examples.length, (
                target,
              ) {
                final e = sense.examples.removeAt(index);
                sense.examples.insert(target, e);
                c.changed();
              }),
              IconButton(
                tooltip: 'Remove example ${index + 1}',
                onPressed: c.locked
                    ? null
                    : () {
                        sense.examples.removeAt(index);
                        c.changed();
                      },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
          _text(
            'English example',
            example.english,
            (v) => example.english = v,
            lines: 2,
            fieldKey: '${identityHashCode(example)}-en',
          ),
          _text(
            'Bengali example',
            example.bengali,
            (v) => example.bengali = v,
            lines: 2,
            fieldKey: '${identityHashCode(example)}-bn',
          ),
        ],
      ),
    );
  }
}
