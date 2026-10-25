import '../models/received_message.dart';
import 'models.dart';

/// Display and AI share the original workspace's pure QQ body parser. It handles
/// recursive msg_elements and QQ textual record exports without sharing stores.
Json officialBodyData(Json source) {
  final received = ReceivedMessageBody.fromMap(source);
  var nodes = 0, limitHit = false;
  Json bound(ReceivedMessageBody body, int depth) {
    nodes++;
    if (body.displayText.length > 4000 ||
        (depth >= 6 && body.elements.isNotEmpty)) {
      limitHit = true;
    }
    return {
      'message_type': body.type,
      'content': clipped(body.displayText, 4000),
      'record_title': clipped(body.recordTitle, 180),
      'author': {
        'id': clipped(body.authorId, 256),
        'username': clipped(body.authorName, 128),
        'member_role': body.authorRole,
        'bot': body.isBotAuthor,
      },
      if (body.timestamp != null)
        'timestamp': body.timestamp!.toIso8601String(),
      'attachments': [
        for (final a in body.attachments.take(6))
          {
            'url': clipped(a.url, 4096),
            'filename': clipped(a.filename, 180),
            'content_type': a.contentType,
            'width': a.width,
            'height': a.height,
            'voice_wav_url': clipped(a.voiceWavUrl, 4096),
            'asr_refer_text': clipped(a.transcript, 2000),
          },
      ],
      if (body.card != null)
        'ark_data': {
          'ark_type': body.card!.type,
          'ark_name': body.card!.name,
          'fields': {
            for (final key in [
              'title',
              'desc',
              'jump_url',
              'source',
              'nickname',
              'address',
              'preview',
            ])
              if (body.card!.fields[key] is String)
                key: clipped(text(body.card!.fields[key]), 2000),
          },
        },
      'msg_elements': [
        if (depth < 6)
          for (final child in body.elements)
            if (nodes < 60) bound(child, depth + 1),
      ],
    };
  }

  final display = bound(received, 0),
      body = ReceivedMessageBody.fromMap(display);
  final lines = <String>[], images = <Json>[];
  var remaining = 10000,
      truncated = received.hasMoreElements || nodes >= 60 || limitHit;
  void add(String value) {
    if (value.isEmpty) return;
    if (remaining <= 0) {
      truncated = true;
      return;
    }
    if (value.length > remaining) truncated = true;
    final line = clipped(value, remaining);
    lines.add(line);
    remaining -= line.length;
  }

  void visit(ReceivedMessageBody item, int depth) {
    if (depth > 0) {
      add(
        '— ${item.kindLabel} / 发送者：${item.authorName.isEmpty ? (item.authorId.isEmpty ? '平台未提供' : item.authorId) : item.authorName}${item.timestamp == null ? '' : ' / 时间：${item.timestamp!.toIso8601String()}'} —',
      );
      add(item.displayText);
    }
    if (item.card != null) {
      add(
        '卡片：${item.card!.title}\n${item.card!.description}\n${item.card!.jumpUrl}',
      );
    }
    for (final a in item.attachments) {
      add(
        '[${a.kindLabel}] ${a.filename}${a.transcript.isEmpty ? '' : '\n语音转写：${a.transcript}'}',
      );
      if (a.isImage &&
          images.length < 6 &&
          depth > 0 &&
          a.url.startsWith('https://')) {
        images.add({
          'type': 'image',
          'data': {'url': a.url, 'name': a.filename},
        });
      }
    }
    for (final child in item.elements) {
      if (remaining > 0) {
        visit(child, depth + 1);
      } else {
        truncated = true;
      }
    }
  }

  visit(body, 0);
  if (body.recordTitle.isNotEmpty) lines.insert(0, '记录标题：${body.recordTitle}');
  if (body.type == 103 && body.elements.isEmpty) {
    add('平台未提供引用原文；本地没有可匹配的引用记录时，不可猜测其内容。');
  }
  if (truncated) lines.add('〔引用 / 聊天记录较长，超出读取上限的部分未提供，不可假装已阅读。〕');
  return {
    'body': display,
    'preview': body.isRecord
        ? clipped(body.preview, 180)
        : body.type == 103
        ? '${body.displayText}\n[引用消息]'
        : '${body.displayText}${body.displayText.isEmpty ? '[${body.kindLabel}]' : ''}',
    'context': lines.join('\n'),
    'images': images,
  };
}

bool needsOfficialBody(ReceivedMessageBody body) =>
    body.elements.isNotEmpty ||
    body.isRecord ||
    {3, 101, 102, 103}.contains(body.type) ||
    body.attachments.any((a) => a.transcript.isNotEmpty);

/// Adapt OneBot's actual get_forward_msg response to the same bounded reader.
/// No actions or authorizations are derived from forwarded message contents.
Json oneBotRecordData(Object? response) {
  var count = 0;
  Json convert(Json node, int depth) {
    count++;
    final value = node['type'] == 'node' ? object(node['data']) : node;
    final sender = object(value['sender']);
    final segments = parseSegments(value['content'] ?? value['message']);
    final time = integer(value['time'], 0);
    return {
      'message_type': 0,
      'content': clipped(segments.map(segmentText).join(), 4000),
      'author': {
        'id': text(
          sender['user_id'] ??
              sender['uin'] ??
              value['user_id'] ??
              value['uin'],
        ),
        'username': text(
          sender['card'] ??
              sender['nickname'] ??
              value['nickname'] ??
              value['name'],
        ),
      },
      if (time > 0 && time < 4102444800)
        'timestamp': DateTime.fromMillisecondsSinceEpoch(
          time * 1000,
        ).toIso8601String(),
      'attachments': [
        for (final s
            in segments
                .where(
                  (s) =>
                      {'image', 'record', 'video', 'file'}.contains(s['type']),
                )
                .take(6))
          {
            'content_type': s['type'] == 'image'
                ? 'image/jpeg'
                : s['type'] == 'video'
                ? 'video/mp4'
                : s['type'] == 'record'
                ? 'voice'
                : 'file',
            'url': text(object(s['data'])['url'] ?? object(s['data'])['file']),
            'filename': text(object(s['data'])['name']),
          },
      ],
      'msg_elements': [
        if (depth < 6)
          for (final s in segments.where((s) => s['type'] == 'node'))
            if (count < 60) convert(s, depth + 1),
      ],
    };
  }

  final payload = object(response);
  final nodes = payload['messages'] ?? payload['message'];
  return officialBodyData({
    'message_type': 102,
    'msg_elements': [
      for (final node in (nodes is List ? nodes : const []).take(60))
        if (count < 60) convert(object(node), 0),
    ],
  });
}

/// Never request arbitrary history by a quoted ID. A local reference is resolved
/// only against messages in this exact bot/account/session.
List<Json> withLocalQuote(
  List<Json> segments,
  String reference,
  List<AgentMessage> history, {
  required String sessionKey,
  String currentId = '',
}) {
  final explicit = segments.where((s) => s['type'] == 'reply').firstOrNull;
  final ref = reference.isNotEmpty
      ? reference
      : text(object(explicit?['data'])['id']);
  if (ref.isEmpty) return segments;
  final match = history
      .where(
        (m) =>
            m.sessionKey == sessionKey &&
            m.id != currentId &&
            (m.referenceIndex == ref || m.id == ref || m.id == 'ob:$ref'),
      )
      .lastOrNull;
  if (match == null) return segments;
  final originalBody = match.segments
      .where((s) => s['type'] == 'qq_body')
      .map((s) => object(object(s['data'])['body']))
      .firstOrNull;
  final quote = {
    ...?originalBody,
    'content': originalBody == null
        ? clipped(match.plain, 4000)
        : text(originalBody['content']),
    'author': {'id': match.senderId, 'username': match.senderName},
    'timestamp': match.time.toIso8601String(),
    if (originalBody == null)
      'attachments': [
        for (final image
            in match.segments.where((s) => s['type'] == 'image').take(3))
          if (text(object(image['data'])['url']).startsWith('https://'))
            {
              'content_type': 'image/jpeg',
              'url': text(object(image['data'])['url']),
            },
      ],
  };
  var replaced = false;
  final result = segments.map((segment) {
    if (segment['type'] != 'qq_body') return segment;
    final body = object(object(segment['data'])['body']);
    if (integer(body['message_type'], 0) != 103 ||
        (body['msg_elements'] is List &&
            (body['msg_elements'] as List).isNotEmpty)) {
      return segment;
    }
    replaced = true;
    return <String, dynamic>{
      'type': 'qq_body',
      'data': {
        ...officialBodyData({
          ...body,
          'msg_elements': [quote],
        }),
        if (object(segment['data'])['commandText'] != null)
          'commandText': object(segment['data'])['commandText'],
      },
    };
  }).toList();
  if (!replaced && explicit != null) {
    result.add({
      'type': 'qq_body',
      'data': officialBodyData({
        'message_type': 103,
        'msg_elements': [quote],
      }),
    });
  }
  return result;
}
