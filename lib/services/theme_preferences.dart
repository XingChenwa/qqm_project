import 'package:flutter/material.dart';

import 'storage_service.dart';

/// App-wide appearance, independent of the selected bot and update channel.
class ThemePreferences extends ChangeNotifier {
  final StorageService storage;
  late ThemeMode _mode = ThemeMode.values.firstWhere(
    (value) => value.name == storage.getAppearance(),
    orElse: () => ThemeMode.system,
  );
  ThemePreferences(this.storage);

  ThemeMode get mode => _mode;
  bool _saving = false;
  bool _disposed = false;
  bool get saving => _saving;

  Future<void> select(ThemeMode mode) async {
    if (_disposed || _saving || _mode == mode) return;
    _saving = true;
    notifyListeners();
    try {
      await storage.setAppearance(mode.name);
      _mode = mode;
    } finally {
      _saving = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
