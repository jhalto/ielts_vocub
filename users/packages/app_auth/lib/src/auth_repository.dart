final class Identity {
  const Identity({
    required this.uid,
    required this.email,
    required this.name,
    required this.verified,
    required this.providers,
    this.createdAt,
  });
  final String uid;
  final String email;
  final String name;
  final bool verified;
  final List<String> providers;
  final DateTime? createdAt;
}

final class AuthProblem implements Exception {
  const AuthProblem(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => message;
}

abstract interface class AuthRepository {
  Stream<Identity?> get identities;
  bool get supportsGoogle;
  Future<void> login(String email, String password);
  Future<void> register(String name, String email, String password);
  Future<void> google();
  Future<void> resetPassword(String email);
  Future<void> sendVerification();
  Future<void> reload();
  Future<void> logout();
  Future<Map<String, dynamic>> initializeProfile({String? name});
  Future<String> checkAdmin();
}

String? validateEmail(String? input) {
  final value = input?.trim() ?? '';
  if (value.length > 254 ||
      !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
    return 'Enter a valid email address.';
  }
  return null;
}

String? validateName(String? input) {
  final value = input?.trim() ?? '';
  return value.isEmpty || value.length > 100
      ? 'Enter a name of 1-100 characters.'
      : null;
}
