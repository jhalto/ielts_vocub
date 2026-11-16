import 'package:material_ui/material_ui.dart';

import 'models.dart';

class WordPreview extends StatelessWidget {
  const WordPreview({super.key, required this.draft});
  final WordDraft draft;
  @override
  Widget build(BuildContext context) => SelectionArea(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          draft.spelling.isEmpty ? 'Untitled draft' : draft.spelling,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          draft.pronunciation.isEmpty
              ? 'Pronunciation unavailable'
              : draft.pronunciation,
        ),
        Text('${draft.category.name} / ${draft.difficulty.name}'),
        const Divider(),
        if (draft.senses.isEmpty) const Text('No senses added.'),
        for (final sense in draft.senses) ...[
          Text(
            sense.partOfSpeech.name,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          Text(
            sense.englishMeaning.isEmpty
                ? 'English meaning unavailable'
                : sense.englishMeaning,
          ),
          Text(
            sense.bengaliMeaning.isEmpty
                ? 'Bengali translation unavailable'
                : sense.bengaliMeaning,
          ),
          for (final example in sense.examples) ...[
            const SizedBox(height: 8),
            Text(
              example.english.isEmpty
                  ? 'English example unavailable'
                  : example.english,
            ),
            Text(
              example.bengali.isEmpty
                  ? 'Bengali translation unavailable'
                  : example.bengali,
            ),
          ],
          const Divider(),
        ],
      ],
    ),
  );
}

Future<void> showWordPreview(
  BuildContext context,
  WordDraft draft, {
  String title = 'Preview',
}) => showDialog<void>(
  context: context,
  useRootNavigator: false,
  builder: (context) => AlertDialog(
    title: Text(title),
    content: SizedBox(
      width: 620,
      child: SingleChildScrollView(child: WordPreview(draft: draft)),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  ),
);
