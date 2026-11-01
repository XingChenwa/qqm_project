part of 'controller.dart';

extension AgentBuiltinServices on AgentController {
  Json builtinData(String connectionId) {
    final c = connection(connectionId);
    if (c == null) {
      return {
        'memories': <Json>[],
        'reminders': <Json>[],
        'stickers': <Json>[],
        'feedback': <Json>[],
      };
    }
    final signature =
        '${c.protocol}:${c.selfId}:${store.version('session')}:${store.version('agent-memory')}:${store.version('agent-reminder')}:${store.version('agent-stickers')}:${store.version('agent-feedback')}';
    final cached = _builtinOverviewCache[connectionId];
    if (cached?.signature == signature) return cached!.value;
    final chats = sessions(
      c.id,
    ).where((s) => s.protocol == c.protocol && s.selfId == c.selfId).toList();
    final keys = chats.map((s) => s.key).toSet();
    final value = <String, dynamic>{
      'memories': [
        for (final s in chats)
          for (final row
              in (store.get(_builtinKey(c, 'memory', s.key))?['items']
                          as List? ??
                      [])
                  .map(object))
            {...row, 'chatKey': s.key, 'chatName': s.name},
      ],
      'reminders': store
          .all('agent-reminder')
          .where(
            (row) =>
                row['connectionId'] == c.id &&
                row['selfId'] == c.selfId &&
                keys.contains(row['chatKey']),
          )
          .toList(),
      'stickers':
          store.get(_builtinKey(c, 'stickers'))?['items'] as List? ?? [],
      'feedback': store
          .all('agent-feedback')
          .where((row) => keys.contains(row['chatKey']))
          .take(100)
          .toList(),
    };
    if (_builtinOverviewCache.length > 10) _builtinOverviewCache.clear();
    _builtinOverviewCache[connectionId] = (signature: signature, value: value);
    return value;
  }

  Uint8List? builtinStickerBytes(String connectionId, String id) {
    final c = connection(connectionId);
    if (c == null ||
        !(builtinData(connectionId)['stickers'] as List)
            .map(object)
            .any((row) => row['id'] == id)) {
      return null;
    }
    final encoded = text(
      store.get('${_builtinKey(c, 'stickers')}:$id')?['bytes'],
    );
    return encoded.isEmpty ? null : base64Decode(encoded);
  }

  /// Local operator controls. The UI asks before deleting these scoped entries.
  Future<void> removeBuiltinData(
    String connectionId,
    String category,
    String id,
  ) async {
    final c = connection(connectionId);
    if (c == null ||
        !{'memories', 'reminders', 'stickers', 'feedback'}.contains(category)) {
      throw const AgentException('记录类型或机器人不存在。');
    }
    final row = (builtinData(connectionId)[category] as List)
        .map(object)
        .where((row) => row['id'] == id)
        .firstOrNull;
    if (row == null) throw const AgentException('当前机器人没有这条记录。');
    if (category == 'memories' || category == 'stickers') {
      final key = _builtinKey(
        c,
        category == 'memories' ? 'memory' : 'stickers',
        category == 'memories' ? text(row['chatKey']) : '',
      );
      final rows = (store.get(key)?['items'] as List? ?? [])
          .map(object)
          .where((item) => item['id'] != id)
          .toList();
      await store.put(key, {'items': rows});
      if (category == 'stickers') await store.remove('$key:$id');
    } else if (category == 'reminders') {
      if (row['status'] == 'sending') {
        throw const AgentException('此提醒正在发送，请等待回执后操作。');
      }
      await store.put('agent-reminder:$id', {...row, 'status': 'cancelled'});
    } else {
      await store.remove('agent-feedback:$id');
    }
    _changed();
  }

  String _builtinKey(AgentConnection c, String section, [String chat = '']) =>
      'agent-$section:${base64Url.encode(utf8.encode('${c.protocol}:${c.id}:${c.selfId}|$chat'))}';

  String _builtinUser(
    AgentConnection c,
    AgentSession s,
    AgentMessage? trigger,
    String requested,
  ) {
    final id = requested.isEmpty
        ? (trigger?.senderId ?? (s.kind == 'private' ? s.peerId : ''))
        : requested;
    final known = {
      c.selfId,
      if (s.kind == 'private') s.peerId,
      if (trigger != null) trigger.senderId,
      ...store.messages(s.key).map((m) => m.senderId),
      ...store
          .messages(s.key)
          .expand((m) => m.segments)
          .where((seg) => seg['type'] == 'at')
          .map((seg) => text(object(seg['data'])['qq'])),
    }..remove('all');
    if (id.isEmpty || !known.contains(id) || !c.acceptsPeer(id)) {
      throw const AgentException('只能选择当前会话出现过的真实用户ID，请先查询活跃成员。');
    }
    return id;
  }

  AgentMessage _builtinMessage(
    AgentSession s,
    AgentMessage? trigger,
    String id,
  ) {
    if (id.isEmpty && trigger != null && trigger.sessionKey == s.key) {
      return trigger;
    }
    final raw = id.replaceFirst(RegExp(r'^ob:'), '');
    final message = store
        .messages(s.key)
        .where((m) => m.id == id || m.id == 'ob:$raw')
        .firstOrNull;
    if (message == null) {
      throw const AgentException('当前会话没有这条消息，请用历史工具返回的真实消息ID。');
    }
    return message;
  }

  Json _builtinMessageView(AgentMessage m, {bool context = true}) => {
    'messageId': m.id,
    'senderId': m.senderId,
    'senderName': m.senderName,
    'time': m.time.toIso8601String(),
    'outgoing': m.outgoing,
    'text': clipped(m.inputText, 4000),
    if (context && m.quotedContext.isNotEmpty)
      'quotedContext': clipped(m.quotedContext, 6000),
    'attachments': [
      for (final seg in m.segments.where(
        (seg) => {'image', 'record', 'video', 'file'}.contains(seg['type']),
      ))
        {
          'type': seg['type'],
          'name': object(seg['data'])['name'],
          'url': object(seg['data'])['url'],
        },
    ],
  };

  List<Json> _builtinImages(AgentMessage m, AgentPreset p) => [
    ...m.segments.where((seg) => seg['type'] == 'image'),
    if (p.readMessageContext) ...m.contextImages,
  ];

  String _builtinAvatar(AgentConnection c, String userId) {
    if (c.isOfficial) {
      if (userId == c.selfId) {
        throw const AgentException('AppID不是机器人用户OpenID，平台未提供机器人头像。');
      }
      final url = qqOpenIdAvatar(c.selfId, userId);
      if (url.isEmpty) throw const AgentException('平台未提供可用的用户OpenID。');
      return url;
    }
    if (!qqId(userId)) throw const AgentException('用户QQ号无效。');
    return Uri.https('q1.qlogo.cn', '/g', {
      'b': 'qq',
      'nk': userId,
      's': '640',
    }).toString();
  }

  /// Fixed operations, bound to one stored connection/session. No credentials or
  /// arbitrary protocol calls are accepted from a model or imported package.
  Future<Json> executeBuiltinTool(
    String sessionKey,
    String name,
    Json args, {
    AgentMessage? trigger,
    AgentPreset? preset,
    AgentTurn? turn,
  }) async {
    final s = session(sessionKey);
    if (s == null) throw const AgentException('会话不存在。');
    _validateSession(s);
    final c = connection(s.connectionId)!;
    final p =
        preset ?? AgentPreset(id: 'builtin', name: '内置能力', prompt: '使用真实工具结果');
    final defs = agentBuiltinDefinitions(
      preset: p,
      official: c.isOfficial,
      vision: true,
      video: canReadVideo(p),
    );
    final definition = defs.where((d) => d['name'] == name).firstOrNull;
    if (definition == null) throw const AgentException('当前预设或协议未启用此内置能力。');
    validateArguments(args, object(definition['parameters']));
    if (trigger != null &&
        (trigger.sessionKey != s.key ||
            trigger.outgoing ||
            trigger.senderIsBot)) {
      throw const AgentException('当前触发消息的身份或会话不匹配。');
    }
    final epoch = _epochs[c.id] ?? 0;
    void check() {
      turn?.check();
      if (_closed || (_epochs[c.id] ?? 0) != epoch) {
        throw const AgentException('机器人已切换或停止，取消旧操作。');
      }
    }

    check();
    final history = store.messages(s.key);
    final cancel = turn?.cancel ?? CancelToken();
    Json result(Object? value) => {
      'text': value is String ? value : jsonEncode(value),
    };
    Future<AgentMessage> resolveMessage(AgentMessage message) async {
      if (c.isOfficial) return message;
      final expanded = await _readOneBotRecords(
        c,
        s,
        [message],
        1,
        turn ?? AgentTurn(() => !_closed && connected(c.id)),
        readRecords: p.readMessageContext,
      );
      check();
      final resolved = expanded.single;
      await store.updateMessage(
        s.key,
        resolved.id,
        (old) => old.copyWith(segments: resolved.segments),
      );
      return resolved;
    }

    Future<Json> sentText(
      AgentSession target,
      List<String> messages, {
      String at = '',
      String reply = '',
    }) async {
      final ids = <String>[];
      for (var i = 0; i < messages.length; i++) {
        check();
        final segments = <Json>[
          if (i == 0 && at.isNotEmpty)
            {
              'type': 'at',
              'data': {'qq': _builtinUser(c, s, trigger, at)},
            },
          if (i == 0 && reply.isNotEmpty)
            {
              'type': 'reply',
              'data': {
                'id': _builtinMessage(
                  s,
                  trigger,
                  reply,
                ).id.replaceFirst(RegExp(r'^ob:'), ''),
              },
            },
          textSegment(messages[i]),
        ];
        try {
          final id = await send(
            target.key,
            messages[i],
            source: 'skill',
            segments: segments,
            turn: turn,
            replyMessageId: target.key == s.key ? trigger?.id : null,
          );
          ids.add(id);
        } catch (error) {
          if (ids.isEmpty) rethrow;
          return {
            'text': jsonEncode({
              'sent': ids.length,
              'messageIds': ids,
              'messages': messages.take(ids.length).toList(),
              'error': describeError(error),
              'notice': '已确认成功的消息不要重发；未取得回执的消息请先核实，不能自动重试。',
            }),
            'sent': true,
            'isError': true,
          };
        }
      }
      return {
        'text': jsonEncode({
          'sent': ids.length,
          'messageIds': ids,
          'messages': messages,
        }),
        'sent': true,
      };
    }

    switch (name) {
      case 'send_message':
        final values = strings(
          args['messages'],
        ).where((v) => v.trim().isNotEmpty).toList();
        if (values.isEmpty) throw const AgentException('消息不能为空。');
        final slots = _transports[c.id]?.replyCapacity(
          s.kind,
          s.peerId,
          trigger?.id ?? '',
        );
        if (slots != null && slots < values.length) {
          if (slots < 1) throw const AgentException('当前官机回复次数已用完，请等待新消息。');
          values[slots - 1] = values.skip(slots - 1).join('\n\n');
          values.removeRange(slots, values.length);
        }
        return sentText(
          s,
          values,
          at: text(args['atUserId']),
          reply: text(args['replyToMessageId']),
        );
      case 'send_to':
        if (!p.crossChatSendEnabled ||
            trigger == null ||
            !RegExp(r'转告|转发|发给|发送到|通知').hasMatch(trigger.inputText) ||
            RegExp(r'不要|不许|别发|别告诉|别通知').hasMatch(trigger.inputText)) {
          throw const AgentException('跨会话发送需预设授权，并由当前用户明确要求转告。');
        }
        final target = sessions(c.id)
            .where(
              (x) =>
                  x.key == args['chatKey'] &&
                  x.selfId == c.selfId &&
                  x.protocol == c.protocol,
            )
            .firstOrNull;
        if (target == null) throw const AgentException('目标必须是当前机器人已知的会话。');
        return sentText(target, [text(args['text'])]);
      case 'get_recent_messages':
      case 'search_messages':
        final limit = integer(args['limit'], 20),
            offset = integer(args['offset'], 0);
        final query = text(args['query']).toLowerCase();
        final values = history.reversed
            .where(
              (m) =>
                  name != 'search_messages' ||
                  m.inputText.toLowerCase().contains(query) ||
                  (p.readMessageContext &&
                      m.quotedContext.toLowerCase().contains(query)),
            )
            .skip(offset)
            .take(limit)
            .toList()
            .reversed;
        return result({
          'messages': values
              .map((m) => _builtinMessageView(m, context: p.readMessageContext))
              .toList(),
          'notice': '仅限本会话本地保存记录，不代表完整QQ历史。',
        });
      case 'get_message_detail':
      case 'read_forward':
      case 'get_message_images':
        var message = _builtinMessage(s, trigger, text(args['messageId']));
        if (name == 'read_forward' && !p.readMessageContext) {
          throw const AgentException('预设已关闭引用和聊天记录读取。');
        }
        if (name != 'get_message_detail') {
          message = await resolveMessage(message);
        }
        return {
          ...result(
            _builtinMessageView(message, context: p.readMessageContext),
          ),
          if (name == 'get_message_images')
            'images': _builtinImages(message, p).take(4).toList(),
        };
      case 'get_active_members':
        final users = <String, Json>{};
        for (final m in history.where((m) => !m.outgoing)) {
          final old = users[m.senderId];
          users[m.senderId] = {
            'userId': m.senderId,
            'name': m.senderName,
            'lastSeen': m.time.toIso8601String(),
            'recentCount': integer(old?['recentCount'], 0) + 1,
          };
        }
        return result({
          'members': users.values
              .toList()
              .reversed
              .take(integer(args['limit'], 10))
              .toList(),
        });
      case 'get_chats':
        return result({
          'chats': sessions(c.id)
              .where((x) => x.selfId == c.selfId && x.protocol == c.protocol)
              .take(integer(args['limit'], 20))
              .map(
                (x) => {
                  'chatKey': x.key,
                  'name': x.name,
                  'kind': x.kind,
                  'lastActive': x.updated.toIso8601String(),
                },
              )
              .toList(),
        });
      case 'get_user_avatar':
        final id = _builtinUser(c, s, trigger, text(args['userId']));
        final url = _builtinAvatar(c, id);
        return {
          ...result({
            'userId': id,
            'source': url,
            'notice': '以下图片是用户头像。实际读取成功后再评价；无法解码时不可猜测内容。',
          }),
          'images': [
            {
              'type': 'image',
              'data': {'url': url},
            },
          ],
        };
      case 'get_user_info':
      case 'get_group_info':
        final group = name == 'get_group_info';
        if (group && s.kind != 'group') throw const AgentException('当前会话是私聊。');
        final id = group
            ? s.peerId
            : _builtinUser(c, s, trigger, text(args['userId']));
        Json data;
        if (c.isOfficial) {
          data = await _transports[c.id]!.loadOfficialProfile(
            group
                ? 'group'
                : s.kind == 'group'
                ? 'member'
                : 'private',
            s.peerId,
            memberId: group ? '' : id,
          );
        } else {
          data = object(
            await _transports[c.id]!.call(
              group
                  ? 'get_group_info'
                  : s.kind == 'group'
                  ? 'get_group_member_info'
                  : 'get_stranger_info',
              {
                if (group || s.kind == 'group') 'group_id': int.parse(s.peerId),
                if (!group) 'user_id': int.parse(id),
                'no_cache': false,
              },
            ),
          );
        }
        check();
        return result({
          'id': id,
          'protocol': c.protocol,
          for (final key in [
            'name',
            'nickname',
            'username',
            'card',
            'group_name',
            'member_count',
            'max_member_count',
            'role',
            'member_role',
            'sex',
            'age',
            'level',
            'member_num',
            'status',
          ])
            if (data[key] is String || data[key] is num) key: data[key],
          if (!group && id != c.selfId) 'avatarUrl': _builtinAvatar(c, id),
          'notice': c.isOfficial
              ? 'ID是当前AppID下的OpenID，不是QQ号。资料取决于平台授权。'
              : '资料由当前协议端提供。',
        });
      case 'memory_append':
      case 'memory_query':
      case 'memory_remove':
        final key = _builtinKey(c, 'memory', s.key),
            rows =
                (store.get(_builtinKey(c, 'memory', s.key))?['items']
                            as List? ??
                        [])
                    .map(object)
                    .toList();
        final user = trigger?.senderId ?? (s.kind == 'private' ? s.peerId : '');
        if (name == 'memory_append') {
          final id = _builtinUser(c, s, trigger, text(args['userId']));
          final content = text(args['content']).trim();
          if (content.isEmpty) throw const AgentException('印象内容不能为空。');
          if (rows.length >= 200) {
            throw const AgentException('本会话已有200条印象，请先删除不再需要的记录。');
          }
          final row = {
            'id': const Uuid().v4(),
            'userId': id,
            'target': text(args['target']),
            'content': content,
            'createdBy': user,
            'at': DateTime.now().toIso8601String(),
          };
          rows.add(row);
          await store.put(key, {'items': rows});
          return result(row);
        }
        if (name == 'memory_remove') {
          final found = rows
              .where((row) => row['id'] == args['id'])
              .firstOrNull;
          if (found == null || found['createdBy'] != user) {
            throw const AgentException('只能删除本人在此会话创建的印象。');
          }
          rows.remove(found);
          await store.put(key, {'items': rows});
          return result({'removed': true});
        }
        final query = text(args['query']).toLowerCase();
        return result({
          'items': rows
              .where(
                (row) =>
                    (text(args['userId']).isEmpty ||
                        row['userId'] == args['userId']) &&
                    (query.isEmpty ||
                        jsonEncode(row).toLowerCase().contains(query)),
              )
              .take(40)
              .toList(),
        });
      case 'set_reminder':
      case 'list_reminders':
      case 'cancel_reminder':
        if (trigger == null) throw const AgentException('提醒需要当前提问者身份。');
        final rows = store
            .all('agent-reminder')
            .where(
              (row) =>
                  row['chatKey'] == s.key && row['userId'] == trigger.senderId,
            )
            .toList();
        if (name == 'list_reminders') return result({'reminders': rows});
        if (name == 'cancel_reminder') {
          final row = rows.where((row) => row['id'] == args['id']).firstOrNull;
          if (row == null || row['status'] != 'pending') {
            throw const AgentException('当前用户没有这条待执行提醒。');
          }
          await store.put('agent-reminder:${row['id']}', {
            ...row,
            'status': 'cancelled',
          });
          return result({'cancelled': true});
        }
        final now = DateTime.now(),
            at = text(args['at']).isEmpty
                ? DateTime.now().add(
                    Duration(seconds: integer(args['inSeconds'], 0)),
                  )
                : DateTime.tryParse(text(args['at']));
        if (at == null ||
            at.difference(now).inSeconds < 1 ||
            at.difference(now).inDays > 30 ||
            text(args['text']).trim().isEmpty) {
          throw const AgentException('请明确提醒内容和未来2秒至30天的时间；绝对时间请提供日期和时区。');
        }
        if (rows.where((row) => row['status'] == 'pending').length >= 20) {
          throw const AgentException('当前用户已有20条待执行提醒。');
        }
        final row = {
          'id': const Uuid().v4(),
          'chatKey': s.key,
          'connectionId': c.id,
          'selfId': c.selfId,
          'userId': trigger.senderId,
          'text': text(args['text']),
          'at': at.toIso8601String(),
          'status': 'pending',
          'replyId': trigger.id,
        };
        await store.put('agent-reminder:${row['id']}', row);
        return result({
          ...row,
          'notice': '提醒已保存，应用运行且机器人在线时执行；官机仍受平台主动/被动发送权限限制。',
        });
      case 'list_stickers':
      case 'collect_sticker':
      case 'get_sticker_image':
      case 'send_sticker':
      case 'sticker_note':
        final key = _builtinKey(c, 'stickers'),
            rows =
                (store.get(_builtinKey(c, 'stickers'))?['items'] as List? ?? [])
                    .map(object)
                    .toList();
        if (name == 'list_stickers') {
          return result({
            'items': rows
                .where((row) => text(row['note']).contains(text(args['query'])))
                .take(50)
                .toList(),
          });
        }
        if (name == 'collect_sticker') {
          final pictures = _builtinImages(
            await resolveMessage(
              _builtinMessage(s, trigger, text(args['messageId'])),
            ),
            p,
          );
          final index = integer(args['index'], 1) - 1;
          if (index < 0 || index >= pictures.length) {
            throw const AgentException('这条消息没有指定的图片。');
          }
          if (rows.length >= 50) throw const AgentException('本机器人表情库已达50张。');
          final picture = pictures[index], data = object(picture['data']);
          final ref = text(data['url']).isEmpty
              ? text(data['file'])
              : text(data['url']);
          Uint8List bytes;
          if (ref.startsWith('base64://') || ref.startsWith('data:image/')) {
            bytes = base64Decode(
              ref.substring(
                ref.startsWith('base64://') ? 9 : ref.indexOf(',') + 1,
              ),
            );
          } else {
            final uri = agentImageUri(ref);
            if (uri == null) throw const AgentException('图片未提供可用的公共HTTPS地址。');
            bytes = (await agentPublicGet(
              http,
              uri,
              cancel: cancel,
              maxBytes: 2 * 1024 * 1024,
            )).bytes;
          }
          if (bytes.length > 2 * 1024 * 1024) {
            throw const AgentException('收藏图片限2MB。');
          }
          await ai.images.prepare(
            {
              'type': 'image',
              'data': {'file': 'base64://${base64Encode(bytes)}'},
            },
            512,
            cancel,
            scope: s.key,
          );
          check();
          final row = {
            'id': const Uuid().v4(),
            'note': text(args['note']),
            'size': bytes.length,
            'at': DateTime.now().toIso8601String(),
          };
          await store.put('$key:${row['id']}', {'bytes': base64Encode(bytes)});
          rows.add(row);
          await store.put(key, {'items': rows});
          return result(row);
        }
        final row = rows.where((row) => row['id'] == args['id']).firstOrNull;
        if (row == null) throw const AgentException('没有此收藏表情，请先列出真实ID。');
        if (name == 'sticker_note') {
          row['note'] = text(args['note']);
          await store.put(key, {'items': rows});
          return result(row);
        }
        final bytes = base64Decode(
          text(store.get('$key:${row['id']}')?['bytes']),
        );
        if (name == 'get_sticker_image') {
          return {
            ...result(row),
            'images': [
              {
                'type': 'image',
                'data': {'file': 'base64://${base64Encode(bytes)}'},
              },
            ],
          };
        }
        final receipt = await sendImage(
          s.key,
          bytes,
          turn: turn,
          replyMessageId: trigger?.id,
        );
        return {...result(receipt), 'sent': true};
      case 'send_image':
        final url = text(args['url']);
        if (args['preview'] == true) {
          return {
            ...result({'url': url}),
            'images': [
              {
                'type': 'image',
                'data': {'url': url},
              },
            ],
          };
        }
        final image = await ai.images.prepare(
          {
            'type': 'image',
            'data': {'url': url},
          },
          p.imageMaxEdge,
          cancel,
          scope: s.key,
        );
        check();
        final receipt = await sendImage(
          s.key,
          image.bytes,
          name: 'image.jpg',
          turn: turn,
          replyMessageId: trigger?.id,
        );
        return {...result(receipt), 'sent': true};
      case 'send_poke':
        final id = _builtinUser(c, s, trigger, text(args['targetUserId']));
        final receipt = await _transports[c.id]!.call('send_poke', {
          'user_id': int.parse(id),
          if (s.kind == 'group') 'group_id': int.parse(s.peerId),
        });
        check();
        return result({'poked': true, 'receipt': receipt});
      case 'search_images':
        return result(
          await ai.web.searchImages(
            text(args['query']),
            cancel,
            limit: integer(args['limit'], 6),
          ),
        );
      case 'read_video':
        final m = _builtinMessage(s, trigger, text(args['messageId']));
        final choices = m.segments
            .where((seg) => seg['type'] == 'video')
            .toList();
        final index = integer(args['index'], 1) - 1;
        if (index < 0 || index >= choices.length) {
          throw const AgentException('这条消息没有指定的视频，请使用本会话真实消息ID。');
        }
        final data = object(choices[index]['data']),
            url = text(data['url']).isNotEmpty
                ? text(data['url'])
                : text(data['file']);
        final provider = videoProviderFor(p);
        if (provider == null || trigger == null) {
          throw const AgentException('请在预设中配置视频理解模型，或选择图片转述模型进行多帧识别。');
        }
        final active = turn ?? AgentTurn(() => !_closed && connected(c.id));
        final analysis = await videos.analyze(
          scope: s.key,
          source: url,
          question: text(args['question']).isEmpty
              ? trigger.inputText
              : text(args['question']),
          provider: provider,
          preset: p,
          turn: active,
          onUsage: (used, usage) async {
            await store.addUsage(
              integer(usage['prompt_tokens'], 0).clamp(0, 10000000),
              integer(usage['completion_tokens'], 0).clamp(0, 10000000),
            );
            await _recordRunUsage(c, s, trigger, active, used, usage);
          },
        );
        check();
        return result(analysis);
      case 'check_holiday':
        return result(
          agentHolidays(text(args['date']), integer(args['days'], 7)),
        );
      case 'get_current_time':
        final now = DateTime.now();
        return result({
          'time': now.toIso8601String(),
          'timezone': now.timeZoneName,
          'offsetMinutes': now.timeZoneOffset.inMinutes,
        });
      case 'report_feedback':
        if ((builtinData(c.id)['feedback'] as List).length >= 100) {
          throw const AgentException('当前机器人已有100条本地反馈，请先在“能力与资料”清理。');
        }
        final id = const Uuid().v4();
        await store.put('agent-feedback:$id', {
          'id': id,
          'chatKey': s.key,
          'userId': trigger?.senderId,
          'content': text(args['content']),
          'at': DateTime.now().toIso8601String(),
        });
        return result({
          'saved': true,
          'id': id,
          'notice': '反馈保存在管理器本地，未向外部联系人发送。',
        });
    }
    throw const AgentException('内置工具不存在。');
  }

  String builtinMemoryContext(AgentConnection c, AgentSession s) {
    final rows =
        store.get(_builtinKey(c, 'memory', s.key))?['items'] as List? ?? [];
    return clipped(
      rows
          .map(
            (row) =>
                '${object(row)['target'] ?? object(row)['userId']}: ${object(row)['content']}',
          )
          .join('\n'),
      5000,
    );
  }

  /// Persisted before delivery. Unknown receipts are never blindly retried.
  Future<void> processReminders({DateTime? now}) async {
    if (_closed || migrationPaused || !ready || _checkingReminders) return;
    _checkingReminders = true;
    try {
      final time = now ?? DateTime.now();
      for (final row
          in store
              .all('agent-reminder')
              .where((row) {
                final at = DateTime.tryParse(text(row['at']));
                return row['status'] == 'pending' &&
                    at != null &&
                    !at.isAfter(time);
              })
              .take(100)) {
        if (_closed || migrationPaused) return;
        final at = DateTime.tryParse(text(row['at'])),
            c = connection(text(row['connectionId'])),
            s = session(text(row['chatKey']));
        if (at == null ||
            at.isAfter(time) ||
            c == null ||
            s == null ||
            c.selfId != row['selfId'] ||
            !connected(c.id) ||
            s.paused) {
          continue;
        }
        final key = 'agent-reminder:${row['id']}';
        await store.put(key, {...row, 'status': 'sending'});
        try {
          await send(
            s.key,
            '提醒：${text(row['text'])}',
            source: 'reminder',
            replyMessageId: text(row['replyId']),
          );
          await store.put(key, {
            ...row,
            'status': 'sent',
            'sentAt': DateTime.now().toIso8601String(),
          });
        } catch (e) {
          await store.put(key, {
            ...row,
            'status': 'failed',
            'error': describeError(e),
          });
          _log('warning', '提醒未发送：${describeError(e)}', c.id, s.key, 'reminder');
        }
      }
    } finally {
      _checkingReminders = false;
    }
  }
}
