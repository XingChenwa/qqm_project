import '../../utils/platforms.dart';
import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/bot_client.dart';
import '../../core/plugin_manager.dart';
import '../../models/outgoing_message.dart';
import '../../models/message.dart';
import '../../models/plugin.dart';
import '../../utils/helpers.dart';
import '../../utils/bot_command_context.dart';
import '../../utils/constants.dart';
import '../../utils/message_history.dart';
import '../../services/ip_whitelist_service.dart';
import '../../services/storage_service.dart';
import '../../services/mobile_notifications.dart';
import '../themes/app_theme.dart';
import '../widgets/chat_input.dart';
import '../widgets/mobile_workspace.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/message_bubble.dart';
import '../widgets/group_member_actions.dart';
import '../widgets/chat_timeline.dart';
import '../widgets/plugin_panel.dart';
import '../widgets/dashboard_panel.dart';
import '../widgets/log_panel.dart';
import '../widgets/app_logo.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/ip_whitelist_dialog.dart';
import 'settings_screen.dart';
import 'notifications_screen.dart';
import 'group_settings_screen.dart';
import 'chat_history_screen.dart';

class MainScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  final ThemeMode themeMode;
  final bool openSettingsOnStart;

  const MainScreen({
    super.key,
    required this.toggleTheme,
    required this.themeMode,
    this.openSettingsOnStart = false,
  });

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final ScrollController _messageScrollController = ScrollController(
    keepScrollOffset: false,
  );
  final List<String> _logs = [];
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final _historySearch = TextEditingController();
  Timer? _historySearchDebounce;
  String _historyQuery = '';
  int _searchLimit = 60;
  int? _sessionTypeFilter;

  ChatSession? _selectedSession;
  BotClient? _botClient;
  MessageModel? _replyToMessage;
  final _composerController = ChatInputController();
  int _sideIndex = 2;
  bool _mobileChatOpen = false;
  bool _startupConnectTried = false;
  int _chatOpenRevision = 0;
  int _chatSentRevision = 0;
  int _accountEpoch = -1;
  IpWhitelistProblem? _shownIpWhitelistProblem;
  MobileNotifications? _notifications;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final client = context.read<BotClient>();
      _botClient = client;
      _accountEpoch = client.accountEpoch;
      client.refresh();
      _selectFirstSessionIfNeeded(client);
      client.addListener(_onBotUpdate);
      client.onLog = _addLog;
      client.onMessageReceived = _processWithPlugins;
      _notifications = MobileNotifications(
        bot: client,
        storage: context.read<StorageService>(),
        visibleSession: () =>
            _sideIndex == 2 && _mobileChatOpen ? _selectedSession?.id : null,
        onOpen: _openSystemNotification,
      );
      unawaited(_notifications!.start());
      if (_selectedSession != null) {
        client.refreshSessionProfile(_selectedSession!.id);
      }
      _tryStartupConnect(client);
      if (widget.openSettingsOnStart) _openSettings();
    });
  }

  @override
  void dispose() {
    _notifications?.dispose();
    _botClient?.removeListener(_onBotUpdate);
    _messageScrollController.dispose();
    _composerController.dispose();
    _historySearchDebounce?.cancel();
    _historySearch.dispose();
    super.dispose();
  }

  Future<void> _openSystemNotification(
    String appId,
    String sessionId,
    String noticeId,
  ) async {
    if (!mounted) return;
    final bot = context.read<BotClient>();
    if (bot.config.appId != appId) await bot.switchBot(appId);
    if (!mounted || bot.config.appId != appId) return;
    if (noticeId.isNotEmpty) {
      await _openNotifications(groupId: sessionId);
      return;
    }
    final session = bot.sessions.where((s) => s.id == sessionId).firstOrNull;
    if (session == null) return;
    setState(() {
      _sideIndex = 2;
      _selectedSession = session;
      _mobileChatOpen = true;
      _replyToMessage = null;
      _chatOpenRevision++;
    });
    await bot.markSessionRead(session.id);
  }

  Future<void> _openNotifications({String? groupId}) async {
    _notifications?.inboxVisible = true;
    try {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => NotificationsScreen(
            systemNotifications: _notifications,
            groupId: groupId,
          ),
        ),
      );
    } finally {
      _notifications?.inboxVisible = false;
    }
  }

  Future<void> _openSessionSettings(ChatSession session) => Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => GroupSettingsScreen(session: session)),
  );

  Future<void> _openHistory(ChatSession session, {String? messageId}) async {
    final bot = context.read<BotClient>();
    final target = bot.groups.target(session.id);
    final selection = await Navigator.push<ChatHistorySelection>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ChatHistoryScreen(session: session, initialMessageId: messageId),
      ),
    );
    if (!mounted ||
        !bot.groups.isCurrent(target) ||
        _selectedSession?.id != session.id) {
      return;
    }
    if (selection?.reply != null) {
      setState(() => _replyToMessage = selection!.reply);
    }
    if (selection?.mention case final memberId?) {
      _composerController.mention(memberId);
    }
  }

  Widget _notificationBell(BotClient bot) => IconButton(
    tooltip: '消息与通知',
    onPressed: () => _openNotifications(),
    icon: Badge(
      isLabelVisible: bot.groups.unreadCount > 0,
      label: Text(
        bot.groups.unreadCount > 99 ? '99+' : '${bot.groups.unreadCount}',
      ),
      child: const Icon(Icons.notifications_none_rounded),
    ),
  );

  Future<void> _sessionMenu(ChatSession session, BotClient bot) async {
    final target = bot.groups.target(session.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(session.name, overflow: TextOverflow.ellipsis),
            ),
            ListTile(
              leading: Icon(
                session.isMuted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(session.isMuted ? '取消屏蔽消息提醒' : '屏蔽消息提醒'),
              subtitle: const Text('保留记录，不影响机器人和插件收发'),
              onTap: () => Navigator.pop(sheet, 'mute'),
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: Text(session.sessionType == 1 ? '群聊设置' : '用户设置'),
              onTap: () => Navigator.pop(sheet, 'settings'),
            ),
          ],
        ),
      ),
    );
    if (!mounted ||
        !bot.groups.isCurrent(target) ||
        !bot.sessions.any((s) => s.id == session.id)) {
      return;
    }
    if (action == 'settings') {
      await _openSessionSettings(session);
    } else if (action == 'mute') {
      try {
        await bot.setSessionMuted(
          session.id,
          !session.isMuted,
          expected: target,
        );
      } catch (_) {
        if (mounted) {
          await AppDialogs.show(context, '免打扰设置未保存，请重试', error: true);
        }
      }
    }
  }

  Future<void> _tryStartupConnect(BotClient client) async {
    if (_startupConnectTried || client.isConnected || client.isConnecting) {
      return;
    }
    _startupConnectTried = true;

    final config = client.config;
    if (config.appId.isEmpty || config.clientSecret.isEmpty) {
      _addLog(
        '[${_clockText(DateTime.now())}] 未配置 AppID / ClientSecret，已跳过自动连接',
      );
      return;
    }
    await client.connect();
  }

  void _addLog(String log) {
    if (!mounted || _botClient?.config.enableLogging == false) return;
    setState(() {
      _logs.add(log);
      if (_logs.length > 10000) _logs.removeAt(0);
    });
  }

  void _onBotUpdate() {
    if (!mounted) return;
    final epoch = _botClient?.accountEpoch ?? -1;
    if (epoch != _accountEpoch) {
      _accountEpoch = epoch;
      _selectedSession = null;
      _replyToMessage = null;
      _historySearchDebounce?.cancel();
      _historySearch.clear();
      _historyQuery = '';
      _searchLimit = 60;
      _sessionTypeFilter = null;
      _mobileChatOpen = false;
      _chatOpenRevision++;
    }
    _selectFirstSessionIfNeeded(_botClient);
    setState(() {});
    final bot = _botClient;
    final problem = bot?.ipWhitelistProblem;
    if (bot != null &&
        problem != null &&
        !identical(problem, _shownIpWhitelistProblem)) {
      _shownIpWhitelistProblem = problem;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(bot.ipWhitelistProblem, problem)) return;
        unawaited(
          AppDialogs.present<void>(
            context,
            key: 'ip-whitelist:${problem.appId}',
            stillRelevant: () =>
                mounted && identical(bot.ipWhitelistProblem, problem),
            builder: (_) => IpWhitelistDialog(problem: problem),
          ).whenComplete(() => bot.dismissIpWhitelistProblem(problem)),
        );
      });
    }
  }

  void _selectFirstSessionIfNeeded(BotClient? client) {
    if (client == null) return;
    if (_selectedSession != null) {
      final matches = client.sessions.where(
        (session) => session.id == _selectedSession!.id,
      );
      if (matches.isNotEmpty) {
        _selectedSession = matches.first;
        return;
      }
      _selectedSession = null;
    }
    if (client.sessions.isEmpty) return;
    _selectedSession = client.sessions.first;
  }

  Future<bool> _processWithPlugins(MessageModel message) async {
    if (!mounted || !context.read<BotClient>().shouldAutoRespondTo(message)) {
      return false;
    }
    final activeBot = context.read<BotClient>();
    final epoch = activeBot.accountEpoch;
    final rawContent =
        message.extra?['rawContent']?.toString() ?? message.content;
    final commandContext = botCommandContext(
      rawContent,
      isGroup: message.extra?['isGroup'] == true,
      eventType: message.extra?['eventType']?.toString() ?? '',
      botId: activeBot.botId,
      botName: activeBot.botName,
      mentions: message.extra?['mentions'] is List
          ? message.extra!['mentions'] as List
          : message.rawEvent['mentions'] is List
          ? message.rawEvent['mentions'] as List
          : const [],
    );
    final pluginMessage = PluginMessage(
      messageId: message.id,
      sessionId: message.sessionId,
      senderId: message.senderId,
      senderName: message.senderName,
      content: commandContext.content,
      messageType: message.messageType,
      isGroup: message.extra?['isGroup'] == true,
      timestamp: message.timestamp,
      // Do not elevate a command using an older cached profile role.
      senderRole: message.receivedBody.authorRole.isNotEmpty
          ? message.receivedBody.authorRole
          : message.extra?['senderRole']?.toString() ?? '',
      isFullGroupMessage: message.isFullGroupMessage,
      isMentioned: commandContext.isMentioned,
      eventType: message.extra?['pluginEventId'] != null
          ? 'interaction'
          : 'message',
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
    );

    final plugins = context.read<PluginManager>();
    if (parseSlashCommand(commandContext.content)?.command == '主动消息' &&
        (!message.isFullGroupMessage || commandContext.isMentioned) &&
        !plugins.plugins.any(
          (plugin) =>
              plugin.info.id == 'group_authorization' && plugin.info.isEnabled,
        )) {
      _addLog('[${_clockText(DateTime.now())}] 主动消息权限插件未启用，请在「插件」中手动开启。');
    }
    final responses = await plugins.processMessage(pluginMessage);
    if (!mounted || activeBot.accountEpoch != epoch) return false;

    final bot = activeBot;
    for (final response in responses) {
      if (!mounted || bot.accountEpoch != epoch) return false;
      final sent = await _sendPluginResponse(
        bot,
        message,
        response.content,
        reply: response.reply,
        pluginId: response.pluginId,
      );
      bot.onLog?.call(
        '[${_clockText(DateTime.now())}] 插件 ${response.pluginName} ${sent ? '回复已发送到 QQ' : '回复发送失败: ${bot.lastSendError}'}',
      );
    }
    return responses.isNotEmpty;
  }

  Future<bool> _sendPluginResponse(
    BotClient bot,
    MessageModel source,
    String content, {
    PluginReply? reply,
    String pluginId = '',
  }) {
    final isGroup = source.extra?['isGroup'] == true;
    if (reply != null && reply.format != 'auto') {
      for (final button in reply.buttons.expand((row) => row)) {
        if (button.callback && !button.data.startsWith('qqm:$pluginId:')) {
          bot.onLog?.call('插件按钮回调必须使用所属插件的命名空间。');
          return Future.value(false);
        }
      }
      final eventId = source.extra?['pluginEventId']?.toString() ?? '';
      return bot.sendConfiguredMessage(
        source.sessionId,
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
            replyMode: eventId.isEmpty ? ReplyMode.automatic : ReplyMode.event,
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
        replyTo: source,
      );
    }
    return containsMarkdown(content)
        ? bot.sendMarkdownMessage(
            source.sessionId,
            content,
            isGroup: isGroup,
            replyTo: source,
          )
        : bot.sendTextMessage(
            source.sessionId,
            content,
            isGroup: isGroup,
            replyTo: source,
          );
  }

  @override
  Widget build(BuildContext context) {
    final bot = context.watch<BotClient>();
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (usePhoneLayout(context)) return _mobileScaffold(bot);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: isDark ? AppTheme.darkBg : AppTheme.lightBg,
      body: Row(
        children: [
          _navigationRail(bot),
          Expanded(
            child: Column(
              children: [
                _titleBar(bot),
                if (bot.isConnecting) _progressBar(bot),
                if (bot.connectionError.isNotEmpty) _errorBanner(bot),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return Padding(
                        padding: const EdgeInsets.all(16),
                        child: switch (_sideIndex) {
                          0 => DashboardPanel(
                            bot: bot,
                            onOpenChat: () => _navigateTo(2),
                            onOpenPlugins: () => _navigateTo(3),
                            onOpenSettings: _openSettings,
                          ),
                          3 => _panel(child: const PluginPanel()),
                          4 => _panel(child: LogPanel(logs: _logs)),
                          _ => Row(
                            children: [
                              _sessionPanel(
                                bot,
                                width: _layoutFor(
                                  constraints.maxWidth,
                                ).sessionWidth,
                              ),
                              const SizedBox(width: 16),
                              Expanded(child: _conversation(bot)),
                            ],
                          ),
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navigationRail(BotClient bot) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: MediaQuery.sizeOf(context).width < 1180 ? 76 : 188,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSidebar : AppTheme.lightSidebar,
        border: Border(
          right: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 82,
            child: Row(
              children: [
                const SizedBox(width: 18),
                const AppLogo(),
                if (MediaQuery.sizeOf(context).width >= 1180)
                  const SizedBox(width: 10),
                if (MediaQuery.sizeOf(context).width >= 1180)
                  const Expanded(
                    child: Text(
                      'QQ 机器人\n工作台',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        height: 1.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  _navItem(0, Icons.dashboard_rounded, '总览'),
                  _navItem(2, Icons.chat_bubble_outline_rounded, '聊天会话'),
                  _navItem(3, Icons.extension_rounded, '插件'),
                  _navItem(4, Icons.receipt_long_rounded, '日志'),
                  _navItem(
                    6,
                    Icons.settings_rounded,
                    '设置',
                    onTap: _openSettings,
                  ),
                ],
              ),
            ),
          ),
          if (MediaQuery.sizeOf(context).width >= 1180) _systemStatusCard(bot),
          Padding(
            padding: EdgeInsets.fromLTRB(
              MediaQuery.sizeOf(context).width < 1180 ? 8 : 16,
              10,
              MediaQuery.sizeOf(context).width < 1180 ? 8 : 16,
              16,
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: '切换主题',
                  onPressed: widget.toggleTheme,
                  icon: Icon(
                    widget.themeMode == ThemeMode.dark
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                  ),
                ),
                if (MediaQuery.sizeOf(context).width >= 1180)
                  const SizedBox(width: 8),
                if (MediaQuery.sizeOf(context).width >= 1180)
                  Expanded(
                    child: Tooltip(
                      message: 'v${AppConstants.appVersion}',
                      child: Text(
                        'v${AppConstants.appVersion}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  _DashboardLayout _layoutFor(double width) {
    if (width < 1040) {
      return const _DashboardLayout(
        sessionWidth: 240,
        rightWidth: 300,
        gutter: 8,
        gap: 8,
      );
    }
    if (width < 1200) {
      return const _DashboardLayout(
        sessionWidth: 300,
        rightWidth: 320,
        gutter: 10,
        gap: 8,
      );
    }
    if (width < 1380) {
      return const _DashboardLayout(
        sessionWidth: 310,
        rightWidth: 336,
        gutter: 12,
        gap: 10,
      );
    }
    return const _DashboardLayout(
      sessionWidth: 340,
      rightWidth: 374,
      gutter: 14,
      gap: 10,
    );
  }

  Widget _navItem(
    int index,
    IconData icon,
    String label, {
    VoidCallback? onTap,
  }) {
    final selected = _sideIndex == index;
    final collapsed = MediaQuery.sizeOf(context).width < 1180;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: collapsed ? 12 : 14,
        vertical: 5,
      ),
      child: Tooltip(
        message: collapsed ? label : '',
        child: Material(
          color: selected ? AppTheme.qqBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap ?? () => _navigateTo(index),
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected
                        ? Colors.white
                        : Theme.of(context).hintColor,
                  ),
                  if (!collapsed) const SizedBox(width: 12),
                  if (!collapsed)
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: selected
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: selected
                              ? Colors.white
                              : Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _navigateTo(int index) {
    if (_scaffoldKey.currentState?.isDrawerOpen == true) Navigator.pop(context);
    setState(() {
      _sideIndex = index;
      if (index == 2) _chatOpenRevision++;
    });
  }

  void _onManualMessageSent(String sessionId) {
    if (!mounted || _selectedSession?.id != sessionId || _sideIndex != 2) {
      return;
    }
    setState(() => _chatSentRevision++);
  }

  Future<void> _openSettings() async {
    if (_scaffoldKey.currentState?.isDrawerOpen == true) Navigator.pop(context);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
    if (mounted && _selectedSession != null) {
      setState(() => _chatOpenRevision++);
      _botClient?.refreshSessionProfile(_selectedSession!.id);
    }
  }

  Future<void> _chooseBot(BotClient bot) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: SizedBox(
          height: math.min(440, MediaQuery.sizeOf(sheet).height * .75),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Text(
                  '切换机器人',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: Text('每个 AppID 的会话、OpenID 和聊天记录分别保存。'),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (final profile in bot.botProfiles)
                      ListTile(
                        leading: ProfileAvatar(
                          name: profile.displayName.isEmpty
                              ? '机器人'
                              : profile.displayName,
                          url: profile.avatarUrl,
                          radius: 20,
                        ),
                        title: Text(
                          profile.appId == bot.config.appId &&
                                  bot.botName.isNotEmpty
                              ? bot.botName
                              : profile.displayName.isEmpty
                              ? '机器人 ${profile.appId}'
                              : profile.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          'AppID · ${profile.appId}${profile.appId == bot.config.appId ? ' · 当前' : ''}',
                        ),
                        trailing: profile.appId == bot.config.appId
                            ? const Icon(
                                Icons.check_circle,
                                color: AppTheme.qqBlue,
                              )
                            : null,
                        onTap: () => Navigator.pop(sheet, profile.appId),
                      ),
                    ListTile(
                      leading: const Icon(Icons.add_circle_outline),
                      title: const Text('添加 / 配置机器人'),
                      onTap: () => Navigator.pop(sheet, '__add__'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == '__add__') {
      await _openSettings();
      return;
    }
    try {
      await bot.switchBot(selected);
    } catch (_) {
      if (mounted) {
        AppDialogs.show(context, '切换失败，原配置仍保留。请检查本地存储。', error: true);
      }
    }
  }

  Future<void> _toggleConnection(BotClient bot) async {
    if (bot.isConnecting) return;
    if (bot.isConnected) {
      bot.disconnect();
    } else if (bot.config.appId.isEmpty || bot.config.clientSecret.isEmpty) {
      await _openSettings();
    } else {
      await bot.connect();
    }
  }

  Widget _mobileScaffold(BotClient bot) {
    final chatting =
        _sideIndex == 2 && _mobileChatOpen && _selectedSession != null;
    final title = chatting
        ? _selectedSession!.name
        : switch (_sideIndex) {
            0 => '运行总览',
            3 => '插件',
            4 => '日志',
            _ => '会话',
          };
    return MobileWorkspace(
      scaffoldKey: _scaffoldKey,
      chatting: chatting,
      connected: bot.isConnected,
      connecting: bot.isConnecting,
      section: _sideIndex,
      title: title,
      botLabel: bot.config.appId.isEmpty ? '选择或添加机器人' : bot.botDisplayName,
      isGroup: _selectedSession?.sessionType == 1,
      avatarUrl: _selectedSession?.avatarUrl,
      onBack: () => setState(() => _mobileChatOpen = false),
      onSwitchBot: () => _chooseBot(bot),
      onConnection: () => _toggleConnection(bot),
      onSettings: chatting
          ? () => _openSessionSettings(_selectedSession!)
          : _openSettings,
      settingsLabel: chatting
          ? (_selectedSession!.sessionType == 1 ? '群聊设置' : '用户设置')
          : '设置',
      onNotifications: () => _openNotifications(),
      notificationCount: bot.groups.unreadCount,
      onNewChat: _newSession,
      onHistory: chatting ? () => _openHistory(_selectedSession!) : null,
      onNavigate: _navigateTo,
      body: Column(
        children: [
          if (bot.isConnecting) _progressBar(bot),
          if (bot.connectionError.isNotEmpty) _errorBanner(bot),
          Expanded(
            child: switch (_sideIndex) {
              0 => DashboardPanel(
                bot: bot,
                onOpenChat: () => _navigateTo(2),
                onOpenPlugins: () => _navigateTo(3),
                onOpenSettings: _openSettings,
              ),
              3 => const PluginPanel(),
              4 => LogPanel(logs: _logs),
              _ =>
                chatting
                    ? _conversation(bot)
                    : _sessionPanel(bot, width: double.infinity),
            },
          ),
        ],
      ),
    );
  }

  Widget _systemStatusCard(BotClient bot) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Icon(
                bot.isConnected
                    ? Icons.check_circle_rounded
                    : Icons.info_outline_rounded,
                color: bot.isConnected ? AppTheme.qqGreen : AppTheme.amber,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  bot.isConnected ? '机器人在线' : '机器人离线',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: bot.isConnected ? AppTheme.qqGreen : AppTheme.amber,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _metricLine('会话', '${bot.sessions.length}'),
          _metricLine('本次全量群消息', '${bot.fullGroupMessageCount}'),
          _metricLine(
            '事件',
            bot.lastEventType.isEmpty ? '-' : bot.lastEventType,
          ),
        ],
      ),
    );
  }

  Widget _metricLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor),
          ),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _titleBar(BotClient bot) {
    final connected = bot.isConnected;
    final compact = MediaQuery.sizeOf(context).width < 1000;
    return Container(
      height: compact ? 68 : 76,
      padding: EdgeInsets.symmetric(horizontal: compact ? 16 : 24),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  switch (_sideIndex) {
                    0 => '运行总览',
                    3 => '插件工作空间',
                    4 => '运行日志',
                    _ => '聊天工作台',
                  },
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (!compact) const SizedBox(height: 5),
                if (!compact)
                  Text(
                    _sideIndex == 3
                        ? '安装、配置与开发扩展，让每项能力各归其位。'
                        : 'QQ 官方机器人 API v2 · 管理连接、对话与扩展',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: '切换机器人',
            child: TextButton.icon(
              onPressed: () => _chooseBot(bot),
              icon: const Icon(Icons.swap_horiz_rounded, size: 19),
              label: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: compact ? 84 : 150),
                child: Text(
                  bot.config.appId.isEmpty ? '选择机器人' : bot.botDisplayName,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            ),
          ),
          if (!compact)
            _pill(
              connected ? '已连接' : '未连接',
              connected ? AppTheme.qqGreen : AppTheme.muted,
            ),
          SizedBox(width: compact ? 4 : 12),
          if (compact)
            IconButton(
              tooltip: connected ? '断开连接' : '连接机器人',
              onPressed: bot.isConnecting ? null : () => _toggleConnection(bot),
              icon: Icon(
                Icons.power_settings_new_rounded,
                color: connected ? AppTheme.qqGreen : null,
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: bot.isConnecting ? null : () => _toggleConnection(bot),
              icon: Icon(
                connected
                    ? Icons.logout_rounded
                    : Icons.power_settings_new_rounded,
                size: 17,
              ),
              label: Text(connected ? '断开连接' : '连接'),
            ),
          const SizedBox(width: 10),
          _notificationBell(bot),
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
            icon: const Icon(Icons.settings_rounded),
          ),
        ],
      ),
    );
  }

  Widget _pill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _statusDot(Color color) => Container(
    width: 9,
    height: 9,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );

  Widget _progressBar(BotClient bot) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      color: AppTheme.amber.withValues(alpha: 0.1),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            _stepLabel(bot.connectStep),
            style: const TextStyle(fontSize: 12, color: AppTheme.amber),
          ),
        ],
      ),
    );
  }

  Widget _errorBanner(BotClient bot) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      color: AppTheme.qqRed.withValues(alpha: 0.08),
      child: Row(
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: AppTheme.qqRed,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              bot.connectionError,
              style: const TextStyle(color: AppTheme.qqRed, fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: bot.clearError,
            icon: const Icon(Icons.close_rounded, size: 16),
            color: AppTheme.qqRed,
          ),
        ],
      ),
    );
  }

  void _searchHistory(String value) {
    _historySearchDebounce?.cancel();
    void apply() {
      if (!mounted) return;
      setState(() {
        _historyQuery = value.trim();
        _searchLimit = 60;
      });
    }

    if (value.trim().isEmpty) {
      apply();
    } else {
      _historySearchDebounce = Timer(const Duration(milliseconds: 220), apply);
    }
  }

  Widget? _clearHistorySearchButton() => _historySearch.text.isEmpty
      ? null
      : IconButton(
          tooltip: '清除聊天记录搜索',
          icon: const Icon(Icons.close_rounded, size: 18),
          onPressed: () {
            _historySearch.clear();
            _searchHistory('');
          },
        );

  Widget _historyResults(BotClient bot) {
    final rows = bot.searchChatHistory(
      _historyQuery,
      sessionType: _sessionTypeFilter,
    );
    if (rows.isEmpty) {
      return _emptyState(
        Icons.manage_search_rounded,
        '没有找到聊天记录',
        '试试消息内容、成员昵称、引用或语音转写。',
      );
    }
    final sessions = {for (final session in bot.sessions) session.id: session};
    final count = rows.length.clamp(0, _searchLimit);
    return ListView.builder(
      key: ValueKey('history-search-$_historyQuery-$_sessionTypeFilter'),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: count + 1 + (count < rows.length ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Text(
              '${rows.length} 条本地聊天记录',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).hintColor,
              ),
            ),
          );
        }
        if (index > count) {
          return TextButton(
            onPressed: () => setState(() => _searchLimit += 60),
            child: const Text('加载更多搜索结果'),
          );
        }
        final message = rows[index - 1];
        final session = sessions[message.sessionId]!;
        return Material(
          color: Colors.transparent,
          child: ListTile(
            key: ValueKey('history-hit-${session.id}-${message.id}'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 3,
            ),
            leading: ProfileAvatar(
              name: session.name,
              url: session.avatarUrl,
              isGroup: session.sessionType == 1,
              radius: 19,
            ),
            title: Text(
              session.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              '${message.senderName.isEmpty ? '消息' : message.senderName} · ${_formatRelativeTime(message.timestamp)}\n${historyMatchSnippet(message, _historyQuery)}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
            onTap: () async {
              final target = bot.groups.target(session.id);
              FocusScope.of(context).unfocus();
              setState(() {
                _selectedSession = session;
                _mobileChatOpen = true;
                _replyToMessage = null;
                _chatOpenRevision++;
              });
              await bot.markSessionRead(session.id);
              if (!mounted ||
                  !bot.groups.isCurrent(target) ||
                  _selectedSession?.id != session.id) {
                return;
              }
              await _openHistory(session, messageId: message.id);
            },
          ),
        );
      },
    );
  }

  Widget _sessionPanel(BotClient bot, {required double width}) {
    final visibleSessions = bot.sessions.where((session) {
      return _sessionTypeFilter == null ||
          session.sessionType == _sessionTypeFilter;
    }).toList();
    if (usePhoneLayout(context)) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              key: const ValueKey('chat-history-search'),
              controller: _historySearch,
              onChanged: _searchHistory,
              maxLength: 200,
              decoration: InputDecoration(
                hintText: '搜索聊天记录',
                counterText: '',
                suffixIcon: _clearHistorySearchButton(),
                prefixIcon: const Icon(Icons.search_rounded, size: 21),
                filled: true,
                fillColor: Theme.of(context).scaffoldBackgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Wrap(
              runSpacing: 4,
              children: [
                _filterChip(
                  '全部',
                  _sessionTypeFilter == null,
                  bot.sessions.length,
                  null,
                ),
                _filterChip(
                  '单聊',
                  _sessionTypeFilter == 0,
                  bot.sessions.where((s) => s.sessionType == 0).length,
                  0,
                ),
                _filterChip(
                  '群聊',
                  _sessionTypeFilter == 1,
                  bot.sessions.where((s) => s.sessionType == 1).length,
                  1,
                ),
              ],
            ),
          ),
          Expanded(
            child: _historyQuery.isNotEmpty
                ? _historyResults(bot)
                : visibleSessions.isEmpty
                ? _emptyState(
                    Icons.chat_bubble_outline_rounded,
                    '还没有会话',
                    '连接机器人，开始接收群聊和单聊消息。',
                  )
                : ListView.separated(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.only(bottom: 16),
                    itemCount: visibleSessions.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      indent: 82,
                      color: Theme.of(
                        context,
                      ).dividerColor.withValues(alpha: .6),
                    ),
                    itemBuilder: (_, index) =>
                        _sessionTile(visibleSessions[index], bot),
                  ),
          ),
        ],
      );
    }
    return _panel(
      width: width,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
            child: Row(
              children: [
                const Text(
                  '会话',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
                const Spacer(),
                IconButton.outlined(
                  onPressed: _newSession,
                  icon: const Icon(Icons.add_rounded, size: 19),
                  tooltip: '新建会话',
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('chat-history-search'),
                    controller: _historySearch,
                    onChanged: _searchHistory,
                    maxLength: 200,
                    decoration: InputDecoration(
                      hintText: '搜索聊天记录',
                      counterText: '',
                      suffixIcon: _clearHistorySearchButton(),
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Wrap(
              runSpacing: 4,
              children: [
                _filterChip(
                  '全部',
                  _sessionTypeFilter == null,
                  bot.sessions.length,
                  null,
                ),
                _filterChip(
                  '单聊',
                  _sessionTypeFilter == 0,
                  bot.sessions.where((s) => s.sessionType == 0).length,
                  0,
                ),
                _filterChip(
                  '群聊',
                  _sessionTypeFilter == 1,
                  bot.sessions.where((s) => s.sessionType == 1).length,
                  1,
                ),
              ],
            ),
          ),
          Expanded(
            child: _historyQuery.isNotEmpty
                ? _historyResults(bot)
                : visibleSessions.isEmpty
                ? _emptyState(
                    Icons.forum_outlined,
                    '暂无会话',
                    '连接机器人后，收到的消息会出现在这里。',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                    itemCount: visibleSessions.length,
                    itemBuilder: (_, index) =>
                        _sessionTile(visibleSessions[index], bot),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, bool selected, int count, int? sessionType) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        tooltip: '$label：$count 个会话',
        label: Text(label),
        showCheckmark: false,
        selected: selected,
        onSelected: (_) => setState(() {
          _sessionTypeFilter = sessionType;
          _searchLimit = 60;
        }),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Future<void> _newSession() async {
    final idController = TextEditingController();
    final nameController = TextEditingController();
    var isGroup = true;
    final result = await showDialog<({String id, String name, bool isGroup})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('新建会话'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('使用机器人事件中的 OpenID，普通 QQ 号或群号不可代替。'),
                const SizedBox(height: 12),
                SwitchListTile(
                  title: const Text('群聊会话'),
                  value: isGroup,
                  onChanged: (value) => update(() => isGroup = value),
                ),
                TextField(
                  controller: idController,
                  decoration: const InputDecoration(labelText: '会话 OpenID'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '会话名称（可选）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (idController.text.trim().isEmpty) return;
                Navigator.pop(dialogContext, (
                  id: idController.text.trim(),
                  name: nameController.text.trim(),
                  isGroup: isGroup,
                ));
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    await context.read<BotClient>().addSession(
      result.id,
      name: result.name,
      isGroup: result.isGroup,
    );
    if (!mounted) return;
    final session = context
        .read<BotClient>()
        .sessions
        .where((s) => s.id == result.id)
        .firstOrNull;
    if (session != null) {
      setState(() {
        _selectedSession = session;
        _replyToMessage = null;
        _sessionTypeFilter = null;
        _mobileChatOpen = true;
        _chatOpenRevision++;
      });
    }
  }

  Widget _sessionTile(ChatSession session, BotClient bot) {
    final mobile = usePhoneLayout(context);
    final selected = _selectedSession?.id == session.id && !mobile;
    final accent = session.sessionType == 1
        ? AppTheme.qqGreen
        : AppTheme.qqBlue;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: mobile ? 0 : 4),
      child: Material(
        color: selected
            ? AppTheme.qqBlue.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onLongPress: () => _sessionMenu(session, bot),
          onSecondaryTap: () => _sessionMenu(session, bot),
          onTap: () {
            setState(() {
              _selectedSession = session;
              _mobileChatOpen = true;
              _replyToMessage = null;
              _chatOpenRevision++;
            });
            bot.markSessionRead(session.id);
            bot.refreshSessionProfile(session.id);
          },
          child: Padding(
            padding: mobile
                ? const EdgeInsets.symmetric(horizontal: 18, vertical: 14)
                : const EdgeInsets.all(10),
            child: Row(
              children: [
                ProfileAvatar(
                  name: session.name,
                  url: session.avatarUrl,
                  isGroup: session.sessionType == 1,
                  radius: mobile ? 25 : 23,
                ),
                SizedBox(width: mobile ? 14 : 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              session.name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: mobile ? 16 : 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            _formatRelativeTime(session.lastMessageTime),
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context).hintColor,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              formatQqMessageContent(session.lastMessage),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: mobile ? 13 : 12,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ),
                          if (session.isMuted)
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Icon(
                                Icons.notifications_off_outlined,
                                size: 15,
                              ),
                            ),
                          if (session.unreadCount > 0 && !session.isMuted)
                            _unreadBadge(session.unreadCount),
                          if (session.unreadCount == 0 && !mobile)
                            _statusDot(accent),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _conversation(BotClient bot) {
    final session = _selectedSession;
    return _panel(
      child: LayoutBuilder(
        builder: (context, constraints) => Column(
          children: [
            if (!usePhoneLayout(context)) _conversationHeader(session),
            Expanded(
              child: session == null
                  ? _emptyState(
                      Icons.chat_bubble_outline_rounded,
                      '选择一个会话',
                      bot.isConnected ? '机器人已在线，等待消息进入。' : '先连接机器人，然后打开会话回复消息。',
                    )
                  : ColoredBox(
                      color: Theme.of(context).brightness == Brightness.dark
                          ? AppTheme.darkBg
                          : const Color(0xFFF7F9FE),
                      child: _messageList(bot, session),
                    ),
            ),
            if (session != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(
                    0,
                    constraints.maxHeight -
                        (!usePhoneLayout(context) ? 74 : 0) -
                        math.min(80, constraints.maxHeight * .15),
                  ),
                ),
                child: _composer(session),
              ),
          ],
        ),
      ),
    );
  }

  Widget _conversationHeader(ChatSession? session) {
    return Container(
      height: 74,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          if (session != null)
            ProfileAvatar(
              name: session.name,
              url: session.avatarUrl,
              isGroup: session.sessionType == 1,
              radius: 22,
            ),
          if (session != null) const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session?.name ?? '聊天会话',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  session == null
                      ? '选择会话开始聊天'
                      : '${session.sessionType == 1 ? "群聊" : "单聊"} · ${session.id}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
          if (session != null)
            IconButton(
              onPressed: () => _openHistory(session),
              icon: const Icon(Icons.history_rounded),
              tooltip: '聊天记录',
            ),
          IconButton(
            onPressed: session == null
                ? null
                : () => _openSessionSettings(session),
            icon: const Icon(Icons.tune_rounded),
            tooltip: session?.sessionType == 1 ? '群聊设置' : '用户设置',
          ),
        ],
      ),
    );
  }

  Widget _messageList(BotClient bot, ChatSession session) {
    final messages = bot.getMessagesForSession(session.id);
    if (messages.isEmpty) {
      return _emptyState(
        Icons.mark_chat_unread_outlined,
        '暂无消息',
        '收到第一条消息后，就可以在这里查看和回复。',
      );
    }
    return ChatTimeline(
      key: ValueKey('timeline-${bot.config.appId}-${session.id}'),
      sessionId: session.id,
      messages: messages,
      controller: _messageScrollController,
      openRevision: _chatOpenRevision,
      sentRevision: _chatSentRevision,
      itemBuilder: (_, chronologicalIndex) {
        final message = messages[chronologicalIndex];
        final memberTarget = bot.groups.target(session.id);
        final showSender =
            chronologicalIndex == 0 ||
            messages[chronologicalIndex - 1].senderId != message.senderId;
        return MessageBubble(
          key: ValueKey('${session.id}:${message.id}'),
          message: message,
          showSender: showSender,
          onSenderLongPress:
              session.sessionType == 1 &&
                  !message.isBotAuthor &&
                  message.senderId.isNotEmpty
              ? () => GroupMemberActions.show(
                  context,
                  bot,
                  memberTarget,
                  message.senderId,
                  name: message.senderName,
                  avatarUrl: message.senderAvatarUrl,
                  onMention: () {
                    if (bot.groups.isCurrent(memberTarget) &&
                        _selectedSession?.id == session.id) {
                      _composerController.mention(message.senderId);
                    }
                  },
                )
              : null,
          canRecall: bot.canRecallMessage(message),
          onRecall: () async {
            if (!message.isFromBot) {
              final confirmed = await AppDialogs.present<bool>(
                context,
                builder: (dialog) => AlertDialog(
                  title: const Text('撤回群成员消息？'),
                  content: Text(
                    '${message.senderName}：${message.sessionPreview}',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialog, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialog, true),
                      child: const Text('确认撤回'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
            }
            final recalled = await bot.recallMessage(message);
            if (!recalled && mounted) {
              await AppDialogs.show(
                context,
                bot.lastSendError,
                title: '撤回失败',
                error: true,
              );
            }
          },
          onReply: message.isFromBot || message.isRecalled
              ? (message.isRecalled || message.referenceIndex.isEmpty
                    ? null
                    : () => setState(() => _replyToMessage = message))
              : () => setState(() => _replyToMessage = message),
        );
      },
    );
  }

  Future<void> _showEmojiPicker(ChatSession session) =>
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        constraints: const BoxConstraints(maxWidth: 600),
        builder: (sheetContext) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .6,
          child: EmojiPicker(
            onEmojiSelected: (emoji) async {
              Navigator.pop(sheetContext);
              final bot = context.read<BotClient>();
              final sent = await bot.sendImageMessage(
                session.id,
                emoji.localPath ?? emoji.url,
                isGroup: session.sessionType == 1,
                replyTo: _replyToMessage,
              );
              if (sent) {
                _onManualMessageSent(session.id);
              } else if (mounted) {
                AppDialogs.show(
                  context,
                  bot.lastSendError,
                  title: '发送失败',
                  error: true,
                );
              }
            },
          ),
        ),
      );

  Widget _composer(ChatSession session) {
    return ChatInput(
      controller: _composerController,
      mentionCandidates: {
        for (final message
            in context
                .read<BotClient>()
                .getMessagesForSession(session.id)
                .take(400))
          if (!message.isBotAuthor && message.senderId.isNotEmpty)
            message.senderId: message.senderName,
      },
      key: ValueKey('${context.read<BotClient>().config.appId}:${session.id}'),
      isGroup: session.sessionType == 1,
      latestEventId: context.read<BotClient>().latestReplyEventId(session.id),
      defaultMarkdownTemplateId: context
          .read<BotClient>()
          .config
          .markdownTemplateId,
      defaultTemplateParams: context
          .read<BotClient>()
          .config
          .markdownTemplateParams,
      onSendConfigured: (request) =>
          context.read<BotClient>().sendConfiguredMessage(
            session.id,
            request,
            isGroup: session.sessionType == 1,
            replyTo: _replyToMessage,
          ),
      previewConfigured: (request) =>
          context.read<BotClient>().previewConfiguredMessage(
            session.id,
            request,
            isGroup: session.sessionType == 1,
            replyTo: _replyToMessage,
          ),
      sendError: () => context.read<BotClient>().lastSendError,
      replyTo: _replyToMessage,
      onCancelReply: () => setState(() => _replyToMessage = null),
      onEmojiTap: () => _showEmojiPicker(session),
      onMessageSent: () => _onManualMessageSent(session.id),
      onSendText: (text) => context.read<BotClient>().sendTextMessage(
        session.id,
        text,
        isGroup: session.sessionType == 1,
        replyTo: _replyToMessage,
      ),
      onSendMarkdown: (markdown, {useTemplate, templateId, templateParams}) =>
          context.read<BotClient>().sendMarkdownMessage(
            session.id,
            markdown,
            isGroup: session.sessionType == 1,
            replyTo: _replyToMessage,
            useTemplate: useTemplate ?? false,
            templateId: templateId,
            templateParams: templateParams,
          ),
      onSendImage: (url) => context.read<BotClient>().sendImageMessage(
        session.id,
        url,
        isGroup: session.sessionType == 1,
        replyTo: _replyToMessage,
      ),
      onSlashCommand: (command, args) async {
        final replyAtStart = _replyToMessage;
        final botAtStart = context.read<BotClient>();
        final epochAtStart = botAtStart.accountEpoch;
        final result = await context.read<PluginManager>().processCommandReply(
          command,
          args,
          PluginMessage(
            messageId: '',
            sessionId: session.id,
            senderId: '',
            senderName: '操作员',
            senderRole: 'operator',
            content: '',
            messageType: 0,
            isGroup: session.sessionType == 1,
            timestamp: DateTime.now(),
          ),
        );
        if (!mounted || botAtStart.accountEpoch != epochAtStart) return false;
        if (result == null) {
          throw const FormatException('未找到可用命令，请检查插件是否启用');
        }
        final source =
            (replyAtStart?.sessionId == session.id ? replyAtStart : null) ??
            MessageModel(
              id: '',
              sessionId: session.id,
              senderId: '',
              senderName: '操作员',
              content: '',
              messageType: 0,
              timestamp: DateTime.now(),
              extra: {'isGroup': session.sessionType == 1},
            );
        return _sendPluginResponse(
          botAtStart,
          source,
          result.content,
          reply: result.reply,
          pluginId: result.pluginId,
        );
      },
    );
  }

  Widget _panel({double? width, required Widget child}) {
    if (usePhoneLayout(context)) {
      return SizedBox(width: width, child: child);
    }
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _emptyState(IconData icon, String title, String body) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxHeight < 180) {
          return Center(
            child: Text(
              title,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          );
        }
        return Center(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    icon,
                    size: 42,
                    color: Theme.of(context).hintColor.withValues(alpha: 0.42),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _unreadBadge(int count) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.qqBlue,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  String _stepLabel(ConnectStep step) {
    return switch (step) {
      ConnectStep.gettingToken => '获取 Token',
      ConnectStep.gettingGateway => '获取网关',
      ConnectStep.connecting => '连接网关',
      ConnectStep.done || ConnectStep.idle => '',
    };
  }

  String _formatRelativeTime(DateTime time) {
    final local = time.toLocal();
    final diff = DateTime.now().difference(local);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分';
    if (diff.inDays < 1) return '${diff.inHours}时';
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _clockText(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }
}

class _DashboardLayout {
  final double sessionWidth;
  final double rightWidth;
  final double gutter;
  final double gap;

  const _DashboardLayout({
    required this.sessionWidth,
    required this.rightWidth,
    required this.gutter,
    required this.gap,
  });
}
