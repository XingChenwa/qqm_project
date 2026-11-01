import 'dart:async';
import '../../models/plugin.dart';
import '../../services/node_plugin_service.dart';
import 'bridge_plugin.dart';

class NodePlugin extends BridgePlugin {
  final NodePluginService service;
  NodePlugin(super.info, super.definition, this.service);
  @override
  Duration get executionTimeout => const Duration(seconds: 45);
  @override
  Duration get bridgeTimeout => const Duration(seconds: 40);
  @override
  String get bridgeUrl => service.endpoint;
  @override
  String get bridgeToken => service.token;
  @override
  Map<String, dynamic> get bridgeParameters => {'package_id': info.id};
  @override
  Map<String, dynamic> get bridgeConfig => {
    'owner_openids': info.config['owner_openids'] ?? '',
    'allow_proactive': info.config['allow_proactive'] == true,
  };
  @override
  Future<void> validateBridge() async {
    definition.validateConfig(info.config, requireValues: true);
    await service.loadSettings();
  }

  @override
  Future<Map<String, dynamic>> requestService(
    String route,
    String appId, [
    Map<String, dynamic> data = const {},
  ]) async {
    if (route == 'deactivate' && (service.paused || service.endpoint.isEmpty)) {
      return {'ok': true};
    }
    await service.ensureStarted().timeout(const Duration(seconds: 35));
    return super.requestService(route, appId, data);
  }

  @override
  String bridgeFailure(Map<String, dynamic> response) {
    final error = response['error'];
    return error is String && error.length < 300
        ? error
        : '原版插件启动失败，请检查依赖、原生配置文件和运行环境。';
  }

  @override
  String bridgeStatus(Map<String, dynamic> response) {
    final value = response['diagnostic'];
    return value is String && value.length < 300 ? value : '';
  }

  @override
  Future<void> onTick() => service.paused ? Future.value() : super.onTick();
  @override
  bool acceptsUnmentioned(PluginMessage message) =>
      info.permissions.contains('events:group-all');
  @override
  List<PluginCommand> get commands => const [];
  @override
  Future<PluginReply?> execute(PluginMessage message) async {
    if (!bridgeRunning ||
        service.paused ||
        message.eventType != 'message' ||
        message.messageId.isEmpty) {
      return null;
    }
    final appId = host?.appId ?? '';
    if (appId.isEmpty) return null;
    try {
      final response = await requestService('message', appId, {
        'job_id': message.messageId,
        'message': message.toMap(),
      });
      if (!bridgeRunning || host?.currentAppId() != appId) return null;
      if (response['ok'] == true && response['matched'] == true) {
        return const PluginReply('', format: 'deferred');
      }
    } catch (error) {
      reportServiceError(
        error is FormatException
            ? error.message.toString()
            : '原版插件尚未就绪，请查看插件运行环境与配置。',
      );
    }
    return null;
  }
}
