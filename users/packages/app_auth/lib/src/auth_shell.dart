import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'auth_controller.dart';
import 'auth_repository.dart';

class AuthShell extends StatefulWidget {
  const AuthShell({
    super.key,
    required this.repository,
    this.adminOnly = false,
    this.offlineBuilder,
    this.clearPrivate,
  });
  final AuthRepository repository;
  final bool adminOnly;
  final Widget Function(String? uid)? offlineBuilder;
  final Future<void> Function(String uid)? clearPrivate;
  @override
  State<AuthShell> createState() => _AuthShellState();
}

class _AuthShellState extends State<AuthShell> with WidgetsBindingObserver {
  late final AuthController controller;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    controller = AuthController(
      widget.repository,
      adminOnly: widget.adminOnly,
      clearPrivate: widget.clearPrivate,
    );
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && controller.identity != null) {
      unawaited(controller.refreshSession());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }

  Future<void> _signOut() async {
    if (widget.clearPrivate != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sign out and clear private offline data?'),
          content: const Text(
            'This removes your local progress, unfinished session and pending changes from this device. Unsynced changes will be lost. Downloaded vocabulary stays available to guests.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep learning'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Sign out'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await controller.signOut();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final c = controller;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            widget.adminOnly ? 'Vocabulary Administration' : 'VocabSwipe',
          ),
          actions: [
            if (c.identity != null)
              TextButton(
                onPressed: c.busy ? null : _signOut,
                child: const Text('Sign out'),
              ),
          ],
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (c.busy || c.starting)
                      const LinearProgressIndicator(semanticsLabel: 'Working'),
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
                    if (!c.starting && c.identity == null && !c.guest)
                      _Credentials(controller: c),
                    if (c.guest) ...[
                      Text(
                        'Welcome, guest',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Guest access does not save personal progress. Downloaded vocabulary is available below.',
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: c.leaveGuest,
                        child: const Text('Sign in or create an account'),
                      ),
                    ],
                    if (c.identity != null)
                      _Account(key: ValueKey(c.identity!.uid), controller: c),
                    if (!widget.adminOnly &&
                        (c.identity != null || c.guest) &&
                        widget.offlineBuilder != null)
                      widget.offlineBuilder!(c.identity?.uid),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _Credentials extends StatefulWidget {
  const _Credentials({required this.controller});
  final AuthController controller;
  @override
  State<_Credentials> createState() => _CredentialsState();
}

class _CredentialsState extends State<_Credentials> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _name = TextEditingController();
  bool _register = false;
  bool _reset = false;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final c = widget.controller;
    final password = _password.text;
    _password.clear();
    _confirm.clear();
    if (_reset) {
      await c.run(
        () => c.repository.resetPassword(_email.text),
        success: 'If this address has an account, a reset email will arrive.',
      );
    } else if (_register) {
      await c.register(_name.text, _email.text, password);
    } else {
      await c.run(() => c.repository.login(_email.text, password));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Form(
      key: _form,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _reset
                  ? 'Reset password'
                  : _register
                  ? 'Create your account'
                  : 'Welcome back',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            const Text(
              'Signing in, registration and email actions require an internet connection.',
            ),
            const SizedBox(height: 20),
            if (_register && !_reset)
              TextFormField(
                controller: _name,
                enabled: !c.busy,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: validateName,
                autofillHints: const [AutofillHints.name],
                textInputAction: TextInputAction.next,
              ),
            TextFormField(
              controller: _email,
              enabled: !c.busy,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
              validator: validateEmail,
              autofillHints: const [AutofillHints.email],
              textInputAction: TextInputAction.next,
            ),
            if (!_reset)
              TextFormField(
                controller: _password,
                enabled: !c.busy,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
                autofillHints: [
                  _register
                      ? AutofillHints.newPassword
                      : AutofillHints.password,
                ],
                validator: (v) =>
                    v == null || v.isEmpty ? 'Enter your password.' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            if (_register && !_reset)
              TextFormField(
                controller: _confirm,
                enabled: !c.busy,
                decoration: const InputDecoration(
                  labelText: 'Confirm password',
                ),
                obscureText: true,
                validator: (v) =>
                    v != _password.text ? 'Passwords must match.' : null,
                onFieldSubmitted: (_) => _submit(),
              ),
            if (_register && !_reset)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Your password must meet the configured account password policy.',
                ),
              ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: c.busy ? null : _submit,
              child: Text(
                _reset
                    ? 'Send reset email'
                    : _register
                    ? 'Register'
                    : 'Sign in',
              ),
            ),
            if (!_reset)
              OutlinedButton(
                onPressed: c.busy || !c.repository.supportsGoogle
                    ? null
                    : () => c.run(c.repository.google),
                child: const Text('Continue with Google'),
              ),
            if (!_reset && !c.repository.supportsGoogle)
              const Text(
                'Google sign-in is not available in this Windows build. Use email and password.',
              ),
            TextButton(
              onPressed: c.busy
                  ? null
                  : () => setState(() {
                      _reset = !_reset;
                      _password.clear();
                      _confirm.clear();
                    }),
              child: Text(_reset ? 'Back to sign in' : 'Forgot password?'),
            ),
            if (!c.adminOnly && !_reset) ...[
              TextButton(
                onPressed: c.busy
                    ? null
                    : () => setState(() {
                        _register = !_register;
                        _password.clear();
                        _confirm.clear();
                      }),
                child: Text(
                  _register
                      ? 'Already registered? Sign in'
                      : 'Create an account',
                ),
              ),
              TextButton(
                onPressed: c.busy ? null : c.enterGuest,
                child: const Text('Continue as guest'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Account extends StatefulWidget {
  const _Account({super.key, required this.controller});
  final AuthController controller;
  @override
  State<_Account> createState() => _AccountState();
}

class _AccountState extends State<_Account> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final user = c.identity!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          c.profile?['name'] as String? ?? user.name,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(user.email),
        const SizedBox(height: 12),
        Text(user.verified ? 'Email verified' : 'Email not verified'),
        Text('Sign-in providers: ${user.providers.join(', ')}'),
        if (user.createdAt != null)
          Text(
            'Account created: ${user.createdAt!.toLocal().toString().split(' ').first}',
          ),
        const SizedBox(height: 12),
        if (!user.verified)
          FilledButton(
            onPressed: c.busy || !c.canResend ? null : c.sendVerification,
            child: Text(
              c.canResend
                  ? 'Send verification email'
                  : 'Wait 60 seconds before resending',
            ),
          ),
        OutlinedButton(
          onPressed: c.busy ? null : c.refreshSession,
          child: const Text('Refresh session and verification'),
        ),
        if (c.profilePending) ...[
          const Text(
            'Profile setup is pending. Your sign-in is saved; reconnect and retry.',
          ),
          OutlinedButton(
            onPressed: c.busy ? null : () => c.run(c.refreshProfile),
            child: const Text('Retry profile setup'),
          ),
        ],
        if (c.adminOnly) ...[
          Text(
            c.adminAllowed ? 'Administrator access verified: ${c.role}' : 'Administrator access is not authorized. An online role check is required.',
          ),
        ] else ...[
          const Text(
            'A restored session allows offline access to already-downloaded content. Server revocation cannot be checked while offline.',
          ),
          const SizedBox(height: 12),
          Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  enabled: !c.busy,
                  decoration: const InputDecoration(
                    labelText: 'New display name',
                  ),
                  validator: validateName,
                ),
                TextButton(
                  onPressed: c.busy
                      ? null
                      : () async {
                          if (!(_form.currentState?.validate() ?? false)) {
                            return;
                          }
                          await c.run(
                            () => c.refreshProfile(name: _name.text.trim()),
                          );
                        },
                  child: const Text('Save name'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Your learning progress is saved locally. Pending changes are not cloud backups.',
          ),
        ],
      ],
    );
  }
}
