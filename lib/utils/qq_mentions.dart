const qqUserMentionPattern =
    r'<qqbot-at-user\s+id="([A-Za-z0-9_-]{1,128})"\s*/>';
const qqEveryoneMentionPattern = r'<qqbot-at-everyone\s*/>';
const qqMentionPattern = '(?:$qqUserMentionPattern|$qqEveryoneMentionPattern)';
bool containsQqUserMention(String text) =>
    RegExp(qqUserMentionPattern).hasMatch(text);
bool containsQqEveryoneMention(String text) =>
    RegExp(qqEveryoneMentionPattern).hasMatch(text);
bool containsQqMention(String text) => RegExp(qqMentionPattern).hasMatch(text);
