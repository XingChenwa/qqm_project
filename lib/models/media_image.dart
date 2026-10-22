/// A platform material reference belongs to one bot. Preview URLs are temporary
/// and deliberately kept in memory only: do not add this model to Hive/config.
class BotMediaImage {
  final String id, reference, filename, previewUrl;
  final DateTime? createdAt, expiresAt;
  final int width, height;
  const BotMediaImage({
    required this.id,
    required this.reference,
    this.filename = '',
    this.previewUrl = '',
    this.createdAt,
    this.expiresAt,
    this.width = 0,
    this.height = 0,
  });

  factory BotMediaImage.fromMap(Map<String, dynamic> map) {
    DateTime? date(dynamic value) {
      final seconds = int.tryParse('$value');
      if (seconds == null || seconds <= 0 || seconds > 253402300799) {
        return null;
      }
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
    }

    final id = map['image_id']?.toString() ?? '';
    final reference = map['url']?.toString() ?? '';
    if (id.isEmpty || id.length > 256 || !isMediaReference(reference)) {
      throw const FormatException('平台返回的素材标识或引用格式无效');
    }
    final preview = map['preview_url']?.toString() ?? '';
    return BotMediaImage(
      id: id,
      reference: reference,
      filename: map['file_name']?.toString() ?? '',
      previewUrl: isMaterialCosUrl(preview) ? preview : '',
      createdAt: date(map['created_at']),
      expiresAt: date(map['expires_at']),
      width: int.tryParse('${map['width']}') ?? 0,
      height: int.tryParse('${map['height']}') ?? 0,
    );
  }

  bool get expired => expiresAt?.isBefore(DateTime.now()) ?? false;
  String get displayName => filename.isEmpty ? '图片素材' : filename;
  String get markdown {
    // Use QQ's explicit display-size syntax. The size is a layout hint, not a
    // conversion of the source file. Avoid exposing hash filenames as alt text.
    final w = width > 0 ? width.clamp(1, 1280) : 320;
    final h = width > 0 && height > 0
        ? (height * w / width).round().clamp(1, 8192)
        : 320;
    return '![图片 #${w}px #${h}px]($reference)';
  }

  BotMediaImage withDimensions(int width, int height) => BotMediaImage(
    id: id,
    reference: reference,
    filename: filename,
    previewUrl: previewUrl,
    createdAt: createdAt,
    expiresAt: expiresAt,
    width: width,
    height: height,
  );
}

bool containsMaterialReference(String text) =>
    text.contains('qqbot-media://image/v1/');

bool isMediaReference(String value) {
  if (value.length > 4096 || value.trim() != value) return false;
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'qqbot-media' &&
      uri.host == 'image' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      !uri.hasQuery &&
      !uri.hasFragment &&
      RegExp(r'^/v1/[A-Za-z0-9._~-]+$').hasMatch(uri.path);
}

/// The official upload and preview endpoint is a Tencent COS HTTPS URL. Never
/// follow a redirect or send bot authentication to a signed object URL.
bool isMaterialCosUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment &&
      RegExp(
        r'^[a-z0-9-]+\.cos\.[a-z0-9-]+\.myqcloud\.com$',
      ).hasMatch(uri.host);
}

class BotMediaPage {
  final List<BotMediaImage> images;
  final String cursor;
  final int total;
  const BotMediaPage(this.images, this.cursor, this.total);
  factory BotMediaPage.fromMap(Map<String, dynamic> map) {
    if (map['images'] is! List) {
      throw const FormatException('平台返回的素材列表格式无效');
    }
    return BotMediaPage(
      (map['images'] as List).map((raw) {
        if (raw is! Map) throw const FormatException('素材条目格式无效');
        return BotMediaImage.fromMap(Map<String, dynamic>.from(raw));
      }).toList(),
      map['next_cursor']?.toString() ?? '',
      int.tryParse('${map['total']}') ?? 0,
    );
  }
}
