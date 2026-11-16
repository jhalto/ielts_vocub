import 'dart:async';

import 'package:app_auth/app_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../features/words/models.dart';
import '../features/words/repository.dart';
import '../features/words/controllers.dart';
import '../features/words/editor_page.dart';
import 'admin_gate.dart';
import '../features/imports/client.dart';
import '../features/imports/import_page.dart';
import '../features/imports/platform.dart' show clearImportSessions;
import '../features/users/client.dart';
import '../features/users/user_page.dart';

class AdminWorkspace extends StatefulWidget {
  const AdminWorkspace({
    super.key,
    required this.uid,
    required this.auth,
    required this.onTheme,
    required this.vocabularyFactory,
    this.importFactory,
    this.userAdminFactory,
  });
  final String uid;
  final AuthController auth;
  final VoidCallback onTheme;
  final VocabularyFactory vocabularyFactory;
  final ImportFactory? importFactory;
  final UserAdminFactory? userAdminFactory;
  @override
  State<AdminWorkspace> createState() => _AdminWorkspaceState();
}

class _AdminWorkspaceState extends State<AdminWorkspace> {
  late final VocabularyRepository repository;
  late final WordListController list;
  final search = TextEditingController();
  Timer? debounce;
  final scaffoldKey = GlobalKey<ScaffoldState>();
  int selected = 0;
  bool wasAllowed = false;
  PublicationFilter publication = PublicationFilter.all;
  Category? category;
  Difficulty? difficulty;
  @override
  void initState() {
    super.initState();
    repository = widget.vocabularyFactory(widget.uid, () {
      unawaited(widget.auth.refreshProfile());
    });
    list = WordListController(repository);
    widget.auth.addListener(_authChanged);
    _authChanged();
  }

  void _authChanged() {
    if (widget.auth.identity?.uid != widget.uid) {
      try {
        clearImportSessions(widget.uid);
      } catch (_) {
        /* Storage may be disabled by the browser. */
      }
    }
    if (widget.auth.canEnter && widget.auth.role != 'super_admin') {
      try {
        clearImportSessions(widget.uid, endpointSuffix: 'userAdminApi');
      } catch (_) {
        /* Storage may be disabled. */
      }
    }
    final allowed =
        widget.auth.canEnter && widget.auth.identity?.uid == widget.uid;
    if (allowed && !wasAllowed) unawaited(list.load(reset: true));
    if (!allowed && wasAllowed) list.invalidate();
    wasAllowed = allowed;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.auth.removeListener(_authChanged);
    debounce?.cancel();
    search.dispose();
    list.dispose();
    repository.close();
    super.dispose();
  }

  void _filter() {
    unawaited(
      list.filter(
        WordFilters(
          prefix: search.text,
          publication: publication,
          category: category,
          difficulty: difficulty,
        ),
      ),
    );
  }

  Future<void> _edit([AdminWord? word]) async {
    if (!widget.auth.canEnter) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => WordEditorPage(
          repository: repository,
          auth: widget.auth,
          uid: widget.uid,
          word: word,
        ),
      ),
    );
    if (mounted && widget.auth.canEnter) await list.load(reset: true);
  }

  Widget _navigation() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          'VocabSwipe Admin',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
      ),
      ListTile(
        leading: const Icon(Icons.menu_book_outlined),
        title: const Text('Words'),
        selected: selected == 0,
        onTap: () {
          setState(() => selected = 0);
          scaffoldKey.currentState?.closeDrawer();
        },
      ),
      ListTile(
        leading: const Icon(Icons.upload_file),
        title: const Text('JSON imports'),
        onTap: () async {
          if (!widget.auth.canEnter) return;
          scaffoldKey.currentState?.closeDrawer();
          final client = (widget.importFactory ?? createImportClient)(
            widget.uid,
            () => unawaited(widget.auth.refreshProfile()),
          );
          await Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => ImportPage(
                uid: widget.uid,
                auth: widget.auth,
                vocabulary: repository,
                client: client,
              ),
            ),
          );
          if (mounted && widget.auth.canEnter) await list.load(reset: true);
        },
      ),
      if (widget.auth.canEnter && widget.auth.role == 'super_admin')
        ListTile(
          leading: const Icon(Icons.manage_accounts_outlined),
          title: const Text('User management'),
          onTap: () async {
            if (!widget.auth.canEnter || widget.auth.role != 'super_admin') {
              return;
            }
            scaffoldKey.currentState?.closeDrawer();
            final client = (widget.userAdminFactory ?? createUserAdminClient)(
              widget.uid,
              () => unawaited(widget.auth.refreshProfile()),
            );
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => UserAdminPage(
                  uid: widget.uid,
                  auth: widget.auth,
                  client: client,
                ),
              ),
            );
          },
        ),
      ListTile(
        leading: const Icon(Icons.account_circle_outlined),
        title: const Text('Account'),
        selected: selected == 1,
        onTap: () {
          setState(() => selected = 1);
          scaffoldKey.currentState?.closeDrawer();
        },
      ),
      const Spacer(),
      Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          '${widget.auth.identity?.email ?? ''}\n${widget.auth.role ?? ''}',
        ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 960;
      final body = selected == 0 ? _words() : _account();
      return Scaffold(
        key: scaffoldKey,
        appBar: AppBar(
          title: Text(
            selected == 0 ? 'Vocabulary management' : 'Administrator account',
          ),
          actions: [
            IconButton(
              tooltip: 'Toggle light/dark theme',
              onPressed: widget.onTheme,
              icon: const Icon(Icons.brightness_6_outlined),
            ),
            TextButton(
              onPressed: () => widget.auth.signOut(),
              child: const Text('Sign out'),
            ),
          ],
        ),
        drawer: wide ? null : Drawer(child: SafeArea(child: _navigation())),
        body: Row(
          children: [
            if (wide) SizedBox(width: 240, child: _navigation()),
            if (wide) const VerticalDivider(width: 1),
            Expanded(child: body),
          ],
        ),
      );
    },
  );
  Widget _account() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.auth.identity?.name ?? '',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(widget.auth.identity?.email ?? ''),
        Text('Verified role: ${widget.auth.role ?? ''}'),
        const SizedBox(height: 12),
        const Text(
          'Administrator access is checked online. Roles cannot be changed from this panel.',
        ),
        OutlinedButton(
          onPressed: widget.auth.refreshSession,
          child: const Text('Refresh session and role'),
        ),
      ],
    ),
  );
  Widget _words() => ListenableBuilder(
    listenable: list,
    builder: (context, _) => SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('Words', style: Theme.of(context).textTheme.headlineMedium),
              FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('Create word'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: search,
            maxLength: 128,
            decoration: const InputDecoration(
              labelText: 'Spelling prefix (case-sensitive)',
              hintText: 'Search the beginning of a spelling',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (_) {
              debounce?.cancel();
              debounce = Timer(const Duration(milliseconds: 300), _filter);
            },
          ),
          const Text(
            'Search uses a server index. It matches spelling prefixes exactly, including case; it does not search arbitrary substrings or meanings.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<PublicationFilter>(
                  isExpanded: true,
                  initialValue: publication,
                  decoration: const InputDecoration(labelText: 'Publication'),
                  items: PublicationFilter.values
                      .map(
                        (v) => DropdownMenuItem(
                          value: v,
                          child: Text(switch (v) {
                            PublicationFilter.all => 'All states',
                            PublicationFilter.published => 'Published',
                            PublicationFilter.draft => 'Draft / unpublished',
                            PublicationFilter.retired => 'Retired',
                          }),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    setState(() => publication = v!);
                    _filter();
                  },
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<Category?>(
                  isExpanded: true,
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: [
                    const DropdownMenuItem<Category?>(
                      value: null,
                      child: Text('All categories'),
                    ),
                    for (final v in Category.values)
                      DropdownMenuItem(value: v, child: Text(v.name)),
                  ],
                  onChanged: (v) {
                    setState(() => category = v);
                    _filter();
                  },
                ),
              ),
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<Difficulty?>(
                  isExpanded: true,
                  initialValue: difficulty,
                  decoration: const InputDecoration(labelText: 'Difficulty'),
                  items: [
                    const DropdownMenuItem<Difficulty?>(
                      value: null,
                      child: Text('All difficulties'),
                    ),
                    for (final v in Difficulty.values)
                      DropdownMenuItem(value: v, child: Text(v.name)),
                  ],
                  onChanged: (v) {
                    setState(() => difficulty = v);
                    _filter();
                  },
                ),
              ),
              IconButton(
                tooltip: 'Refresh words',
                onPressed: list.loading ? null : () => list.load(reset: true),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (list.loading)
            const LinearProgressIndicator(semanticsLabel: 'Loading words'),
          if (list.refreshedAt != null)
            Text(
              'Last successful refresh: ${list.refreshedAt!.toLocal().toString().split('.').first}',
            ),
          if (list.error != null) ...[
            Semantics(
              liveRegion: true,
              child: Text(
                list.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
            OutlinedButton(
              onPressed: () => list.load(),
              child: const Text('Retry loading words'),
            ),
          ],
          if (!list.loading &&
              list.error == null &&
              list.page?.words.isEmpty == true)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No words match these filters. Create a draft or change the filters.',
              ),
            ),
          for (final word in list.page?.words ?? <AdminWord>[])
            Card(
              child: ListTile(
                title: Text(word.draft.spelling),
                subtitle: Text(
                  '${word.draft.category.name} / ${word.draft.difficulty.name} - ${word.status} - revision ${word.revision}',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: list.loading ? null : () => _edit(word),
              ),
            ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: list.loading || list.pageIndex == 0
                    ? null
                    : list.previous,
                child: const Text('Previous page'),
              ),
              Text(
                'Page ${list.pageIndex + 1} - ${list.page?.words.length ?? 0} words on this page',
              ),
              TextButton(
                onPressed: list.loading || list.page?.hasNext != true
                    ? null
                    : list.next,
                child: const Text('Next page'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
