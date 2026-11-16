import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'platform_types.dart';

@JS('document.createElement')
external JSObject _element(String name);

extension type _Input(JSObject object) implements JSObject {
  external set type(String value);
  external set accept(String value);
  external _Files? get files;
  external void click();
  external void addEventListener(String event, JSFunction listener);
  external void removeEventListener(String event, JSFunction listener);
}

extension type _Files(JSObject object) implements JSObject {
  external _File? item(int index);
}

extension type _File(JSObject object) implements JSObject {
  external String get name;
  external String get type;
  external double get size;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

Future<PickedJson?> pickJsonFile() async {
  final input = _Input(_element('input'))
    ..type = 'file'
    ..accept = '.json,application/json';
  final selected = Completer<_File?>();
  final changed = ((JSObject _) {
    if (!selected.isCompleted) selected.complete(input.files?.item(0));
  }).toJS;
  final cancelled = ((JSObject _) {
    if (!selected.isCompleted) selected.complete(null);
  }).toJS;
  input.addEventListener('change', changed);
  input.addEventListener('cancel', cancelled);
  try {
    input.click();
    final file = await selected.future;
    if (file == null) return null;
    if (file.size > 524288) {
      throw const FormatException('File exceeds 512 KiB.');
    }
    if (!file.name.toLowerCase().endsWith('.json') ||
        ![
          '',
          'application/json',
          'text/json',
        ].contains(file.type.toLowerCase())) {
      throw const FormatException('Select a JSON file. CSV is not supported.');
    }
    final bytes = (await file.arrayBuffer().toDart).toDart.asUint8List();
    return PickedJson(file.name, file.type, bytes);
  } finally {
    input.removeEventListener('change', changed);
    input.removeEventListener('cancel', cancelled);
  }
}

@JS('window.sessionStorage')
external _Storage get _storage;

extension type _Storage(JSObject object) implements JSObject {
  external int get length;
  external String? key(int index);
  external String? getItem(String key);
  external void setItem(String key, String value);
  external void removeItem(String key);
}

class _WebSession implements ImportSession {
  _WebSession(this.key);
  final String key;
  @override
  String? read() => _storage.getItem(key);
  @override
  void write(String value) => _storage.setItem(key, value);
  @override
  void clear() => _storage.removeItem(key);
}

ImportSession createImportSession(String namespace, String uid) =>
    _WebSession('vocabulary-import-v1:${jsonEncode([namespace, uid])}');

void clearImportSessions(String uid, {String? endpointSuffix}) {
  // Clear only this owner's import checkpoints, including a page already closed.
  for (var i = _storage.length - 1; i >= 0; i--) {
    final key = _storage.key(i);
    if (key == null || !key.startsWith('vocabulary-import-v1:')) continue;
    try {
      final namespace = jsonDecode(
        key.substring('vocabulary-import-v1:'.length),
      );
      if (namespace is List &&
          namespace.length == 2 &&
          namespace[1] == uid &&
          (endpointSuffix == null ||
              (namespace[0] is String &&
                  (namespace[0] as String).endsWith(endpointSuffix)))) {
        _storage.removeItem(key);
      }
    } on FormatException {
      continue;
    }
  }
}
