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
import 'support/server_fixture_api.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

class OfflineBot extends BotClient {
  OfflineBot(super.storage, {super.apiService});
  int connectCalls = 0;
  @override
  Future<bool> connect() async {
    connectCalls++;
    return false;
  }
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
    final groupApi = ServerFixtureApi();
    final bot = OfflineBot(storage, apiService: groupApi);
    service = await ManagerServer.start(
      bot: bot,
      plugins: plugins,
      storage: storage,
      data: temporary,
      assets: Directory.current,
      port: 0,
      autoConnect: true,
    );
    var origin = service.address;
    String? cookie;
    var entrancePath = '';
    String? serviceHost;
    Future<({int code, String text, dynamic data, List<Cookie> cookies})>
    request(
      String route, {
      Map<String, dynamic>? body,
      bool header = true,
      String? foreignOrigin,
      String? host,
      bool root = false,
    }) async {
      final req = await http.openUrl(
        body == null ? 'GET' : 'POST',
        origin.resolve(root ? route : '$entrancePath$route'),
      );
      req.followRedirects = false;
      if (header) req.headers.set('X-QQM-Request', '1');
      if (cookie != null) req.headers.set('Cookie', cookie!);
      if (foreignOrigin != null) req.headers.set('Origin', foreignOrigin);
      if (host ?? serviceHost case final String authority) {
        req.headers.set('Host', authority);
      }
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final response = await req.close();
      if (response.cookies.isNotEmpty) {
        cookie = '${response.cookies.last.name}=${response.cookies.last.value}';
      }
      final text = await utf8.decoder.bind(response).join();
      dynamic data;
      try {
        data = jsonDecode(text);
      } catch (_) {}
      return (
        code: response.statusCode,
        text: text,
        data: data,
        cookies: response.cookies,
      );
    }

    check((await request('/health')).code == 200, '健康检查');
    check(service.needsSetup && bot.connectCalls == 0, '设置密码前不得自动连接机器人');
    check((await request('/')).code == 200, '页面资源');
    for (final path in [
      'setup-token.txt',
      'admin-auth.json',
      'admin-password.txt',
    ]) {
      check((await request('/data/$path')).code == 404, '密码与初始化码不能通过 HTTP 读取');
    }
    check(
      (await request('/api/auth/status')).data['needsSetup'] == true,
      '首次使用显示密码设置页',
    );
    check((await request('/api/state')).code == 401, '接口必须登录');
    check(
      (await request('/api/connect', body: {})).code == 401,
      '未设置密码不能直接使用管理功能',
    );
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
      (await request('/api/login', body: {'password': 'wrong'})).code == 428,
      '未设置密码不能跳过初始化登录',
    );
    final token = (await File(service.setupTokenPath).readAsString()).trim();
    const password = 'offline-test-password-2026';
    check(
      !(await request('/api/auth/status')).text.contains(token),
      '初始化码不能经接口泄露',
    );
    check(
      (await request(
            '/api/setup',
            body: {
              'token': 'wrong',
              'password': password,
              'confirmation': password,
              'entrance': 'offline-private-entrance',
            },
          )).code ==
          400,
      '必须验证本地初始化码',
    );
    check(
      (await request(
            '/api/setup',
            body: {
              'token': token,
              'password': 'short',
              'confirmation': 'short',
              'entrance': 'offline-private-entrance',
            },
          )).code ==
          400,
      '必须设置足够长度的管理密码',
    );
    check(
      (await request(
            '/api/setup',
            body: {
              'token': token,
              'password': password,
              'confirmation': '$password-mismatch',
              'entrance': 'offline-private-entrance',
            },
          )).code ==
          400,
      '两次密码必须一致',
    );
    check(service.needsSetup && bot.connectCalls == 0, '无效初始化不能开放使用或自动连接');
    check(
      (await request(
            '/api/setup',
            body: {
              'token': token,
              'password': password,
              'confirmation': password,
            },
          )).code ==
          400,
      '管理密码和安全入口必须一并设置',
    );
    check(
      (await request(
            '/api/setup',
            body: {
              'token': token,
              'password': password,
              'confirmation': password,
              'entrance': 'offline-private-entrance',
            },
          )).code ==
          200,
      '首次设置管理密码',
    );
    entrancePath = '/offline-private-entrance';
    for (final path in [
      '/',
      '/api/state',
      '/api/login',
      '/app.js',
      '/wrong-entrance/',
      '/wrong-entrance/api/state',
      '$entrancePath%2fapi/state',
      '$entrancePath/api%2fstate',
      '$entrancePath//api/state',
      '$entrancePath/../app.js',
    ]) {
      final response = await request(path, root: true);
      check(response.code == 404, '错误入口和根路径不能访问管理资源：$path');
      check(!response.text.contains(entrancePath), '404 不得泄露入口');
    }
    check((await request('/')).code == 200, '完整安全入口可打开页面');
    check((await request('/style.css')).code == 200, '入口内样式可读取');
    check(
      (await request('/health', root: true)).data.toString() == '{ok: true}',
      '健康检查不泄露配置',
    );
    check(!service.needsSetup && bot.connectCalls == 1, '密码设置后才允许自动连接');
    check(!await File(service.setupTokenPath).exists(), '一次性初始化码设置后移除');
    final authRecord = await File(
      '${temporary.path}/admin-auth.json',
    ).readAsString();
    check(
      !authRecord.contains(password) && !authRecord.contains(token),
      '只保存加盐密码哈希',
    );
    check(
      (await request(
            '/api/setup',
            body: {
              'token': token,
              'password': '$password-replacement',
              'confirmation': '$password-replacement',
              'entrance': 'cannot-replace-entrance',
            },
          )).code ==
          409,
      '初始化接口不能覆盖已设置的密码',
    );
    check((await request('/api/logout', body: {})).code == 200, '初始化后可正常退出登录');
    check(
      (await request('/api/login', body: {'password': 'wrong'})).code == 401,
      '错误密码',
    );
    check(
      (await request('/api/login', body: {'password': password})).code == 200,
      '密码登录',
    );
    final state = await request('/api/state');
    final scope = {'appId': '10000001', 'epoch': state.data['epoch']};
    final groupScope = {...scope, 'group': 'fixture-group'};
    final params = Uri(
      queryParameters: groupScope.map((key, value) => MapEntry(key, '$value')),
    ).query;
    bot.groups.ingest(
      'GROUP_JOIN_REQUEST',
      groupApi.joinRequest('fixture-group'),
      emit: false,
    );
    check(
      (await request('/api/notices?$params')).data['notices'].length == 1,
      '群事件独立保存并可筛选',
    );
    check(
      (await request('/api/group/info?$params')).data['group_member_num'] ==
          123,
      '官方群资料接口',
    );
    check(
      (await request('/api/group/bot-state?$params')).data['member_role'] ==
          'admin',
      '机器人群状态',
    );
    check(
      (await request('/api/group/members?$params')).data['next_cursor'] ==
          'fixture-page-2',
      '群成员分页',
    );
    final id = bot.groups.notices.single.id;
    check(
      (await request(
            '/api/group/approve',
            body: {...groupScope, 'id': id, 'approve': true},
          )).code ==
          200,
      '入群申请可审批',
    );
    check(
      groupApi.approvals.single['requestId'] == 'fixture-request-1' &&
          groupApi.approvals.single['blacklist'] == false,
      '审批回传申请ID且不默认拉黑',
    );
    check(
      (await request(
            '/api/group/approve',
            body: {...groupScope, 'id': id, 'approve': false},
          )).code ==
          400,
      '已审核不可重复审批',
    );
    check(
      (await request(
            '/api/group/mute',
            body: {
              ...groupScope,
              'member': 'member-a',
              'operation': 'add',
              'expiresAt': DateTime.now()
                  .add(const Duration(minutes: 10))
                  .toUtc()
                  .toIso8601String(),
            },
          )).code ==
          200,
      '成员禁言设置',
    );
    check(
      (await request('/api/group/mute?$params')).data['members'].length == 1,
      '群禁言状态查询',
    );
    check(
      (await request(
            '/api/group/mute',
            body: {...groupScope, 'member': 'member-a', 'operation': 'del'},
          )).code ==
          200,
      '成员解除禁言',
    );
    check(
      (await request(
            '/api/group/moderatable-member?$params&member=member-a',
          )).code ==
          200,
      '成员管理使用官方角色校验',
    );
    check(
      (await request(
                '/api/group/remove',
                body: {...groupScope, 'member': 'member-a'},
              )).code ==
              400 &&
          groupApi.removedMembers.isEmpty,
      '没有明确确认不能移除成员',
    );
    check(
      (await request(
                '/api/group/remove',
                body: {...groupScope, 'member': 'member-b', 'confirmed': true},
              )).code ==
              400 &&
          groupApi.removedMembers.isEmpty,
      '不能移除群主',
    );
    check(
      (await request(
                '/api/group/remove',
                body: {...groupScope, 'member': 'member-a', 'confirmed': true},
              )).code ==
              200 &&
          groupApi.removedMembers.single == 'member-a',
      '确认后仅移除选定成员',
    );
    check(
      (await request(
                '/api/group/remove',
                body: {
                  ...groupScope,
                  'epoch': -1,
                  'member': 'member-a',
                  'confirmed': true,
                },
              )).code ==
              400 &&
          groupApi.removedMembers.length == 1,
      '旧机器人世代不能移除成员',
    );
    check(
      (await request(
            '/api/session/mute',
            body: {...scope, 'session': 'fixture-group', 'muted': true},
          )).code ==
          200,
      '会话屏蔽消息提醒',
    );
    check(
      (await request('/api/group/info?$params&epoch=-1')).code == 400,
      '旧凭据世代不可读取群管理接口',
    );
    check(
      (await request(
            '/api/group/mute',
            body: {
              ...groupScope,
              'appId': 'another-app',
              'member': 'member-a',
              'operation': 'del',
            },
          )).code ==
          400,
      '跨机器人管理操作拒绝',
    );
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

    // Upgrade an existing password-only installation. An unauthenticated
    // visitor cannot choose its entrance, and HTTPS reverse-proxy cookies stay
    // both Secure and scoped after the authenticated migration.
    await service.close();
    service = null;
    final authFile = File('${temporary.path}/admin-auth.json');
    final oldRecord =
        jsonDecode(await authFile.readAsString()) as Map<String, dynamic>;
    oldRecord['version'] = 1;
    oldRecord.remove('entrance');
    await authFile.writeAsString(jsonEncode(oldRecord));
    final upgradedPlugins = PluginManager(storage);
    await upgradedPlugins.init();
    final upgradedBot = OfflineBot(storage, apiService: ServerFixtureApi());
    service = await ManagerServer.start(
      bot: upgradedBot,
      plugins: upgradedPlugins,
      storage: storage,
      data: temporary,
      assets: Directory.current,
      host: '0.0.0.0',
      port: 0,
      publicUrl: 'https://bot.example.invalid',
      autoConnect: true,
    );
    origin = service.address.replace(host: '127.0.0.1');
    serviceHost = 'bot.example.invalid';
    entrancePath = '';
    cookie = null;
    check(service.needsEntrance && !service.needsSetup, '旧密码安装只需补设入口，不能重新初始化');
    check(upgradedBot.connectCalls == 0, '补设入口前不自动连接');
    check((await request('/api/state')).code == 401, '迁移前仍须登录');
    check(
      (await request(
            '/api/auth/entrance',
            body: {'entrance': 'attacker-entrance'},
          )).code ==
          401,
      '陌生人不能抢占旧安装入口',
    );
    check((await request('/api/setup', body: {})).code == 409, '升级不会重新开放初始化');
    check(
      (await request(
            '/api/login',
            body: {'password': password},
            foreignOrigin: 'https://attacker.invalid',
          )).code ==
          403,
      '反代模式拒绝跨站登录',
    );
    final login = await request(
      '/api/login',
      body: {'password': password},
      foreignOrigin: 'https://bot.example.invalid',
    );
    check(
      login.code == 200 && login.data['needsEntrance'] == true,
      '使用原密码登录后补入口',
    );
    check((await request('/api/state')).code == 428, '未补入口不能使用管理 API');
    check(
      (await request(
            '/api/auth/entrance',
            body: {'entrance': '../bad'},
          )).code ==
          400,
      '不能通过迁移写入非法入口',
    );
    final upgraded = await request(
      '/api/auth/entrance',
      body: {'entrance': 'upgraded-safe-entrance'},
    );
    check(upgraded.code == 200, '已认证的旧管理员补设入口');
    final scopedCookie = upgraded.cookies.last;
    check(
      scopedCookie.path == '/upgraded-safe-entrance/' &&
          scopedCookie.secure &&
          scopedCookie.httpOnly,
      '反代会话 Cookie 保留 Secure/HttpOnly 和入口作用域',
    );
    check(upgradedBot.connectCalls == 1, '入口设置完成才自动连接');
    check((await request('/')).code == 404, '迁移后根地址关闭');
    entrancePath = '/upgraded-safe-entrance';
    check((await request('/api/state')).code == 200, '迁移后完整入口可继续访问原数据');
    final updatedRecord = jsonDecode(await authFile.readAsString()) as Map;
    check(updatedRecord['hash'] == oldRecord['hash'], '升级保留原密码哈希');
    stdout.writeln(
      'PASS: Linux 网页密码＋安全入口、旧密码迁移、反代 Secure Cookie、自动连接门禁、CSRF/越界防护、多机器人隔离、聊天恢复、七插件和文件编辑。',
    );
  } finally {
    await service?.close();
    http.close(force: true);
    await Hive.close();
    check(temporary.path.contains('qqm-server-smoke-'), '清理范围校验失败');
    await temporary.delete(recursive: true);
  }
}
