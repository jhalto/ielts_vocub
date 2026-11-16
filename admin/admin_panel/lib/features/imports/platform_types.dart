import 'dart:typed_data';

class PickedJson {
  PickedJson(this.name, this.mime, this.bytes);
  final String name, mime;
  final Uint8List bytes;
}

abstract interface class ImportSession {
  String? read();
  void write(String value);
  void clear();
}

class MemoryImportSession implements ImportSession {
  String? value;
  @override
  String? read() => value;
  @override
  void write(String value) => this.value = value;
  @override
  void clear() => value = null;
}
