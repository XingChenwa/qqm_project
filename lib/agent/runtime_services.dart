part of 'controller.dart';

class _AgentBurstWindow {
  final String connectionId, senderId;
  final DateTime started = DateTime.now();
  final List<AgentMessage> messages = [];
  Timer? timer;
  _AgentBurstWindow(this.connectionId, this.senderId);
}

extension _AgentRuntimeServices on AgentController {
  Future<void> _restartRuntimes() async {
    for (final c in connections.where((c) => connected(c.id))) {
      await _activateRuntime(c);
    }
  }

  String _requestKey(AgentConnection c, String flag) =>
      'plugin-request:${_runtimeScope(c)}:${base64Url.encode(utf8.encode(flag))}';
  Future<void> _dispatchRequest(AgentConnection c, Json raw) async {
    final kind = text(raw['request_type']), flag = text(raw['flag']);
    if (!{'friend', 'group'}.contains(kind) ||
        flag.isEmpty ||
        flag.length > 512 ||
        !qqId(text(raw['user_id']))) {
      return;
    }
    if (store.get(_requestKey(c, flag)) != null) {
      _log('info', '重复的申请事件已忽略，避免重复处理。', c.id, '', 'request');
      return;
    }
    final event = {
      'request_type': kind,
      'self_id': c.selfId,
      'user_id': text(raw['user_id']),
      if (qqId(text(raw['group_id']))) 'group_id': text(raw['group_id']),
      'flag': flag,
      'sub_type': text(raw['sub_type']),
      'comment': clipped(text(raw['comment']), 200),
      'nickname': clipped(text(raw['nickname']), 100),
    };
    for (final e in _runtimeExtensions(c).where(
      (e) => strings(
        object(e.manifest['compatibility'])['providers'],
      ).contains('$kind.request'),
    )) {
      try {
        await _runPackage(
          c,
          e,
          'provider',
          args: {'name': '$kind.request'},
          extra: {'event': event, 'requestEvent': event},
        );
      } catch (error) {
        _log(
          'warning',
          '申请插件未完成：${e.name} · ${describeError(error)}',
          c.id,
          '',
          'request',
        );
      }
      if (store.get(_requestKey(c, flag)) != null) break;
    }
  }

  String _pluginChatKey(AgentSession s) => '${s.kind}:${s.peerId}';
  Future<bool> _offerBurst(
    AgentConnection c,
    AgentSession s,
    AgentMessage m,
  ) async {
    final selected = _runtimeExtensions(c)
        .where(
          (e) => strings(
            object(e.manifest['compatibility'])['providers'],
          ).contains('wake.burst-policy'),
        )
        .toList();
    if (selected.isEmpty || !c.aiEnabled) return false;
    var window = _burstWindows[s.key];
    if (window != null && window.senderId != m.senderId) {
      _flushBurst(c, s, window);
      window = null;
    }
    window ??= _AgentBurstWindow(c.id, m.senderId);
    final epoch = _epochs[c.id] ?? 0;
    var wait = 0;
    try {
      for (final e in selected) {
        final result = await _runPackage(
          c,
          e,
          'provider',
          args: {'name': 'wake.burst-policy'},
          s: s,
          trigger: m,
          extra: {
            'entry': _entry(m),
            'meta': {
              'senderId': window.senderId,
              'startedAt': window.started.millisecondsSinceEpoch,
              'windowMs': c.batchWindowMs,
              'elapsedMs': DateTime.now()
                  .difference(window.started)
                  .inMilliseconds,
            },
          },
        );
        wait = integer(object(result['value'])['extendMs'], 0).clamp(0, 5000);
        if (wait > 0) break;
      }
    } catch (error) {
      _log(
        'warning',
        '连发策略未完成，按普通消息处理：${describeError(error)}',
        c.id,
        s.key,
        'plugin',
      );
    }
    if (_closed || !connected(c.id) || (_epochs[c.id] ?? 0) != epoch) {
      return true;
    }
    if (wait <= 0 && window.messages.isEmpty) return false;
    window.messages.add(m);
    _burstWindows[s.key] = window;
    window.timer?.cancel();
    final remaining =
        12000 - DateTime.now().difference(window.started).inMilliseconds;
    if (wait <= 0 || remaining <= 0 || window.messages.length >= 20) {
      _flushBurst(c, s, window);
    } else {
      final pending = window;
      window.timer = Timer(
        Duration(milliseconds: wait.clamp(1, remaining)),
        () => _flushBurst(c, s, pending),
      );
      _replyState(
        c,
        s,
        'batching',
        '正在等待同一用户的后续消息（已合并 ${window.messages.length} 条）。',
        messageId: m.id,
        log: false,
      );
    }
    return true;
  }

  void _flushBurst(
    AgentConnection c,
    AgentSession s,
    _AgentBurstWindow window,
  ) {
    if (!identical(_burstWindows[s.key], window)) return;
    _burstWindows.remove(s.key);
    window.timer?.cancel();
    final fresh = session(s.key);
    if (fresh == null ||
        fresh.paused ||
        !connected(c.id) ||
        window.messages.isEmpty) {
      return;
    }
    _enqueue(c, fresh, window.messages.last, batch: List.of(window.messages));
  }

  Future<void> _recordRunUsage(
    AgentConnection c,
    AgentSession s,
    AgentMessage trigger,
    AgentTurn turn,
    AgentProvider provider,
    Json usage,
  ) async {
    if (!usage.containsKey('prompt_tokens') &&
        !usage.containsKey('completion_tokens')) {
      return;
    }
    final key =
        '${turn.started.microsecondsSinceEpoch}:${s.key}:${provider.id}';
    final id = _usageRunIds.putIfAbsent(key, () => const Uuid().v4());
    if (_usageRunIds.length > 1000) {
      _usageRunIds.remove(_usageRunIds.keys.first);
    }
    final previous = store.get('usage-run:$id'),
        old = object(previous?['usage']);
    final input = integer(usage['prompt_tokens'], 0).clamp(0, 10000000),
        output = integer(usage['completion_tokens'], 0).clamp(0, 10000000);
    final cached = integer(
      object(usage['prompt_tokens_details'])['cached_tokens'] ??
          usage['prompt_cache_hit_tokens'],
      0,
    ).clamp(0, input);
    final totals = {
      'promptTokens': integer(old['promptTokens'], 0) + input,
      'completionTokens': integer(old['completionTokens'], 0) + output,
      'cachedTokens': integer(old['cachedTokens'], 0) + cached,
      'totalTokens': integer(old['totalTokens'], 0) + input + output,
      'calls': integer(old['calls'], 0) + 1,
    };
    await store.put('usage-run:$id', {
      'id': id,
      'connectionId': c.id,
      'selfId': c.selfId,
      'chatKey': s.key,
      'startedAt': turn.started.millisecondsSinceEpoch,
      'model': provider.model,
      'vendor': provider.id,
      'usage': totals,
      'trigger': [
        for (final item in _batchContexts[s.key] ?? [trigger])
          {
            'senderId': item.senderId,
            'senderName': item.senderName,
            'atMe':
                item.addressed ||
                item.segments.any(
                  (seg) =>
                      seg['type'] == 'at' &&
                      text(object(seg['data'])['qq']) == c.selfId,
                ),
            'text': '',
          },
      ],
    });
    final rows = store.all('usage-run');
    if (rows.length > 2000) {
      rows.sort(
        (a, b) =>
            integer(a['startedAt'], 0).compareTo(integer(b['startedAt'], 0)),
      );
      for (final row in rows.take(rows.length - 2000)) {
        await store.remove('usage-run:${row['id']}');
      }
    }
  }

  Future<Json> _pluginRequestParameters(
    AgentConnection c,
    List<AgentExtension> selected,
    Json request,
    AgentSession s,
    AgentMessage trigger,
    AgentTurn turn,
  ) async {
    var body = request;
    for (final e in selected.where(
      (e) => strings(
        object(e.manifest['compatibility'])['providers'],
      ).contains('llm.request-params'),
    )) {
      final context = _runtimeInput(c, e, s: s, trigger: trigger, turn: turn);
      final value = await _runPackage(
        c,
        e,
        'provider',
        args: {'name': 'llm.request-params'},
        s: s,
        trigger: trigger,
        turn: turn,
        extra: {'body': body, 'context': context},
      );
      final replacement = object(object(value['value'])['body']);
      if (replacement['tools'] is List) {
        final allowed = {
          for (final tool in (body['tools'] as List? ?? []))
            text(object(object(tool)['function'])['name']): object(tool),
        };
        final tools = (replacement['tools'] as List).map(object).toList();
        if (tools.every(
          (t) => allowed.containsKey(text(object(t['function'])['name'])),
        )) {
          body = {
            ...body,
            'tools': tools
                .map((t) => allowed[text(object(t['function'])['name'])])
                .toList(),
          };
        }
      }
      if ({'auto', 'none', 'required'}.contains(replacement['tool_choice'])) {
        body = {...body, 'tool_choice': replacement['tool_choice']};
      }
      if (replacement['parallel_tool_calls'] is bool) {
        body = {
          ...body,
          'parallel_tool_calls': replacement['parallel_tool_calls'],
        };
      } else {
        body = {...body}..remove('parallel_tool_calls');
      }
    }
    return body;
  }

  String _runtimeScope(AgentConnection c) =>
      '${c.protocol}:${c.id}:${c.selfId}';
  List<AgentExtension> _runtimeExtensions(
    AgentConnection c, [
    AgentPreset? preset,
  ]) {
    final selected =
        preset ?? presets.where((p) => p.id == c.presetId).firstOrNull;
    final ids = {...c.pluginIds, ...?selected?.skillIds};
    return extensions
        .where((e) => e.enabled && e.isJavaScript && ids.contains(e.id))
        .toList();
  }

  bool _runtimeAlive(AgentConnection c, AgentExtension e) =>
      !_closed &&
      connected(c.id) &&
      connection(c.id)?.selfId == c.selfId &&
      extensions.any((x) => x.id == e.id && x.enabled);

  Json _entry(AgentMessage m) => {
    'id': m.id.replaceFirst('ob:', ''),
    'mid': m.id.replaceFirst('ob:', ''),
    'senderId': m.senderId,
    'senderName': m.senderName,
    'self': m.outgoing,
    'atMe':
        m.addressed ||
        m.segments.any(
          (s) =>
              s['type'] == 'at' &&
              text(object(s['data'])['qq']) == session(m.sessionKey)?.selfId,
        ),
    'text': clipped(
      m.inputText.replaceAll('@${session(m.sessionKey)?.selfId} ', ''),
      4000,
    ),
    'content': clipped(
      m.inputText.replaceAll('@${session(m.sessionKey)?.selfId} ', ''),
      4000,
    ),
    'ts': m.time.millisecondsSinceEpoch,
    'media': m.segments
        .where((seg) => seg['type'] == 'image')
        .map(
          (seg) => {
            'kind': 'image',
            if (text(object(seg['data'])['url']).isNotEmpty)
              'url': text(object(seg['data'])['url']),
            if (!text(
              object(seg['data'])['file'],
            ).startsWith(RegExp(r'(?:base64://|file:|[A-Za-z]:|/)')))
              'file': text(object(seg['data'])['file']),
          },
        )
        .toList(),
    'segments': m.segments
        .where(
          (s) =>
              s['type'] != 'record' ||
              !text(object(s['data'])['file']).startsWith('base64://'),
        )
        .map(
          (s) => {
            ...s,
            if (s['type'] == 'image')
              'data': {...object(s['data'])}..remove('file'),
          },
        )
        .toList(),
  };
  Json _sentEntry(AgentMessage m) => {
    'type': m.segments.any((s) => s['type'] == 'record')
        ? 'record'
        : m.segments.any((s) => s['type'] == 'image')
        ? 'image'
        : 'text',
    'text': m.plain,
    'at': m.time.millisecondsSinceEpoch,
    'message_id': m.id,
  };
  Json _runtimeInput(
    AgentConnection c,
    AgentExtension e, {
    AgentSession? s,
    AgentMessage? trigger,
    AgentTurn? turn,
    Json extra = const {},
  }) {
    final entries = s == null ? <AgentMessage>[] : store.messages(s.key);
    final rows = s == null
        ? <Json>[]
        : store
              .all('usage-run')
              .where(
                (r) =>
                    r['connectionId'] == c.id &&
                    r['selfId'] == c.selfId &&
                    r['chatKey'] == s.key,
              )
              .take(2000)
              .toList();
    final prices = <String, Json>{};
    for (final provider in providers.where(
      (p) => p.inputPrice != null && p.outputPrice != null,
    )) {
      final price = {
        'in': provider.inputPrice,
        'out': provider.outputPrice,
        'cached': provider.cachedPrice ?? provider.inputPrice,
        'source': 'custom',
      };
      prices['${provider.id}/${provider.model}'] = price;
      prices.putIfAbsent(provider.model, () => price);
    }
    final selected = _runtimeExtensions(
      c,
      s == null
          ? null
          : presets
                .where(
                  (p) => p.id == (s.presetId.isEmpty ? c.presetId : s.presetId),
                )
                .firstOrNull,
    );
    final chosenPreset = presets
        .where(
          (p) =>
              p.id ==
              (s == null || s.presetId.isEmpty ? c.presetId : s.presetId),
        )
        .firstOrNull;
    final modelTools = providers.any(
      (p) => p.id == chosenPreset?.providerId && p.tools,
    );
    final ledgerReady =
        rows.every((r) => prices.containsKey('${r['vendor']}/${r['model']}')) &&
        providers.any((p) => p.inputPrice != null && p.outputPrice != null);
    final available = [
      if (modelTools) ...[
        for (final x in selected)
          if (!strings(
                object(x.manifest['compatibility'])['requirements'],
              ).contains('usageLedger') ||
              ledgerReady)
            ...x.tools.map((t) => text(t['name'])),
        'finish',
      ],
    ];
    final turnId = turn == null
        ? ''
        : '${turn.started.microsecondsSinceEpoch}-${s?.key ?? c.id}';
    return {
      'protocol': c.protocol,
      'selfId': c.selfId,
      'selfInfo': {'user_id': c.selfId, 'nickname': nickname(c.id)},
      'kind': s?.kind ?? '',
      'chatKey': s == null ? '' : _pluginChatKey(s),
      'chatId': s?.peerId ?? '',
      'chatName': s?.name ?? '',
      'sessionId': turnId,
      'triggerEntries':
          (s == null ? <AgentMessage>[] : _batchContexts[s.key] ?? [?trigger])
              .map(_entry)
              .toList(),
      'recentEntries': entries
          .skip((entries.length - 100).clamp(0, entries.length))
          .map(_entry)
          .toList(),
      'session': {
        'id': turnId,
        'trigger':
            (s == null ? <AgentMessage>[] : _batchContexts[s.key] ?? [?trigger])
                .map(_entry)
                .toList(),
        'sent': entries
            .where(
              (m) =>
                  m.outgoing &&
                  (turn == null || !m.time.isBefore(turn.started)),
            )
            .map(_sentEntry)
            .toList(),
      },
      'coreConfig': {
        'snowluma': {
          'httpUrl': 'http://qqm-onebot.invalid',
          'httpAccessToken': '',
        },
      },
      'hostConfig': {
        'tools': {'enabled': modelTools},
        'persona': {'selfNickname': nickname(c.id), 'botName': nickname(c.id)},
        'modelPrices': prices,
        'ledgerReady': ledgerReady,
      },
      'availableTools': available,
      'ledger': rows
          .map((r) => {...r, 'chatKey': s == null ? '' : _pluginChatKey(s)})
          .toList(),
      'capabilities': selected
          .expand(
            (x) => strings(object(x.manifest['compatibility'])['providers']),
          )
          .toSet()
          .toList(),
      ...extra,
    };
  }

  Future<Json> _runPackage(
    AgentConnection c,
    AgentExtension e,
    String operation, {
    Json args = const {},
    AgentSession? s,
    AgentMessage? trigger,
    AgentTurn? turn,
    Json extra = const {},
    void Function()? onSent,
  }) async {
    await store.settled();
    final epoch = _epochs[c.id] ?? 0;
    bool active() => _runtimeAlive(c, e) && (turn == null || turn.active);
    final input = _runtimeInput(
      c,
      e,
      s: s,
      trigger: trigger,
      turn: turn,
      extra: extra,
    );
    if (operation == 'tool') {
      final requirements = strings(
        object(e.manifest['compatibility'])['requirements'],
      );
      if (requirements.contains('onebot') && c.isOfficial) {
        throw const AgentException('此工具需要 OneBot 连接。');
      }
      if (requirements.contains('usageLedger') &&
          object(input['hostConfig'])['ledgerReady'] != true) {
        throw const AgentException(
          '请先在 AI 模型高级设置填写输入 / 输出价格，再查询真实费用；未配置的费用不会按 0 元计算。',
        );
      }
    }
    var mediaReceipts = 0;
    final outcome = await packages.run(
      manifest: e.manifest,
      settings: e.config,
      operation: operation,
      scope: _runtimeScope(c),
      args: args,
      input: input,
      active: active,
      cancel: turn?.cancel,
      runtimeActive: () => _runtimeAlive(c, e) && (_epochs[c.id] ?? 0) == epoch,
      persistent: true,
      sourceRevision: store.version('extension').toString(),
      hostCall: _runtimeHost(
        c,
        e,
        s,
        trigger,
        turn,
        onSent: onSent,
        onMediaSent: () => mediaReceipts++,
        epoch: epoch,
        requestEvent: object(extra['requestEvent']),
        capabilityPath: strings(extra['_capabilityPath']),
      ),
      sendImage: s == null
          ? null
          : (bytes, name) async {
              final r = await sendImage(
                s.key,
                bytes,
                name: name,
                turn: turn,
                replyMessageId: trigger?.id,
              );
              onSent?.call();
              return r;
            },
      sendText: s == null
          ? null
          : (message) async {
              await send(
                s.key,
                message,
                source: 'plugin',
                turn: turn,
                replyMessageId: trigger?.id,
              );
              onSent?.call();
              return {'ok': true};
            },
      sendMedia: s == null
          ? null
          : (bytes, name, type) async {
              final r = await sendAudio(
                s.key,
                bytes,
                turn: turn,
                replyMessageId: trigger?.id,
              );
              mediaReceipts++;
              onSent?.call();
              return r;
            },
    );
    final declaredAck = e.tools
        .where((t) => object(t['handler'])['id'] == args['id'])
        .map((t) => t['requiresMediaAck'])
        .firstOrNull;
    final needsMediaAck =
        operation == 'tool' &&
        (declaredAck is bool
            ? declaredAck
            : strings(
                object(e.manifest['compatibility'])['requirements'],
              ).contains('media'));
    if (needsMediaAck && mediaReceipts == 0 && outcome['isError'] != true) {
      return {
        'isError': true,
        'content': '语音工具没有取得发送回执。请检查运行日志中的服务错误；本轮未确认发送语音。',
      };
    }
    final redacted = object(
      redactAgentValue(outcome, [
        ...e.privateSettingValues,
        ...e.secrets.values,
      ]),
    );
    if (operation == 'tool' && redacted['isError'] == true) {
      final content = text(redacted['content'] ?? redacted['text']);
      final status = RegExp(
        r'\bHTTP\s*(\d{3})\b',
        caseSensitive: false,
      ).firstMatch(content)?[1];
      final isVoice = needsMediaAck;
      if (isVoice && status == '503') {
        final message =
            '语音合成服务暂不可用（HTTP 503）。本轮没有取得语音发送回执；请稍后重试，或在插件设置检查 / 更换可用的合成服务地址。';
        _log('warning', message, c.id, s?.key ?? '', 'tool-result');
        return {...redacted, 'content': message};
      }
      _log(
        'warning',
        '工具返回错误：${e.name} / ${text(args['id'])}${status == null ? '' : '（HTTP $status）'}。',
        c.id,
        s?.key ?? '',
        'tool-result',
      );
    }
    return redacted;
  }

  Future<void> _activateRuntime(AgentConnection c) async {
    for (final e in _runtimeExtensions(c)) {
      try {
        await _runPackage(c, e, 'activate');
      } catch (error) {
        _log(
          'warning',
          '插件启动失败：${e.name} · ${describeError(error)}',
          c.id,
          '',
          'plugin',
        );
      }
    }
  }

  Future<Json> _runHooks(
    AgentConnection c,
    List<AgentExtension> selected,
    String name,
    Json data,
    AgentSession s,
    AgentMessage trigger,
    AgentTurn turn, {
    void Function()? onSent,
  }) async {
    var value = data;
    for (final e in selected.where(
      (e) =>
          strings(object(e.manifest['compatibility'])['hooks']).contains(name),
    )) {
      turn.check();
      final result = await _runPackage(
        c,
        e,
        'hook',
        args: {'name': name},
        s: s,
        trigger: trigger,
        turn: turn,
        extra: value,
        onSent: onSent,
      );
      final decision = object(result['result']);
      if (decision['block'] == true) {
        throw AgentException(
          text(decision['reason']).isEmpty
              ? '插件阻止了此工具操作。'
              : text(decision['reason']),
        );
      }
      value = {
        ...value,
        if (result['messages'] is List) 'messages': result['messages'],
        if (result['response'] is Map) 'response': result['response'],
      };
    }
    return value;
  }

  AgentHostCall _runtimeHost(
    AgentConnection c,
    AgentExtension e,
    AgentSession? s,
    AgentMessage? trigger,
    AgentTurn? turn, {
    void Function()? onSent,
    void Function()? onMediaSent,
    int? epoch,
    Json requestEvent = const {},
    List<String> capabilityPath = const [],
  }) => (operation, args) async {
    if (!_runtimeAlive(c, e) ||
        (epoch != null && (_epochs[c.id] ?? 0) != epoch)) {
      throw const AgentException('机器人连接或插件已停止。');
    }
    turn?.check();
    switch (operation) {
      case 'sendMediaUrl':
        if (s == null ||
            !{s.key, _pluginChatKey(s)}.contains(text(args['chatKey']))) {
          throw const AgentException('插件只能向当前会话发送 URL 语音。');
        }
        final receipt = await sendAudioUrl(
          s.key,
          text(args['url']),
          turn: turn,
          replyMessageId: trigger?.id,
        );
        onMediaSent?.call();
        onSent?.call();
        return receipt;
      case 'log':
        _log(
          {'info', 'warning', 'error'}.contains(args['level'])
              ? text(args['level'])
              : 'info',
          '[${e.name}] ${text(args['text'])}',
          c.id,
          s?.key ?? '',
          'plugin',
        );
        return null;
      case 'validateImageUrl':
        await _validatePluginImage(text(args['url']));
        return text(args['url']);
      case 'updateConfig':
        final name = text(
          object(object(args['value'])['persona'])['selfNickname'],
        );
        if (name.isEmpty || name.length > 100) {
          throw const AgentException('仅允许同步当前机器人的显示昵称。');
        }
        await store.put('self-name:${c.id}:${c.selfId}', {'name': name});
        _changed();
        return {'ok': true};
      case 'sendText':
        final target = text(args['chatKey']);
        AgentSession? destination =
            s != null && (s.key == target || _pluginChatKey(s) == target)
            ? s
            : null;
        if (destination == null &&
            turn == null &&
            text(e.config['notifyChatKey']).isNotEmpty) {
          destination = sessions(c.id)
              .where(
                (x) =>
                    (x.key == target || _pluginChatKey(x) == target) &&
                    (target == e.config['notifyChatKey'] ||
                        '${x.kind}:${x.peerId}' == e.config['notifyChatKey']),
              )
              .firstOrNull;
        }
        if (destination == null) {
          throw const AgentException('插件只能发送到当前会话或明确配置的通知会话。');
        }
        await send(
          destination.key,
          text(args['text']),
          source: 'plugin',
          turn: turn,
          replyMessageId: trigger?.id,
        );
        onSent?.call();
        return {
          'ok': true,
          'message_id': store.messages(destination.key).last.id,
        };
      case 'onebot':
        return _pluginOneBot(
          c,
          e,
          s,
          trigger,
          turn,
          args,
          requestEvent: requestEvent,
        );
      case 'notify':
        if (requestEvent.isNotEmpty) {
          final attempted = store.get(
            _requestKey(c, text(requestEvent['flag'])),
          );
          if (attempted != null && attempted['status'] != 'acknowledged') {
            throw const AgentException('申请尚未获得处理回执，不发送已同意 / 拒绝的通知。');
          }
        }
        final peer = text(args['peer']);
        final owners = text(
          e.config['ownerIds'],
        ).split(RegExp(r'[,，\s]+')).toSet();
        if (c.isOfficial ||
            args['kind'] != 'private' ||
            !owners.contains(peer) ||
            !qqId(peer)) {
          throw const AgentException('此插件未配置这个通知收件人。');
        }
        final destination = await openSession(c.id, 'private', peer);
        await send(destination.key, text(args['text']), source: 'plugin');
        return {'ok': true};
      case 'capability':
        final name = text(args['name']);
        final target = _runtimeExtensions(c)
            .where(
              (x) => strings(
                object(x.manifest['compatibility'])['providers'],
              ).contains(name),
            )
            .firstOrNull;
        if (target == null ||
            target.id == e.id ||
            capabilityPath.contains(target.id) ||
            capabilityPath.length >= 4) {
          throw const AgentException('该插件能力未启用，或出现循环调用。');
        }
        final values = args['args'] as List? ?? [];
        final result = await _runPackage(
          c,
          target,
          'capability',
          args: {
            'name': name,
            if (text(args['method']).isNotEmpty) 'method': args['method'],
            'values': values,
          },
          s: s,
          trigger: trigger,
          turn: turn,
          extra: {
            ...(values.isEmpty ? <String, dynamic>{} : object(values.first)),
            '_capabilityPath': [...capabilityPath, e.id],
          },
        );
        return result['value'];
      default:
        throw const AgentException('此插件宿主操作不可用。');
    }
  };

  Future<void> _validatePluginImage(String value) async {
    await http.validatePublicUri(httpEndpoint(value));
  }

  Future<Object?> _pluginOneBot(
    AgentConnection c,
    AgentExtension e,
    AgentSession? s,
    AgentMessage? trigger,
    AgentTurn? turn,
    Json args, {
    Json requestEvent = const {},
  }) async {
    if (c.isOfficial) {
      throw const AgentException('此账号操作需要 OneBot 连接；QQBot 官方协议没有对应接口。');
    }
    final action = text(args['action']), params = object(args['params']);
    if ({'set_friend_add_request', 'set_group_add_request'}.contains(action)) {
      final kind = text(requestEvent['request_type']);
      final flag = text(requestEvent['flag']);
      if (flag.isEmpty ||
          params['flag'] != flag ||
          action != 'set_${kind}_add_request' ||
          params['approve'] is! bool ||
          (kind == 'group' && params['sub_type'] != requestEvent['sub_type'])) {
        throw const AgentException('申请操作必须对应本次收到的真实事件。');
      }
      Set<String> ids(String name) =>
          text(e.config[name]).split(RegExp(r'[,，、\s]+')).where(qqId).toSet();
      final targets = {
        text(requestEvent['user_id']),
        text(requestEvent['group_id']),
      };
      final deny = ids('denyList'), allow = ids('allowList');
      final rejected = targets.any(deny.contains);
      final permitted =
          rejected ||
          (e.config[kind == 'friend'
                      ? 'autoApproveFriend'
                      : 'autoApproveGroup'] ==
                  true &&
              (allow.isEmpty || targets.any(allow.contains)));
      if (!permitted || params['approve'] != !rejected) {
        throw const AgentException('申请处理不符合插件设置中的开关和名单。');
      }
      final key = _requestKey(c, flag);
      final previous = store.get(key);
      if (previous != null) {
        if (previous['status'] == 'acknowledged') {
          return {'ok': true, 'duplicate': true};
        }
        throw const AgentException('此申请已经尝试处理，结果尚未确认，请在 QQ 中核实；不会自动重试。');
      }
      await store.put(key, {
        'status': 'pending',
        'at': DateTime.now().toIso8601String(),
        'extensionId': e.id,
      });
      try {
        final result = await _transports[c.id]!.call(action, {
          'flag': flag,
          'approve': params['approve'],
          if (kind == 'group') 'sub_type': requestEvent['sub_type'],
          if (kind == 'group') 'reason': clipped(text(params['reason']), 200),
        });
        await store.put(key, {
          'status': 'acknowledged',
          'at': DateTime.now().toIso8601String(),
          'extensionId': e.id,
        });
        _log(
          'info',
          '${kind == 'friend' ? '好友' : '群'}申请已取得${params['approve'] == true ? '同意' : '拒绝'}回执。',
          c.id,
          '',
          'request',
        );
        return result;
      } catch (error) {
        await store.put(key, {
          'status': 'unknown',
          'at': DateTime.now().toIso8601String(),
          'extensionId': e.id,
        });
        _log('warning', '申请处理未取得回执，请在 QQ 中核实结果。', c.id, '', 'request');
        rethrow;
      }
    }
    const reads = {
      'get_login_info',
      'get_stranger_info',
      'get_qzone_msg_list',
      'get_image',
      'ocr_image',
    };
    const writes = {'send_qzone_msg', 'set_qq_profile', 'set_qq_avatar'};
    if (!reads.contains(action) && !writes.contains(action)) {
      throw const AgentException('插件不允许调用这个 OneBot 接口。');
    }
    if (action == 'get_stranger_info' && text(params['user_id']) != c.selfId) {
      throw const AgentException('只能查询机器人自己的资料。');
    }
    if (params.containsKey('user_id') && text(params['user_id']) != c.selfId) {
      throw const AgentException('插件不能操作其他 QQ 用户。');
    }
    if (action == 'get_qzone_msg_list' &&
        (integer(params['pos'], -1) < 0 ||
            integer(params['num'], 0) < 1 ||
            integer(params['num'], 0) > 20)) {
      throw const AgentException('空间读取范围无效。');
    }
    if (action == 'get_image' || action == 'ocr_image') {
      final value = text(params[action == 'get_image' ? 'file' : 'image']);
      final known = s == null
          ? <String>{}
          : store
                .messages(s.key)
                .expand((m) => m.segments)
                .where((seg) => seg['type'] == 'image')
                .expand(
                  (seg) => [
                    text(object(seg['data'])['file']),
                    text(object(seg['data'])['url']),
                  ],
                )
                .where((v) => v.isNotEmpty && !v.startsWith('base64://'))
                .toSet();
      if (!known.contains(value)) await _validatePluginImage(value);
      if (value.isEmpty ||
          value.length > 8192 ||
          value.startsWith('file:') ||
          value.startsWith('base64://')) {
        throw const AgentException('仅允许读取当前会话图片或公共图片链接。');
      }
    }
    if (writes.contains(action)) {
      final permission = action == 'send_qzone_msg'
          ? 'allowPublish'
          : action == 'set_qq_avatar'
          ? 'allowAvatar'
          : 'allowProfile';
      if (e.config[permission] == false || e.config['dryRun'] == true) {
        throw const AgentException('对应写入功能已关闭或处于演练模式。');
      }
      if (jsonEncode(params).length > 32000) {
        throw const AgentException('资料操作参数过大。');
      }
      if (action == 'set_qq_avatar') {
        await _validatePluginImage(text(params['file']));
      }
      if (action == 'set_qq_profile') {
        if (params.isEmpty ||
            params.keys.any(
              (k) => !{'nickname', 'personal_note', 'sex'}.contains(k),
            ) ||
            (params['nickname'] != null &&
                (text(params['nickname']).trim().isEmpty ||
                    text(params['nickname']).runes.length > 16)) ||
            (params['personal_note'] != null &&
                text(params['personal_note']).runes.length > 80) ||
            (params['sex'] != null && !{0, 1, 2}.contains(params['sex']))) {
          throw const AgentException('昵称、签名或性别参数无效。');
        }
      }
      if (action == 'send_qzone_msg') {
        if (text(params['content']).length > 5000 ||
            ![1, 4, 64].contains(params['ugc_right'])) {
          throw const AgentException('空间内容或可见范围无效。');
        }
        if (params['images'] != null &&
            (params['images'] is! List ||
                (params['images'] as List).length > 9)) {
          throw const AgentException('空间图片最多 9 张。');
        }
        for (final url in strings(params['images']).take(10)) {
          await _validatePluginImage(url);
        }
      }
    }
    turn?.check();
    return _transports[c.id]!.call(action, params);
  }
}
