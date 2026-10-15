import 'dart:convert';

import '../utils/helpers.dart';

String faceLabel(String value) => value
    .trim()
    .replaceFirst(RegExp(r'^\['), '')
    .replaceFirst(RegExp(r'\]$'), '')
    .replaceFirst(RegExp(r'^/'), '')
    .trim();

class QqTextPart {
  final String text;
  final String? faceId;
  final String label;
  final bool sticker;
  const QqTextPart(
    this.text, {
    this.faceId,
    this.label = '',
    this.sticker = false,
  });
  bool get isFace => faceId != null;

  static List<QqTextPart> parse(String content, {List<dynamic>? mentions}) {
    final result = <QqTextPart>[];
    final text = content.trim();
    var start = 0;
    final pattern = RegExp(
      r'<faceType\s*=\s*"?\d+"?[^>]{0,8192}>|<emoji:[^>]{1,32}>|\[QQ表情(?:包)?(?:#\d+|:\s*[^\]]+)?\]',
    );
    for (final match in pattern.allMatches(text).take(200)) {
      if (match.start > start) {
        result.add(
          QqTextPart(
            formatQqMessageContent(
              text.substring(start, match.start),
              mentions: mentions,
              trim: false,
            ),
          ),
        );
      }
      final raw = match.group(0)!;
      var id = '', label = '';
      final faceType = RegExp(
        r'faceType\s*=\s*"?(\d+)',
      ).firstMatch(raw)?.group(1);
      final sticker = faceType == '6' || raw.startsWith('[QQ表情包');
      if (raw.startsWith('<faceType')) {
        id =
            RegExp(
              r'''faceId\s*=\s*["']([^"']*)["']''',
            ).firstMatch(raw)?.group(1) ??
            '';
        final ext =
            RegExp(
              r'''ext\s*=\s*["']([^"']*)["']''',
            ).firstMatch(raw)?.group(1) ??
            '';
        if (ext.length <= 8192) {
          try {
            final details = jsonDecode(
              utf8.decode(base64Decode(base64.normalize(ext))),
            );
            if (details is Map) {
              final value =
                  details['text'] ?? details['name'] ?? details['summary'];
              if (value is String && value.length <= 128) {
                label = faceLabel(value);
              }
            }
          } catch (_) {}
        }
      } else if (raw.startsWith('<emoji:')) {
        id = raw.substring(7, raw.length - 1);
      } else {
        id = RegExp(r'#(\d+)').firstMatch(raw)?.group(1) ?? '';
        final colon = raw.indexOf(':');
        if (colon >= 0) {
          label = faceLabel(raw.substring(colon + 1, raw.length - 1));
        }
      }
      result.add(
        QqTextPart(
          formatQqMessageContent(raw),
          faceId: id,
          label: label,
          sticker: sticker,
        ),
      );
      start = match.end;
    }
    if (start < text.length) {
      result.add(
        QqTextPart(
          formatQqMessageContent(
            text.substring(start),
            mentions: mentions,
            trim: false,
          ),
        ),
      );
    }
    return result;
  }
}

class QFaceResource {
  final String id, label, url;
  const QFaceResource(this.id, this.label, this.url);
}

class QFaceCatalog {
  final Map<String, QFaceResource> byId;
  final Map<String, QFaceResource> byName;
  const QFaceCatalog.empty() : byId = const {}, byName = const {};
  const QFaceCatalog._(this.byId, this.byName);
  bool get isEmpty => byId.isEmpty;

  factory QFaceCatalog.fromJson(dynamic data) {
    if (data is! List) return const QFaceCatalog.empty();
    final ids = <String, QFaceResource>{}, names = <String, QFaceResource>{};
    for (final row in data.take(2000)) {
      if (row is! Map) continue;
      final id = row['emojiId']?.toString() ?? '';
      final description = row['describe'];
      if (!RegExp(r'^\d{1,6}$').hasMatch(id) ||
          description is! String ||
          description.length > 128 ||
          row['assets'] is! List) {
        continue;
      }
      final label = faceLabel(description);
      String? png, apng;
      for (final asset in row['assets']) {
        if (asset is! Map || asset['path'] is! String) continue;
        final path = asset['path'] as String;
        if (!RegExp(
          '^assets/qq_emoji/$id/(png|apng)/[A-Za-z0-9_-]+\\.png\$',
        ).hasMatch(path)) {
          continue;
        }
        final url = 'https://koishi.js.org/QFace/$path';
        if (path.contains('/png/')) {
          png ??= url;
        } else {
          apng ??= url;
        }
      }
      final url = png ?? apng;
      if (url == null || label.isEmpty) continue;
      final resource = QFaceResource(id, label, url);
      ids.putIfAbsent(id, () => resource);
      names.putIfAbsent(label, () => resource);
    }
    return QFaceCatalog._(Map.unmodifiable(ids), Map.unmodifiable(names));
  }

  QFaceResource? resolve(QqTextPart part) {
    if (!part.isFace || part.sticker) return null;
    if (part.faceId!.isNotEmpty) return byId[part.faceId];
    return byName[faceLabel(part.label)];
  }
}
