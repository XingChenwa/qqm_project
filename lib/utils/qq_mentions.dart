const qqUserMentionPattern =
    r'<qqbot-at-user\s+id="([A-Za-z0-9_-]{1,128})"\s*/>';
bool containsQqUserMention(String text) =>
    RegExp(qqUserMentionPattern).hasMatch(text);
