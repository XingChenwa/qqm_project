import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/ui/widgets/message_bubble.dart';
import 'package:qq_bot_manager/ui/widgets/profile_avatar.dart';

void main() {
  for (final group in [false, true]) {
    testWidgets('${group ? "群成员" : "单聊用户"}消息保留个人头像，不当作QQ群头像', (tester) async {
      const avatarUrl = 'https://q.qlogo.cn/qqapp/10000001/person-openid/640';
      final message = MessageModel(
        id: 'incoming',
        sessionId: group ? 'group-openid' : 'person-openid',
        senderId: 'person-openid',
        senderName: '测试用户',
        senderAvatarUrl: avatarUrl,
        content: '你好',
        messageType: 0,
        timestamp: DateTime(2026, 10, 20),
        extra: {
          'eventType': group ? 'GROUP_MESSAGE_CREATE' : 'C2C_MESSAGE_CREATE',
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageBubble(message: message)),
        ),
      );
      final avatar = tester.widget<ProfileAvatar>(find.byType(ProfileAvatar));
      expect(avatar.isGroup, isFalse);
      expect(avatar.url, avatarUrl);
      expect(
        tester
            .widget<CachedNetworkImage>(find.byType(CachedNetworkImage))
            .imageUrl,
        avatarUrl,
      );
      expect(find.byIcon(Icons.groups_rounded), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('QQ群会话只显示群图标，即使旧记录仍存有群头像URL', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ProfileAvatar(
            name: '测试群',
            url: 'https://example.invalid/old-group-avatar.png',
            isGroup: true,
          ),
        ),
      ),
    );
    expect(find.byType(CachedNetworkImage), findsNothing);
    expect(find.byIcon(Icons.groups_rounded), findsOneWidget);
  });
}
