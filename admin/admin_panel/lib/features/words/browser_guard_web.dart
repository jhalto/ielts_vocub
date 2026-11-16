import 'dart:js_interop';

@JS('window.addEventListener')
external void _addListener(String type, JSFunction listener);
@JS('window.removeEventListener')
external void _removeListener(String type, JSFunction listener);

extension type _UnloadEvent(JSObject object) implements JSObject {
  external void preventDefault();
  external set returnValue(String value);
}

class BrowserGuard {
  BrowserGuard(bool Function() dirty) {
    _listener = ((JSObject raw) {
      if (dirty()) {
        final event = _UnloadEvent(raw);
        event.preventDefault();
        event.returnValue = '';
      }
    }).toJS;
    _addListener('beforeunload', _listener);
  }
  late final JSFunction _listener;
  void dispose() => _removeListener('beforeunload', _listener);
}
