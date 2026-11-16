import 'platform_types.dart';

Future<PickedJson?> pickJsonFile() async =>
    throw UnsupportedError('File selection requires Admin Web.');
ImportSession createImportSession(String namespace, String uid) =>
    MemoryImportSession();
void clearImportSessions(String uid, {String? endpointSuffix}) {}
