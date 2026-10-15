String profileName(Object? value) {
  if (value is! String) return '';
  final name = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ').trim();
  return name == 'null' ? '' : name;
}

String profileAvatar(Object? value) {
  if (value is! String) return '';
  final text = value.trim();
  if (text.length > 4096 || RegExp(r'\s').hasMatch(text)) return '';
  final uri = Uri.tryParse(text.startsWith('//') ? 'https:$text' : text);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return '';
  }
  return uri.toString();
}

String firstProfileName(Iterable<Object?> values) => values
    .map(profileName)
    .firstWhere((name) => name.isNotEmpty, orElse: () => '');

String firstProfileAvatar(Iterable<Object?> values) => values
    .map(profileAvatar)
    .firstWhere((url) => url.isNotEmpty, orElse: () => '');

/// QQ's user-avatar CDN uses the bot AppID and that user's OpenID, not a QQ
/// account number. No bot token or client secret belongs in this URL.
String qqOpenIdAvatar(String appId, String openId) {
  final app = appId.trim();
  final user = openId.trim();
  if (!RegExp(r'^[0-9]{1,32}$').hasMatch(app) ||
      !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(user)) {
    return '';
  }
  return Uri.https('q.qlogo.cn', '/qqapp/$app/$user/640').toString();
}

/// Recognize our generated fallback so it can be replaced by actual profile
/// data, or rebuilt when the current bot AppID changes.
bool isQqOpenIdAvatar(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.toLowerCase() != 'q.qlogo.cn' ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.hasPort) {
    return false;
  }
  final path = uri.pathSegments;
  return path.length == 4 &&
      path[0] == 'qqapp' &&
      path[3] == '640' &&
      qqOpenIdAvatar(path[1], path[2]).isNotEmpty;
}

String userProfileAvatar(
  String appId,
  String openId,
  Iterable<Object?> cached,
) {
  // Saved explicit URLs take priority over a generated CDN address. Never
  // reuse a generated address for another AppID / OpenID.
  final explicit = firstProfileAvatar(
    cached.where((value) => !isQqOpenIdAvatar(profileAvatar(value))),
  );
  return explicit.isNotEmpty ? explicit : qqOpenIdAvatar(appId, openId);
}

bool isFallbackProfileName(String name, String id, {bool isGroup = false}) =>
    name.trim().isEmpty ||
    name == id ||
    name == '用户' ||
    name == '机器人' ||
    name == '${isGroup ? '群聊' : '用户'}-$id' ||
    (id.length > 12 &&
        name == '${id.substring(0, 6)}...${id.substring(id.length - 4)}');
