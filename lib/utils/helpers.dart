import 'dart:convert';

import 'package:intl/intl.dart';
export 'package:qqm_plugins/sdk.dart' show parseSlashCommand;

String formatTimestamp(DateTime dt) {
  dt = dt.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final msgDate = DateTime(dt.year, dt.month, dt.day);

  if (msgDate == today) {
    return DateFormat('HH:mm').format(dt);
  } else if (msgDate == today.subtract(const Duration(days: 1))) {
    return '昨天 ${DateFormat('HH:mm').format(dt)}';
  } else if (dt.year == now.year) {
    return DateFormat('MM-dd HH:mm').format(dt);
  }
  return DateFormat('yyyy-MM-dd HH:mm').format(dt);
}

String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String escapeMarkdown(String text) {
  return text
      .replaceAll('\\', '\\\\')
      .replaceAll('*', '\\*')
      .replaceAll('_', '\\_')
      .replaceAll('`', '\\`')
      .replaceAll('~', '\\~')
      .replaceAll('|', '\\|');
}

bool isValidUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
}

String generateId() {
  return DateTime.now().microsecondsSinceEpoch.toRadixString(36);
}

String stripLeadingBotMention(String content) => content.replaceFirst(
  RegExp(r'^\s*(?:<@!?[^>]+>|<qqbot-at-user\s+id="[^"]+"\s*/>)\s*'),
  '',
);

bool containsMarkdown(String text) => RegExp(
  r'(^|\n)\s*(?:#{1,6}\s|>\s|[-*+]\s|\d+\.\s|```|~~~)|\*\*[^*]+\*\*|!?\[[^\]]*\]\([^\)]+\)',
).hasMatch(text);

String formatQqMessageContent(
  String content, {
  List<dynamic>? mentions,
  bool trim = true,
}) {
  var text = content;
  final mentionNames = <String, String>{};

  for (final mention in mentions ?? const []) {
    if (mention is! Map) continue;
    final name =
        mention['username']?.toString() ??
        mention['nick']?.toString() ??
        mention['name']?.toString();
    if (name != null && name.isNotEmpty) {
      for (final key in ['id', 'openid', 'user_openid', 'member_openid']) {
        final id = mention[key]?.toString();
        if (id != null && id.isNotEmpty) mentionNames[id] = name;
      }
    }
  }

  text = text.replaceAllMapped(
    RegExp(r'<qqbot-at-user\s+id="([^"]+)"\s*/>'),
    (match) =>
        '@${mentionNames[match.group(1)] ?? _shortOpenId(match.group(1) ?? '')}',
  );
  text = text.replaceAll(RegExp(r'<qqbot-at-everyone\s*/>'), '@全体成员');

  text = text.replaceAllMapped(
    RegExp(r'<@!?([^>]+)>'),
    (match) =>
        '@${mentionNames[match.group(1)] ?? _shortOpenId(match.group(1) ?? '')}',
  );

  text = text.replaceAllMapped(
    RegExp(r'<faceType=([^,\s>]+),faceId="([^"]*)",ext="([^"]*)"\s*>'),
    (match) {
      final type = match.group(1) ?? '';
      final id = match.group(2) ?? '';
      final ext = _decodeFaceExt(match.group(3) ?? '');
      final label = type == '6' ? 'QQ表情包' : 'QQ表情';
      if (ext.isNotEmpty) return '[$label: $ext]';
      if (id.isNotEmpty && id != '0') return '[$label#$id]';
      return '[$label]';
    },
  );

  text = text.replaceAllMapped(
    RegExp(r'<emoji:([^>]+)>'),
    (match) => '[QQ表情#${match.group(1)}]',
  );

  return trim ? text.trim() : text;
}

String _decodeFaceExt(String ext) {
  if (ext.isEmpty) return '';
  try {
    final normalized = base64.normalize(ext);
    final decoded = utf8.decode(base64Decode(normalized));
    final data = jsonDecode(decoded);
    if (data is Map) {
      return data['text']?.toString() ??
          data['name']?.toString() ??
          data['summary']?.toString() ??
          '';
    }
  } catch (_) {
    return '';
  }
  return '';
}

String _shortOpenId(String id) {
  if (id.isEmpty) return '用户';
  if (id.length <= 8) return id;
  return '${id.substring(0, 4)}...${id.substring(id.length - 4)}';
}
