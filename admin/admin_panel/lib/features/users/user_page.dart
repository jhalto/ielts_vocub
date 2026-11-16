import 'dart:async';

import 'package:app_auth/app_auth.dart';
import 'package:material_ui/material_ui.dart';

import '../imports/platform.dart';
import '../words/models.dart' show PublicationFailure;
import '../words/browser_guard_stub.dart'
    if (dart.library.js_interop) '../words/browser_guard_web.dart';
import 'client.dart';
import 'controller.dart';
import 'models.dart';

class UserAdminPage extends StatefulWidget {
  const UserAdminPage({
    super.key,
    required this.uid,
    required this.auth,
    required this.client,
    this.session,
  });
  final String uid;
  final AuthController auth;
  final UserAdminClient client;
  final ImportSession? session;
  @override
  State<UserAdminPage> createState() => _UserAdminPageState();
}

class _UserAdminPageState extends State<UserAdminPage> {
  late final UserAdminController c;
  late final BrowserGuard browser;
  late final TextEditingController keyLookup;
  final lookup = TextEditingController(),
      provider = TextEditingController(),
      reason = TextEditingController();
  String lookupMode = 'uid',
      filterRole = 'all',
      filterDisabled = 'all',
      filterVerified = 'all',
      changeRole = 'student';
  bool dirty = false, allowPop = false;
  Timer? timer;
  bool get allowed =>
      widget.auth.canEnter &&
      widget.auth.identity?.uid == widget.uid &&
      widget.auth.role == 'super_admin';
  bool get mustWarn => dirty || c.mustWarn;
  @override
  void initState() {
    super.initState();
    c = UserAdminController(
      uid: widget.uid,
      client: widget.client,
      session:
          widget.session ??
          createImportSession('${widget.client.endpoint}', widget.uid),
    );
    keyLookup = TextEditingController(text: c.operationKey ?? '');
    browser = BrowserGuard(() => mustWarn);
    widget.auth.addListener(_authChanged);
    _authChanged();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && c.nextRetry != null) setState(() {});
    });
  }

  void _authChanged() {
    final clear =
        widget.auth.identity?.uid != widget.uid ||
        (widget.auth.canEnter && widget.auth.role != 'super_admin');
    if (clear) {
      reason.clear();
      lookup.clear();
      keyLookup.clear();
      provider.clear();
      dirty = false;
    }
    c.setAccess(allowed, clearPrivate: clear);
  }

  @override
  void dispose() {
    widget.auth.removeListener(_authChanged);
    timer?.cancel();
    browser.dispose();
    lookup.dispose();
    provider.dispose();
    reason.dispose();
    keyLookup.dispose();
    c.dispose();
    super.dispose();
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        useRootNavigator: false,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(text)),
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
  Future<bool> _mayLeave() async =>
      !mustWarn ||
      await _confirm(
        'Leave unfinished user administration?',
        'Unsubmitted choices will be lost. A submitted request may still commit; leaving does not cancel it. Keep the operation ID/key. Unconfirmed request bytes normally remain in this account/environment’s tab recovery storage. Signing out or losing the role clears that recovery; neither action cancels server work.',
        'Leave user management',
      );
  Future<void> _leave() async {
    if (!await _mayLeave() || !mounted) return;
    setState(() => allowPop = true);
    Navigator.pop(context);
  }

  Future<void> _select(String value, bool byEmail) async {
    if (dirty &&
        !await _confirm(
          'Replace unsubmitted choices?',
          'The current unsubmitted reason and role choice will be cleared after this lookup succeeds.',
          'Look up account',
        )) {
      return;
    }
    if (!mounted || !allowed) return;
    await c.lookup(value.trim(), byEmail: byEmail);
    if (mounted && c.error == null && c.selected != null) {
      setState(() {
        reason.clear();
        changeRole = c.selected!.role == 'unsupported'
            ? 'student'
            : c.selected!.role;
        dirty = false;
      });
    }
  }

  Future<void> _change(String action, Object value) async {
    final user = c.selected;
    if (user == null || !c.canChange) return;
    final explanation = reason.text.trim();
    if (explanation.length < 5 || explanation.length > 500) {
      setState(
        () => c.error = const PublicationFailure(
          'reason',
          'Enter a reason of 5–500 characters.',
        ),
      );
      return;
    }
    final destination = action == 'setRole'
        ? 'role $value'
        : value == true
        ? 'disabled'
        : 'enabled';
    if (!await _confirm(
          'Confirm account change?',
          'Target: ${user.uid}\nEmail: ${user.email ?? 'none'}\nCurrent role/status: ${user.role} / ${user.disabled ? 'disabled' : 'enabled'}\nRequested: $destination\nRevision: ${user.revision}\nReason: $explanation\n\nThis revokes sessions and requires a fresh target sign-in after the server timestamp. The backend protects the last active admin and refuses self changes. Auth and Firestore may remain pending; HTTP 200 alone is not completion.',
          'Confirm change',
        ) ||
        !mounted ||
        !allowed) {
      return;
    }
    await c.submit(action, value, explanation, reviewedTarget: user);
    if (mounted && c.hasIntent) setState(() => dirty = false);
  }

  Future<void> _newChange() async {
    if (!await _confirm(
          'Review a new change?',
          'Keep the old operation ID/key. This does not cancel, unlock or rewrite server work. After clearing local recovery, explicitly refresh the target and review a new reason/confirmation. Never assume a timed-out request did nothing.',
          'Review new change',
        ) ||
        !mounted ||
        !allowed) {
      return;
    }
    c.beginNewChange();
    if (!c.hasIntent) {
      setState(() {
        reason.clear();
        dirty = false;
      });
    }
  }

  Map<String, dynamic> _filters() => {
    if (filterRole != 'all') 'role': filterRole,
    if (filterDisabled != 'all') 'disabled': filterDisabled == 'disabled',
    if (filterVerified != 'all') 'verified': filterVerified == 'verified',
    if (provider.text.trim().isNotEmpty) 'provider': provider.text.trim(),
  };
  Widget _dropdown(
    String label,
    String value,
    List<String> values,
    void Function(String) change,
  ) => SizedBox(
    width: 200,
    child: DropdownButtonFormField<String>(
      isExpanded: true,
      key: ValueKey('$label-$value'),
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: values
          .map((v) => DropdownMenuItem(value: v, child: Text(v)))
          .toList(),
      onChanged: c.canRequest ? (v) => setState(() => change(v!)) : null,
    ),
  );
  Widget _directory() {
    final page = c.directory;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'User directory',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Text(
              'One native Auth page per request; filters apply only to that page. An empty result may still have a next page. No substring/name search or total user count is supplied.',
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                _dropdown('Role filter', filterRole, [
                  'all',
                  ...userRoles,
                ], (v) => filterRole = v),
                _dropdown('Account filter', filterDisabled, [
                  'all',
                  'enabled',
                  'disabled',
                ], (v) => filterDisabled = v),
                _dropdown('Verification filter', filterVerified, [
                  'all',
                  'verified',
                  'unverified',
                ], (v) => filterVerified = v),
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: provider,
                    maxLength: 64,
                    enabled: c.canRequest,
                    decoration: const InputDecoration(
                      labelText: 'Provider ID filter (optional)',
                      hintText: 'password or google.com',
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: c.canRequest ? () => c.firstPage(_filters()) : null,
                child: const Text('Apply filters / restart directory'),
              ),
            ),
            if (page != null) ...[
              Text(
                'Displayed filters: ${c.filters.isEmpty ? 'none' : c.filters.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
              ),
              Text(
                '${page.users.length} matching accounts · ${page.scanned} accounts inspected on this native page',
              ),
              if (page.users.isEmpty)
                Text(
                  page.next == null
                      ? 'No matching accounts on this page. End of directory.'
                      : 'No matches on this page. More accounts are available: use Next page.',
                ),
              for (final user in page.users)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '${user.name.isEmpty ? user.uid : user.name} · ${user.role}',
                  ),
                  subtitle: Text(
                    '${user.email ?? 'No email'}\n${user.uid}\n${user.disabled ? 'Disabled' : 'Enabled'} · ${user.pending ? 'Administration pending' : 'No pending administration'}',
                  ),
                  trailing: OutlinedButton(
                    onPressed: c.canRequest && !c.hasIntent
                        ? () => _select(user.uid, false)
                        : null,
                    child: const Text('View account'),
                  ),
                ),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: c.canRequest && c.hasPrevious
                        ? c.previousPage
                        : null,
                    child: const Text('Previous page'),
                  ),
                  OutlinedButton(
                    onPressed: c.canRequest && page.next != null
                        ? c.nextPage
                        : null,
                    child: const Text('Next page'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _details() {
    final u = c.selected!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Account details',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            SelectableText('UID: ${u.uid}'),
            Text('Name: ${u.name}'),
            Text('Email: ${u.email ?? 'none'}'),
            Text('Providers: ${u.providers.join(', ')}'),
            Text('Email verified: ${u.verified}'),
            Text('Account: ${u.disabled ? 'disabled' : 'enabled'}'),
            Text('Trusted Auth role: ${u.role}'),
            Text('Created: ${u.created}'),
            Text('Last sign-in: ${u.lastSignIn ?? 'unavailable'}'),
            Text(
              'Administration revision: ${u.revision}${u.revision == 0 ? ' (legacy or initial bootstrap; enrollment is not distinguished by this API)' : ' (managed)'}',
            ),
            Text(
              u.pending
                  ? 'Administration is pending; observed Auth fields may be intermediate. Changes are blocked.'
                  : 'No pending administration reported.',
            ),
            if (c.selectedStale)
              const Text(
                'These details need an explicit fresh read before a NEW change. An operation receipt is not the current account state.',
              ),
            if (u.uid == widget.uid)
              const Text(
                'Self role/status changes are prohibited. Another managed super admin must act.',
              ),
            if (u.role == 'unsupported')
              const Text(
                'Unsupported existing role. Contact a trusted operator; this screen cannot overwrite it.',
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: c.canRequest ? c.refreshSelected : null,
                child: const Text('Refresh current target'),
              ),
            ),
            TextField(
              controller: reason,
              enabled: c.canChange,
              minLines: 2,
              maxLines: 4,
              maxLength: 500,
              decoration: const InputDecoration(
                labelText: 'Change reason (5–500 characters)',
                helperText: 'Stored in the server audit. Avoid unrelated personal or secret information.',
              ),
              onChanged: (_) => setState(() => dirty = true),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 230,
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    key: ValueKey('requested-$changeRole'),
                    initialValue: changeRole,
                    decoration: const InputDecoration(
                      labelText: 'Requested approved role',
                    ),
                    items: userRoles
                        .map(
                          (role) =>
                              DropdownMenuItem(value: role, child: Text(role)),
                        )
                        .toList(),
                    onChanged: c.canChange
                        ? (value) => setState(() {
                            changeRole = value!;
                            dirty = true;
                          })
                        : null,
                  ),
                ),
                FilledButton(
                  onPressed:
                      c.canChange &&
                          changeRole != u.role &&
                          (changeRole == 'student' ||
                              (!u.disabled && u.verified))
                      ? () => _change('setRole', changeRole)
                      : null,
                  child: const Text('Confirm role change'),
                ),
                OutlinedButton(
                  onPressed: c.canChange
                      ? () => _change('setDisabled', !u.disabled)
                      : null,
                  child: Text(
                    u.disabled ? 'Enable account' : 'Disable account',
                  ),
                ),
              ],
            ),
            const Text(
              'Assigning student revokes the administrative role. Grants require an enabled, verified target. Last-active-admin decisions are authoritative on the server; there is no browser bypass.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _operation() {
    final op = c.operation;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Administration operation',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (c.frozen != null) ...[
              SelectableText(
                'Unconfirmed operation ID: ${c.frozen!.data['operationId']}',
              ),
              Text(
                'Target: ${c.frozen!.data['targetUid']} · ${c.frozen!.data['action']}',
              ),
              const Text(
                'The outcome is unknown. Retry the identical request or inspect its matching operation key. Do not replace its payload or preconditions.',
              ),
              FilledButton(
                onPressed: c.canRequest ? c.retryOriginal : null,
                child: const Text('Retry unchanged request'),
              ),
            ],
            if (c.operationKey != null) ...[
              SelectableText('Operation key: ${c.operationKey}'),
              OutlinedButton(
                onPressed: c.canRequest ? c.refreshOperation : null,
                child: const Text('Refresh operation status'),
              ),
            ],
            if (op != null) ...[
              SelectableText('Operation ID: ${op.id}'),
              SelectableText('Actor UID: ${op.actor}'),
              SelectableText('Target UID: ${op.target}'),
              Text(
                'State: ${op.state} · phase: ${op.phase} · administration revision: ${op.revision}',
              ),
              Text(
                'Before: ${op.before['role']} / ${op.before['disabled'] ? 'disabled' : 'enabled'}',
              ),
              Text(
                'Requested after: ${op.after['role']} / ${op.after['disabled'] ? 'disabled' : 'enabled'}',
              ),
              if (op.errorCode != null)
                Text(
                  'Last server outcome: ${op.errorCode} · ${op.retryable ? 'retryable when no worker owns it' : 'operator inspection required'}',
                ),
              if (op.complete) ...[
                const Text(
                  'Server-confirmed complete. This receipt is historical; explicitly refresh target details before another change.',
                ),
                Text(
                  'Target must sign in again at/after ${DateTime.fromMillisecondsSinceEpoch(op.signInAfter! * 1000, isUtc: true).toIso8601String()}. Refreshing an old session is insufficient.',
                ),
              ],
              if (!op.complete && op.worker)
                const Text(
                  'A durable worker owns this operation. Refresh status; do not start overlapping work. Worker age is not proof that it stopped.',
                ),
              if (op.state == 'recovery_required')
                const Text(
                  'Trusted recovery required. A verified operator must follow docs/user_admin_api.md and confirm the invocation AND unknown Auth requests settled. This browser has no unlock, force, cancellation or bypass control.',
                ),
              if (op.state == 'pending' && !op.worker)
                FilledButton(
                  onPressed: c.canResume
                      ? () async {
                          if (await _confirm(
                                'Resume the same frozen operation?',
                                'Target: ${op.target}\nOriginal actor: ${op.actor}\nAction: ${op.action}\nRequested state: ${op.after['role']} / ${op.after['disabled'] ? 'disabled' : 'enabled'}\nThe original payload, reason and preconditions remain unchanged; your UID is audited as resumer.',
                                'Resume same operation',
                              ) &&
                              mounted &&
                              allowed) {
                            await c.resume();
                          }
                        }
                      : null,
                  child: const Text('Resume same operation'),
                ),
            ],
            if (c.rejected || op?.complete == true)
              OutlinedButton(
                onPressed: c.canRequest ? _newChange : null,
                child: const Text('Review new change'),
              ),
            const Text(
              'HTTP 200 is not completion. Only the server complete state confirms the workflow; this screen cannot release a locked worker.',
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
      canPop: allowPop || !mustWarn,
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
          title: const Text('User management'),
          actions: [
            TextButton(
              onPressed: () async {
                if (await _mayLeave() && mounted) await widget.auth.signOut();
              },
              child: const Text('Sign out'),
            ),
          ],
        ),
        body: !allowed
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Current super-admin authorization is required.',
                    ),
                    OutlinedButton(
                      onPressed: widget.auth.refreshSession,
                      child: const Text('Refresh session / sign in again'),
                    ),
                  ],
                ),
              )
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Super-admin-only account administration. No deletion, exports, private learning data or raw claims are available.',
                    ),
                    const Text(
                      'An unconfirmed request is stored only in this account/environment’s browser tab recovery storage and may contain its audit reason. Keep the operation ID/key. No credentials are stored.',
                    ),
                    if (c.busy)
                      const LinearProgressIndicator(
                        semanticsLabel:
                            'User administration request in progress',
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
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _dropdown('Exact lookup type', lookupMode, [
                          'uid',
                          'email',
                        ], (v) => lookupMode = v),
                        SizedBox(
                          width: 360,
                          child: TextField(
                            controller: lookup,
                            enabled: c.canRequest && !c.hasIntent,
                            maxLength: 254,
                            decoration: const InputDecoration(
                              labelText: 'Exact UID or email',
                            ),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: c.canRequest && !c.hasIntent
                              ? () =>
                                    _select(lookup.text, lookupMode == 'email')
                              : null,
                          child: const Text('Look up account'),
                        ),
                      ],
                    ),
                    _directory(),
                    if (c.selected != null) _details(),
                    const SizedBox(height: 16),
                    TextField(
                      controller: keyLookup,
                      enabled: c.canRequest,
                      maxLength: 64,
                      decoration: const InputDecoration(
                        labelText: 'Operation key to inspect',
                        helperText: 'Current managed super admins may inspect/resume another actor’s frozen server operation.',
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: c.canRequest
                            ? () async {
                                if (dirty &&
                                    !await _confirm(
                                      'Inspect an operation?',
                                      'Unsubmitted choices will be replaced only after a matching server receipt is confirmed.',
                                      'Inspect operation',
                                    )) {
                                  return;
                                }
                                if (mounted && allowed) {
                                  await c.inspect(keyLookup.text.trim());
                                  if (mounted && c.error == null) {
                                    setState(() {
                                      reason.clear();
                                      dirty = false;
                                    });
                                  }
                                }
                              }
                            : null,
                        child: const Text('Inspect operation'),
                      ),
                    ),
                    if (c.hasIntent) _operation(),
                  ],
                ),
              ),
      ),
    ),
  );
}
