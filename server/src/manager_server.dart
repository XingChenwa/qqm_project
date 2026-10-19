import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/plugin_dispatcher.dart';
import 'package:qq_bot_manager/core/plugin_manager.dart';
import 'package:qq_bot_manager/models/config.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/plugin_manifest.dart';
import 'package:qq_bot_manager/models/received_message.dart';
import 'package:qq_bot_manager/services/ip_whitelist_service.dart';
import 'package:qq_bot_manager/services/plugin_workspace.dart';
import 'package:qq_bot_manager/services/storage_service.dart';
import 'package:qq_bot_manager/utils/constants.dart';
import 'package:qq_bot_manager/core/group_management.dart';
import 'package:qq_bot_manager/models/group_notice.dart';
import 'admin_auth.dart';

/// Authenticated same-origin control plane. No generic filesystem, proxy,
/// subprocess or command-execution route is exposed to the browser.
class ManagerServer {
  final BotClient bot;
  final PluginManager plugins;
  final StorageService storage;
  final Directory assets;
  final PluginWorkspace workspace;
  final String publicUrl;
  final AdminAuth _auth;
  final bool _autoConnect;
  final _sessions = <String, DateTime>{};
  final _failures = <String, ({int count, DateTime since})>{};
  final _logs = <Map<String, dynamic>>[];
  final _ip = PublicIpService();
  late final HttpServer _server;
  int _revision = 0, _logId = 0, _activeRequests = 0;
  bool _closed = false, _authBusy = false;
  Timer? _tick;
  Future<void> _mutations = Future<void>.value();

  ManagerServer._(
    this.bot,
    this.plugins,
    this.storage,
    this.assets,
    Directory data,
    this.publicUrl,
    this._auth,
    this._autoConnect,
  ) : workspace = PluginWorkspace(
        Directory(p.join(data.path, 'plugin_workspace')),
      );

  static Future<ManagerServer> start({
    required BotClient bot,
    required PluginManager plugins,
    required StorageService storage,
    required Directory data,
    required Directory assets,
    String host = '127.0.0.1',
    int port = 23336,
    String publicUrl = '',
    bool autoConnect = false,
  }) async {
    if (publicUrl.isNotEmpty) {
      final uri = Uri.tryParse(publicUrl);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.query.isNotEmpty ||
          uri.fragment.isNotEmpty ||
          (uri.path.isNotEmpty && uri.path != '/')) {
        throw const FormatException('public-url 必须为 HTTPS 网站源地址（不含路径）');
      }
      publicUrl = uri.origin;
    }
    final auth = await AdminAuth.open(data);
    final result = ManagerServer._(
      bot,
      plugins,
      storage,
      assets,
      data,
      publicUrl,
      auth,
      autoConnect,
    );
    await result.workspace.ensureRoot();
    result._server = await HttpServer.bind(host, port);
    result._server.autoCompress = true;
    bot.refresh();
    bot.addListener(result._changed);
    plugins.addListener(result._changed);
    bot.onLog = result._addLog;
    bot.onMessageReceived = PluginDispatcher(bot, plugins).process;
    result._server.listen((request) => unawaited(result._handle(request)));
    var ticking = false;
    result._tick = Timer.periodic(const Duration(minutes: 1), (_) async {
      if (ticking || result._closed || !result._auth.isConfigured) return;
      ticking = true;
      try {
        await plugins.tick();
      } finally {
        ticking = false;
      }
    });
    result._maybeAutoConnect();
    return result;
  }

  static String _randomToken() => base64Url
      .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Uri get address =>
      Uri(scheme: 'http', host: _server.address.address, port: _server.port);
  bool get needsSetup => !_auth.isConfigured;
  String get setupTokenPath => _auth.setupTokenPath;
  void _maybeAutoConnect() {
    if (!_closed &&
        _auth.isConfigured &&
        _autoConnect &&
        bot.config.appId.isNotEmpty &&
        bot.config.clientSecret.isNotEmpty) {
      unawaited(bot.connect());
    }
  }

  void _changed() => _revision++;
  String _redact(String value) {
    for (final config in bot.botProfiles) {
      for (final secret in [config.clientSecret, config.accessToken]) {
        if (secret.isNotEmpty) value = value.replaceAll(secret, '[已隐藏]');
      }
    }
    return value.replaceAll(RegExp(r'auth_token=[^\s&,]+'), 'auth_token=[已隐藏]');
  }

  void _addLog(String line) {
    _logs.add({
      'id': ++_logId,
      'text': _redact(line),
      'time': DateTime.now().toIso8601String(),
    });
    if (_logs.length > 2000) _logs.removeAt(0);
    _changed();
  }

  void _json(HttpRequest request, dynamic value, [int code = 200]) {
    request.response.statusCode = code;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(value));
  }

  Future<Map<String, dynamic>> _body(HttpRequest request) async {
    final chunks = <int>[];
    await for (final chunk in request.timeout(const Duration(seconds: 15))) {
      if (chunks.length + chunk.length > 1048576) {
        throw const FormatException('请求超过 1 MB');
      }
      chunks.addAll(chunk);
    }
    final value = jsonDecode(utf8.decode(chunks));
    if (value is! Map<String, dynamic>) {
      throw const FormatException('请求应为 JSON 对象');
    }
    return value;
  }

  String _str(Map<String, dynamic> body, String key, [int max = 65536]) {
    final value = body[key];
    if (value == null) return '';
    if (value is! String || value.length > max) {
      throw FormatException('$key 格式无效');
    }
    return value;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  String? _session(HttpRequest request) {
    _sessions.removeWhere((_, expires) => expires.isBefore(DateTime.now()));
    for (final cookie in request.cookies) {
      if (cookie.name == 'qqm_session' && _sessions.containsKey(cookie.value)) {
        return cookie.value;
      }
    }
    return null;
  }

  void _grantSession(HttpRequest request) {
    if (_sessions.length >= 32) _sessions.remove(_sessions.keys.first);
    final token = _randomToken();
    _sessions[token] = DateTime.now().add(const Duration(hours: 12));
    request.response.cookies.add(
      Cookie('qqm_session', token)
        ..httpOnly = true
        ..secure = publicUrl.isNotEmpty
        ..sameSite = SameSite.strict
        ..path = '/'
        ..maxAge = 43200,
    );
  }

  Future<void> _authenticate(HttpRequest request, {required bool setup}) async {
    if (setup && _auth.isConfigured) {
      _json(request, {'error': '管理密码已经设置，请直接登录'}, 409);
      return;
    }
    if (!setup && !_auth.isConfigured) {
      _json(request, {'error': '首次使用必须先设置管理密码', 'needsSetup': true}, 428);
      return;
    }
    final peer = request.connectionInfo?.remoteAddress.address ?? 'unknown';
    _failures.removeWhere(
      (_, value) => DateTime.now().difference(value.since).inMinutes >= 5,
    );
    final failure = _failures[peer];
    if ((failure != null && failure.count >= 10) || _failures.length >= 1024) {
      _json(request, {'error': '尝试次数过多，请 5 分钟后重试'}, 429);
      return;
    }
    // Reserve an attempt before any asynchronous work. Only one expensive KDF
    // runs at a time; parallel first-install requests cannot replace a password.
    _failures[peer] = (
      count: (failure?.count ?? 0) + 1,
      since: failure?.since ?? DateTime.now(),
    );
    final body = await _body(request);
    final password = _str(body, 'password', 256);
    if (setup) {
      await _auth.configure(
        token: _str(body, 'token', 256),
        password: password,
        confirmation: _str(body, 'confirmation', 256),
      );
      _maybeAutoConnect();
      _changed();
    } else if (!await _auth.verifyPassword(password)) {
      _json(request, {'error': '管理密码不正确'}, 401);
      return;
    }
    _failures.remove(peer);
    _grantSession(request);
    _json(request, {'ok': true});
  }

  bool _sameOrigin(HttpRequest request) {
    final origin = request.headers.value('Origin');
    final host = request.headers.value('Host');
    // Defend DNS rebinding; HttpServer's address is only implicit on wildcard.
    final uri = Uri.tryParse('http://${host ?? ''}');
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return false;
    }
    if (publicUrl.isNotEmpty) {
      if (uri.authority != Uri.parse(publicUrl).authority) return false;
      return origin == null || origin == publicUrl;
    }
    if (_server.address.isLoopback &&
        !{'localhost', '127.0.0.1', '::1'}.contains(uri.host)) {
      return false;
    }
    return origin == null || origin == 'http://$host';
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    _activeRequests++;
    try {
      response.headers
        ..set('Cache-Control', 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Referrer-Policy', 'no-referrer')
        ..set('X-Frame-Options', 'DENY')
        ..set(
          'Content-Security-Policy',
          "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' https: data:; connect-src 'self'; frame-src https:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
        );
      if (_closed || _activeRequests > 64) {
        _json(request, {'error': '服务繁忙，请稍后重试'}, 503);
        return;
      }
      if (!_sameOrigin(request)) {
        _json(request, {'error': '来源不被允许'}, 403);
        return;
      }
      final route = request.uri.path;
      if (route == '/health' && request.method == 'GET') {
        _json(request, {
          'ok': true,
          'version': AppConstants.appVersion,
          'build': AppConstants.appBuild,
        });
        return;
      }
      if (!route.startsWith('/api/')) {
        if (request.method != 'GET' && request.method != 'HEAD') {
          response.statusCode = 405;
          return;
        }
        const files = {
          '/': ('server/web/index.html', 'text/html; charset=utf-8'),
          '/app.js': ('server/web/app.js', 'text/javascript; charset=utf-8'),
          '/group-management.js': (
            'server/web/group-management.js',
            'text/javascript; charset=utf-8',
          ),
          '/style.css': ('server/web/style.css', 'text/css; charset=utf-8'),
          '/logo.png': ('assets/branding/logo.png', 'image/png'),
        };
        final asset = files[route];
        if (asset == null) {
          response.statusCode = 404;
          return;
        }
        response.headers.set('Content-Type', asset.$2);
        final file = File(p.join(assets.path, asset.$1));
        if (!await file.exists()) {
          response.statusCode = 404;
          return;
        }
        if (request.method == 'GET') await response.addStream(file.openRead());
        return;
      }
      // Custom header plus strict Origin means cross-site forms/fetch cannot
      // mutate this service, even on plain localhost HTTP. No CORS is enabled.
      if (request.headers.value('X-QQM-Request') != '1') {
        _json(request, {'error': '请从管理界面访问'}, 403);
        return;
      }
      if (route == '/api/auth/status' && request.method == 'GET') {
        _json(request, {'needsSetup': needsSetup});
        return;
      }
      if ((route == '/api/login' || route == '/api/setup') &&
          request.method == 'POST') {
        if (_authBusy) {
          _json(request, {'error': '正在验证管理密码，请稍后重试'}, 429);
          return;
        }
        _authBusy = true;
        try {
          await _serial(
            () => _authenticate(request, setup: route == '/api/setup'),
          );
        } finally {
          _authBusy = false;
        }
        return;
      }
      if (needsSetup) {
        _json(request, {'error': '首次使用必须先设置管理密码', 'needsSetup': true}, 401);
        return;
      }
      final session = _session(request);
      if (session == null) {
        _json(request, {'error': '请先登录管理器'}, 401);
        return;
      }
      if (request.method == 'GET') {
        await _get(request);
        return;
      }
      if (request.method != 'POST') {
        response.statusCode = 405;
        return;
      }
      final body = await _body(request);
      if (route == '/api/logout') {
        _sessions.remove(session);
        response.cookies.add(
          Cookie('qqm_session', '')
            ..path = '/'
            ..maxAge = 0
            ..httpOnly = true,
        );
        _json(request, {'ok': true});
        return;
      }
      await _serial(() => _post(request, body));
    } catch (error) {
      if (error is FormatException ||
          error is PluginManifestException ||
          error is GroupApiException ||
          error is StateError) {
        final message = error is PluginManifestException
            ? error.message
            : error is FormatException
            ? error.message
            : error is GroupApiException
            ? error.message
            : error.toString();
        _json(request, {'error': _redact(message)}, 400);
      } else {
        _json(request, {'error': '操作未完成，请检查服务状态、目录权限或请求格式'}, 500);
      }
    } finally {
      _activeRequests--;
      await response.close();
    }
  }

  Map<String, dynamic> _config(BotConfig config) => {
    'appId': config.appId,
    'hasSecret': config.clientSecret.isNotEmpty,
    'autoReconnect': config.autoReconnect,
    'receiveAllGroupMessages': config.receiveAllGroupMessages,
    'autoReplyToAllGroupMessages': config.autoReplyToAllGroupMessages,
    'enableOiapiNickname': config.enableOiapiNickname,
    'useSandbox': config.useSandbox,
    'reconnectInterval': config.reconnectInterval,
  };
  void _checkAccount(String value) {
    if (value != bot.config.appId) throw StateError('机器人已切换，请刷新后重试');
  }

  void _checkEpoch(Map<String, dynamic> values) {
    _checkAccount(_str(values, 'appId', 64));
    if (int.tryParse('${values['epoch']}') != bot.accountEpoch) {
      throw StateError('机器人凭据已切换，请刷新后重试');
    }
  }

  GroupTarget _groupTarget(Map<String, dynamic> values) {
    _checkEpoch(values);
    final group = _str(values, 'group', 512);
    if (group.isEmpty) throw const FormatException('缺少群 OpenID');
    return GroupTarget(bot.config.appId, group, bot.accountEpoch);
  }

  Map<String, dynamic> _received(ReceivedMessageBody body) => {
    'text': body.displayText,
    'author': body.authorName,
    'attachments': [
      for (final a in body.attachments)
        {'url': a.openUrl, 'filename': a.displayName, 'isImage': a.isImage},
    ],
    if (body.card != null)
      'card': {
        'title': body.card!.title,
        'description': body.card!.description,
        'url': body.card!.jumpUrl,
        'preview': body.card!.previewUrl,
      },
    'elements': body.elements.map(_received).toList(),
  };
  Map<String, dynamic> _message(MessageModel message) => {
    'id': message.id,
    'senderId': message.senderId,
    'senderName': message.senderName,
    'senderAvatarUrl': message.senderAvatarUrl,
    'isFromBot': message.isFromBot,
    'content': message.content,
    'markdownContent': message.markdownContent,
    'isRecalled': message.isRecalled,
    'canRecall': bot.canRecallMessage(message),
    'time': message.timestamp.toIso8601String(),
    'imageUrl': message.imageUrl,
    if (message.hasReceivedPayload) 'body': _received(message.receivedBody),
  };
  Future<void> _get(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final route = request.uri.path;
    if (route.startsWith('/api/group/')) {
      final target = _groupTarget(query);
      final data = switch (route) {
        '/api/group/info' => await bot.groups.loadInfo(target),
        '/api/group/bot-state' => await bot.groups.loadBotState(target),
        '/api/group/mute' => await bot.groups.loadMute(target),
        '/api/group/members' => await bot.groups.members(
          target,
          cursor: query['cursor'] ?? '',
        ),
        '/api/group/member' => await bot.groups.member(
          target,
          query['member'] ?? '',
        ),
        '/api/group/requests' => {
          'next_cursor': await bot.groups.syncRequests(
            target,
            cursor: query['cursor'] ?? '',
          ),
        },
        _ => throw const FormatException('群管理接口不存在'),
      };
      _json(request, data);
      return;
    }
    switch (request.uri.path) {
      case '/api/state':
        if (query['revision'] == '$_revision') {
          _json(request, {'unchanged': true});
          return;
        }
        final problem = bot.ipWhitelistProblem;
        _json(request, {
          'revision': _revision,
          'epoch': bot.accountEpoch,
          'groupNoticeUnread': bot.groups.unreadCount,
          'version': AppConstants.appVersion,
          'build': AppConstants.appBuild,
          'config': _config(bot.config),
          'bots': bot.botProfiles.map(_config).toList(),
          'status': bot.connectionStatus,
          'connected': bot.isConnected,
          'connecting': bot.isConnecting,
          'error': _redact(bot.connectionError),
          'botName': bot.botName,
          'sessions': bot.sessions.take(1000).map((s) => s.toMap()).toList(),
          'plugins': [
            for (final plugin in plugins.plugins)
              {
                'id': plugin.info.id,
                'name': plugin.info.name,
                'version': plugin.info.version,
                'description': plugin.info.description,
                'enabled': plugin.info.isEnabled,
                'bundled': plugins.isBundled(plugin.info.id),
                'error': plugins.errorFor(plugin.info.id),
                'commands': [
                  for (final command in plugin.commands)
                    '/${command.usage.isEmpty ? command.name : command.usage}',
                ],
              },
          ],
          'ipProblem': problem == null
              ? null
              : {
                  'appId': problem.appId,
                  'message': _redact(problem.message),
                  'sourceIp': problem.sourceIp,
                  'url': problem.settingsUri.toString(),
                },
        });
      case '/api/messages':
        _checkAccount(query['appId'] ?? '');
        final session = query['session'] ?? '';
        final messages = bot.getMessagesForSession(session);
        _json(request, {
          'appId': bot.config.appId,
          'session': session,
          'messages': messages
              .skip(max(0, messages.length - 500))
              .map(_message)
              .toList(),
          'hasOlder': messages.length > 500,
        });
      case '/api/notices':
        _checkEpoch(query);
        _json(request, {
          'notices': bot.groups.notices
              .map((notice) => notice.toMap())
              .toList(),
        });
      case '/api/logs':
        _json(request, {'logs': _logs});
      case '/api/ip':
        _json(request, {'ips': await _ip.lookup(), 'location': '服务器公网出口 IPv4'});
      case '/api/plugins/source':
        final id = query['id'] ?? '';
        final plugin = plugins.plugins
            .where((item) => item.info.id == id)
            .firstOrNull;
        if (plugin == null) throw const FormatException('未找到插件');
        _json(request, {
          'source': plugins.exportPlugin(id),
          'config': plugin.info.config,
        });
      case '/api/workspace':
        final id = query['id'] ?? '';
        _json(request, {
          'projects': await workspace.projects(),
          'files': id.isEmpty ? <String>[] : await workspace.files(id),
        });
      case '/api/workspace/read':
        _json(request, {
          'source': await workspace.read(
            query['id'] ?? '',
            query['file'] ?? '',
          ),
        });
      default:
        _json(request, {'error': '接口不存在'}, 404);
    }
  }

  Future<void> _post(HttpRequest request, Map<String, dynamic> body) async {
    switch (request.uri.path) {
      case '/api/notices/read':
        _checkEpoch(body);
        if (body['all'] == true) {
          bot.groups.markAllRead();
        } else {
          bot.groups.markRead(_str(body, 'id', 128));
        }
      case '/api/group/approve':
        final target = _groupTarget(body);
        final notice = bot.groups.notices
            .where(
              (notice) =>
                  notice.id == _str(body, 'id', 128) &&
                  notice.groupId == target.groupId,
            )
            .firstOrNull;
        if (notice == null ||
            body['approve'] is! bool ||
            (body['blacklist'] != null && body['blacklist'] is! bool)) {
          throw const FormatException('申请不存在或审核参数无效');
        }
        await bot.groups.approve(
          notice,
          approve: body['approve'] as bool,
          reason: _str(body, 'reason', 500),
          blacklist: body['blacklist'] == true,
        );
      case '/api/group/mute':
        final target = _groupTarget(body);
        final operation = _str(body, 'operation', 16);
        final expiry = body['expiresAt'] == null
            ? null
            : DateTime.tryParse(_str(body, 'expiresAt', 64));
        await bot.groups.setMemberMute(
          target,
          _str(body, 'member', 512),
          operation: operation,
          expiresAt: expiry,
        );
      case '/api/session/mute':
        _checkEpoch(body);
        if (body['muted'] is! bool) throw const FormatException('屏蔽设置必须为开关');
        await bot.setSessionMuted(
          _str(body, 'session', 512),
          body['muted'] as bool,
        );
      case '/api/recall':
        _checkEpoch(body);
        final message = bot
            .getMessagesForSession(_str(body, 'session', 512))
            .where((message) => message.id == _str(body, 'message', 1024))
            .firstOrNull;
        if (message == null || !await bot.recallMessage(message)) {
          throw StateError(
            bot.lastSendError.isEmpty ? '消息不存在或不能撤回' : bot.lastSendError,
          );
        }
      case '/api/config':
        final appId = _str(body, 'appId', 32).trim();
        if (!RegExp(r'^[0-9]{4,32}$').hasMatch(appId)) {
          throw const FormatException('请填写有效的 AppID');
        }
        final previous = bot.botProfiles
            .where((c) => c.appId == appId)
            .firstOrNull;
        final config = BotConfig.fromMap(previous?.toMap() ?? {});
        config.appId = appId;
        final secret = _str(body, 'clientSecret', 256).trim();
        if (secret.isNotEmpty) {
          config.clientSecret = secret;
          config.accessToken = '';
          config.tokenExpiresAt = 0;
        }
        if (config.clientSecret.isEmpty) {
          throw const FormatException('请填写机器人密钥');
        }
        for (final key in [
          'autoReconnect',
          'receiveAllGroupMessages',
          'autoReplyToAllGroupMessages',
          'enableOiapiNickname',
          'useSandbox',
        ]) {
          if (body[key] != null && body[key] is! bool) {
            throw const FormatException('设置值应为开关');
          }
        }
        config.autoReconnect =
            body['autoReconnect'] as bool? ?? config.autoReconnect;
        config.receiveAllGroupMessages =
            body['receiveAllGroupMessages'] as bool? ??
            config.receiveAllGroupMessages;
        config.autoReplyToAllGroupMessages =
            body['autoReplyToAllGroupMessages'] as bool? ??
            config.autoReplyToAllGroupMessages;
        config.enableOiapiNickname =
            body['enableOiapiNickname'] as bool? ?? config.enableOiapiNickname;
        config.useSandbox = body['useSandbox'] as bool? ?? config.useSandbox;
        config.apiBaseUrl = AppConstants.qqBaseUrl;
        await bot.updateConfig(config);
      case '/api/switch':
        await bot.switchBot(_str(body, 'appId', 32));
      case '/api/connect':
        _checkAccount(_str(body, 'appId', 32));
        if (!await bot.connect()) {
          throw StateError(_redact(bot.connectionError));
        }
      case '/api/disconnect':
        _checkAccount(_str(body, 'appId', 32));
        bot.disconnect();
      case '/api/session':
        _checkAccount(_str(body, 'appId', 32));
        final id = _str(body, 'id', 256).trim();
        if (id.isEmpty) throw const FormatException('OpenID 不能为空');
        await bot.addSession(
          id,
          isGroup: body['isGroup'] == true,
          name: _str(body, 'name', 80),
        );
      case '/api/read':
        _checkAccount(_str(body, 'appId', 32));
        await bot.markSessionRead(_str(body, 'session', 256));
      case '/api/send':
        _checkAccount(_str(body, 'appId', 32));
        final session = bot.sessions
            .where((s) => s.id == _str(body, 'session', 256))
            .firstOrNull;
        if (session == null) throw const FormatException('请先选择会话');
        final content = _str(body, 'content');
        final replyId = _str(body, 'replyId', 512);
        final reply = replyId.isEmpty
            ? null
            : bot
                  .getMessagesForSession(session.id)
                  .where((m) => m.id == replyId)
                  .firstOrNull;
        bool sent;
        switch (_str(body, 'format', 20)) {
          case 'markdown':
            sent = await bot.sendMarkdownMessage(
              session.id,
              content,
              isGroup: session.sessionType == 1,
              replyTo: reply,
            );
          case 'image':
            final uri = Uri.tryParse(content);
            if (uri == null ||
                uri.scheme != 'https' ||
                uri.host.isEmpty ||
                uri.userInfo.isNotEmpty) {
              throw const FormatException('网页端发送图片请使用 HTTPS 图片链接');
            }
            sent = await bot.sendImageMessage(
              session.id,
              content,
              isGroup: session.sessionType == 1,
              replyTo: reply,
            );
          case 'text':
            if (content.trim().isEmpty) throw const FormatException('消息不能为空');
            sent = await bot.sendTextMessage(
              session.id,
              content,
              isGroup: session.sessionType == 1,
              replyTo: reply,
            );
          default:
            throw const FormatException('不支持此消息类型');
        }
        if (!sent) throw StateError(_redact(bot.lastSendError));
      case '/api/ip/dismiss':
        final problem = bot.ipWhitelistProblem;
        if (problem != null) bot.dismissIpWhitelistProblem(problem);
      case '/api/plugins/toggle':
        final id = _str(body, 'id', 64);
        final ok = body['enabled'] == true
            ? await plugins.enablePlugin(id)
            : await plugins.disablePlugin(id);
        if (!ok) throw StateError(plugins.errorFor(id) ?? '插件状态修改失败');
      case '/api/plugins/import':
        final installed = await plugins.installPlugin(
          _str(body, 'source', 262144),
          replaceExisting: body['replace'] == true,
        );
        _json(request, {'ok': true, 'id': installed.id});
        return;
      case '/api/plugins/config':
        if (body['config'] is! Map<String, dynamic>) {
          throw const FormatException('配置应为 JSON 对象');
        }
        if (!await plugins.updatePluginConfig(
          _str(body, 'id', 64),
          body['config'],
        )) {
          throw const FormatException('插件不存在');
        }
      case '/api/workspace/seed':
        final id = _str(body, 'id', 64);
        await workspace.seedProject(id, plugins.exportPlugin(id));
      case '/api/workspace/write':
        await workspace.write(
          _str(body, 'id', 64),
          _str(body, 'file', 220),
          _str(body, 'source', 262144),
          expected: body['expected'] == null
              ? null
              : _str(body, 'expected', 262144),
          createOnly: body['createOnly'] == true,
        );
      case '/api/workspace/install':
        await plugins.installPlugin(
          await workspace.assembleProject(_str(body, 'id', 64)),
          replaceExisting: body['replace'] == true,
        );
      default:
        _json(request, {'error': '接口不存在'}, 404);
        return;
    }
    _changed();
    _json(request, {'ok': true});
  }

  Future<void> close() async {
    _closed = true;
    _tick?.cancel();
    await _server.close(force: true);
    await _mutations;
    bot.disconnect();
    await bot.groups.flush();
    bot.removeListener(_changed);
    plugins.removeListener(_changed);
    bot.dispose();
    plugins.dispose();
    _ip.dispose();
    await storage.flush();
  }
}
