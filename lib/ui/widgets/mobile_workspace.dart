import 'package:flutter/material.dart';

import '../themes/app_theme.dart';
import 'profile_avatar.dart';

/// Phone navigation deliberately stays separate from the desktop workbench.
class MobileWorkspace extends StatelessWidget {
  final GlobalKey<ScaffoldState> scaffoldKey;
  final bool chatting, connected, connecting, isGroup;
  final int section;
  final String title, botLabel;
  final String? avatarUrl;
  final Widget body;
  final VoidCallback onBack, onSwitchBot, onConnection, onSettings, onNewChat;
  final ValueChanged<int> onNavigate;
  final VoidCallback? onNotifications;
  final VoidCallback? onHistory;
  final VoidCallback? onAgent;
  final int notificationCount;
  final String settingsLabel;

  const MobileWorkspace({
    super.key,
    required this.scaffoldKey,
    required this.chatting,
    required this.connected,
    required this.connecting,
    required this.section,
    required this.title,
    required this.botLabel,
    required this.body,
    required this.onBack,
    required this.onSwitchBot,
    required this.onConnection,
    required this.onSettings,
    required this.onNewChat,
    required this.onNavigate,
    this.isGroup = false,
    this.avatarUrl,
    this.onNotifications,
    this.onHistory,
    this.onAgent,
    this.notificationCount = 0,
    this.settingsLabel = '设置',
  });

  static const _sections = [2, 3, 0, 4];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = connecting
        ? '连接中'
        : connected
        ? '已连接'
        : '未连接';
    final statusColor = connected ? AppTheme.qqGreen : theme.hintColor;
    return PopScope(
      canPop: !chatting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && chatting) onBack();
      },
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: section == 2 ? theme.colorScheme.surface : null,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          toolbarHeight: chatting ? 66 : 72,
          titleSpacing: chatting ? 0 : 20,
          leading: chatting
              ? IconButton(
                  tooltip: '返回会话列表',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                )
              : null,
          title: chatting
              ? Row(
                  children: [
                    ProfileAvatar(
                      name: title,
                      url: avatarUrl ?? '',
                      isGroup: isGroup,
                      radius: 19,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Tooltip(
                            message: '切换机器人',
                            child: InkWell(
                              onTap: onSwitchBot,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Flexible(
                                    child: Text(
                                      '$botLabel · $status',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: statusColor,
                                      ),
                                    ),
                                  ),
                                  const Icon(Icons.expand_more, size: 14),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              : Text(
                  title,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                  ),
                ),
          actions: [
            if (!chatting && onAgent != null)
              IconButton(
                tooltip: 'QQ Agent 独立工作区',
                onPressed: onAgent,
                icon: const Icon(Icons.auto_awesome_outlined, size: 22),
              ),
            if (chatting && onHistory != null)
              IconButton(
                tooltip: '聊天记录',
                onPressed: onHistory,
                icon: const Icon(Icons.history_rounded, size: 22),
              ),
            if (!chatting && section == 2)
              IconButton(
                tooltip: '新建会话',
                onPressed: onNewChat,
                icon: const Icon(Icons.add_comment_outlined, size: 23),
              ),
            if (onNotifications != null)
              IconButton(
                tooltip: '消息与通知',
                onPressed: onNotifications,
                icon: Badge(
                  isLabelVisible: notificationCount > 0,
                  label: Text(
                    notificationCount > 99 ? '99+' : '$notificationCount',
                  ),
                  child: const Icon(Icons.notifications_none_rounded, size: 23),
                ),
              ),
            IconButton(
              tooltip: settingsLabel,
              onPressed: onSettings,
              icon: const Icon(Icons.settings_outlined, size: 23),
            ),
            const SizedBox(width: 4),
          ],
          bottom: chatting
              ? null
              : PreferredSize(
                  preferredSize: const Size.fromHeight(54),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Tooltip(
                            message: '切换机器人',
                            child: Material(
                              color: theme.colorScheme.primary.withValues(
                                alpha: .06,
                              ),
                              borderRadius: BorderRadius.circular(14),
                              child: InkWell(
                                onTap: onSwitchBot,
                                borderRadius: BorderRadius.circular(14),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 12,
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.smart_toy_outlined,
                                        color: AppTheme.qqBlue,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          botLabel,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      const Icon(
                                        Icons.unfold_more_rounded,
                                        size: 16,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: connecting ? null : onConnection,
                          icon: connecting
                              ? const SizedBox.square(
                                  dimension: 12,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  connected
                                      ? Icons.check_circle_rounded
                                      : Icons.link_rounded,
                                  size: 16,
                                ),
                          label: Text(status),
                          style: TextButton.styleFrom(
                            foregroundColor: statusColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        body: SafeArea(top: false, child: body),
        bottomNavigationBar: chatting
            ? null
            : DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: theme.dividerColor)),
                ),
                child: NavigationBar(
                  selectedIndex: _sections.indexOf(section).clamp(0, 3),
                  onDestinationSelected: (index) =>
                      onNavigate(_sections[index]),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.chat_bubble_outline_rounded),
                      selectedIcon: Icon(Icons.chat_bubble_rounded),
                      label: '会话',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.extension_outlined),
                      selectedIcon: Icon(Icons.extension_rounded),
                      label: '插件',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.space_dashboard_outlined),
                      selectedIcon: Icon(Icons.space_dashboard_rounded),
                      label: '总览',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.receipt_long_outlined),
                      selectedIcon: Icon(Icons.receipt_long_rounded),
                      label: '日志',
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
