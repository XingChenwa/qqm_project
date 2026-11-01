/// Display-only summary. Signed release metadata is never modified.
List<String> conciseReleaseNotes(String source) {
  final items = <String>[];
  for (var line in source.split(RegExp(r'\r?\n'))) {
    line = line.trim();
    if (line.isEmpty ||
        line.startsWith('#') ||
        line.startsWith('```') ||
        RegExp(
          r'https?://|sha-?256|checksum|构建编号|签名公钥|安装说明|安装包|下载链接|GitCode|GitHub|unsigned|\.apk|\.exe|\.dmg|\.ipa',
          caseSensitive: false,
        ).hasMatch(line)) {
      continue;
    }
    line = line
        .replaceFirst(RegExp(r'^(?:[-*+•]\s+|\d+[.)、]\s*)'), '')
        .replaceAll(RegExp(r'[*`_]'), '')
        .trim();
    if (line.isEmpty || RegExp(r'^[-:|\s]+$').hasMatch(line)) continue;
    final shortened = line.runes.length > 82
        ? '${String.fromCharCodes(line.runes.take(81))}…'
        : line;
    if (!items.contains(shortened)) items.add(shortened);
    if (items.length == 3) break;
  }
  return items.isEmpty ? const ['修复一些问题，优化使用体验。'] : items;
}

/// Invite links are kept separately from the short bullet summary. Only the
/// public QQ group-share endpoint may create this action in update notes.
String? communityInviteFromNotes(String source) {
  for (final match in RegExp(
    r'https://qun\.qq\.com/universal-share/share\?[^\s<>()\]]+',
  ).allMatches(source)) {
    final value = match.group(0)!;
    if (value.length > 1500) continue;
    final uri = Uri.tryParse(value);
    if (uri != null &&
        uri.scheme == 'https' &&
        uri.host == 'qun.qq.com' &&
        uri.userInfo.isEmpty &&
        uri.port == 443 &&
        uri.path == '/universal-share/share' &&
        uri.query.isNotEmpty &&
        !uri.hasFragment) {
      return value;
    }
  }
  return null;
}
