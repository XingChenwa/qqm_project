import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../models/plugin.dart';
import '../services/storage_service.dart';
import '../utils/helpers.dart';
import 'plugins/built_in_plugins.dart';

class PluginManager extends ChangeNotifier {
  final Logger _log = Logger('PluginManager');
  final StorageService _storage;
  final List<BotPlugin> _plugins = [];

  PluginManager(this._storage);

  List<BotPlugin> get plugins => List.unmodifiable(_plugins);

  Future<void> init() async {
    _plugins.clear();
    _registerBuiltInPlugins(_savedPluginConfigsById());
    notifyListeners();
  }

  Map<String, PluginInfo> _savedPluginConfigsById() {
    try {
      return {for (final info in _storage.getPluginConfigs()) info.id: info};
    } catch (e, stackTrace) {
      _log.warning('Failed to restore plugin configs', e, stackTrace);
      return {};
    }
  }

  void _registerBuiltInPlugins(Map<String, PluginInfo> savedConfigs) {
    for (final definition in BuiltInPluginRegistry.definitions) {
      final saved = savedConfigs[definition.id];
      final info = PluginInfo(
        id: definition.id,
        name: definition.name,
        version: definition.version,
        description: definition.description,
        author: definition.author,
        directory: definition.directory,
        isEnabled: saved?.isEnabled ?? definition.enabledByDefault,
        config: {...definition.defaultConfig, ...?saved?.config},
        permissions: definition.permissions,
      );

      final plugin = BuiltInPluginRegistry.create(info.id, info);
      if (plugin == null) continue;

      _plugins.add(plugin);
      if (info.isEnabled) {
        unawaited(_enablePluginSafely(plugin));
      }
      _log.info(
        'Loaded plugin: ${info.name} (${info.isEnabled ? "enabled" : "disabled"})',
      );
    }
  }

  Future<void> _enablePluginSafely(BotPlugin plugin) async {
    try {
      await plugin.onEnable().timeout(const Duration(seconds: 5));
    } catch (e, stackTrace) {
      plugin.info.isEnabled = false;
      _log.warning(
        'Plugin ${plugin.info.name} failed to enable',
        e,
        stackTrace,
      );
      await _storage.savePluginConfig(plugin.info);
      notifyListeners();
    }
  }

  BotPlugin? _findPlugin(String pluginId) {
    for (final plugin in _plugins) {
      if (plugin.info.id == pluginId) return plugin;
    }
    return null;
  }

  Future<bool> enablePlugin(String pluginId) async {
    final plugin = _findPlugin(pluginId);
    if (plugin == null) return false;
    if (plugin.info.isEnabled) return true;

    try {
      await plugin.onEnable().timeout(const Duration(seconds: 5));
      plugin.info.isEnabled = true;
      await _storage.savePluginConfig(plugin.info);
      _log.info('Enabled plugin: ${plugin.info.name}');
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      _log.warning(
        'Failed to enable plugin: ${plugin.info.name}',
        e,
        stackTrace,
      );
      return false;
    }
  }

  Future<bool> disablePlugin(String pluginId) async {
    final plugin = _findPlugin(pluginId);
    if (plugin == null) return false;
    if (!plugin.info.isEnabled) return true;

    try {
      await plugin.onDisable().timeout(const Duration(seconds: 5));
    } catch (e, stackTrace) {
      _log.warning(
        'Plugin ${plugin.info.name} failed while disabling',
        e,
        stackTrace,
      );
    }

    plugin.info.isEnabled = false;
    await _storage.savePluginConfig(plugin.info);
    _log.info('Disabled plugin: ${plugin.info.name}');
    notifyListeners();
    return true;
  }

  Future<bool> uninstallPlugin(String pluginId) async {
    final plugin = _findPlugin(pluginId);
    if (plugin == null) return false;

    if (plugin.info.isEnabled) {
      await disablePlugin(pluginId);
    }
    _plugins.removeWhere((p) => p.info.id == pluginId);
    await _storage.deletePluginConfig(pluginId);
    _log.info('Uninstalled plugin: ${plugin.info.name}');
    notifyListeners();
    return true;
  }

  Future<List<PluginResponse>> processMessage(PluginMessage message) async {
    final responses = <PluginResponse>[];
    final command = parseSlashCommand(message.content);

    for (final plugin in _plugins.where((p) => p.info.isEnabled)) {
      try {
        final result =
            await (command == null
                    ? plugin.onMessage(message)
                    : plugin.onCommand(command.command, command.args))
                .timeout(plugin.executionTimeout);
        if (result == null || result.trim().isEmpty) continue;

        responses.add(
          PluginResponse(
            pluginId: plugin.info.id,
            pluginName: plugin.info.name,
            content: result.trim(),
          ),
        );
      } on TimeoutException {
        _log.warning('Plugin ${plugin.info.name} timed out on message');
      } catch (e, stackTrace) {
        _log.severe('Plugin ${plugin.info.name} message error', e, stackTrace);
      }
    }

    return responses;
  }

  Future<String?> processCommand(
    String command,
    List<String> args,
    PluginMessage? context,
  ) async {
    final normalized = command
        .trim()
        .replaceFirst(RegExp(r'^/+'), '')
        .toLowerCase();
    if (normalized.isEmpty) return null;

    for (final plugin in _plugins.where((p) => p.info.isEnabled)) {
      try {
        final result = await plugin
            .onCommand(normalized, args)
            .timeout(plugin.executionTimeout);
        if (result != null && result.trim().isNotEmpty) return result.trim();
      } on TimeoutException {
        _log.warning(
          'Plugin ${plugin.info.name} timed out on command /$normalized',
        );
      } catch (e, stackTrace) {
        _log.severe('Plugin ${plugin.info.name} command error', e, stackTrace);
      }
    }

    return null;
  }

  Future<void> tick() async {
    for (final plugin in _plugins.where((p) => p.info.isEnabled)) {
      try {
        await plugin.onTick().timeout(const Duration(seconds: 3));
      } catch (e, stackTrace) {
        _log.fine('Plugin ${plugin.info.name} tick failed', e, stackTrace);
      }
    }
  }

  Future<bool> updatePluginConfig(
    String pluginId,
    Map<String, dynamic> config,
  ) async {
    final plugin = _findPlugin(pluginId);
    if (plugin == null) return false;

    await plugin.updateConfig(config);
    await _storage.savePluginConfig(plugin.info);
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    for (final plugin in _plugins.where((p) => p.info.isEnabled)) {
      unawaited(plugin.onDisable());
    }
    super.dispose();
  }
}

class PluginResponse {
  final String pluginId;
  final String pluginName;
  final String content;

  const PluginResponse({
    required this.pluginId,
    required this.pluginName,
    required this.content,
  });
}
