/// Some QQ forwarded records arrive as a textual export, not as attachments.
/// A numbered section can also be a single quoted message. Keep its type and
/// fields instead of treating every export as a merged conversation.
/// The raw event remains untouched for details and reply indices.
Map<String, dynamic>? parseForwardedRecordText(
  String source, {
  bool forceRecord = false,
}) {
  if (source.length > 1024 * 1024) return null;
  final headers = RegExp(
    r'^\s*={3,}\s*消息\s*\d+\s*={3,}\s*$',
    multiLine: true,
  ).allMatches(source).toList();
  if (headers.isEmpty || headers.length > 200) return null;
  final records = <Map<String, dynamic>>[];
  final fields = RegExp(
    r'^\s*\[(消息内容|消息类型|发送者|发送时间|时间|引用内容|引用发送者|附件\s*\d+)\]\s*',
    multiLine: true,
  );
  for (var i = 0; i < headers.length; i++) {
    final section = source.substring(
      headers[i].end,
      i + 1 < headers.length ? headers[i + 1].start : source.length,
    );
    final matches = fields.allMatches(section).toList();
    if (matches.isEmpty) return null;
    var content = '', author = '', timestamp = '', type = '';
    var quotedText = '', quotedAuthor = '';
    final attachments = <Map<String, dynamic>>[];
    for (var j = 0; j < matches.length; j++) {
      final key = matches[j].group(1)!;
      final value = section
          .substring(
            matches[j].end,
            j + 1 < matches.length ? matches[j + 1].start : section.length,
          )
          .trim();
      if (key == '消息内容') {
        content = value;
      } else if (key == '消息类型') {
        type = value;
      } else if (key == '发送者') {
        author = value;
      } else if (key == '时间' || key == '发送时间') {
        timestamp = value;
      } else if (key == '引用内容') {
        quotedText = value;
      } else if (key == '引用发送者') {
        quotedAuthor = value;
      } else if (attachments.length < 50) {
        final attachment = _attachment(value);
        // An unrecognised export must remain visible as text, not disappear.
        if (attachment == null) return null;
        attachments.add(attachment);
      }
    }
    records.add({
      'message_type': switch (type) {
        '引用消息' || '103' => 103,
        '并行消息' || '101' => 101,
        '聊天记录' || '102' => 102,
        '卡片消息' || '3' => 3,
        _ => quotedText.isNotEmpty ? 103 : 0,
      },
      'content': content,
      if (author.isNotEmpty) 'author': {'username': author},
      if (timestamp.isNotEmpty) 'timestamp': timestamp,
      if (attachments.isNotEmpty) 'attachments': attachments,
      if (quotedText.isNotEmpty)
        'msg_elements': [
          {
            'content': quotedText,
            if (quotedAuthor.isNotEmpty) 'author': {'username': quotedAuthor},
          },
        ],
    });
  }
  final prefix = source.substring(0, headers.first.start).trim();
  final title = prefix.startsWith('[') && prefix.endsWith(']')
      ? prefix.substring(1, prefix.length - 1)
      : prefix;
  // A real forwarded record can contain one quoted row. Only an explicit
  // record type/title or multiple rows makes it a record container.
  if (!forceRecord && records.length == 1 && !title.endsWith('聊天记录')) {
    return records.single;
  }
  return {
    'message_type': 102,
    'content': '',
    'record_title': title,
    'msg_elements': records,
  };
}

Map<String, dynamic>? _attachment(String text) {
  final url = RegExp(
    r'URL\s*[:：]\s*(https?://\S+)',
    caseSensitive: false,
  ).firstMatch(text)?.group(1);
  final uri = url == null ? null : Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
  String field(String name) =>
      RegExp(
        '$name\\s*[:：]\\s*(.*?)(?=\\s*(?:类型|文件名|尺寸|大小|URL)\\s*[:：]|\$)',
        caseSensitive: false,
        dotAll: true,
      ).firstMatch(text)?.group(1)?.trim() ??
      '';
  final dimensions = RegExp(r'(\d+)\s*[x×*]\s*(\d+)').firstMatch(field('尺寸'));
  final filename = field('文件名');
  final type = field('类型');
  final suffix = Uri.tryParse(filename)?.path.toLowerCase() ?? '';
  final image = type == '图片' || type.startsWith('image/');
  final audio = type == '语音' || type.startsWith('audio/');
  final size = RegExp(
    r'([\d.]+)\s*(B|KB|MB|GB)',
    caseSensitive: false,
  ).firstMatch(field('大小'));
  final multiplier = switch (size?.group(2)?.toUpperCase()) {
    'KB' => 1024,
    'MB' => 1024 * 1024,
    'GB' => 1024 * 1024 * 1024,
    _ => 1,
  };
  return {
    'url': url,
    'filename': filename,
    'content_type': image
        ? type.startsWith('image/')
              ? type
              : suffix.endsWith('.gif')
              ? 'image/gif'
              : suffix.endsWith('.png')
              ? 'image/png'
              : suffix.endsWith('.webp')
              ? 'image/webp'
              : 'image/jpeg'
        : audio
        ? 'voice'
        : type == '视频'
        ? 'video/mp4'
        : 'file',
    if (dimensions != null) ...{
      'width': int.tryParse(dimensions.group(1)!) ?? 0,
      'height': int.tryParse(dimensions.group(2)!) ?? 0,
    },
    if (size != null)
      'size': ((double.tryParse(size.group(1)!) ?? 0) * multiplier)
          .round()
          .clamp(0, 1024 * 1024 * 1024),
  };
}
