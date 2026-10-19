import 'dart:async';
import 'dart:convert';

import '../runtime/notifier.dart';
import '../runtime/assets.dart';
import 'package:logging/logging.dart';

import '../models/plugin.dart';
import '../models/plugin_manifest.dart';
import '../services/storage_service.dart';
import 'plugins/manifest_plugin.dart';
import 'plugins/script_plugin.dart';
import 'plugins/script_runner.dart';

class PluginManager extends ChangeNotifier {
  static final _botScope = Object();
  final Logger _log = Logger('PluginManager');
  final StorageService _storage;
  final List<BotPlugin> _plugins = [];
  final Map<String, String> _errors = {};
  final Map<String, PluginStore> _stores = {};
  final Map<String, int> _active = {};
  final Map<String, DateTime> _cooldowns = {};
  bool _disposed = false;
  final _bundledIds = <String>{};

  final PluginScriptRunner Function() _scriptRunnerFactory;
  PluginManager(
    this._storage, {
    PluginScriptRunner Function()? scriptRunnerFactory,
  }) : _scriptRunnerFactory = scriptRunnerFactory ?? PluginScriptRunner.new;

  List<BotPlugin> get plugins => List.unmodifiable(_plugins);
  int get enabledCount => _plugins.where((p) => p.info.isEnabled).length;
  String? errorFor(String id) => _errors[id];
  Map<String, String> get unavailablePlugins => Map.unmodifiable({
    for (final entry in _errors.entries)
      if (!_plugins.any((plugin) => plugin.info.id == entry.key))
        entry.key: entry.value,
  });
  bool isBundled(String id) => _bundledIds.contains(id);

  BotPlugin _create(PluginManifest definition, PluginInfo info) =>
      definition.runtime == 'script'
      ? ScriptPlugin(info, definition, runnerFactory: _scriptRunnerFactory)
      : ManifestPlugin(info, definition);

  String commandHelp() {
    final lines = <String>['插件命令菜单（支持 / 或 # 前缀）'];
    for (final plugin in _plugins.where((p) => p.info.isEnabled)) {
      if (plugin.commands.isEmpty) continue;
      lines.add('\n【${plugin.info.name}】');
      for (final command in plugin.commands) {
        lines.add(
          '/${command.usage.isEmpty ? command.name : command.usage} — ${command.description}',
        );
      }
    }
    lines.add('\n群内免 @ 需要平台已开启“接收所有消息”；普通聊天不会兜底回复。');
    return lines.join('\n');
  }

  void _bind(BotPlugin plugin) {
    plugin.host = PluginHost(
      help: commandHelp,
      appId: () =>
          Zone.current[_botScope] as String? ?? _storage.activeBotAppId,
      store: () {
        final scope = jsonEncode([
          Zone.current[_botScope] as String? ?? _storage.activeBotAppId,
          plugin.info.id,
        ]);
        return _stores.putIfAbsent(
          scope,
          () => PluginStore(
            () => _storage.readPluginData(scope),
            (value) => _storage.writePluginData(scope, value),
          ),
        );
      },
    );
  }

  Future<void> init() async {
    for (final plugin in _plugins) {
      try {
        await plugin.onDisable().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    _plugins.clear();
    _errors.clear();
    _bundledIds.clear();
    final savedConfigs = _savedPluginConfigsById();
    final index =
        jsonDecode(await rootBundle.loadString('plugins/index.json')) as Map;
    for (final path in index['plugins'] as List) {
      if (path is! String ||
          !RegExp(r'^plugins/[a-z][a-z0-9_]+/plugin[.]json$').hasMatch(path)) {
        _log.warning('已跳过无效的随附插件路径');
        continue;
      }
      final bundledId = path.split('/')[1];
      _bundledIds.add(bundledId);
      try {
        var definition = PluginManifest.parse(
          await rootBundle.loadString(path),
        );
        if (definition.id != bundledId) {
          throw const PluginManifestException('插件目录与 ID 不一致');
        }
        final saved = savedConfigs[definition.id];
        if (saved?.isCustomized == true) {
          definition = PluginManifest.parse(jsonEncode(saved!.manifest));
          if (definition.id != bundledId) {
            throw const PluginManifestException('插件 ID 不一致');
          }
        } else if (definition.runtime == 'script' &&
            definition.data['entrypoint'] is String) {
          final data =
              jsonDecode(jsonEncode(definition.data)) as Map<String, dynamic>;
          (data['script'] as Map)['source'] = await rootBundle.loadString(
            'plugins/${definition.id}/${data['entrypoint']}',
          );
          definition = PluginManifest.parse(jsonEncode(data));
        }
        final info = definition.toInfo(saved: saved, enabledByDefault: false);
        final plugin = _create(definition, info);
        _plugins.add(plugin);
        _bind(plugin);
        if (info.isEnabled) await _enablePluginSafely(plugin);
      } catch (_) {
        _errors[bundledId] = '插件定义无效，已跳过加载；原始配置仍保留，可重新导入修复。';
        _log.warning('已跳过无效的插件定义：$bundledId');
      }
    }
    for (final saved in savedConfigs.values.where((p) => !isBundled(p.id))) {
      if (saved.manifest.isEmpty) continue;
      try {
        final definition = PluginManifest.parse(jsonEncode(saved.manifest));
        if (definition.id != saved.id) {
          throw const PluginManifestException('保存的插件 ID 不一致。');
        }
        final info = definition.toInfo(saved: saved);
        final plugin = _create(definition, info);
        _plugins.add(plugin);
        _bind(plugin);
        if (info.isEnabled) await _enablePluginSafely(plugin);
      } catch (_) {
        _errors[saved.id] = '插件定义无效，已跳过加载；原始配置仍保留。';
        _log.warning('已跳过无效的第三方插件配置：${saved.id}');
      }
    }
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

  /// 导入只安装定义，不启用、不请求外网、不发送 QQ 消息。
  Future<PluginInfo> installPlugin(
    String source, {
    bool replaceExisting = false,
  }) async {
    final definition = PluginManifest.parse(source);
    if (definition.runtime == 'script' &&
        definition.data['script']['source'] is! String) {
      throw const PluginManifestException('导入需要完整脚本源码；请从工作台安装含 .ht 的项目。');
    }
    final previous = _findPlugin(definition.id);
    if (previous != null && !replaceExisting) {
      throw const PluginManifestException('插件 ID 已存在，请确认后选择替换。');
    }
    if (previous == null &&
        _plugins.where((p) => !isBundled(p.info.id)).length >= 32) {
      throw const PluginManifestException('第三方插件最多安装 32 个。');
    }
    final info = definition.toInfo(saved: previous?.info)
      ..isEnabled = false
      ..isCustomized = true;
    await _storage.savePluginConfig(info);
    if (previous != null) {
      previous.info.isEnabled = false;
      try {
        await previous.onDisable().timeout(const Duration(seconds: 5));
      } catch (_) {
        /* 替换时不执行旧插件的回复。 */
      }
      _plugins.remove(previous);
    }
    final installed = _create(definition, info);
    _bind(installed);
    _plugins.add(installed);
    _errors.remove(info.id);
    notifyListeners();
    return info;
  }

  String exportPlugin(String id) {
    final plugin = _findPlugin(id);
    if (plugin == null) throw const PluginManifestException('未找到插件。');
    return PluginManifest.parse(
      jsonEncode(plugin.info.manifest),
      allowBuiltin: true,
    ).exportDefinition();
  }

  Future<String> exportPluginData(String id) async {
    final plugin = _findPlugin(id);
    if (plugin == null) throw const PluginManifestException('插件不存在。');
    return const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'plugin_id': id,
      'data': await plugin.host!.store.snapshot(),
    });
  }

  Future<void> clearPluginData(String id) async {
    final plugin = _findPlugin(id);
    if (plugin == null) throw const PluginManifestException('插件不存在。');
    if (plugin.info.isEnabled || (_active[id] ?? 0) != 0) {
      throw const PluginManifestException('请先停用插件，等待当前任务结束后再清理。');
    }
    await plugin.host!.store.clear();
  }

  Future<void> _enablePluginSafely(BotPlugin plugin) async {
    try {
      await plugin.onEnable().timeout(const Duration(seconds: 5));
    } catch (e, stackTrace) {
      try {
        await plugin.onDisable().timeout(const Duration(seconds: 2));
      } catch (_) {}
      plugin.info.isEnabled = false;
      _errors[plugin.info.id] = e is PluginManifestException
          ? e.message
          : '插件启用失败，请检查配置。';
      _log.warning(
        'Plugin ${plugin.info.name} failed to enable',
        e,
        stackTrace,
      );
      await _storage.savePluginConfig(plugin.info);
      if (!_disposed) notifyListeners();
    }
  }

  BotPlugin? _findPlugin(String pluginId) {
    for (final plugin in _plugins) {
      if (plugin.info.id == pluginId) return plugin;
    }
    return null;
  }

  /// Local preview only: no QQ sends, external HTTP or persistent plugin data.
  Future<PluginReply?> previewPlugin(
    String source,
    PluginMessage message,
  ) async {
    final definition = PluginManifest.parse(source);
    if (definition.runtime == 'http') {
      throw const PluginManifestException('HTTP 插件请在自己的测试服务验证，预览不会调用外部接口。');
    }
    final info = definition.toInfo();
    final plugin = definition.runtime == 'script'
        ? ScriptPlugin(
            info,
            definition,
            runnerFactory: _scriptRunnerFactory,
            networkForTesting: (_) async => {'error': '本地试运行不联网'},
          )
        : ManifestPlugin(info, definition);
    var data = <String, dynamic>{};
    plugin.host = PluginHost(
      help: commandHelp,
      appId: () => 'local-preview',
      store: () => PluginStore(() async => data, (next) async {
        data = next;
      }),
    );
    try {
      await plugin.onEnable().timeout(const Duration(seconds: 5));
      return await plugin.execute(message).timeout(plugin.executionTimeout);
    } finally {
      await plugin.onDisable();
    }
  }

  Future<bool> enablePlugin(String pluginId) async {
    final plugin = _findPlugin(pluginId);
    if (plugin == null) return false;
    if (plugin.info.isEnabled) return true;

    try {
      await plugin.onEnable().timeout(const Duration(seconds: 5));
      plugin.info.isEnabled = true;
      _errors.remove(pluginId);
      await _storage.savePluginConfig(plugin.info);
      _log.info('Enabled plugin: ${plugin.info.name}');
      notifyListeners();
      return true;
    } catch (e, stackTrace) {
      try {
        await plugin.onDisable().timeout(const Duration(seconds: 2));
      } catch (_) {}
      _errors[pluginId] = e is PluginManifestException
          ? e.message
          : '插件启用失败，请检查配置。';
      _log.warning(
        'Failed to enable plugin: ${plugin.info.name}',
        e,
        stackTrace,
      );
      notifyListeners();
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
    // 随附项目始终保留入口，可停用或用同一加载器覆盖源码。
    if (isBundled(pluginId)) return false;
    final plugin = _findPlugin(pluginId);
    if (plugin == null) return false;

    if (plugin.info.isEnabled) {
      await disablePlugin(pluginId);
    }
    _plugins.removeWhere((p) => p.info.id == pluginId);
    _errors.remove(pluginId);
    await _storage.deletePluginConfig(pluginId);
    _log.info('Uninstalled plugin: ${plugin.info.name}');
    notifyListeners();
    return true;
  }

  Future<List<PluginResponse>> processMessage(
    PluginMessage message, {
    String? onlyPluginId,
  }) async {
    final responses = <PluginResponse>[];
    final appId = _storage.activeBotAppId;

    final candidates = _plugins
        .where(
          (p) =>
              p.info.isEnabled &&
              (onlyPluginId == null || p.info.id == onlyPluginId),
        )
        .toList();
    candidates.sort((a, b) {
      final priority = ((a.info.manifest['priority'] as int?) ?? 100).compareTo(
        (b.info.manifest['priority'] as int?) ?? 100,
      );
      return priority != 0
          ? priority
          : _plugins.indexOf(a).compareTo(_plugins.indexOf(b));
    });
    for (final plugin in candidates) {
      // 等待前一个插件期间可能发生停用或卸载，执行前再检查一次。
      if (_disposed ||
          _storage.activeBotAppId != appId ||
          !plugin.info.isEnabled ||
          !_plugins.contains(plugin)) {
        continue;
      }
      if (message.isFullGroupMessage &&
          !message.isMentioned &&
          !plugin.acceptsUnmentioned(message)) {
        continue;
      }
      if (message.eventType == 'interaction' &&
          !message.callbackData.startsWith('qqm:${plugin.info.id}:')) {
        continue;
      }
      if ((_active[plugin.info.id] ?? 0) >= 4) continue;
      final cooldownKey = jsonEncode([
        appId,
        plugin.info.id,
        message.sessionId,
        message.senderId,
      ]);
      final cooldown = plugin.info.manifest['cooldown_ms'] as int? ?? 0;
      final last = _cooldowns[cooldownKey];
      if (cooldown > 0 &&
          last != null &&
          DateTime.now().difference(last).inMilliseconds < cooldown) {
        continue;
      }
      _active[plugin.info.id] = (_active[plugin.info.id] ?? 0) + 1;
      try {
        final result = await runZoned(
          () => plugin.execute(message),
          zoneValues: {_botScope: appId},
        ).timeout(plugin.executionTimeout);
        if (_disposed ||
            _storage.activeBotAppId != appId ||
            !plugin.info.isEnabled ||
            !_plugins.contains(plugin)) {
          continue;
        }
        _errors.remove(plugin.info.id);
        if (result == null) continue;
        if (result.format == 'auto' && result.content.trim().isEmpty) continue;
        if (result.format != 'auto') PluginReply.fromMap(result.toMap());
        if (cooldown > 0) {
          if (_cooldowns.length >= 2048) {
            _cooldowns.remove(_cooldowns.keys.first);
          }
          _cooldowns[cooldownKey] = DateTime.now();
        }

        responses.add(
          PluginResponse(
            pluginId: plugin.info.id,
            pluginName: plugin.info.name,
            content: result.content.trim(),
            reply: result,
          ),
        );
        // One matched plugin owns the response, preserving passive reply quotas.
        break;
      } on TimeoutException {
        _errors[plugin.info.id] = '插件执行超时。';
        _log.warning('Plugin ${plugin.info.name} timed out on message');
      } catch (e) {
        _errors[plugin.info.id] = e is PluginManifestException
            ? e.message
            : e is FormatException
            ? e.message
            : '插件运行异常，请检查配置。';
        _log.warning('插件 ${plugin.info.name}：${_errors[plugin.info.id]}');
      } finally {
        _active[plugin.info.id] = (_active[plugin.info.id] ?? 1) - 1;
      }
    }

    if (!_disposed) notifyListeners();
    return responses;
  }

  Future<String?> processCommand(
    String command,
    List<String> args,
    PluginMessage? context,
  ) async => (await processCommandReply(command, args, context))?.content;

  Future<PluginResponse?> processCommandReply(
    String command,
    List<String> args,
    PluginMessage? context,
  ) async {
    final normalized = command
        .trim()
        .replaceFirst(RegExp(r'^[/#]+'), '')
        .toLowerCase();
    if (normalized.isEmpty) return null;

    final results = await processMessage(
      PluginMessage(
        messageId: context?.messageId ?? '',
        sessionId: context?.sessionId ?? '',
        senderId: context?.senderId ?? '',
        senderName: context?.senderName ?? '操作员',
        content: '/$normalized${args.isEmpty ? '' : ' ${args.join(' ')}'}',
        messageType: context?.messageType ?? 0,
        isGroup: context?.isGroup ?? false,
        timestamp: context?.timestamp ?? DateTime.now(),
        senderRole: context?.senderRole ?? 'operator',
      ),
    );
    return results.firstOrNull;
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

    if (plugin.info.manifest.isNotEmpty) {
      config = PluginManifest.parse(
        jsonEncode(plugin.info.manifest),
        allowBuiltin: true,
      ).validateConfig(config);
    }
    await plugin.updateConfig(config);
    await _storage.savePluginConfig(plugin.info);
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    _disposed = true;
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
  final PluginReply? reply;

  const PluginResponse({
    required this.pluginId,
    required this.pluginName,
    required this.content,
    this.reply,
  });
}
