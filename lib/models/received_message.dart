import '../utils/helpers.dart';

String _text(dynamic value) =>
    value is String ? value : (value?.toString() ?? '');
int _integer(dynamic value) =>
    value is num ? value.toInt() : int.tryParse(_text(value)) ?? 0;
Map<String, dynamic> _map(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

String normalizeAttachmentUrl(dynamic value) {
  final url = _text(value).trim();
  return url.startsWith('//') ? 'https:$url' : url;
}

class ReceivedAttachment {
  final String url, filename, contentType, voiceWavUrl, transcript;
  final int width, height, size;
  const ReceivedAttachment({
    required this.url,
    this.filename = '',
    this.contentType = '',
    this.voiceWavUrl = '',
    this.transcript = '',
    this.width = 0,
    this.height = 0,
    this.size = 0,
  });
  factory ReceivedAttachment.fromMap(Map<String, dynamic> data) =>
      ReceivedAttachment(
        url: normalizeAttachmentUrl(
          data['url'] ?? data['image_url'] ?? data['cdn_url'],
        ),
        filename: _text(data['filename']),
        contentType: _text(data['content_type']).toLowerCase(),
        width: _integer(data['width']),
        height: _integer(data['height']),
        size: _integer(data['size']),
        voiceWavUrl: normalizeAttachmentUrl(data['voice_wav_url']),
        transcript: _text(data['asr_refer_text']),
      );

  bool get isImage =>
      contentType.startsWith('image/') ||
      (contentType.isEmpty &&
          ((width > 0 && height > 0) ||
              RegExp(
                r'\.(?:png|jpe?g|gif|webp|bmp)$',
                caseSensitive: false,
              ).hasMatch(Uri.tryParse(url)?.path ?? '')));
  bool get isVoice =>
      contentType == 'voice' ||
      contentType.startsWith('audio/') ||
      voiceWavUrl.isNotEmpty;
  bool get isVideo => contentType.startsWith('video/');
  String get kindLabel =>
      isImage ? '图片' : (isVoice ? '语音' : (isVideo ? '视频' : '文件'));
  String get displayName => filename.isNotEmpty ? filename : '$kindLabel附件';
  String get openUrl => isVoice && voiceWavUrl.isNotEmpty ? voiceWavUrl : url;
}

class ReceivedCard {
  final String type, name, prompt;
  final Map<String, dynamic> fields;
  const ReceivedCard({
    this.type = '',
    this.name = '',
    this.prompt = '',
    this.fields = const {},
  });
  factory ReceivedCard.fromMap(Map<String, dynamic> data) => ReceivedCard(
    type: _text(data['ark_type']),
    name: _text(data['ark_name']),
    prompt: _text(data['prompt']),
    fields: _map(data['fields']),
  );
  String get title =>
      _text(fields['title'] ?? fields['nickname'] ?? fields['name']).isNotEmpty
      ? _text(fields['title'] ?? fields['nickname'] ?? fields['name'])
      : (name.isNotEmpty ? name : '分享卡片');
  String get description => _text(fields['desc'] ?? fields['address']);
  String get previewUrl =>
      normalizeAttachmentUrl(fields['preview'] ?? fields['avatar']);
  String get jumpUrl => normalizeAttachmentUrl(fields['jump_url']);
  String get source => _text(fields['source'] ?? fields['tag']);
}

class ReceivedMessageBody {
  final int type;
  final String text, authorName, authorId, authorRole, elementIndex;
  final List<dynamic> mentions;
  final List<ReceivedAttachment> attachments;
  final ReceivedCard? card;
  final List<ReceivedMessageBody> elements;
  final Map<String, String> scene;
  final bool isBotAuthor, hasMoreElements;

  const ReceivedMessageBody({
    this.type = 0,
    this.text = '',
    this.authorName = '',
    this.authorId = '',
    this.authorRole = '',
    this.elementIndex = '',
    this.mentions = const [],
    this.attachments = const [],
    this.card,
    this.elements = const [],
    this.scene = const {},
    this.isBotAuthor = false,
    this.hasMoreElements = false,
  });

  factory ReceivedMessageBody.fromMap(Map<String, dynamic> data) =>
      _parse(data, 0, [200]);

  static ReceivedMessageBody _parse(
    Map<String, dynamic> data,
    int depth,
    List<int> remaining, [
    List<dynamic> inheritedMentions = const [],
  ]) {
    final author = _map(data['author']);
    final mentions = data['mentions'] is List
        ? List<dynamic>.from(data['mentions'])
        : inheritedMentions;
    final scene = <String, String>{};
    final rawScene = _map(data['message_scene']);
    if (rawScene['ext'] is List) {
      for (final entry in rawScene['ext']) {
        if (entry is! String) continue;
        final equal = entry.indexOf('=');
        if (equal > 0) {
          scene[entry.substring(0, equal)] = entry.substring(equal + 1);
        }
      }
    }
    final attachments = <ReceivedAttachment>[];
    if (data['attachments'] is List) {
      for (final raw in data['attachments']) {
        if (raw is Map) attachments.add(ReceivedAttachment.fromMap(_map(raw)));
      }
    }
    final elements = <ReceivedMessageBody>[];
    var hasMore = false;
    if (data['msg_elements'] is List) {
      for (final raw in data['msg_elements']) {
        if (raw is! Map) continue;
        if (depth >= 8 || remaining[0] <= 0) {
          hasMore = true;
          break;
        }
        remaining[0]--;
        elements.add(_parse(_map(raw), depth + 1, remaining, mentions));
      }
    }
    return ReceivedMessageBody(
      type: _integer(data['message_type']),
      text: _text(data['content']),
      authorName: _text(
        author['username'] ?? author['nick'] ?? author['nickname'],
      ),
      authorId: _text(
        author['member_openid'] ?? author['user_openid'] ?? author['id'],
      ),
      authorRole: _text(author['member_role']),
      isBotAuthor: author['bot'] == true,
      elementIndex: _text(data['msg_idx']),
      mentions: mentions,
      attachments: attachments,
      card: data['ark_data'] is Map
          ? ReceivedCard.fromMap(_map(data['ark_data']))
          : null,
      elements: elements,
      scene: scene,
      hasMoreElements: hasMore,
    );
  }

  String get displayText => formatQqMessageContent(text, mentions: mentions);
  String get kindLabel => switch (type) {
    3 => '卡片消息',
    101 => '并行消息',
    102 => '聊天记录',
    103 => '引用消息',
    _ => '消息',
  };
  String get preview {
    if (type == 103) return '[引用消息] ${_firstText()}'.trim();
    if (type == 101 || type == 102) {
      return '[$kindLabel] ${_firstText()}'.trim();
    }
    if (displayText.isNotEmpty) return displayText;
    if (card != null) {
      return '[${card!.name.isEmpty ? '卡片' : card!.name}] ${card!.title}';
    }
    if (attachments.isNotEmpty) {
      return attachments
          .map((a) => '[${a.kindLabel}] ${a.filename}'.trim())
          .join(' ');
    }
    if (elements.isNotEmpty) return _firstText();
    return '[消息]';
  }

  String _firstText() {
    if (displayText.isNotEmpty) return displayText;
    for (final element in elements) {
      final text = element._firstText();
      if (text.isNotEmpty) return text;
    }
    return card?.title ??
        (attachments.isEmpty ? '' : attachments.first.displayName);
  }
}

/// 仅用于“消息详情”展示；不修改保存的原始事件和引用索引。
dynamic redactMessageDetails(dynamic value) {
  if (value is DateTime) return value.toIso8601String();
  if (value is Map) {
    return value.map(
      (key, child) => MapEntry(
        key.toString(),
        RegExp(
              r'token|secret|authorization',
              caseSensitive: false,
            ).hasMatch(key.toString())
            ? '（已隐藏）'
            : redactMessageDetails(child),
      ),
    );
  }
  if (value is List) return value.map(redactMessageDetails).toList();
  if (value is String &&
      RegExp(r'^auth_token=', caseSensitive: false).hasMatch(value)) {
    return 'auth_token=（已隐藏）';
  }
  return value;
}
