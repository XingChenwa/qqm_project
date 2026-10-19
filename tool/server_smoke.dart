// Standalone Dart integration test. Never contacts QQ or sends real messages.
import 'dart:convert';
import 'dart:io';
import 'package:hive/hive.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/runtime/assets_server.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import '../server/src/manager_server.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> main() async {
  final temporary = await Directory.systemTemp.createTemp('qqm-server-smoke-');
  final http = HttpClient();
  ManagerServer? service;
  try {
    Hive.init(temporary.path);
    rootBundle.root = Directory.current;
    final storage = StorageService();
    await storage.init();
    await storage.saveBotConfig(
      BotConfig(
        appId: '10000001',
        clientSecret: 'fixture-secret-never-returned',
        accessToken: 'fixture-token-never-returned',
      ),
    );
    storage.selectChatAccount('10000001');
    await storage.saveSession(
      ChatSession(
        id: 'fixture-group',
        name: '离线测试群',
        sessionType: 1,
        avatarUrl: 'https://example.invalid/group.png',
        lastMessageTime: DateTime.now(),
      ),
    );
    await storage.saveMessage(
      MessageModel(
        id: 'fixture-message',
        sessionId: 'fixture-group',
        senderId: 'fixture-user',
        senderName: '测试成员',
        content: '<script>not-executed</script>',
        messageType: 0,
        timestamp: DateTime.now(),
      ),
    );
    final plugins = PluginManager(storage);
    await plugins.init();
    check(
      plugins.plugins.length == 7 && plugins.enabledCount == 0,
      '七个插件应默认关闭',
    );
    final bot = BotClient(storage);
    service = await ManagerServer.start(
      bot: bot,
      plugins: plugins,
      storage: storage,
      data: temporary,
      assets: Directory.current,
      port: 0,
    );
    final origin = service.address;
    String? cookie;
    Future<({int code, String text, dynamic data})> request(
      String route, {
      Map<String, dynamic>? body,
      bool header = true,
      String? foreignOrigin,
      String? host,
    }) async {
      final req = await http.openUrl(
        body == null ? 'GET' : 'POST',
        origin.resolve(route),
      );
      if (header) req.headers.set('X-QQM-Request', '1');
      if (cookie != null) req.headers.set('Cookie', cookie!);
      if (foreignOrigin != null) req.headers.set('Origin', foreignOrigin);
      if (host != null) req.headers.set('Host', host);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      if (response.cookies.isNotEmpty) {
        cookie =
            '${response.cookies.first.name}=${response.cookies.first.value}';
      }
      final text = await utf8.decoder.bind(response).join();
      dynamic data;
      try {
        data = jsonDecode(text);
      } catch (_) {}
      return (code: response.statusCode, text: text, data: data);
    }

    check((await request('/health')).code == 200, '健康检查');
    check((await request('/')).code == 200, '页面资源');
    check(
      (await request('/data/admin-password.txt')).code == 404,
      '密码不能通过 HTTP 读取',
    );
    check((await request('/api/state')).code == 401, '接口必须登录');
    check(
      (await request(
            '/api/login',
            body: {'password': 'wrong'},
            header: false,
          )).code ==
          403,
      '缺少自定义请求头',
    );
    check(
      (await request(
            '/api/login',
            body: {'password': 'wrong'},
            foreignOrigin: 'https://evil.invalid',
          )).code ==
          403,
      '跨站请求应拒绝',
    );
    check(
      (await request('/api/state', host: 'evil.invalid')).code == 403,
      '本地服务拒绝 DNS 重绑定',
    );
    check(
      (await request('/api/login', body: {'password': 'wrong'})).code == 401,
      '错误密码',
    );
    final password = (await File(
      '${temporary.path}/admin-password.txt',
    ).readAsString()).trim();
    check(
      (await request('/api/login', body: {'password': password})).code == 200,
      '密码登录',
    );
    final state = await request('/api/state');
    check(
      state.data['sessions'].length == 1 &&
          state.data['sessions'][0]['avatarUrl'] == '',
      '重启恢复会话但不使用群头像',
    );
    check(
      !state.text.contains('fixture-secret') &&
          !state.text.contains('fixture-token'),
      '凭据不能返回网页',
    );
    check(
      (await request(
            '/api/messages?appId=10000001&session=fixture-group',
          )).data['messages'].length ==
          1,
      '读取当前机器人聊天',
    );
    check(
      (await request(
            '/api/messages?appId=10000002&session=fixture-group',
          )).code ==
          400,
      '跨机器人读取应拒绝',
    );
    check(
      (await request(
            '/api/send',
            body: {
              'appId': '10000002',
              'session': 'fixture-group',
              'content': 'not sent',
              'format': 'text',
            },
          )).code ==
          400,
      '跨机器人发送应拒绝',
    );
    check(
      (await request(
            '/api/workspace/read?id=example_plugin&file=../admin-password.txt',
          )).code ==
          400,
      '阻止文件越界读取',
    );
    check(
      (await request(
            '/api/workspace/seed',
            body: {'id': 'example_plugin'},
          )).code ==
          200,
      '导出插件为工作区文件',
    );
    final tree = await request('/api/workspace?id=example_plugin');
    check((tree.data['files'] as List).contains('main.ht'), '脚本应可编辑');
    final source = (await request(
      '/api/workspace/read?id=example_plugin&file=main.ht',
    )).data['source'];
    check(
      (await request(
            '/api/workspace/write',
            body: {
              'id': 'example_plugin',
              'file': 'main.ht',
              'source': source,
              'expected': 'stale edit',
            },
          )).code ==
          400,
      '旧草稿不得覆盖其他编辑器',
    );
    check(
      (await request(
            '/api/workspace/install',
            body: {'id': 'example_plugin', 'replace': true},
          )).code ==
          200,
      '插件安装应使用同一加载器',
    );
    check(plugins.enabledCount == 0, '安装后不得擅自启用');
    check(
      (await request(
            '/api/config',
            body: {
              'appId': '10000002',
              'clientSecret': 'another-fixture-secret',
            },
          )).code ==
          200,
      '保存第二个机器人',
    );
    check(
      (await request('/api/state')).data['sessions'].isEmpty,
      '切换后不能复用旧群 OpenID',
    );
    check(
      (await request('/api/switch', body: {'appId': '10000001'})).code == 200,
      '切回机器人',
    );
    check(
      (await request('/api/state')).data['sessions'].length == 1,
      '切回后恢复原会话',
    );
    check((await request('/api/logout', body: {})).code == 200, '退出登录');
    check((await request('/api/state')).code == 401, '退出后接口失效');
    stdout.writeln('PASS: Linux 网页服务、登录/CSRF/越界防护、多机器人隔离、聊天恢复、七插件和文件编辑。');
  } finally {
    await service?.close();
    http.close(force: true);
    await Hive.close();
    check(temporary.path.contains('qqm-server-smoke-'), '清理范围校验失败');
    await temporary.delete(recursive: true);
  }
}
