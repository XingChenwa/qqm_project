part of 'controller.dart';

/// Deferred delivery is owned by the host, not a JS timer bound to a finished
/// model turn. Rows contain task/context identifiers, never API credentials.
extension AgentCoverDelivery on AgentController {
  Uri _coverEndpoint(AgentExtension e) {
    if (!e.isJavaScript ||
        !strings(e.packageManifest['permissions']).contains('cover_delivery')) {
      throw const AgentException('此 Skill 没有声明翻唱后台发送能力。');
    }
    final base = Uri.tryParse(text(e.config['baseOrigin']).trim());
    final path = text(e.config['apiPath']).isEmpty
        ? '/api/tool'
        : text(e.config['apiPath']);
    if (base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.hasQuery ||
        base.hasFragment ||
        !{'', '/'}.contains(base.path) ||
        !RegExp(r'^/(?:[A-Za-z0-9_-]+/)*[A-Za-z0-9_-]+/?$').hasMatch(path)) {
      throw const AgentException('请配置有效的翻唱 HTTPS 地址和 API 路径。');
    }
    final key = text(e.config['apiKey']);
    if (key.isEmpty ||
        key.length > 512 ||
        key.contains(RegExp(r'[\x00-\x20\x7f]'))) {
      throw const AgentException('请在 Skill 设置填写有效的 API 密钥。');
    }
    return Uri.parse('${base.origin}$path');
  }

  String _coverKey(
    String connectionId,
    String selfId,
    String extensionId,
    String sessionKey,
    String endpoint,
    String scope,
    String jobId,
  ) =>
      'agent-cover-delivery:${const Uuid().v5(Namespace.url.value, jsonEncode([connectionId, selfId, extensionId, sessionKey, endpoint, scope, jobId]))}';

  Json _coverPublic(Json row) => {
    'job_id': row['jobId'],
    'state': row['state'],
    'remote_status': row['remoteStatus'],
    'message': row['message'] ?? '',
    if (row['receipt'] is Map) 'receipt': row['receipt'],
  };

  Future<void> recoverCoverDeliveries() async {
    for (final row
        in store
            .all('agent-cover-delivery')
            .where((x) => x['state'] == 'sending')) {
      await store.put(text(row['key']), {
        ...row,
        'state': 'uncertain',
        'message': '上次退出时语音回执未确认，请在QQ核对；不会自动重发。',
      });
      _log(
        'warning',
        '翻唱上次发送回执未确认，已停止自动重发。',
        text(row['connectionId']),
        text(row['sessionKey']),
        'cover-delivery',
      );
    }
  }

  Future<Json> coverDeliveryOperation(
    AgentConnection c,
    AgentExtension e,
    AgentSession s,
    AgentMessage trigger,
    Json args,
  ) async {
    if (trigger.sessionKey != s.key ||
        trigger.outgoing ||
        trigger.senderIsBot ||
        trigger.senderId.isEmpty ||
        !_runtimeAlive(c, e)) {
      throw const AgentException('需要当前机器人会话中真实用户的消息。');
    }
    final endpoint = _coverEndpoint(e);
    final scope = text(args['scope']), jobId = text(args['jobId']);
    final suffix = '|${c.protocol}:${c.selfId}|${_pluginChatKey(s)}';
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(jobId) ||
        !scope.startsWith('qqm-zip:') ||
        !scope.endsWith(suffix) ||
        !RegExp(
          r'^[A-Za-z0-9-]{20,64}$',
        ).hasMatch(scope.substring(8, scope.length - suffix.length))) {
      throw const AgentException('任务标识或会话不匹配，未安排发送。');
    }
    final key = _coverKey(
      c.id,
      c.selfId,
      e.id,
      s.key,
      endpoint.toString(),
      scope,
      jobId,
    );
    final old = store.get(key);
    switch (args['action']) {
      case 'status':
        return old == null
            ? {'registered': false}
            : {'registered': true, ..._coverPublic(old)};
      case 'cancel':
        if (old == null) return {'ok': true, 'registered': false};
        if (old['senderId'] != trigger.senderId) {
          throw const AgentException('只有原提问者可取消自动发送。');
        }
        if (old['state'] == 'sending') {
          throw const AgentException('语音正在发送，无法撤回已提交的请求，请先核对QQ。');
        }
        if (old['state'] != 'sent') {
          _cancelledCoverDeliveries.add(key);
          await store.put(key, {
            ...old,
            'state': 'cancelled',
            'message': '已取消自动发送。',
          });
        }
        return {'ok': true, ..._coverPublic(store.get(key)!)};
      case 'watch':
      case 'send':
        break;
      default:
        throw const AgentException('未知翻唱发送操作。');
    }
    final manual = args['action'] == 'send';
    if (!manual && e.config['autoSend'] != true) {
      return {'registered': false, 'message': '自动发送已关闭，完成后需要查询并手动调用发送工具。'};
    }
    var row = old;
    if (row == null) {
      if (store
              .all('agent-cover-delivery')
              .where(
                (x) =>
                    x['connectionId'] == c.id &&
                    !{
                      'sent',
                      'failed',
                      'cancelled',
                      'uncertain',
                    }.contains(x['state']),
              )
              .length >=
          32) {
        throw const AgentException('当前机器人已有32个待发送翻唱，请先处理已有任务。');
      }
      row = {
        'key': key,
        'connectionId': c.id,
        'selfId': c.selfId,
        'protocol': c.protocol,
        'extensionId': e.id,
        'sessionKey': s.key,
        'senderId': trigger.senderId,
        'caller': agentToolCaller(trigger, s),
        'replyId': trigger.id,
        'jobId': jobId,
        'scope': scope,
        'endpoint': endpoint.toString(),
        'created': DateTime.now().toIso8601String(),
        'nextCheck': DateTime.now()
            .add(const Duration(seconds: 15))
            .toIso8601String(),
        'state': 'watching',
        'message': '已登记后台任务；管理器保持连接时，完成后自动发回本会话。',
      };
      await store.put(key, row);
      _log('info', '翻唱已登记完成后发送 · 任务 $jobId', c.id, s.key, 'cover-delivery');
    }
    if (!manual) {
      return {
        'registered': !{
          'sent',
          'failed',
          'cancelled',
          'uncertain',
        }.contains(row['state']),
        ..._coverPublic(row),
      };
    }
    if (row['state'] == 'sent') {
      return {'alreadySent': true, ..._coverPublic(row)};
    }
    if (row['state'] == 'uncertain') {
      throw const AgentException('此任务上次发送回执不明，请先在QQ核对；未重复发送。');
    }
    if (row['state'] == 'cancelled') {
      throw const AgentException('此任务的自动发送已取消；请在服务器下载成品后另行发送。');
    }
    if (_coverDeliveryInFlight.contains(key)) {
      throw const AgentException('此任务正在检查或发送，请稍后查看，不要重复发送。');
    }
    _coverDeliveryInFlight.add(key);
    try {
      await _deliverCover(row, manual: true);
      final fresh = store.get(key)!;
      if (fresh['state'] == 'sent') {
        return {'sent': true, ..._coverPublic(fresh)};
      }
      throw AgentException(
        text(fresh['message']).isEmpty
            ? '翻唱尚未完成，已保留后台检查。'
            : text(fresh['message']),
      );
    } finally {
      _coverDeliveryInFlight.remove(key);
    }
  }

  ({AgentConnection c, AgentExtension e, AgentSession s})? _coverContext(
    Json row, {
    bool manual = false,
  }) {
    final c = connection(text(row['connectionId'])),
        s = session(text(row['sessionKey']));
    final e = extensions.where((x) => x.id == row['extensionId']).firstOrNull;
    if (_closed ||
        migrationPaused ||
        c == null ||
        s == null ||
        e == null ||
        !connected(c.id) ||
        !e.enabled ||
        s.paused ||
        c.selfId != row['selfId'] ||
        s.connectionId != c.id ||
        s.selfId != c.selfId ||
        s.protocol != row['protocol'] ||
        !_runtimeExtensions(
          c,
          presets
              .where(
                (p) => p.id == (s.presetId.isEmpty ? c.presetId : s.presetId),
              )
              .firstOrNull,
        ).any((x) => x.id == e.id) ||
        (!manual &&
            (e.config['autoSend'] != true || busySessions.contains(s.key)))) {
      return null;
    }
    if (_coverEndpoint(e).toString() != row['endpoint']) {
      throw const AgentException('翻唱服务器地址已变化，原任务暂停发送；请用原地址查看成品。');
    }
    return (c: c, e: e, s: s);
  }

  Future<Json> _coverCall(
    Json row,
    AgentExtension e,
    String action, {
    bool audio = false,
  }) async {
    final token = CancelToken();
    _coverDeliveryCancels.add(token);
    try {
      final value = object(
        await http.request(
          _coverEndpoint(e),
          method: 'POST',
          headers: {'Authorization': 'Bearer ${text(e.config['apiKey'])}'},
          body: {
            'action': action,
            'scope': row['scope'],
            'caller': row['caller'],
            'args': {'job_id': row['jobId']},
          },
          timeoutSeconds: audio ? 60 : 15,
          maxBytes: audio ? 8 * 1024 * 1024 : 262144,
          cancel: token,
        ),
      );
      if (value['isError'] == true || value['ok'] == false) {
        throw AgentException(
          text(value['message']).isEmpty
              ? '翻唱服务未完成请求。'
              : text(value['message']),
        );
      }
      return value;
    } finally {
      _coverDeliveryCancels.remove(token);
    }
  }

  ({bool ready, String? id}) _coverReply(
    Json row,
    AgentConnection c,
    AgentSession s,
    AgentExtension e,
  ) {
    if (!c.isOfficial) return (ready: true, id: null);
    final t = _transports[c.id]!;
    for (final m in store.messages(s.key).reversed) {
      if (m.outgoing ||
          m.senderIsBot ||
          m.senderId != row['senderId'] ||
          m.id == row['blockedReplyId']) {
        continue;
      }
      if ((t.replyCapacity(s.kind, s.peerId, m.id) ?? 0) > 0) {
        return (ready: true, id: m.id);
      }
    }
    if (e.config['allowProactive'] == true &&
        row['blockedReplyId'] != '@proactive') {
      return (ready: true, id: null);
    }
    return (ready: false, id: null);
  }

  Future<void> _deliverCover(Json row, {bool manual = false}) async {
    final context = _coverContext(row, manual: manual);
    if (context == null) return;
    final (c: c, e: e, s: s) = context;
    final key = text(row['key']);
    final response = await _coverCall(row, e, 'status');
    if (_cancelledCoverDeliveries.contains(key) ||
        _coverContext(row, manual: manual) == null) {
      return;
    }
    final job = object(response['job']);
    if (job['id'] != row['jobId'] || job['type'] != 'cover') {
      throw const AgentException('返回的任务标识或类型不匹配。');
    }
    row = {
      ...row,
      'remoteStatus': job['status'],
      'nextCheck': DateTime.now()
          .add(const Duration(seconds: 15))
          .toIso8601String(),
      'errors': 0,
    };
    if ({'failed', 'cancelled'}.contains(job['status'])) {
      row.addAll({
        'state': job['status'],
        'message': '翻唱未完成：${text(job['message'])}',
      });
      await store.put(key, row);
      _replyState(c, s, 'cover-error', text(row['message']), error: true);
      return;
    }
    if (job['status'] != 'completed') {
      await store.put(key, row);
      return;
    }
    if (job['voice_complete'] == false) {
      await store.put(key, {
        ...row,
        'state': 'failed',
        'message': '完整成品超过5MB语音限制，请在翻唱服务器任务列表下载；未用短试听代替。',
      });
      _replyState(
        c,
        s,
        'cover-error',
        text(store.get(key)!['message']),
        error: true,
      );
      return;
    }
    final reply = _coverReply(row, c, s, e);
    if (!reply.ready) {
      final changed = row['state'] != 'waiting_message';
      row.addAll({
        'state': 'waiting_message',
        'message': '翻唱已完成，官机当前无可用回复窗口。请原提问者在本会话发送新消息；有主动消息权限也可在Skill设置开启主动发送。',
      });
      await store.put(key, row);
      if (changed) _replyState(c, s, 'cover-ready', text(row['message']));
      return;
    }
    final value = await _coverCall(row, e, 'audio', audio: true);
    if (value['selection'] is! Map ||
        (object(value['selection'])['duration'] as num? ?? 0) <= 0) {
      throw const AgentException('成品缺少完整范围资料，未发送旧版短试听。');
    }
    final data = value['audioBase64'];
    if (data is! String || data.length > 7 * 1024 * 1024) {
      throw const AgentException('翻唱音频无效或超出发送限制。');
    }
    final audio = AgentAudio(base64Decode(data));
    // The extension/config/connection may have changed while HTTP was in flight.
    if (_cancelledCoverDeliveries.contains(key) ||
        _coverContext(row, manual: manual) == null ||
        store.get(key)?['state'] == 'cancelled') {
      return;
    }
    row.addAll({
      'state': 'sending',
      'attempt': const Uuid().v4(),
      'attemptedAt': DateTime.now().toIso8601String(),
    });
    await store.put(key, row);
    try {
      final receipt = await sendAudio(
        s.key,
        audio.bytes,
        replyMessageId: reply.id,
      );
      await store.put(key, {
        ...row,
        'state': 'sent',
        'receipt': receipt,
        'message': '完整翻唱已自动发送，已取得QQ语音消息回执。',
        'sentAt': DateTime.now().toIso8601String(),
      });
      _replyState(
        c,
        s,
        'cover-sent',
        '翻唱成品已发送。',
        messageId: text(receipt['message_id']),
      );
    } catch (error) {
      final message = describeError(error);
      final rejected =
          error is AgentHttpException &&
              error.statusCode >= 400 &&
              error.statusCode < 500 ||
          RegExp('被动回复窗口|被动回复次数|等待新消息|请先连接|连接已切换|QQBot 已停止').hasMatch(message);
      await store.put(key, {
        ...row,
        'state': rejected
            ? (c.isOfficial ? 'waiting_message' : 'failed')
            : 'uncertain',
        'blockedReplyId': reply.id ?? '@proactive',
        'message': rejected
            ? 'QQ未接受本次发送：$message；请原提问者发送新消息后再试。'
            : '发送回执不明：$message；请先在QQ核对，不会自动重发。',
      });
      _replyState(
        c,
        s,
        'cover-error',
        text(store.get(key)!['message']),
        error: true,
      );
    }
  }

  Future<void> processCoverDeliveries({DateTime? now}) async {
    if (_closed || migrationPaused || !ready || _checkingCoverDeliveries) {
      return;
    }
    _checkingCoverDeliveries = true;
    try {
      final clock = now ?? DateTime.now();
      final rows = store
          .all('agent-cover-delivery')
          .where(
            (row) =>
                {'watching', 'waiting_message'}.contains(row['state']) &&
                !(DateTime.tryParse(text(row['nextCheck'])) ?? clock).isAfter(
                  clock,
                ),
          )
          .toList();
      rows.sort((a, b) => text(a['nextCheck']).compareTo(text(b['nextCheck'])));
      var checked = 0;
      for (var row in rows) {
        final key = text(row['key']);
        if (_closed || migrationPaused) return;
        if (_coverDeliveryInFlight.contains(key)) continue;
        _coverDeliveryInFlight.add(key);
        try {
          final context = _coverContext(row);
          if (context == null) continue;
          if (row['state'] == 'waiting_message' &&
              !_coverReply(row, context.c, context.s, context.e).ready) {
            continue;
          }
          if (checked++ >= 4) break;
          final created = DateTime.tryParse(text(row['created']));
          if (created == null || clock.difference(created).inHours >= 24) {
            await store.put(key, {
              ...row,
              'state': 'failed',
              'message': '自动检查已超过24小时，请在服务器查看任务。',
            });
            continue;
          }
          await _deliverCover(row);
        } catch (error) {
          row = store.get(key) ?? row;
          if (!{'watching', 'waiting_message'}.contains(row['state'])) continue;
          final message = describeError(error),
              count = integer(row['errors'], 0) + 1;
          final backoff = (15 * (1 << count.clamp(0, 4))).clamp(30, 300);
          await store.put(key, {
            ...row,
            'errors': count,
            'message': '检查未完成：$message',
            'nextCheck': clock
                .add(Duration(seconds: backoff))
                .toIso8601String(),
          });
          if (row['message'] != '检查未完成：$message') {
            _log(
              'warning',
              '翻唱后台检查：$message',
              text(row['connectionId']),
              text(row['sessionKey']),
              'cover-delivery',
            );
          }
        } finally {
          _coverDeliveryInFlight.remove(key);
        }
      }
    } finally {
      _checkingCoverDeliveries = false;
    }
  }
}
