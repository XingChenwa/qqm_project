import '../models/message.dart';
import '../models/outgoing_message.dart';
import '../models/plugin.dart';
import '../utils/helpers.dart';
import '../utils/bot_command_context.dart';
import 'bot_client.dart';
import 'plugin_manager.dart';

/// UI-independent host used by the Linux service. The same loaders, permission
/// rules, reply sequences and per-AppID stores are used as the native clients.
class PluginDispatcher {
  final BotClient bot;
  final PluginManager manager;
  PluginDispatcher(this.bot, this.manager);

  Future<bool> process(MessageModel message) async {
    if (!bot.shouldAutoRespondTo(message)) return false;
    final epoch = bot.accountEpoch;
    final command = botCommandContext(
      message.extra?['rawContent']?.toString() ?? message.content,
      isGroup: message.extra?['isGroup'] == true,
      eventType: message.extra?['eventType']?.toString() ?? '',
      botId: bot.botId,
      botName: bot.botName,
      mentions: message.extra?['mentions'] is List
          ? message.extra!['mentions'] as List
          : message.rawEvent['mentions'] as List? ?? [],
    );
    final responses = await manager.processMessage(
      PluginMessage(
        messageId: message.id,
        sessionId: message.sessionId,
        senderId: message.senderId,
        senderName: message.senderName,
        content: command.content,
        messageType: message.messageType,
        isGroup: message.extra?['isGroup'] == true,
        timestamp: message.timestamp,
        senderRole: message.receivedBody.authorRole.isNotEmpty
            ? message.receivedBody.authorRole
            : message.extra?['senderRole']?.toString() ?? '',
        isFullGroupMessage: message.isFullGroupMessage,
        isMentioned: command.isMentioned,
        eventType: message.extra?['pluginEventId'] == null
            ? 'message'
            : 'interaction',
        callbackData: message.extra?['callbackData']?.toString() ?? '',
        attachments: [
          for (final a in message.receivedBody.attachments)
            {
              'url': a.url,
              'filename': a.filename,
              'content_type': a.contentType,
              'width': a.width,
              'height': a.height,
              'size': a.size,
            },
        ],
      ),
    );
    if (bot.accountEpoch != epoch) return false;
    for (final response in responses) {
      if (bot.accountEpoch != epoch) return false;
      final reply = response.reply;
      final isGroup = message.extra?['isGroup'] == true;
      bool sent;
      if (reply != null && reply.format != 'auto') {
        if (reply.buttons
            .expand((row) => row)
            .any(
              (button) =>
                  button.callback &&
                  !button.data.startsWith('qqm:${response.pluginId}:'),
            )) {
          bot.onLog?.call('插件按钮回调命名空间无效，已拒绝发送。');
          continue;
        }
        final eventId = message.extra?['pluginEventId']?.toString() ?? '';
        sent = await bot.sendConfiguredMessage(
          message.sessionId,
          OutgoingMessage(
            type: reply.format == 'media'
                ? 7
                : reply.format == 'markdown'
                ? 2
                : 0,
            content: reply.content,
            mediaSource: reply.mediaUrl,
            mediaFileType: reply.mediaType,
            options: MessageSendOptions(
              replyMode: eventId.isEmpty
                  ? ReplyMode.automatic
                  : ReplyMode.event,
              eventId: eventId,
              quoteSelectedMessage: false,
              keyboard: reply.buttons.isEmpty
                  ? null
                  : MessageKeyboard(
                      rows: [
                        for (var i = 0; i < reply.buttons.length; i++)
                          [
                            for (var j = 0; j < reply.buttons[i].length; j++)
                              MessageButton(
                                id: 'plugin_${i}_$j',
                                label: reply.buttons[i][j].label,
                                visitedLabel: reply.buttons[i][j].label,
                                data: reply.buttons[i][j].data,
                                actionType: reply.buttons[i][j].url
                                    ? 0
                                    : reply.buttons[i][j].callback
                                    ? 1
                                    : 2,
                                permissionType:
                                    reply.buttons[i][j].userIds.isEmpty ? 2 : 0,
                                userIds: reply.buttons[i][j].userIds,
                              ),
                          ],
                      ],
                    ),
            ),
          ),
          isGroup: isGroup,
          replyTo: message,
        );
      } else {
        sent = await (containsMarkdown(response.content)
            ? bot.sendMarkdownMessage(
                message.sessionId,
                response.content,
                isGroup: isGroup,
                replyTo: message,
              )
            : bot.sendTextMessage(
                message.sessionId,
                response.content,
                isGroup: isGroup,
                replyTo: message,
              ));
      }
      bot.onLog?.call(
        '插件 ${response.pluginName} ${sent ? '回复已发送到 QQ' : '回复发送失败：${bot.lastSendError}'}',
      );
    }
    return responses.isNotEmpty;
  }
}
