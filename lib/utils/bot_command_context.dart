final _leadingMention = RegExp(
  r'^\s*(?:<@!?([^>]+)>|<qqbot-at-user\s+id="([^"]+)"\s*/>)\s*',
);

/// Normalize plugin input, never the stored/displayed QQ message.
/// A full-group event is not, by itself, evidence of addressing this bot.
({String content, bool isMentioned}) botCommandContext(
  String content, {
  required bool isGroup,
  required String eventType,
  String botId = '',
  String botName = '',
  List<dynamic> mentions = const [],
}) {
  if (!isGroup ||
      !{
        'GROUP_AT_MESSAGE_CREATE',
        'GROUP_MESSAGE_CREATE',
      }.contains(eventType)) {
    return (content: content, isMentioned: false);
  }
  final authoritativeAt = eventType == 'GROUP_AT_MESSAGE_CREATE';
  final selfIds = <String>{if (botId.isNotEmpty) botId};
  final selfNames = <String>{};
  var mentioned = authoritativeAt;
  for (final user in mentions.whereType<Map>()) {
    final ids = {
      for (final key in ['id', 'openid', 'user_openid', 'member_openid'])
        if ((user[key]?.toString() ?? '').isNotEmpty) user[key].toString(),
    };
    // Some deliveries include an explicit self marker. Do not mistake bot=true
    // (which can describe any bot in the group) for is_you=true.
    if (user['is_you'] == true || (botId.isNotEmpty && ids.contains(botId))) {
      mentioned = true;
      selfIds.addAll(ids);
      final name = user['username']?.toString().trim() ?? '';
      if (name.isNotEmpty) selfNames.add(name);
    }
  }
  final leading = _leadingMention.firstMatch(content);
  final target = leading?.group(1) ?? leading?.group(2);
  if (leading != null && (authoritativeAt || selfIds.contains(target))) {
    mentioned = true;
    content = content.substring(leading.end);
  } else {
    // Only use a bare display-name fallback when no structured recipient data
    // exists. Explicitly addressing another ID must not be overridden by name.
    if (botName.trim().isNotEmpty &&
        (authoritativeAt || mentioned || mentions.isEmpty)) {
      selfNames.add(botName.trim());
    }
    for (final name
        in selfNames.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      final prefix = RegExp(
        '^\\s*@${RegExp.escape(name)}(?=\\s|[/#]|\$)\\s*',
      ).firstMatch(content);
      if (prefix != null) {
        mentioned = true;
        content = content.substring(prefix.end);
        break;
      }
    }
  }
  return (content: content, isMentioned: mentioned);
}
