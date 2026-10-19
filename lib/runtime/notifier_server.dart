/// Minimal synchronous notification port for the headless Dart runtime.
class ChangeNotifier {
  final _listeners = <void Function()>[];
  bool _closed = false;
  void addListener(void Function() listener) {
    if (!_closed) _listeners.add(listener);
  }

  void removeListener(void Function() listener) => _listeners.remove(listener);
  void notifyListeners() {
    for (final listener in List.of(_listeners)) {
      if (!_closed && _listeners.contains(listener)) listener();
    }
  }

  void dispose() {
    _closed = true;
    _listeners.clear();
  }
}
