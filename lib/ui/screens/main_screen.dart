import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/bot_client.dart';
import '../../core/plugin_manager.dart';
import '../../core/message_handler.dart';
import '../../services/storage_service.dart';
import '../../models/message.dart';
import '../../models/plugin.dart';
import '../../utils/helpers.dart';
import '../../utils/constants.dart';
import '../themes/app_theme.dart';
import '../widgets/chat_input.dart';
import '../widgets/emoji_picker.dart';
import '../widgets/message_bubble.dart';
import '../widgets/chat_timeline.dart';
import '../widgets/plugin_panel.dart';
import '../widgets/dashboard_panel.dart';
import '../widgets/log_panel.dart';
import '../widgets/app_logo.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/app_dialogs.dart';
import 'settings_screen.dart';

class MainScreen extends StatefulWidget {
  final VoidCallback toggleTheme;
  final ThemeMode themeMode;

  const MainScreen({
    super.key,
    required this.toggleTheme,
    required this.themeMode,
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
  String _sessionSearch = '';
  int? _sessionTypeFilter;

  ChatSession? _selectedSession;
  BotClient? _botClient;
  MessageModel? _replyToMessage;
  int _toolIndex = 0;
  int _sideIndex = 2;
  bool _mobileChatOpen = false;
  bool _startupConnectTried = false;
  int _chatOpenRevision = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final client = context.read<BotClient>();
      _botClient = client;
      client.refresh();
      _selectFirstSessionIfNeeded(client);
      client.addListener(_onBotUpdate);
      client.onLog = _addLog;
      client.onMessageReceived = _processWithPlugins;
      if (_selectedSession != null) {
        client.refreshSessionProfile(_selectedSession!.id);
      }
      _tryStartupConnect(client);
    });
  }

  @override
  void dispose() {
    _botClient?.removeListener(_onBotUpdate);
    _messageScrollController.dispose();
    super.dispose();
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
    _selectFirstSessionIfNeeded(_botClient);
    setState(() {});
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

  Future<void> _processWithPlugins(MessageModel message) async {
    if (!context.read<BotClient>().shouldAutoRespondTo(message)) return;
    final weatherOnly =
        message.isFullGroupMessage &&
        !context.read<BotClient>().config.autoReplyToAllGroupMessages;
    final rawContent =
        message.extra?['rawContent']?.toString() ?? message.content;
    final content = message.extra?['eventType'] == 'GROUP_AT_MESSAGE_CREATE'
        ? stripLeadingBotMention(rawContent)
        : rawContent;
    final pluginMessage = PluginMessage(
      messageId: message.id,
      sessionId: message.sessionId,
      senderId: message.senderId,
      senderName: message.senderName,
      content: content,
      messageType: message.messageType,
      isGroup: message.extra?['isGroup'] == true,
      timestamp: message.timestamp,
    );

    final responses = await context.read<PluginManager>().processMessage(
      pluginMessage,
      onlyPluginId: weatherOnly ? 'weather_plugin' : null,
    );
    if (!mounted) return;

    final bot = context.read<BotClient>();
    for (final response in responses) {
      final sent = await _sendPluginResponse(bot, message, response.content);
      bot.onLog?.call(
        '[${_clockText(DateTime.now())}] 插件 ${response.pluginName} ${sent ? '回复已发送到 QQ' : '回复发送失败: ${bot.lastSendError}'}',
      );
    }
    if (responses.isEmpty && mounted && !weatherOnly) {
      final reply = MessageHandler(
        context.read<StorageService>(),
      ).processMessage(message.copyWith(content: content));
      if (reply != null) await _sendPluginResponse(bot, message, reply);
    }
  }

  Future<bool> _sendPluginResponse(
    BotClient bot,
    MessageModel source,
    String content,
  ) {
    final isGroup = source.extra?['isGroup'] == true;
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

    if (MediaQuery.sizeOf(context).width < 700) return _mobileScaffold(bot);

    return Scaffold(
      key: _scaffoldKey,
      endDrawer: Drawer(
        width: 340,
        child: SafeArea(child: _rightPanel(bot, width: 340)),
      ),
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
                          1 => _panel(child: _infoPanel(bot)),
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
      width: 188,
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
                const SizedBox(width: 10),
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
                  _navItem(1, Icons.smart_toy_outlined, '机器人'),
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
          _systemStatusCard(bot),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
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
                const Spacer(),
                Text(
                  'v${AppConstants.appVersion}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
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
        sessionWidth: 280,
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
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
                  color: selected ? Colors.white : Theme.of(context).hintColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
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
    );
  }

  void _navigateTo(int index) {
    if (_scaffoldKey.currentState?.isDrawerOpen == true) Navigator.pop(context);
    setState(() {
      _sideIndex = index;
      if (index == 2) _chatOpenRevision++;
      if (index == 1) _toolIndex = 3;
      if (index == 3) _toolIndex = 0;
      if (index == 4) _toolIndex = 2;
    });
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

  Widget _mobileScaffold(BotClient bot) {
    final chatting =
        _sideIndex == 2 && _mobileChatOpen && _selectedSession != null;
    final title = chatting
        ? _selectedSession!.name
        : switch (_sideIndex) {
            0 => '运行总览',
            1 => '机器人',
            3 => '插件',
            4 => '日志',
            _ => '会话',
          };
    return PopScope(
      canPop: !chatting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && chatting) setState(() => _mobileChatOpen = false);
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: Drawer(child: SafeArea(child: _navigationRail(bot))),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          leading: chatting
              ? IconButton(
                  tooltip: '返回会话列表',
                  onPressed: () => setState(() => _mobileChatOpen = false),
                  icon: const Icon(Icons.arrow_back),
                )
              : null,
          actions: [
            IconButton(
              tooltip: bot.isConnected ? '断开机器人' : '连接机器人',
              onPressed: bot.isConnecting
                  ? null
                  : () {
                      if (bot.isConnected) {
                        bot.disconnect();
                      } else {
                        bot.connect();
                      }
                    },
              icon: Icon(
                bot.isConnected ? Icons.link_off : Icons.link,
                color: bot.isConnected ? AppTheme.qqGreen : null,
              ),
            ),
            IconButton(
              tooltip: '打开功能菜单',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu),
            ),
          ],
        ),
        bottomNavigationBar: chatting
            ? null
            : NavigationBar(
                selectedIndex: const [0, 2, 3, 4].contains(_sideIndex)
                    ? const [0, 2, 3, 4].indexOf(_sideIndex)
                    : 0,
                onDestinationSelected: (index) =>
                    _navigateTo(const [0, 2, 3, 4][index]),
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.space_dashboard_outlined),
                    selectedIcon: Icon(Icons.space_dashboard_rounded),
                    label: '总览',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.forum_outlined),
                    selectedIcon: Icon(Icons.forum_rounded),
                    label: '会话',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.extension_outlined),
                    selectedIcon: Icon(Icons.extension_rounded),
                    label: '插件',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.receipt_long_outlined),
                    selectedIcon: Icon(Icons.receipt_long_rounded),
                    label: '日志',
                  ),
                ],
              ),
        body: SafeArea(
          child: Column(
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
                  1 => _infoPanel(bot),
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
        ),
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
    return Container(
      height: 82,
      padding: const EdgeInsets.symmetric(horizontal: 24),
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
                    1 => '机器人详情',
                    3 => '插件工作空间',
                    4 => '运行日志',
                    _ => '聊天工作台',
                  },
                  style: const TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
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
          _pill(
            connected ? '已连接' : '未连接',
            connected ? AppTheme.qqGreen : AppTheme.muted,
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: bot.isConnecting
                ? null
                : () => connected ? bot.disconnect() : bot.connect(),
            icon: Icon(
              connected
                  ? Icons.logout_rounded
                  : Icons.power_settings_new_rounded,
              size: 17,
            ),
            label: Text(connected ? '断开连接' : '连接'),
          ),
          const SizedBox(width: 10),
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

  Widget _sessionPanel(BotClient bot, {required double width}) {
    final visibleSessions = bot.sessions.where((session) {
      return (_sessionTypeFilter == null ||
              session.sessionType == _sessionTypeFilter) &&
          ('${session.name} ${session.id}'.toLowerCase().contains(
            _sessionSearch.toLowerCase(),
          ));
    }).toList();
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
                    onChanged: (value) =>
                        setState(() => _sessionSearch = value),
                    decoration: InputDecoration(
                      hintText: '搜索会话',
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
            child: visibleSessions.isEmpty
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
          Padding(
            padding: const EdgeInsets.all(14),
            child: OutlinedButton.icon(
              onPressed: _newSession,
              icon: const Icon(Icons.add_rounded),
              label: const Text('新建会话'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
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
        label: Text(count > 0 ? '$label $count' : label),
        selected: selected,
        onSelected: (_) => setState(() => _sessionTypeFilter = sessionType),
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
    final selected = _selectedSession?.id == session.id;
    final accent = session.sessionType == 1
        ? AppTheme.qqGreen
        : AppTheme.qqBlue;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: selected
            ? AppTheme.qqBlue.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
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
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ProfileAvatar(
                  name: session.name,
                  url: session.avatarUrl,
                  isGroup: session.sessionType == 1,
                  radius: 23,
                ),
                const SizedBox(width: 10),
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
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
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
                                fontSize: 12,
                                color: Theme.of(context).hintColor,
                              ),
                            ),
                          ),
                          if (session.unreadCount > 0)
                            _unreadBadge(session.unreadCount),
                          if (session.unreadCount == 0) _statusDot(accent),
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
            _conversationHeader(session),
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
                        74 -
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
    final compact = MediaQuery.sizeOf(context).width < 700;
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
          if (!compact)
            IconButton(
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              icon: const Icon(Icons.widgets_outlined),
              tooltip: '插件与工具',
            ),
          IconButton(
            onPressed: () => _navigateTo(1),
            icon: const Icon(Icons.people_outline_rounded),
            tooltip: '会话信息',
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
      key: ValueKey('timeline-${session.id}'),
      sessionId: session.id,
      messages: messages,
      controller: _messageScrollController,
      openRevision: _chatOpenRevision,
      itemBuilder: (_, chronologicalIndex) {
        final message = messages[chronologicalIndex];
        final showSender =
            chronologicalIndex == 0 ||
            messages[chronologicalIndex - 1].senderId != message.senderId;
        return MessageBubble(
          key: ValueKey('${session.id}:${message.id}'),
          message: message,
          showSender: showSender,
          canRecall: bot.canRecallMessage(message),
          onRecall: () => bot.recallMessage(message),
          onReply: message.isFromBot || message.isRecalled
              ? (message.isRecalled || message.referenceIndex.isEmpty
                    ? null
                    : () => setState(() => _replyToMessage = message))
              : () => setState(() => _replyToMessage = message),
        );
      },
    );
  }

  Widget _rightPanel(BotClient bot, {required double width}) {
    return SizedBox(
      width: width,
      child: Column(
        children: [
          Expanded(
            flex: 3,
            child: _panel(
              child: Column(
                children: [
                  _panelTabs(
                    labels: const ['工具', '信息'],
                    active: _toolIndex == 3 ? 1 : 0,
                    onTap: (index) =>
                        setState(() => _toolIndex = index == 0 ? 0 : 3),
                  ),
                  Expanded(
                    child: _toolIndex == 3 ? _infoPanel(bot) : _toolsPanel(bot),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            flex: 2,
            child: _panel(
              child: Column(
                children: [Expanded(child: LogPanel(logs: _logs))],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panelTabs({
    required List<String> labels,
    required int active,
    required ValueChanged<int> onTap,
  }) {
    return Container(
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 22),
              child: InkWell(
                onTap: () => onTap(i),
                child: SizedBox(
                  height: 54,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        labels[i],
                        style: TextStyle(
                          fontWeight: active == i
                              ? FontWeight.w900
                              : FontWeight.w600,
                          color: active == i ? AppTheme.qqBlue : null,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        width: 52,
                        height: 2,
                        color: active == i
                            ? AppTheme.qqBlue
                            : Colors.transparent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolsPanel(BotClient bot) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('插件')),
              ButtonSegment(value: 1, label: Text('表情')),
            ],
            selected: {_toolIndex == 1 ? 1 : 0},
            showSelectedIcon: false,
            onSelectionChanged: (value) =>
                setState(() => _toolIndex = value.first),
          ),
        ),
        Expanded(
          child: _toolIndex == 1
              ? EmojiPicker(
                  onEmojiSelected: (emoji) async {
                    final session = _selectedSession;
                    if (session == null) return;
                    final sent = await bot.sendImageMessage(
                      session.id,
                      emoji.localPath ?? emoji.url,
                      isGroup: session.sessionType == 1,
                      replyTo: _replyToMessage,
                    );
                    if (!sent && mounted) {
                      AppDialogs.show(
                        context,
                        bot.lastSendError,
                        title: '发送失败',
                        error: true,
                      );
                    }
                  },
                )
              : const PluginPanel(),
        ),
      ],
    );
  }

  Widget _infoPanel(BotClient bot) {
    final session = _selectedSession;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        _infoCard(
          icon: Icons.groups_rounded,
          title: session?.name ?? '未选择会话',
          rows: [
            ('会话 ID', session?.id ?? '-'),
            (
              '资料',
              session?.profileStatus.isNotEmpty == true
                  ? session!.profileStatus
                  : '尚未同步资料',
            ),
            (
              '类型',
              session == null ? '-' : (session.sessionType == 1 ? '群聊' : '单聊'),
            ),
            (
              '消息',
              session == null
                  ? '-'
                  : '${bot.getMessagesForSession(session.id).length}',
            ),
          ],
        ),
        if (session != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: OutlinedButton.icon(
              onPressed: session.profileStatus == '正在查询群资料…'
                  ? null
                  : () => bot.refreshSessionProfile(session.id, force: true),
              icon: const Icon(Icons.refresh),
              label: const Text('刷新会话资料'),
            ),
          ),
        const SizedBox(height: 10),
        _infoCard(
          icon: Icons.smart_toy_outlined,
          title: '机器人状态',
          rows: [
            ('状态', bot.isConnected ? '在线' : '离线'),
            ('网关会话', bot.gatewaySessionId.isEmpty ? '-' : bot.gatewaySessionId),
            ('心跳', bot.lastHeartbeatAckAt == null ? '等待中' : '正常'),
          ],
        ),
      ],
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String title,
    required List<(String, String)> rows,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.qqBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final row in rows) _metricLine(row.$1, row.$2),
        ],
      ),
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
              if (!sent && mounted) {
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
      key: ValueKey(session.id),
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
        final result = await context.read<PluginManager>().processCommand(
          command,
          args,
          PluginMessage(
            messageId: '',
            sessionId: session.id,
            senderId: '',
            senderName: '操作员',
            content: '',
            messageType: 0,
            isGroup: session.sessionType == 1,
            timestamp: DateTime.now(),
          ),
        );
        if (!mounted) return false;
        if (result == null) {
          throw const FormatException('未找到可用命令，请检查插件是否启用');
        }
        final bot = context.read<BotClient>();
        return containsMarkdown(result)
            ? bot.sendMarkdownMessage(
                session.id,
                result,
                isGroup: session.sessionType == 1,
                replyTo: _replyToMessage,
              )
            : bot.sendTextMessage(
                session.id,
                result,
                isGroup: session.sessionType == 1,
                replyTo: _replyToMessage,
              );
      },
    );
  }

  Widget _panel({double? width, required Widget child}) {
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
