import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/bot_client.dart';
import '../../core/plugin_manager.dart';
import '../../services/api_service.dart';
import '../../services/ip_whitelist_service.dart';
import '../widgets/ip_whitelist_dialog.dart';
import '../../utils/constants.dart';
import '../../models/config.dart';
import '../../services/storage_service.dart';
import '../../services/theme_preferences.dart';
import '../../services/desktop_window_controller.dart';
import '../../services/qq_qr_login_service.dart';
import '../themes/app_theme.dart';
import '../../utils/platforms.dart';
import '../widgets/app_logo.dart';
import '../widgets/update_panel.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/qq_qr_login_panel.dart';
import 'browser_screen.dart';
import 'onboarding_screen.dart';

class SettingsScreen extends StatefulWidget {
  final QqQrLoginService Function()? qrServiceFactory;
  const SettingsScreen({super.key, this.qrServiceFactory});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _appIdController = TextEditingController();
  final TextEditingController _clientSecretController = TextEditingController();
  final TextEditingController _apiUrlController = TextEditingController();

  bool _useSandbox = false;
  bool _autoReconnect = true;
  bool _receiveAllGroupMessages = true;
  bool _enableLogging = true;
  bool _closeToTray = false;
  bool _skipCloseConfirmation = false;
  bool _windowPreferencesDirty = false;
  bool _isSaving = false;
  bool _isTestingCredentials = false;
  String _credentialTestStatus = '';
  int _reconnectInterval = 5;
  int _tabIndex = 0;
  int _connectionMethod = 0;
  int _qrRevision = 0;
  bool _addingBot = false;

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
    super.dispose();
  }

  void _loadConfig() {
    _addingBot = false;
    final config = context.read<StorageService>().getBotConfig();
    _appIdController.text = config.appId;
    _clientSecretController.text = config.clientSecret;
    _apiUrlController.text = config.apiBaseUrl;
    _useSandbox = config.useSandbox;
    _autoReconnect = config.autoReconnect;
    _receiveAllGroupMessages = config.receiveAllGroupMessages;
    _enableLogging = config.enableLogging;
    _closeToTray = config.closeToTray;
    _skipCloseConfirmation = config.skipCloseConfirmation;
    _windowPreferencesDirty = false;
    _reconnectInterval = config.reconnectInterval;
  }

  Future<void> _saveConfig() async {
    if (_isSaving) return;
    if (_addingBot &&
        (_appIdController.text.trim().isEmpty ||
            _clientSecretController.text.trim().isEmpty)) {
      _showError('请先填写 AppID 和机器人密钥，或使用扫码连接。');
      return;
    }
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
      autoReplyToAllGroupMessages: previous.autoReplyToAllGroupMessages,
      reconnectInterval: _reconnectInterval,
      monitoredGroups: previous.monitoredGroups,
      monitoredFriends: previous.monitoredFriends,
      // Legacy fields remain readable/exportable but no longer drive replies.
      enableAutoReply: previous.enableAutoReply,
      defaultAutoReply: previous.defaultAutoReply,
      keywordReplies: previous.keywordReplies,
      enableScheduledTasks: previous.enableScheduledTasks,
      enableLogging: _enableLogging,
      enableOiapiNickname: previous.enableOiapiNickname,
      closeToTray: _windowPreferencesDirty
          ? _closeToTray
          : previous.closeToTray,
      skipCloseConfirmation: _windowPreferencesDirty
          ? _skipCloseConfirmation
          : previous.skipCloseConfirmation,
      markdownTemplateId: previous.markdownTemplateId,
      markdownTemplateParams: previous.markdownTemplateParams,
    );

    try {
      await context.read<BotClient>().updateConfig(config);
      if (mounted) {
        await context.read<DesktopWindowController?>()?.refreshPreferences();
      }
      if (!mounted) return;
      _windowPreferencesDirty = false;
      AppDialogs.show(context, '配置已保存');
    } catch (e) {
      if (mounted) _showError('配置保存失败: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showError(String message) {
    AppDialogs.show(context, message, title: '操作失败', error: true);
  }

  Future<bool> _saveQrCredentials(QrBotCredentials credentials) async {
    if (_isSaving || !mounted) return false;
    var saved = false;
    setState(() => _isSaving = true);
    try {
      final bot = context.read<BotClient>();
      final matching = bot.botProfiles
          .where((profile) => profile.appId == credentials.appId)
          .firstOrNull;
      final replacement = BotConfig.fromMap((matching ?? BotConfig()).toMap())
        ..appId = credentials.appId
        ..clientSecret = credentials.appSecret;
      await bot.updateConfig(replacement);
      saved = true;
      if (!mounted) return true;
      setState(() {
        _loadConfig();
        _credentialTestStatus = '';
      });
      final connected = await bot.connect();
      if (mounted) {
        AppDialogs.show(
          context,
          connected
              ? '扫码授权已保存，机器人已连接。'
              : '凭据已保存，但网关尚未连接成功。请查看连接状态，检查平台权限或稍后重试。',
          title: connected ? '连接成功' : '连接未完成',
          error: !connected,
        );
      }
      return true;
    } catch (_) {
      if (mounted) {
        _showError(saved ? '凭据已保存，但连接未完成，请稍后重新连接。' : '扫码凭据保存失败，请重试。');
      }
      return saved;
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _replayOnboarding() async {
    final openConnection = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (route) => OnboardingScreen(
          replay: true,
          onFinished: (open) async => Navigator.pop(route, open),
        ),
      ),
    );
    if (openConnection == true && mounted) {
      setState(() {
        _tabIndex = 0;
        _connectionMethod = 0;
      });
    }
  }

  Future<void> _testCredentials() async {
    if (_isTestingCredentials) return;
    if (_addingBot &&
        (_appIdController.text.trim().isEmpty ||
            _clientSecretController.text.trim().isEmpty)) {
      _showError('请先填写 AppID 和机器人密钥');
      return;
    }
    setState(() {
      _isTestingCredentials = true;
      _credentialTestStatus = '';
    });
    final appId = _appIdController.text.trim();
    final result = await ApiService().getAccessToken(
      appId: appId,
      clientSecret: _clientSecretController.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _isTestingCredentials = false;
      _credentialTestStatus = result.isSuccess ? '验证成功' : '验证失败';
    });
    if (!result.isSuccess) {
      if (isIpWhitelistError(result.error ?? '')) {
        await showDialog<void>(
          context: context,
          builder: (_) => IpWhitelistDialog(
            trackBotProblem: false,
            problem: IpWhitelistProblem(
              appId: appId,
              message: result.error!,
              sourceIp: result.metadata?['sourceIp'] as String?,
            ),
          ),
        );
      } else {
        _showError(result.error ?? '凭据验证失败');
      }
    }
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
        AppDialogs.show(context, '配置已导出；文件包含密钥，请妥善保管');
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
    AppDialogs.show(context, '配置已导出到：${file.path}');
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
    AppDialogs.show(context, '配置已导入');
  }

  @override
  Widget build(BuildContext context) {
    final bot = context.watch<BotClient>();
    final compact = usePhoneLayout(context);
    if (compact) {
      return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: '关闭设置',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          ),
          title: const Text('设置'),
        ),
        body: SafeArea(top: false, child: _settingsShell(bot)),
      );
    }
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
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 12),
            child: Row(
              children: [
                const AppLogo(size: 28),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'QQ 机器人管理器',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 5),
                      _versionChip('v${AppConstants.appVersion}'),
                    ],
                  ),
                ),
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
                    '返回工作台',
                    false,
                    () => Navigator.pop(context),
                  ),
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
    if (usePhoneLayout(context)) {
      return Column(
        children: [
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Row(
                children: [
                  for (final item in const [
                    ('常规', 0, Icons.smart_toy_outlined),
                    ('连接', 1, Icons.link_rounded),
                    ('数据', 3, Icons.folder_outlined),
                    ('数据清理', 4, Icons.cleaning_services_outlined),
                    ('关于', 5, Icons.info_outline_rounded),
                    ('更新', 6, Icons.system_update_rounded),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        showCheckmark: false,
                        avatar: Icon(item.$3, size: 17),
                        label: Text(item.$1),
                        selected: _tabIndex == item.$2,
                        onSelected: (_) => setState(() => _tabIndex = item.$2),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: _tabBody(bot)),
        ],
      );
    }
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
                        _tabButton('数据', 3),
                        _tabButton('数据清理', 4),
                        _tabButton('关于', 5),
                        _tabButton('更新', 6),
                      ],
                    ),
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
      3 => _dataPage(bot),
      4 => _dangerPage(),
      6 => const UpdatePanel(),
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
              if (context.watch<ThemePreferences?>() != null) _appearanceCard(),
              _loggingCard(),
            ].map((card) => SizedBox(width: cardWidth, child: card)).toList(),
          ),
        );
      },
    );
  }

  Widget _appearanceCard() {
    final appearance = context.watch<ThemePreferences>();
    return _card(
      title: '外观与主题',
      icon: Icons.palette_outlined,
      children: [
        const Text('立即切换，应用会记住你的选择。'),
        const SizedBox(height: 12),
        for (final item in const [
          (ThemeMode.system, '跟随系统', Icons.brightness_auto_outlined),
          (ThemeMode.light, '浅色', Icons.light_mode_outlined),
          (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
        ])
          ListTile(
            key: ValueKey('theme-${item.$1.name}'),
            contentPadding: EdgeInsets.zero,
            leading: Icon(item.$3),
            title: Text(item.$2),
            trailing: Icon(
              appearance.mode == item.$1
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
              color: appearance.mode == item.$1
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            enabled: !appearance.saving,
            onTap: () async {
              try {
                await appearance.select(item.$1);
              } catch (_) {
                if (mounted) _showError('主题选择未能保存，请重试。');
              }
            },
          ),
      ],
    );
  }

  Widget _credentialsCard() {
    return _card(
      title: '机器人凭据',
      icon: Icons.verified_user_outlined,
      children: [
        if (context.read<BotClient>().botProfiles.isNotEmpty) ...[
          DropdownButtonFormField<String>(
            key: ValueKey(context.read<BotClient>().config.appId),
            initialValue: context.read<BotClient>().config.appId.isEmpty
                ? null
                : context.read<BotClient>().config.appId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '已保存的机器人'),
            items: [
              for (final profile in context.read<BotClient>().botProfiles)
                DropdownMenuItem(
                  value: profile.appId,
                  child: Text(
                    'AppID · ${profile.appId}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: _isSaving
                ? null
                : (value) async {
                    if (value == null) return;
                    setState(() => _isSaving = true);
                    try {
                      await context.read<BotClient>().switchBot(value);
                      if (mounted) {
                        setState(() {
                          _loadConfig();
                          _qrRevision++;
                        });
                      }
                    } catch (_) {
                      if (mounted) _showError('切换失败，原配置仍保留，请检查本地存储。');
                    } finally {
                      if (mounted) setState(() => _isSaving = false);
                    }
                  },
          ),
          TextButton.icon(
            onPressed: _isSaving
                ? null
                : () => setState(() {
                    _addingBot = true;
                    _appIdController.clear();
                    _clientSecretController.clear();
                    _connectionMethod = 0;
                    _qrRevision++;
                  }),
            icon: const Icon(Icons.add),
            label: const Text('添加其他机器人'),
          ),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            ChoiceChip(
              label: const Text('扫码连接（推荐）'),
              selected: _connectionMethod == 0,
              onSelected: _isSaving
                  ? null
                  : (_) => setState(() => _connectionMethod = 0),
            ),
            ChoiceChip(
              label: const Text('手动配置'),
              selected: _connectionMethod == 1,
              onSelected: _isSaving
                  ? null
                  : (_) => setState(() => _connectionMethod = 1),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_connectionMethod == 0)
          QqQrLoginPanel(
            key: ValueKey(_qrRevision),
            onConfirm: _saveQrCredentials,
            serviceFactory: widget.qrServiceFactory,
            enabled: !_isSaving,
          )
        else ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Text(
              '从 QQ 开放平台获取 AppID 和机器人密钥，填写后保存。',
              style: TextStyle(fontSize: 13),
            ),
          ),
          _field('AppID', _appIdController),
          _field('机器人密钥', _clientSecretController, obscure: true),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton(
                onPressed: _isTestingCredentials ? null : _testCredentials,
                child: Text(_isTestingCredentials ? '验证中...' : '测试凭据'),
              ),
              OutlinedButton(
                onPressed: _isSaving ? null : _saveConfig,
                child: const Text('保存手动配置'),
              ),
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
        const SizedBox(height: 16),
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

  Widget _loggingCard() {
    return _card(
      title: '运行日志',
      icon: Icons.receipt_long_outlined,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('启用日志'),
          value: _enableLogging,
          onChanged: (value) => setState(() => _enableLogging = value),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _saveConfig,
          child: const Text('保存日志设置'),
        ),
      ],
    );
  }

  Widget _windowCard() {
    context.watch<DesktopWindowController?>();
    final saved = context.read<StorageService>().getBotConfig();
    final closeToTray = _windowPreferencesDirty
        ? _closeToTray
        : saved.closeToTray;
    final skipConfirmation = _windowPreferencesDirty
        ? _skipCloseConfirmation
        : saved.skipCloseConfirmation;
    return _card(
      title: '桌面窗口',
      icon: Icons.desktop_windows_outlined,
      children: [
        const Text('标题栏空白处可拖动；双击最大化或还原。最小化按钮仍最小化到任务栏。'),
        SwitchListTile(
          key: const ValueKey('close-to-tray-switch'),
          contentPadding: EdgeInsets.zero,
          title: const Text('关闭窗口时隐藏到系统托盘'),
          subtitle: const Text(
            '开启并保存后，关闭或 Alt+F4 直接隐藏到托盘，不再询问。'
            '未开启时可在关闭弹窗中选择退出或隐藏，并勾选记住选择。托盘不可用时保持窗口可见。',
          ),
          value: closeToTray,
          onChanged: (value) => setState(() {
            _closeToTray = value;
            _skipCloseConfirmation = skipConfirmation;
            _windowPreferencesDirty = true;
          }),
        ),
        if (!closeToTray) ...[
          Text(skipConfirmation ? '已记住：关闭时直接退出。' : '关闭时会询问，不会自动退出或强制驻留。'),
          if (skipConfirmation)
            TextButton.icon(
              onPressed: () => setState(() {
                _closeToTray = closeToTray;
                _skipCloseConfirmation = false;
                _windowPreferencesDirty = true;
              }),
              icon: const Icon(Icons.restore_rounded, size: 18),
              label: const Text('恢复关闭确认（保存后生效）'),
            ),
        ],
        FilledButton(onPressed: _saveConfig, child: const Text('保存窗口设置')),
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
        _summaryLine(
          '群聊',
          '${bot.sessions.where((session) => session.sessionType == 1).length}',
        ),
        _summaryLine(
          '单聊',
          '${bot.sessions.where((session) => session.sessionType == 0).length}',
        ),
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
                  AppDialogs.show(context, '内存图片缓存已清除');
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
    child: Column(
      children: [
        _connectionCard(),
        if (isDesktopPlatform) ...[const SizedBox(height: 12), _windowCard()],
      ],
    ),
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
  Widget _aboutPage() => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          children: [
            const AppLogo(size: 72),
            const SizedBox(height: 16),
            Text('QQ机器人管理器', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            const Text('基于QQ官方开放平台的跨平台桌面管理工具。', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            const Text('学习为目的编写的'),
            const SizedBox(height: 8),
            const SelectableText('作者QQ：2377130783'),
            const SizedBox(height: 8),
            const Text('问题建议可以反馈'),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _replayOnboarding,
              icon: const Icon(Icons.school_outlined),
              label: const Text('重新查看使用引导'),
            ),
            const SizedBox(height: 24),
            const Text('项目地址'),
            const SizedBox(height: 4),
            const SelectableText(
              AppConstants.projectUrl,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () =>
                  openInAppBrowser(context, AppConstants.projectUrl),
              icon: const Icon(Icons.code),
              label: const Text('在应用内打开项目'),
            ),
          ],
        ),
      ),
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
    if (usePhoneLayout(context)) {
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
    AppDialogs.show(context, '所有数据已清除');
  }

  Future<void> _confirmResetConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置机器人配置'),
        content: const Text('重置当前 AppID 的密钥和连接设置，保留聊天记录、表情和插件配置。不影响其他已保存的机器人。'),
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
    final bot = context.read<BotClient>();
    await bot.updateConfig(BotConfig(appId: bot.config.appId));
    if (!mounted) return;
    setState(_loadConfig);
    AppDialogs.show(context, '机器人配置已重置，聊天记录已保留');
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
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 11,
          color: AppTheme.qqBlue,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
