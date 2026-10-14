import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/bot_client.dart';
import '../../core/plugin_manager.dart';
import '../../services/api_service.dart';
import '../../utils/constants.dart';
import '../../models/config.dart';
import '../../services/storage_service.dart';
import '../themes/app_theme.dart';
import '../../utils/platforms.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _appIdController = TextEditingController();
  final TextEditingController _clientSecretController = TextEditingController();
  final TextEditingController _apiUrlController = TextEditingController();
  final TextEditingController _autoReplyController = TextEditingController();
  final TextEditingController _keywordController = TextEditingController();
  final TextEditingController _replyController = TextEditingController();
  final TextEditingController _groupController = TextEditingController();
  final TextEditingController _friendController = TextEditingController();
  final TextEditingController _markdownTemplateController =
      TextEditingController();

  bool _useSandbox = false;
  bool _autoReconnect = true;
  bool _receiveAllGroupMessages = true;
  bool _autoReplyToAllGroupMessages = false;
  bool _enableAutoReply = false;
  bool _enableScheduled = false;
  bool _enableLogging = true;
  bool _isSaving = false;
  bool _isTestingCredentials = false;
  String _credentialTestStatus = '';
  int _reconnectInterval = 5;
  int _tabIndex = 0;

  Map<String, String> _keywordReplies = {};
  List<String> _monitoredGroups = [];
  List<String> _monitoredFriends = [];

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _appIdController.dispose();
    _clientSecretController.dispose();
    _apiUrlController.dispose();
    _autoReplyController.dispose();
    _keywordController.dispose();
    _replyController.dispose();
    _groupController.dispose();
    _friendController.dispose();
    _markdownTemplateController.dispose();
    super.dispose();
  }

  void _loadConfig() {
    final config = context.read<StorageService>().getBotConfig();
    _appIdController.text = config.appId;
    _clientSecretController.text = config.clientSecret;
    _apiUrlController.text = config.apiBaseUrl;
    _autoReplyController.text = config.defaultAutoReply;
    _markdownTemplateController.text = config.markdownTemplateId;
    _useSandbox = config.useSandbox;
    _autoReconnect = config.autoReconnect;
    _receiveAllGroupMessages = config.receiveAllGroupMessages;
    _autoReplyToAllGroupMessages = config.autoReplyToAllGroupMessages;
    _enableAutoReply = config.enableAutoReply;
    _enableScheduled = config.enableScheduledTasks;
    _enableLogging = config.enableLogging;
    _reconnectInterval = config.reconnectInterval;
    _keywordReplies = Map.from(config.keywordReplies);
    _monitoredGroups = List.from(config.monitoredGroups);
    _monitoredFriends = List.from(config.monitoredFriends);
  }

  Future<void> _saveConfig() async {
    if (_isSaving) return;
    final baseUrl = AppConstants.normalizeApiBaseUrl(_apiUrlController.text);
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      _showError('请输入有效的 API 地址，例如 ${AppConstants.qqBaseUrl}');
      return;
    }
    setState(() => _isSaving = true);

    final previous = context.read<StorageService>().getBotConfig();
    final config = BotConfig(
      appId: _appIdController.text.trim(),
      clientSecret: _clientSecretController.text.trim(),
      apiBaseUrl: baseUrl,
      useSandbox: _useSandbox,
      autoReconnect: _autoReconnect,
      receiveAllGroupMessages: _receiveAllGroupMessages,
      autoReplyToAllGroupMessages: _autoReplyToAllGroupMessages,
      reconnectInterval: _reconnectInterval,
      monitoredGroups: _monitoredGroups,
      monitoredFriends: _monitoredFriends,
      enableAutoReply: _enableAutoReply,
      defaultAutoReply: _autoReplyController.text.trim(),
      keywordReplies: _keywordReplies,
      enableScheduledTasks: _enableScheduled,
      enableLogging: _enableLogging,
      markdownTemplateId: _markdownTemplateController.text.trim(),
      markdownTemplateParams: previous.markdownTemplateParams,
    );

    try {
      await context.read<BotClient>().updateConfig(config);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('配置已保存'),
          backgroundColor: AppTheme.qqGreen,
        ),
      );
    } catch (e) {
      if (mounted) _showError('配置保存失败: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppTheme.qqRed),
    );
  }

  Future<void> _testCredentials() async {
    if (_isTestingCredentials) return;
    if (_appIdController.text.trim().isEmpty ||
        _clientSecretController.text.trim().isEmpty) {
      _showError('请先填写 AppID 和机器人密钥');
      return;
    }
    setState(() {
      _isTestingCredentials = true;
      _credentialTestStatus = '';
    });
    final result = await ApiService().getAccessToken(
      appId: _appIdController.text.trim(),
      clientSecret: _clientSecretController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _isTestingCredentials = false;
      _credentialTestStatus = result.isSuccess ? '验证成功' : '验证失败';
    });
    if (!result.isSuccess) _showError(result.error ?? '凭据验证失败');
  }

  Future<void> _exportConfig() async {
    final json = context.read<StorageService>().exportConfig();
    if (isMobilePlatform) {
      try {
        final path = await FilePicker.saveFile(
          dialogTitle: '导出机器人配置',
          fileName:
              'qqbot_config_${DateTime.now().millisecondsSinceEpoch}.json',
          type: FileType.custom,
          allowedExtensions: ['json'],
          bytes: Uint8List.fromList(utf8.encode(json)),
        );
        if (!mounted || path == null) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('配置已导出；文件包含密钥，请妥善保管')));
      } catch (_) {
        if (mounted) _showError('导出失败，请选择可写入的位置');
      }
      return;
    }
    final dir = await FilePicker.getDirectoryPath(dialogTitle: '选择导出目录');
    if (dir == null) return;

    final file = File(
      '$dir/qqbot_config_${DateTime.now().millisecondsSinceEpoch}.json',
    );
    await file.writeAsString(json);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('配置已导出到：${file.path}'),
        backgroundColor: AppTheme.qqGreen,
      ),
    );
  }

  Future<void> _importConfig() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    final path = result?.files.single.path;
    if (path == null) return;

    final json = await File(path).readAsString();
    if (!mounted) return;
    await context.read<StorageService>().importConfig(json);
    if (!mounted) return;
    await context.read<BotClient>().updateConfig(
      context.read<StorageService>().getBotConfig(),
    );
    if (!mounted) return;
    await context.read<PluginManager>().init();
    if (!mounted) return;

    setState(_loadConfig);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('配置已导入'), backgroundColor: AppTheme.qqGreen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bot = context.watch<BotClient>();
    final compact = MediaQuery.sizeOf(context).width < 700;
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (!compact) _sideMenu(bot),
            Expanded(
              child: Column(
                children: [
                  _topBar(bot),
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.all(compact ? 8 : 16),
                      child: _settingsShell(bot),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sideMenu(BotClient bot) {
    return Container(
      width: 228,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        children: [
          SizedBox(
            height: 62,
            child: Row(
              children: [
                const SizedBox(width: 18),
                const Icon(
                  Icons.smart_toy_rounded,
                  color: AppTheme.qqBlue,
                  size: 28,
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'QQ 机器人管理器',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                  ),
                ),
                _versionChip('v1.0.0'),
                const SizedBox(width: 10),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 14),
                  _navItem(
                    Icons.dashboard_outlined,
                    '总览',
                    false,
                    () => Navigator.pop(context),
                  ),
                  _navItem(
                    Icons.chat_bubble_outline_rounded,
                    '消息',
                    false,
                    () {},
                  ),
                  _navItem(Icons.star_border_rounded, '事件', false, () {}),
                  _navItem(Icons.groups_rounded, '群聊', false, () {}),
                  _navItem(Icons.person_outline_rounded, '好友', false, () {}),
                  _navItem(Icons.receipt_long_rounded, '日志', false, () {}),
                  _navItem(Icons.extension_rounded, '插件中心', false, () {}),
                  _navItem(Icons.bar_chart_rounded, '数据统计', false, () {}),
                  _navItem(Icons.settings_rounded, '设置', true, () {}),
                ],
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.all(14),
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
                    Icon(
                      Icons.circle,
                      size: 10,
                      color: bot.isConnected
                          ? AppTheme.qqGreen
                          : AppTheme.qqRed,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      bot.isConnected ? '机器人在线' : '机器人离线',
                      style: TextStyle(
                        color: bot.isConnected
                            ? AppTheme.qqGreen
                            : AppTheme.qqRed,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '机器人 ID：${bot.botId.isEmpty ? "未获取" : bot.botId}',
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 6),
                const Text(
                  '协议：QQ 官方机器人 API v2',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 14),
                OutlinedButton(
                  onPressed: () =>
                      bot.isConnected ? bot.disconnect() : bot.connect(),
                  child: Text(bot.isConnected ? '断开连接' : '重新连接'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(
    IconData icon,
    String label,
    bool selected,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: selected
            ? AppTheme.qqBlue.withValues(alpha: 0.1)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            height: 46,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected ? AppTheme.qqBlue : const Color(0xFF526174),
                  size: 20,
                ),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
                    color: selected ? AppTheme.qqBlue : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _topBar(BotClient bot) {
    return Container(
      height: 62,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          const Text(
            '设置',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
          ),
          const Spacer(),
          _statusChip(
            bot.isConnected ? '机器人在线' : '机器人离线',
            bot.isConnected ? AppTheme.qqGreen : AppTheme.qqRed,
          ),
          const SizedBox(width: 12),
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
            tooltip: '关闭设置',
          ),
        ],
      ),
    );
  }

  Widget _settingsShell(BotClient bot) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 54,
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _tabButton('常规', 0),
                        _tabButton('连接', 1),
                        _tabButton('自动回复', 2),
                        _tabButton('数据', 3),
                        _tabButton('数据清理', 4),
                        _tabButton('关于', 5),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: FilledButton.icon(
                    onPressed: _isSaving ? null : _saveConfig,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_rounded, size: 18),
                    label: Text(_isSaving ? '保存中' : '保存'),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: Theme.of(context).dividerColor),
          Expanded(child: _tabBody(bot)),
        ],
      ),
    );
  }

  Widget _tabButton(String label, int index) {
    final selected = _tabIndex == index;
    return InkWell(
      onTap: () => setState(() => _tabIndex = index),
      child: Container(
        width: 120,
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              label,
              style: TextStyle(
                fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
                color: selected ? AppTheme.qqBlue : null,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: 72,
              height: 2,
              color: selected ? AppTheme.qqBlue : Colors.transparent,
            ),
          ],
        ),
      ),
    );
  }

  Widget _tabBody(BotClient bot) {
    return switch (_tabIndex) {
      0 => _generalGrid(bot),
      1 => _connectionsPage(),
      2 => _autoReplyPage(),
      3 => _dataPage(bot),
      4 => _dangerPage(),
      _ => _aboutPage(),
    };
  }

  Widget _generalGrid(BotClient bot) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - 28;
        final columns = width >= 1300 ? 3 : (width >= 900 ? 2 : 1);
        final cardWidth = (width - (columns - 1) * 12) / columns;
        return SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _credentialsCard(),
              _connectionCard(),
              _targetsCard(),
              _autoReplyCard(),
              _keywordRulesCard(),
              _dataManagementCard(),
              _dataSummaryCard(bot),
              _dangerZoneCard(),
            ].map((card) => SizedBox(width: cardWidth, child: card)).toList(),
          ),
        );
      },
    );
  }

  Widget _credentialsCard() {
    return _card(
      title: '机器人凭据',
      icon: Icons.verified_user_outlined,
      children: [
        _field('AppID', _appIdController),
        _field('机器人密钥', _clientSecretController, obscure: true),
        _field('Markdown 模板 ID', _markdownTemplateController),
        Row(
          children: [
            FilledButton(
              onPressed: _isTestingCredentials ? null : _testCredentials,
              child: Text(_isTestingCredentials ? '验证中...' : '测试凭据'),
            ),
            const SizedBox(width: 10),
            if (_credentialTestStatus.isNotEmpty)
              _statusChip(
                _credentialTestStatus,
                _credentialTestStatus == '验证成功'
                    ? AppTheme.qqGreen
                    : AppTheme.qqRed,
              ),
          ],
        ),
      ],
    );
  }

  Widget _connectionCard() {
    return _card(
      title: '网关连接',
      icon: Icons.link_rounded,
      children: [
        _field('API 地址', _apiUrlController),
        _numberStepper(
          '重连间隔（秒）',
          _reconnectInterval,
          (value) => setState(() => _reconnectInterval = value.clamp(1, 300)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动重连'),
          value: _autoReconnect,
          onChanged: (value) => setState(() => _autoReconnect = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('使用旧版沙箱'),
          value: _useSandbox,
          onChanged: (value) => setState(() => _useSandbox = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('处理全量群消息'),
          subtitle: const Text('本地接收与展示开关；需先在 QQ 开放平台开启“接收所有消息”。关闭不影响 @ 消息。'),
          value: _receiveAllGroupMessages,
          onChanged: (value) =>
              setState(() => _receiveAllGroupMessages = value),
        ),
        FilledButton(onPressed: _saveConfig, child: const Text('保存连接设置')),
      ],
    );
  }

  Widget _targetsCard() {
    return _card(
      title: '关注的会话',
      icon: Icons.groups_rounded,
      children: [
        _addRow(
          _groupController,
          '输入群聊 OpenID...',
          () => _addTarget(_groupController, _monitoredGroups),
        ),
        const SizedBox(height: 8),
        _targetTable(
          '群聊',
          _monitoredGroups,
          AppTheme.qqGreen,
          (id) => setState(() => _monitoredGroups.remove(id)),
        ),
        const SizedBox(height: 8),
        _addRow(
          _friendController,
          '输入用户 OpenID...',
          () => _addTarget(_friendController, _monitoredFriends),
        ),
        const SizedBox(height: 8),
        _targetTable(
          '好友',
          _monitoredFriends,
          AppTheme.qqBlue,
          (id) => setState(() => _monitoredFriends.remove(id)),
        ),
      ],
    );
  }

  Widget _autoReplyCard() {
    return _card(
      title: '自动回复',
      icon: Icons.chat_bubble_outline_rounded,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用自动回复'),
          value: _enableAutoReply,
          onChanged: (value) => setState(() => _enableAutoReply = value),
        ),
        TextField(
          controller: _autoReplyController,
          maxLines: 3,
          decoration: const InputDecoration(labelText: '默认回复内容'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('普通群消息也触发插件和自动回复'),
          subtitle: const Text(
            '默认关闭：全量消息仅处理明确的天气/IP 指令，其他普通聊天只展示。开启后额外执行所有已启用插件和回复规则。',
          ),
          value: _autoReplyToAllGroupMessages,
          onChanged: (value) =>
              setState(() => _autoReplyToAllGroupMessages = value),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('定时任务（暂未实现）'),
          value: false,
          onChanged: null,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用日志'),
          value: _enableLogging,
          onChanged: (value) => setState(() => _enableLogging = value),
        ),
      ],
    );
  }

  Widget _keywordRulesCard() {
    return _card(
      title: '关键词回复',
      icon: Icons.list_alt_rounded,
      trailing: OutlinedButton.icon(
        onPressed: _addKeywordReply,
        icon: const Icon(Icons.add_rounded),
        label: const Text('添加规则'),
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _keywordController,
                decoration: const InputDecoration(labelText: '关键词'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _replyController,
                decoration: const InputDecoration(labelText: '回复内容'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _keywordTable(),
      ],
    );
  }

  Widget _dataManagementCard() {
    return _card(
      title: '配置管理',
      icon: Icons.storage_rounded,
      children: [
        const Text('导出或导入机器人配置、表情和插件设置。'),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _exportConfig,
                child: const Text('导出配置'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _importConfig,
                child: const Text('导入配置'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _dataSummaryCard(BotClient bot) {
    return _card(
      title: '数据统计',
      icon: Icons.pie_chart_outline_rounded,
      children: [
        _summaryLine('消息', '${bot.messages.length}'),
        _summaryLine('会话', '${bot.sessions.length}'),
        _summaryLine('群聊', '${_monitoredGroups.length}'),
        _summaryLine('好友', '${_monitoredFriends.length}'),
        Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton(
            onPressed: () => setState(() => _tabIndex = 3),
            child: const Text('查看更多'),
          ),
        ),
      ],
    );
  }

  Widget _dangerZoneCard() {
    return _card(
      title: '数据清理',
      icon: Icons.warning_amber_rounded,
      danger: true,
      children: [
        const Text(
          '清除数据后无法恢复，请先导出配置。',
          style: TextStyle(color: AppTheme.qqRed),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () {
                  imageCache.clear();
                  imageCache.clearLiveImages();
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('内存图片缓存已清除')));
                },
                child: const Text('清除内存图片缓存'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: OutlinedButton(
                onPressed: _confirmClearAll,
                child: const Text('清除全部数据'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.qqRed),
          onPressed: _confirmResetConfig,
          child: const Text('重置机器人配置'),
        ),
      ],
    );
  }

  Widget _connectionsPage() => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: _connectionCard(),
  );
  Widget _autoReplyPage() => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: _autoReplyCard(),
  );
  Widget _dataPage(BotClient bot) => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: Column(
      children: [
        _dataManagementCard(),
        const SizedBox(height: 12),
        _dataSummaryCard(bot),
      ],
    ),
  );
  Widget _dangerPage() => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: _dangerZoneCard(),
  );
  Widget _aboutPage() => Center(
    child: Text(
      'QQ 机器人管理器\n基于 QQ 官方开放平台的跨平台桌面管理工具。',
      textAlign: TextAlign.center,
      style: TextStyle(color: Theme.of(context).hintColor),
    ),
  );

  Widget _card({
    required String title,
    required IconData icon,
    required List<Widget> children,
    Widget? trailing,
    bool danger = false,
  }) {
    final color = danger ? AppTheme.qqRed : AppTheme.qqBlue;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: danger
            ? AppTheme.qqRed.withValues(alpha: 0.04)
            : Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: danger
              ? AppTheme.qqRed.withValues(alpha: 0.25)
              : Theme.of(context).dividerColor,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: danger ? AppTheme.qqRed : null,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    bool obscure = false,
  }) {
    if (MediaQuery.sizeOf(context).width < 700) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          obscureText: obscure,
          decoration: InputDecoration(labelText: label),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: obscure,
              decoration: const InputDecoration(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numberStepper(String label, int value, ValueChanged<int> onChanged) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          IconButton.outlined(
            onPressed: () => onChanged(value - 1),
            icon: const Icon(Icons.remove_rounded, size: 16),
          ),
          SizedBox(width: 42, child: Center(child: Text('$value'))),
          IconButton.outlined(
            onPressed: () => onChanged(value + 1),
            icon: const Icon(Icons.add_rounded, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _addRow(
    TextEditingController controller,
    String hint,
    VoidCallback onAdd,
  ) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: const Text('添加'),
        ),
      ],
    );
  }

  void _addTarget(TextEditingController controller, List<String> list) {
    final id = controller.text.trim();
    if (id.isEmpty || list.contains(id)) return;
    setState(() {
      list.add(id);
      controller.clear();
    });
  }

  Widget _targetTable(
    String label,
    List<String> rows,
    Color color,
    ValueChanged<String> onDelete,
  ) {
    if (rows.isEmpty) {
      return Text(
        '暂无$label。',
        style: TextStyle(color: Theme.of(context).hintColor),
      );
    }
    return Column(
      children: [
        for (final id in rows)
          Container(
            height: 36,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Expanded(child: Text(id)),
                _statusChip('已启用', color),
                IconButton(
                  onPressed: () => onDelete(id),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppTheme.qqRed,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _keywordTable() {
    if (_keywordReplies.isEmpty) {
      return Text(
        '暂无关键词规则。',
        style: TextStyle(color: Theme.of(context).hintColor),
      );
    }
    return Column(
      children: [
        for (final entry in _keywordReplies.entries)
          Container(
            height: 42,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.key,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(entry.value, overflow: TextOverflow.ellipsis),
                ),
                const SizedBox(width: 80, child: Text('完整匹配')),
                _statusChip('已启用', AppTheme.qqGreen),
                IconButton(
                  onPressed: () =>
                      setState(() => _keywordReplies.remove(entry.key)),
                  icon: const Icon(
                    Icons.delete_outline_rounded,
                    color: AppTheme.qqRed,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _addKeywordReply() {
    final keyword = _keywordController.text.trim();
    final reply = _replyController.text.trim();
    if (keyword.isEmpty || reply.isEmpty) return;
    setState(() {
      _keywordReplies[keyword] = reply;
      _keywordController.clear();
      _replyController.clear();
    });
  }

  Future<void> _confirmClearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('确认清除数据'),
        content: const Text('此操作不可撤销。确定要清除所有数据吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.qqRed),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    context.read<BotClient>().disconnect();
    await context.read<StorageService>().clearAll();
    if (!mounted) return;
    context.read<BotClient>().resetLocalState();
    await context.read<PluginManager>().init();
    if (!mounted) return;
    setState(_loadConfig);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('所有数据已清除'), backgroundColor: AppTheme.qqRed),
    );
  }

  Future<void> _confirmResetConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置机器人配置'),
        content: const Text('仅重置机器人凭据和连接设置，保留聊天记录、表情和插件配置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重置配置'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    context.read<BotClient>().disconnect();
    await context.read<BotClient>().updateConfig(BotConfig());
    if (!mounted) return;
    setState(_loadConfig);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('机器人配置已重置，聊天记录已保留')));
  }

  Widget _summaryLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(label),
          const Spacer(),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }

  Widget _statusChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }

  Widget _versionChip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.qqBlue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.qqBlue,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
