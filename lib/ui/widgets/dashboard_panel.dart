import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/bot_client.dart';
import '../../core/plugin_manager.dart';
import '../../utils/helpers.dart';
import '../themes/app_theme.dart';

class DashboardPanel extends StatelessWidget {
  final BotClient bot;
  final VoidCallback onOpenChat;
  final VoidCallback onOpenPlugins;
  final VoidCallback onOpenSettings;
  const DashboardPanel({
    super.key,
    required this.bot,
    required this.onOpenChat,
    required this.onOpenPlugins,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final plugins = context.watch<PluginManager>();
    final configured =
        bot.config.appId.isNotEmpty && bot.config.clientSecret.isNotEmpty;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 850;
        final metrics = [
          ('会话总数', '${bot.sessions.length}', Icons.forum_outlined),
          (
            '未读消息',
            '${bot.sessions.fold<int>(0, (sum, s) => sum + s.unreadCount)}',
            Icons.mark_chat_unread_outlined,
          ),
          ('运行中插件', '${plugins.enabledCount}', Icons.extension_outlined),
          (
            '全量群事件',
            '${bot.fullGroupMessageCount}',
            Icons.dynamic_feed_outlined,
          ),
        ];
        final columns = constraints.maxWidth >= 700 ? 4 : 2;
        final metricWidth =
            (constraints.maxWidth - 32 - (columns - 1) * 12) / columns;
        final setup = _section(
          context,
          '开始使用',
          Icons.rocket_launch_outlined,
          Column(
            children: [
              _step(
                context,
                1,
                '配置机器人',
                '优先扫码授权，也可手动填写凭据',
                configured,
                onOpenSettings,
              ),
              _step(
                context,
                2,
                '查看聊天会话',
                '连接后接收群聊和单聊消息',
                bot.isConnected,
                onOpenChat,
              ),
              _step(
                context,
                3,
                '添加扩展能力',
                '配置天气或导入自己的插件',
                plugins.enabledCount > 0,
                onOpenPlugins,
              ),
            ],
          ),
        );
        final recent = _section(
          context,
          '最近会话',
          Icons.history_rounded,
          Column(
            children: [
              if (bot.sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 35),
                  child: Text(
                    '还没有会话，连接机器人后会自动出现。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: AppTheme.muted),
                  ),
                )
              else
                for (final session in bot.sessions.take(3))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: AppTheme.qqBlue.withValues(alpha: .08),
                      child: Icon(
                        session.sessionType == 1
                            ? Icons.groups_outlined
                            : Icons.person_outline,
                        color: AppTheme.qqBlue,
                      ),
                    ),
                    title: Text(
                      session.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      session.lastMessage.isEmpty
                          ? '暂无消息'
                          : session.lastMessage,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: Text(
                      formatTimestamp(session.lastMessageTime),
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.muted,
                      ),
                    ),
                    onTap: onOpenChat,
                  ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onOpenChat,
                  child: const Text('进入聊天工作台 →'),
                ),
              ),
            ],
          ),
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: Theme.of(context).brightness == Brightness.dark
                      ? const [Color(0xFF1B2C4D), Color(0xFF1A2334)]
                      : const [Color(0xFFE7EEFF), Color(0xFFF7FAFF)],
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '你的机器人工作空间',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      height: 1.4,
                      letterSpacing: -.6,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '把连接、对话和扩展，放在一个工作台。',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilledButton.icon(
                        onPressed: onOpenSettings,
                        icon: const Icon(Icons.tune, size: 17),
                        label: Text(configured ? '管理机器人' : '配置机器人'),
                      ),
                      OutlinedButton.icon(
                        onPressed: onOpenPlugins,
                        icon: const Icon(Icons.add_box_outlined, size: 17),
                        label: const Text('添加插件'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final metric in metrics)
                  SizedBox(
                    width: metricWidth,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(metric.$3, size: 20, color: AppTheme.qqBlue),
                            const SizedBox(height: 12),
                            Text(
                              metric.$2,
                              style: const TextStyle(
                                fontSize: 27,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              metric.$1,
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppTheme.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: setup),
                  const SizedBox(width: 16),
                  Expanded(child: recent),
                ],
              )
            else ...[
              setup,
              const SizedBox(height: 16),
              recent,
            ],
          ],
        );
      },
    );
  }

  Widget _section(
    BuildContext context,
    String title,
    IconData icon,
    Widget child,
  ) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.qqBlue, size: 20),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    ),
  );

  Widget _step(
    BuildContext context,
    int number,
    String title,
    String subtitle,
    bool done,
    VoidCallback action,
  ) => ListTile(
    contentPadding: EdgeInsets.zero,
    onTap: action,
    leading: Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: (done ? AppTheme.qqGreen : AppTheme.qqBlue).withValues(
          alpha: .08,
        ),
        borderRadius: BorderRadius.circular(11),
      ),
      child: done
          ? const Icon(Icons.check, size: 18, color: AppTheme.qqGreen)
          : Text(
              '$number',
              style: const TextStyle(
                color: AppTheme.qqBlue,
                fontWeight: FontWeight.w700,
              ),
            ),
    ),
    title: Text(
      title,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
    trailing: const Icon(Icons.chevron_right, size: 18),
  );
}
