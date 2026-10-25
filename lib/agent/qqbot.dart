import 'dart:async';
import 'dart:convert';
import '../services/image_upload_service.dart';
import '../services/websocket_service.dart';
import '../utils/constants.dart';
import '../utils/bot_command_context.dart';
import '../utils/profile_helpers.dart';
import '../services/oiapi_service.dart';
import '../services/profile_request_queue.dart';
import '../services/api_service.dart' show ApiResult;
import 'http.dart';
import 'models.dart';
import 'onebot.dart';
import '../models/received_message.dart';
import 'message_context.dart';
import 'audio.dart';

/// A separate official QQ gateway session. Never uses BotClient or its stores.
class QqBotAgentTransport extends AgentTransport {
  final AgentConnection config;
  final AgentHttp _http;
  final WebSocketService _ws;
  final Uri _base, _tokenEndpoint;
  final DateTime Function() _clock;
  final Future<int> Function(String messageId, int limit)? reserveSequence;
  final int Function(String messageId)? sequenceUsed;
  final ProfileRequestQueue _profileQueue;
  final OiapiService _nicknames;
  final _profileDeniedReported = <String>{};
  final _botIds = <String>{};
  final _sequences = <String, int>{};
  final _replies = <String, ({String id, String reference, DateTime at})>{};
  final _latest = <String, String>{};
  String _token = '', _nickname = '', _botId = '', _status = '未连接';
  DateTime? _expires;
  Future<String>? _refreshing;
  Timer? _refresh;
  int _generation = 0;
  bool _stopped = true;
  QqBotAgentTransport(
    this.config, {
    AgentHttp? http,
    WebSocketService? socket,
    Uri? apiBase,
    Uri? tokenEndpoint,
    DateTime Function()? clock,
    this.reserveSequence,
    this.sequenceUsed,
    ProfileRequestQueue? profileQueue,
    OiapiService? nicknames,
  }) : _http = http ?? AgentHttp(),
       _profileQueue = profileQueue ?? ProfileRequestQueue(),
       _nicknames = nicknames ?? OiapiService(),
       _ws = socket ?? WebSocketService(),
       _base =
           apiBase ??
           Uri.parse(
             config.sandbox
                 ? AppConstants.qqSandboxUrl
                 : AppConstants.qqBaseUrl,
           ),
       _tokenEndpoint = tokenEndpoint ?? Uri.parse(AppConstants.qqTokenUrl),
       _clock = clock ?? DateTime.now;
  @override
  bool get connected => !_stopped && _ws.isConnected;
  @override
  String get nickname => _nickname;
  @override
  String get status => _status;
  void _state(String value) {
    _status = value;
    onState?.call();
  }

  bool _current(int epoch) => !_stopped && epoch == _generation;

  Future<String> _accessToken() async {
    if (_stopped) throw const AgentException('QQBot 已停止。');
    if (_expires != null && _clock().isBefore(_expires!) && _token.isNotEmpty) {
      return _token;
    }
    return _refreshing ??= _getToken().whenComplete(() => _refreshing = null);
  }

  Future<String> _getToken() async {
    final epoch = _generation;
    final result = object(
      await _http.request(
        _tokenEndpoint,
        method: 'POST',
        body: {'appId': config.selfId, 'clientSecret': config.clientSecret},
      ),
    );
    if (!_current(epoch)) throw const AgentException('QQBot 已停止。');
    final value = text(result['access_token']);
    if (value.isEmpty) {
      throw const AgentException('未获取到 QQBot 凭证，请检查 AppID 和 ClientSecret。');
    }
    _token = value;
    final seconds = integer(result['expires_in'], 7200).clamp(2, 7200);
    _expires = _clock().add(
      Duration(seconds: seconds > 120 ? seconds - 60 : seconds ~/ 2),
    );
    _refresh?.cancel();
    _refresh = Timer(_expires!.difference(_clock()), () async {
      try {
        _ws.updateAccessToken(await _accessToken());
      } catch (_) {
        if (_current(epoch)) _state('凭证刷新失败 · 请检查网络和密钥');
      }
    });
    return value;
  }

  Future<Json> _api(String path, {String method = 'GET', Json? body}) async {
    final epoch = _generation, token = await _accessToken();
    try {
      final result = object(
        await _http.request(
          _base.resolve(path),
          method: method,
          body: body,
          headers: {'Authorization': 'QQBot $token'},
          timeoutSeconds: 15,
        ),
      );
      if (!_current(epoch)) throw const AgentException('QQBot 连接已切换，已忽略旧接口结果。');
      final code = integer(result['err_code'] ?? result['code'], 0);
      if (code != 0) {
        throw AgentHttpException(
          'QQBot 接口返回错误码 $code。',
          statusCode: 200,
          errorCode: code,
        );
      }
      return result['data'] is Map && result['id'] == null
          ? object(result['data'])
          : result;
    } on AgentHttpException catch (e) {
      final hint = switch (e.errorCode) {
        11253 => '机器人未获此接口的白名单 / 能力授权',
        100007 || 10004 || 100016 => '请检查 AppID 和 ClientSecret',
        40054005 => '消息序号被去重，需要新的 msg_seq',
        304103 || 40034005 || 40034128 => '被动回复窗口已过期或次数已用完，请等待用户发新消息',
        40054002 => '机器人被禁言，无法回复',
        40034101 || 40054003 => '机器人不在此群聊中',
        22009 || 40034100 => '发送超频，请稍后重试',
        40034105 => '没有主动消息权限，请先让用户向机器人发送新消息',
        40054010 => '消息链接未获许可，请检查开放平台消息 URL 配置',
        40054013 => '对方关闭了机器人消息接收',
        _ =>
          e.statusCode == 401
              ? '访问凭证无效，请重新启动连接'
              : e.statusCode == 403
              ? '请求被拒绝，请检查平台权限、IP 白名单与代理配置'
              : '请检查 QQ 平台权限和请求参数',
      };
      final safeTrace = _token.isEmpty
          ? e.traceId
          : e.traceId.replaceAll(_token, '[已隐藏]');
      throw AgentHttpException(
        'QQBot：${e.ipWhitelist ? '接口访问源 IP 不在白名单，请在 https://q.qq.com/qqbot/dashboard/manage/${config.selfId}?sec=dev-settings 配置' : hint}。'
        '${e.ipWhitelist && e.sourceIp != null ? '平台报告源 IP：${e.sourceIp}。' : ''}'
        'HTTP ${e.statusCode}${e.errorCode == null ? '' : ' / 错误码 ${e.errorCode}'}${safeTrace.isEmpty ? '' : ' / 追踪 ID $safeTrace'}',
        statusCode: e.statusCode,
        errorCode: e.errorCode,
        traceId: safeTrace,
        ipWhitelist: e.ipWhitelist,
        sourceIp: e.sourceIp,
      );
    }
  }

  @override
  Future<void> start() async {
    if (!_stopped) return;
    config.validate();
    _stopped = false;
    final epoch = ++_generation;
    _state('QQBot · 获取凭证');
    _ws.onConnectionStateChanged = (_) {
      if (_current(epoch)) {
        _state(
          _ws.isConnected
              ? 'QQBot 已连接'
              : 'QQBot ${_ws.state == ConnectionState.reconnecting ? '重连中' : '连接中'}',
        );
      }
    };
    _ws.onReady = (data) {
      if (!_current(epoch)) return;
      final user = object(data['user']);
      _botId = firstProfileName([
        user['id'],
        user['user_openid'],
        user['member_openid'],
      ]);
      _botIds.addAll(
        [
          config.selfId,
          _botId,
          text(user['user_openid']),
          text(user['member_openid']),
          text(user['union_openid']),
        ].where((s) => s.isNotEmpty),
      );
      _nickname = firstProfileName([
        user['username'],
        user['nickname'],
        user['name'],
      ]);
      onDiagnostic?.call(
        'info',
        'QQBot 网关 READY 鉴权完成${_nickname.isEmpty ? '' : ' · $_nickname'}',
      );
      if (_nickname.isEmpty) unawaited(_loadBotProfile(epoch));
      onState?.call();
    };
    _ws.onDispatch = (type, data) {
      if (_current(epoch)) _event(type, data);
    };
    _ws.refreshAccessToken = _accessToken;
    try {
      final token = await _accessToken();
      final gateway = await _api('/gateway');
      if (!_current(epoch)) return;
      final uri = Uri.tryParse(text(gateway['url']));
      if (uri == null ||
          !{'ws', 'wss'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          (_base.scheme == 'https' && uri.scheme != 'wss')) {
        throw const AgentException('QQBot 网关地址无效。');
      }
      final ok = await _ws.connect(wsUrl: uri.toString(), accessToken: token);
      if (!_current(epoch)) return;
      if (!ok) throw const AgentException('QQBot 网关连接失败，请检查网络、IP 白名单和平台接入权限。');
      _state('QQBot 已连接');
    } catch (_) {
      if (_current(epoch)) {
        _ws.disconnect();
        _state('QQBot 连接失败');
      }
      rethrow;
    }
  }

  Future<void> _loadBotProfile(int epoch) async {
    try {
      final user = await _api('/users/@me');
      if (!_current(epoch)) return;
      _nickname = firstProfileName([
        user['username'],
        user['nickname'],
        _nickname,
      ]);
      _botIds.addAll(
        [
          text(user['id']),
          text(user['user_openid']),
        ].where((s) => s.isNotEmpty),
      );
      onState?.call();
    } catch (_) {
      if (_current(epoch)) {
        onDiagnostic?.call('warning', 'QQBot 自身资料暂未获取，不影响接收和 AI 回复。');
      }
    }
  }

  @override
  Future<Json> loadOfficialProfile(
    String kind,
    String peerId, {
    String memberId = '',
    String lookupId = '',
    bool force = false,
  }) async {
    final epoch = _generation;
    if (!connected || !config.resolveOfficialProfiles) return {};
    if (kind == 'private') {
      if (!config.useOiapiNickname) return {};
      final result = await _nicknames.getNickname(
        appId: config.selfId,
        openId: lookupId.isEmpty ? peerId : lookupId,
      );
      if (!_current(epoch)) return {};
      if (!result.isSuccess) {
        throw const AgentException('单聊昵称补全暂未成功，保留 OpenID；不会阻止 AI 回复。');
      }
      return {
        'name': firstProfileName([result.data?['nickname']]),
        'source': 'oiapi',
      };
    }
    final queueKind = kind == 'group' ? 'group' : 'member';
    final result = await _profileQueue.request(
      kind: queueKind,
      key: '$peerId:$memberId',
      force: force,
      load: () async {
        if (!_current(epoch)) return ApiResult.failure('资料查询已取消');
        try {
          return ApiResult.success(
            await _api(
              '/v2/groups/${Uri.encodeComponent(peerId)}/${kind == 'group' ? 'info' : 'members/${Uri.encodeComponent(memberId)}'}',
            ),
          );
        } on AgentHttpException catch (e) {
          return ApiResult.failure(
            e.message,
            statusCode: e.statusCode,
            errorCode: e.errorCode,
          );
        } catch (_) {
          return ApiResult.failure('资料查询暂未完成，不影响收发消息。');
        }
      },
    );
    if (!_current(epoch)) return {};
    if (!result.isSuccess) {
      if (_profileQueue.isDenied(queueKind) &&
          _profileDeniedReported.add(queueKind)) {
        onDiagnostic?.call(
          'warning',
          '${kind == 'group' ? '群资料' : '群成员资料'}接口未授权（11253 / HTTP 403），已停止自动重复查询；仍可收发消息。',
        );
      }
      throw AgentException(result.error ?? 'QQBot 资料暂未获取。');
    }
    final data = object(result.data);
    final identity = firstProfileName([
      data[kind == 'group' ? 'group_openid' : 'member_openid'],
    ]);
    if (identity.isNotEmpty &&
        identity != (kind == 'group' ? peerId : memberId)) {
      throw const AgentException('资料返回的 OpenID 不匹配，已忽略。');
    }
    return {
      'name': firstProfileName(
        kind == 'group'
            ? [data['group_name'], data['name']]
            : [data['username'], data['nickname'], data['nick'], data['name']],
      ),
      'source': 'qq',
    };
  }

  void _event(String type, Json data) {
    if (!{
      'GROUP_AT_MESSAGE_CREATE',
      'GROUP_MESSAGE_CREATE',
      'C2C_MESSAGE_CREATE',
    }.contains(type)) {
      return;
    }
    final group = type != 'C2C_MESSAGE_CREATE', author = object(data['author']);
    final sender = firstProfileName([
      data['openid'],
      data['user_openid'],
      data['member_openid'],
      group ? author['member_openid'] : author['user_openid'],
      author['member_openid'],
      author['id'],
    ]);
    final peer = group
        ? firstProfileName([data['group_openid'], data['group_id']])
        : sender;
    final id = text(data['id']), kind = group ? 'group' : 'private';
    if (!openId(peer) || !openId(sender) || id.isEmpty) {
      onDiagnostic?.call(
        'warning',
        'QQBot 收到 $type，但缺少有效的会话 / 发送者 OpenID 或消息 ID，已忽略。',
      );
      return;
    }
    final target = '$kind:$peer', key = '$kind:$peer:$id';
    final ext = strings(object(data['message_scene'])['ext']);
    final reference = ext.where((e) => e.startsWith('msg_idx=')).firstOrNull;
    _replies.putIfAbsent(
      key,
      () => (
        id: id,
        reference: reference?.substring(8) ?? '',
        at: DateTime.tryParse(text(data['timestamp'])) ?? _clock(),
      ),
    );
    _latest[target] = id;
    if (_replies.length > 2000) {
      _replies.remove(_replies.keys.first);
    }
    final segments = <Json>[];
    final mentions = data['mentions'] is List
        ? data['mentions'] as List
        : const [];
    final selfIds = {..._botIds, config.selfId, if (_botId.isNotEmpty) _botId};
    for (final mention in mentions.whereType<Map>()) {
      final ids = [
        for (final key in ['id', 'openid', 'user_openid', 'member_openid'])
          text(mention[key]),
      ].where((s) => s.isNotEmpty);
      if (mention['is_you'] == true || ids.any(selfIds.contains)) {
        selfIds.addAll(ids);
      }
    }
    final original = text(data['content']);
    var context = botCommandContext(
      original,
      isGroup: group,
      eventType: type,
      botId: _botId,
      botName: _nickname,
      mentions: mentions,
    );
    for (final self in selfIds) {
      if (context.isMentioned) break;
      context = botCommandContext(
        original,
        isGroup: group,
        eventType: type,
        botId: self,
        botName: _nickname,
        mentions: mentions,
      );
    }
    final content = context.content;
    if (group && context.isMentioned && content != original) {
      segments.add({
        'type': 'at',
        'data': {'qq': config.selfId, 'name': _nickname},
      });
    }
    var cursor = 0;
    for (final match in RegExp(
      r'<@!?([A-Za-z0-9_-]+)>|<qqbot-at-user\s+id="([A-Za-z0-9_-]+)"\s*/>',
    ).allMatches(content)) {
      if (match.start > cursor) {
        segments.add(textSegment(content.substring(cursor, match.start)));
      }
      final target = match[1] ?? match[2]!;
      final name =
          mentions
              .whereType<Map>()
              .where(
                (m) => [
                  m['id'],
                  m['openid'],
                  m['member_openid'],
                  m['user_openid'],
                ].any((v) => text(v) == target),
              )
              .map(
                (m) =>
                    firstProfileName([m['username'], m['nickname'], m['nick']]),
              )
              .where((s) => s.isNotEmpty)
              .firstOrNull ??
          '';
      segments.add({
        'type': 'at',
        'data': {
          'qq': selfIds.contains(target) ? config.selfId : target,
          if (name.isNotEmpty) 'name': name,
        },
      });
      cursor = match.end;
    }
    if (cursor < content.length) {
      segments.add(textSegment(content.substring(cursor)));
    }
    for (final raw in (data['attachments'] as List? ?? []).take(20)) {
      final a = ReceivedAttachment.fromMap(object(raw));
      segments.add({
        'type': a.isImage
            ? 'image'
            : a.isVideo
            ? 'video'
            : a.isVoice
            ? 'record'
            : 'file',
        'data': {
          'url': a.isVoice && a.voiceWavUrl.isNotEmpty ? a.voiceWavUrl : a.url,
          'name': a.filename,
        },
      });
    }
    final received = ReceivedMessageBody.fromMap({...data, 'content': content});
    if (needsOfficialBody(received)) {
      final addressedSegments = segments
          .where(
            (s) =>
                s['type'] == 'at' && object(s['data'])['qq'] == config.selfId,
          )
          .toList();
      final attachments = segments
          .where(
            (s) => {'image', 'record', 'video', 'file'}.contains(s['type']),
          )
          .toList();
      segments
        ..clear()
        ..addAll(addressedSegments)
        ..add({
          'type': 'qq_body',
          'data': {
            ...officialBodyData({...data, 'content': content}),
            'commandText': clipped(content, 4000),
          },
        });
      // Root media is rendered by ReceivedMessageView, while this hidden copy
      // lets the AI vision pipeline read it using the same size/SSRF limits.
      for (final image in attachments.where((s) => s['type'] == 'image')) {
        final details = segments.last['data'] as Json;
        details['images'] = [image, ...(details['images'] as List? ?? [])];
      }
    }
    onEvent?.call({
      'post_type': 'message',
      'self_id': config.selfId,
      'message_type': kind,
      if (group) 'group_id': peer,
      'user_id': sender,
      'message_id': id,
      'message': segments,
      'sender': {
        'nickname': firstProfileName([
          author['username'],
          author['nick'],
          author['nickname'],
          author['name'],
          data['username'],
          data['nick'],
          data['nickname'],
          data['member_name'],
          data['member_nick'],
          sender,
        ]),
      },
      'time':
          (DateTime.tryParse(text(data['timestamp'])) ?? _clock())
              .millisecondsSinceEpoch ~/
          1000,
      '_mentioned':
          type == 'GROUP_AT_MESSAGE_CREATE' ||
          context.isMentioned ||
          segments.any(
            (s) =>
                s['type'] == 'at' && object(s['data'])['qq'] == config.selfId,
          ),
      '_qq_event_type': type,
      '_qq_lookup_id': firstProfileName([author['id'], sender]),
      '_reference_index': reference?.substring(8) ?? '',
      '_quoted_index':
          ext
              .where((e) => e.startsWith('ref_msg_idx='))
              .map((e) => e.substring(12))
              .firstOrNull ??
          '',
      '_sender_is_bot': author['bot'] == true || selfIds.contains(sender),
      '_sender_name_is_fallback': firstProfileName([
        author['username'],
        author['nick'],
        author['nickname'],
        author['name'],
        data['username'],
        data['nick'],
        data['nickname'],
        data['member_name'],
        data['member_nick'],
      ]).isEmpty,
      'group_name': firstProfileName([
        data['group_name'],
        object(data['group'])['group_name'],
        object(data['group'])['name'],
      ]),
    });
  }

  @override
  Future<dynamic> call(String action, [Json params = const {}]) async {
    if (!connected) throw const AgentException('QQBot 尚未连接。');
    if (!{'send_group_msg', 'send_private_msg'}.contains(action)) {
      throw const AgentException(
        'QQBot 不提供 OneBot 好友 / 群列表或合并记录接口；收到消息后会自动创建会话。',
      );
    }
    final epoch = _generation, group = action == 'send_group_msg';
    final peer = text(params[group ? 'group_id' : 'user_id']),
        kind = group ? 'group' : 'private';
    if (!openId(peer)) throw const AgentException('QQBot 目标 OpenID 无效。');
    final segments = parseSegments(params['message']);
    if (segments.any(
      (s) => !{'text', 'at', 'reply', 'image', 'record'}.contains(s['type']),
    )) {
      throw const AgentException('Agent 的 QQBot 连接支持文本、图片、语音与 Markdown @ 消息。');
    }
    final images = segments.where((s) => s['type'] == 'image').toList();
    final records = segments.where((s) => s['type'] == 'record').toList();
    if (records.length > 1 || (records.isNotEmpty && images.isNotEmpty)) {
      throw const AgentException('每条官机消息仅发送一份图片或语音。');
    }
    if (images.length > 1) throw const AgentException('QQBot 每条消息只能发送一张图片。');
    final mentioned = segments.any((s) => s['type'] == 'at');
    if (mentioned && (images.isNotEmpty || records.isNotEmpty)) {
      throw const AgentException('请将图片与 Markdown @ 分开发送。');
    }
    final content = segments
        .where((s) => {'text', 'at'}.contains(s['type']))
        .map((s) {
          final d = object(s['data']);
          if (s['type'] == 'text') return text(d['text']);
          final who = text(d['qq']);
          if (who != 'all' && !openId(who)) {
            throw const AgentException('@ 用户 OpenID 无效。');
          }
          return who == 'all'
              ? '<qqbot-at-everyone />'
              : '<qqbot-at-user id="$who" />';
        })
        .join();
    if (content.trim().isEmpty && images.isEmpty && records.isEmpty ||
        content.length > 12000) {
      throw const AgentException('消息不能为空且不能超过 12000 字符。');
    }
    final trigger = text(params['_reply_id']);
    final reply = trigger.isNotEmpty ? trigger : _latest['$kind:$peer'] ?? '';
    final ref = _replies['$kind:$peer:$reply'];
    final active =
        ref != null &&
        _clock().difference(ref.at).inSeconds < (group ? 300 : 3600);
    if (trigger.isNotEmpty && !active) {
      throw const AgentException('原消息的被动回复窗口已过期，请等待新消息后重试。');
    }
    if (active && replyCapacity(kind, peer, 'ob:$reply') <= 0) {
      throw const AgentException('这条消息的被动回复次数已用完，请等待新消息。');
    }
    final body = <String, dynamic>{
      'msg_type': mentioned ? 2 : 0,
      if (mentioned) 'markdown': {'content': content} else 'content': content,
    };
    if (images.isNotEmpty) {
      final data = object(images.single['data']);
      final file = text(data['file']);
      if (!file.startsWith('base64://') || file.length > 7 * 1024 * 1024) {
        throw const AgentException('QQBot 图片需使用 5 MB 以内的本地数据。');
      }
      final prepared = await const ImageUploadService().prepare(
        base64Decode(file.substring(9)),
        text(data['name']).isEmpty ? 'image.png' : text(data['name']),
      );
      if (!_current(epoch) || !connected) {
        throw const AgentException('QQBot 已停止，已取消图片上传。');
      }
      final uploaded = await _api(
        '/v2/${group ? 'groups' : 'users'}/${Uri.encodeComponent(peer)}/files',
        method: 'POST',
        body: {
          'file_type': 1,
          'file_name': prepared.filename,
          'file_data': base64Encode(prepared.bytes),
          'srv_send_msg': false,
        },
      );
      final info = text(uploaded['file_info']);
      if (info.isEmpty) throw const AgentException('QQBot 图片上传没有返回 file_info。');
      body['msg_type'] = 7;
      body['media'] = {'file_info': info};
    }
    if (records.isNotEmpty) {
      final file = text(object(records.single['data'])['file']);
      if (!file.startsWith('base64://') || file.length > 7 * 1024 * 1024) {
        throw const AgentException('QQBot 语音需要 5 MB 以内的本地数据。');
      }
      final audio = AgentAudio(base64Decode(file.substring(9)));
      if (!{'wav', 'mp3', 'silk'}.contains(audio.extension)) {
        throw const AgentException('QQBot 语音需使用 WAV、MP3 或 SILK，当前格式需要由合成服务转换。');
      }
      if (!_current(epoch) || !connected) {
        throw const AgentException('QQBot 已停止，已取消语音上传。');
      }
      final uploaded = await _api(
        '/v2/${group ? 'groups' : 'users'}/${Uri.encodeComponent(peer)}/files',
        method: 'POST',
        body: {
          'file_type': 3,
          'file_name': audio.name,
          'file_data': base64Encode(audio.bytes),
          'srv_send_msg': false,
        },
      );
      final info = text(uploaded['file_info']);
      if (info.isEmpty) throw const AgentException('QQBot 语音上传没有返回 file_info。');
      body['msg_type'] = 7;
      body['media'] = {'file_info': info};
    }
    final quote = segments.where((s) => s['type'] == 'reply').firstOrNull;
    if (quote != null) {
      final quoted = _replies['$kind:$peer:${object(quote['data'])['id']}'];
      if (quoted == null || quoted.reference.isEmpty) {
        throw const AgentException('这条消息没有可用的引用索引，请取消引用后发送。');
      }
      body['message_reference'] = {'message_id': quoted.reference};
    }
    Future<void> nextSequence() async {
      if (!active) return;
      final limit = group ? 5 : 4;
      final sequence = reserveSequence == null
          ? (_sequences.update(reply, (v) => v + 1, ifAbsent: () => 1))
          : await reserveSequence!(reply, limit);
      _sequences[reply] = sequence;
      if (sequence > limit) {
        throw const AgentException('这条消息的被动回复次数已用完，请等待新消息。');
      }
      body.addAll({'msg_id': ref.id, 'msg_seq': sequence});
    }

    await nextSequence();
    if (!_current(epoch) || !connected) {
      throw const AgentException('QQBot 连接已切换，已取消发送。');
    }
    final path =
        '/v2/${group ? 'groups' : 'users'}/${Uri.encodeComponent(peer)}/messages';
    onDiagnostic?.call(
      'info',
      'QQBot 准备发送${group ? '群聊' : '单聊'}消息 · 类型 ${body['msg_type']} · ${active ? '被动回复，msg_seq=${body['msg_seq']}' : '主动消息'}',
    );
    Json result;
    try {
      result = await _api(path, method: 'POST', body: body);
    } on AgentHttpException catch (e) {
      // Only the explicit deduplication rejection is safe to retry. Never retry
      // a network timeout / uncertain result or silently switch to proactive.
      if (e.errorCode != 40054005 || !active || !_current(epoch)) rethrow;
      onDiagnostic?.call(
        'warning',
        'QQBot 明确拒绝了重复 msg_seq，保留原 msg_id 并使用新序号重试一次。',
      );
      await nextSequence();
      result = await _api(path, method: 'POST', body: body);
    }
    final id = text(result['id']);
    if (id.isEmpty) throw const AgentException('QQBot 未返回消息 ID，请先核对是否已发送。');
    return {'message_id': id};
  }

  @override
  int replyCapacity(String kind, String peerId, String triggerId) {
    final id = triggerId.replaceFirst('ob:', '');
    final ref = _replies['$kind:$peerId:$id'];
    final limit = kind == 'group' ? 5 : 4;
    if (ref == null ||
        _clock().difference(ref.at).inSeconds >=
            (kind == 'group' ? 300 : 3600)) {
      return 0;
    }
    final local = _sequences[id] ?? 0, saved = sequenceUsed?.call(id) ?? 0;
    return (limit - (local > saved ? local : saved)).clamp(0, limit);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    ++_generation;
    _refresh?.cancel();
    _profileQueue.dispose();
    _nicknames.dispose();
    _ws.onDispatch = null;
    _ws.onReady = null;
    _ws.onConnectionStateChanged = null;
    _ws.dispose();
    _http.close();
    _token = '';
    _expires = null;
    _state('未连接');
  }
}
