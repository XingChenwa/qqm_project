import 'dart:convert';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/package_bundle.dart';

/// Called only AFTER the existing entrance, session and same-origin checks.
/// Independent mutation queue: a model request never blocks official bot APIs.
class AgentApi {
  final AgentController controller;
  Future<void> _mutations = Future.value();
  AgentApi(this.controller);
  Future<dynamic> get(String route, Map<String, String> query) async {
    await controller.initialize();
    if (route == '/api/agent/state') return controller.snapshot();
    if (route == '/api/agent/extension/file' ||
        route == '/api/agent/extension/export') {
      final e = controller.extensions
          .where((e) => e.id == query['id'])
          .firstOrNull;
      if (e == null || !e.isJavaScript) {
        throw const AgentException('JavaScript 包不存在。');
      }
      if (route.endsWith('/export')) {
        return {
          'data': base64Encode(AgentPackageBundle.encode(e.manifest, e.config)),
          'filename': '${e.id}.zip',
        };
      }
      final name = query['file'];
      final data = object(e.manifest['files'])[name];
      if (data is! String || data.length > 350000) {
        throw const AgentException('文件不存在或超过文本编辑上限。');
      }
      try {
        return {'source': utf8.decode(base64Decode(data))};
      } catch (_) {
        throw const AgentException('这是二进制文件，不能用文本编辑器打开。');
      }
    }
    if (route == '/api/agent/messages') {
      final key = query['session'] ?? '';
      if (controller.session(key) == null) {
        throw const AgentException('Agent 会话不存在。');
      }
      return {
        'messages': controller.store
            .messages(key)
            .map((m) => m.toJson())
            .toList(),
      };
    }
    throw const AgentException('未知 Agent 接口。');
  }

  Future<dynamic> post(String route, Json body) async {
    await controller.initialize();
    final id = text(body['id']), key = text(body['session']);
    // Long-running work can be stopped or configured through other requests.
    if (route == '/api/agent/send') {
      await controller.send(key, text(body['text']));
      return {'ok': true};
    }
    if (route == '/api/agent/provider/test' ||
        route == '/api/agent/provider/models') {
      final old = controller.providers
          .where(
            (p) =>
                p.id ==
                (text(object(body['value'])['id']).isEmpty
                    ? id
                    : text(object(body['value'])['id'])),
          )
          .firstOrNull;
      final draft = object(body['value']);
      final value = draft.isEmpty
          ? old
          : AgentProvider.fromJson({
              ...draft,
              if (text(draft['apiKey']).isEmpty && draft['clearKey'] != true)
                'apiKey': old?.apiKey ?? '',
            });
      if (value == null) throw const AgentException('请先保存模型配置。');
      return {
        'result': route.endsWith('/test')
            ? await controller.testModel(value)
            : await controller.listModels(value),
      };
    }
    if (route == '/api/agent/contacts') {
      await controller.syncContacts(id);
      return {'ok': true};
    }
    final result = _mutations.then((_) => _mutate(route, body));
    _mutations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<Json> _mutate(String route, Json body) async {
    final id = text(body['id']), key = text(body['session']);
    switch (route) {
      case '/api/agent/connection/save':
        final value = object(body['value']);
        final old = controller.connection(text(value['id']));
        if (text(value['token']).isEmpty && value['clearToken'] != true) {
          value['token'] = old?.token ?? '';
        }
        if (text(value['clientSecret']).isEmpty &&
            value['clearClientSecret'] != true) {
          value['clientSecret'] = old?.clientSecret ?? '';
        }
        await controller.saveConnection(AgentConnection.fromJson(value));
      case '/api/agent/connect':
        await controller.connect(id);
      case '/api/agent/disconnect':
        await controller.disconnect(id);
      case '/api/agent/connection/delete':
        await controller.deleteConnection(id);
      case '/api/agent/provider/save':
        final value = object(body['value']);
        final old = controller.providers
            .where((p) => p.id == text(value['id']))
            .firstOrNull;
        if (text(value['apiKey']).isEmpty && value['clearKey'] != true) {
          value['apiKey'] = old?.apiKey ?? '';
        }
        await controller.saveProvider(AgentProvider.fromJson(value));
      case '/api/agent/provider/delete':
        await controller.deleteProvider(id);
      case '/api/agent/preset/save':
        await controller.savePreset(
          AgentPreset.fromJson(object(body['value'])),
        );
      case '/api/agent/preset/delete':
        await controller.deletePreset(id);
      case '/api/agent/extension/import':
        if (text(body['filename']).toLowerCase().endsWith('.zip')) {
          final raw = text(body['data']);
          if (raw.length > 23 * 1024 * 1024) {
            throw const AgentException('ZIP 安装包过大。');
          }
          await controller.importPackage(base64Decode(raw));
        } else {
          await controller.importExtension(
            text(body['source']),
            filename: text(body['filename']),
          );
        }
      case '/api/agent/extension/configure':
        final old = controller.extensions.where((e) => e.id == id).firstOrNull;
        if (old == null || !old.isJavaScript) {
          throw const AgentException('扩展不存在。');
        }
        await controller.saveExtension(
          old.copyWith(
            settings: body['settings'] is Map
                ? object(body['settings'])
                : old.settings,
            enabled: body['enabled'] == true,
          ),
        );
      case '/api/agent/extension/file/save':
        final old = controller.extensions.where((e) => e.id == id).firstOrNull;
        final name = text(body['file']);
        if (old == null ||
            !old.isJavaScript ||
            !object(old.manifest['files']).containsKey(name) ||
            name == old.manifest['manifestFile']) {
          throw const AgentException('文件不存在或为只读清单。');
        }
        final source = text(body['source']);
        if (source.length > 262144) throw const AgentException('文本文件超过编辑上限。');
        await controller.saveExtension(
          old.copyWith(
            manifest: {
              ...old.manifest,
              'files': {
                ...object(old.manifest['files']),
                name: base64Encode(utf8.encode(source)),
              },
            },
          ),
        );
      case '/api/agent/extension/save':
        final parsed = AgentExtension.parse(text(body['source']));
        final old = controller.extensions
            .where((e) => e.id == parsed.id)
            .firstOrNull;
        await controller.saveExtension(
          AgentExtension(
            parsed.manifest,
            enabled: body['enabled'] == true,
            secrets: body['secrets'] is Map
                ? object(body['secrets']).map((k, v) => MapEntry(k, text(v)))
                : old?.secrets ?? {},
            settings: old?.settings ?? {},
          ),
        );
      case '/api/agent/extension/delete':
        await controller.deleteExtension(id);
      case '/api/agent/session/open':
        final s = await controller.openSession(
          id,
          text(body['kind']),
          text(body['peerId']),
          name: text(body['name']),
        );
        return {'session': s.toJson()};
      case '/api/agent/session/save':
        await controller.configureSession(
          AgentSession.fromJson(object(body['value'])),
        );
      case '/api/agent/session/read':
        await controller.markRead(key);
      case '/api/agent/session/context':
        await controller.clearContext(key);
      case '/api/agent/session/clear':
        await controller.clearHistory(key);
      case '/api/agent/session/reply':
        await controller.regenerate(key);
      case '/api/agent/session/stop':
        controller.stopReply(key);
      case '/api/agent/session/profile':
        await controller.refreshOfficialProfile(key);
      case '/api/agent/session/dismiss-status':
        controller.dismissReplyState(key);
      default:
        throw const AgentException('未知 Agent 操作。');
    }
    return {'ok': true};
  }
}
