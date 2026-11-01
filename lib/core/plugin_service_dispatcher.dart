import '../models/outgoing_message.dart';
import '../services/storage_service.dart';
import '../utils/inline_image.dart';
import 'bot_client.dart';
import 'plugin_manager.dart';

/// External services never receive QQ secrets. Only this host can execute the
/// small set of declared actions, under the current original-workbench AppID.
class PluginServiceDispatcher {
  final BotClient bot;
  final StorageService storage;
  PluginServiceDispatcher(this.bot, this.storage);

  void bind(PluginManager manager) {
    manager.serviceReady = () => bot.isConnected;
    manager.serviceRequest = dispatch;
  }

  Future<Map<String, dynamic>> dispatch(Map<String, dynamic> value) async {
    final epoch = bot.accountEpoch;
    bool current() =>
        bot.accountEpoch == epoch &&
        bot.isConnected &&
        value['app_id'] == bot.config.appId &&
        value['app_id'] == storage.activeBotAppId;
    Map<String, dynamic> failure(String error) => {'ok': false, 'error': error};
    if (!current()) return failure('机器人已切换或尚未连接。');
    final target = value['target_id'];
    final isGroup = value['is_group'];
    if (target is! String ||
        target.isEmpty ||
        target.length > 128 ||
        isGroup is! bool ||
        !storage.getSessions().any(
          (s) => s.id == target && (s.sessionType == 1) == isGroup,
        )) {
      return failure('只能访问当前 AppID 已存在的会话。');
    }
    try {
      switch (value['action']) {
        case 'members':
          if (!isGroup) return failure('成员列表只适用于群聊。');
          final members = <Map<String, dynamic>>[];
          var cursor = '';
          final cursors = <String>{};
          final deadline = DateTime.now().add(const Duration(seconds: 45));
          for (var page = 0; page < 50; page++) {
            if (DateTime.now().isAfter(deadline)) {
              return failure('群成员分页查询超时，请稍后重试。');
            }
            final data = await bot.groups.members(
              bot.groups.target(target),
              cursor: cursor,
            );
            if (!current()) return failure('机器人已切换。');
            final rows = data['members'];
            if (rows is! List) return failure('群成员接口返回格式异常。');
            for (final row in rows.whereType<Map>()) {
              members.add({
                for (final key in [
                  'member_openid',
                  'user_openid',
                  'id',
                  'username',
                  'member_role',
                ])
                  if (row[key] is String) key: row[key],
              });
            }
            cursor = data['next_cursor']?.toString() ?? '';
            if (cursor.isEmpty) return {'ok': true, 'members': members};
            if (members.length > 10000 || !cursors.add(cursor)) break;
          }
          return failure('成员列表过大或分页异常，未返回不完整的群名单。');
        case 'recall':
          final message = storage.getMessageById(
            value['message_id']?.toString() ?? '',
          );
          if (message == null ||
              !message.isFromBot ||
              message.sessionId != target) {
            return failure('只能撤回当前会话中机器人自己发送的消息。');
          }
          final ok = await bot.recallMessage(message);
          return {'ok': ok, if (!ok) 'error': '撤回失败，请检查平台时限和权限。'};
        case 'send':
          final proactive = value['proactive'] == true;
          final replyId = value['reply_to_message_id']?.toString() ?? '';
          final source = storage.getMessageById(replyId);
          if (!proactive &&
              (source == null ||
                  source.sessionId != target ||
                  source.isBotAuthor ||
                  (source.extra?['isGroup'] == true) != isGroup ||
                  DateTime.now().difference(source.timestamp) >
                      const Duration(minutes: 5))) {
            return failure('原消息不存在或被动回复已超过 5 分钟。');
          }
          final content = value['content'] ?? '';
          if (content is! String || content.length > 16000) {
            return failure('插件文本过长。');
          }
          final format = value['format'];
          var media = '';
          if (format == 'media') {
            final data = value['media_base64'];
            final mime = value['mime'];
            if (value['media_type'] != 1 ||
                data is! String ||
                ![
                  'image/png',
                  'image/jpeg',
                  'image/gif',
                  'image/webp',
                ].contains(mime)) {
              return failure('桥接只接受实际图片数据。');
            }
            media = 'data:$mime;base64,$data';
            inlineImageBytes(media);
          } else if (!['text', 'markdown'].contains(format) ||
              content.trim().isEmpty) {
            return failure('插件消息格式无效。');
          }
          if (!current()) return failure('机器人已切换。');
          var messageId = '';
          final ok = await bot.sendConfiguredMessage(
            target,
            OutgoingMessage(
              type: media.isNotEmpty
                  ? 7
                  : format == 'markdown'
                  ? 2
                  : 0,
              content: content,
              mediaSource: media,
              options: MessageSendOptions(
                replyMode: proactive ? ReplyMode.active : ReplyMode.message,
                messageId: proactive ? '' : replyId,
                quoteSelectedMessage: false,
              ),
            ),
            isGroup: isGroup,
            replyTo: proactive ? null : source,
            onSent: (id) {
              messageId = id;
            },
          );
          return {
            'ok': ok,
            if (ok) 'message_id': messageId,
            if (!ok) 'error': 'QQ 平台发送失败，请检查管理器日志。',
          };
        default:
          return failure('宿主不支持此桥接操作。');
      }
    } catch (_) {
      return failure('宿主执行失败，请检查平台接口权限、素材或网络。');
    }
  }
}
