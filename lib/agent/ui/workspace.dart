import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../../ui/widgets/app_dialogs.dart';
import '../../ui/widgets/qq_qr_login_panel.dart';
import '../../services/qq_qr_login_service.dart';
import '../../ui/screens/browser_screen.dart';
import '../controller.dart';
import '../models.dart';
import '../extensions.dart';
import '../package_bundle.dart';
import '../builtin_tools.dart';
import 'editor.dart';
import 'extension_file_manager.dart';
import '../../services/data_migration_service.dart';
import '../../services/desktop_file_location.dart';
import '../../utils/platforms.dart';
import '../../ui/screens/data_migration_screen.dart';
import 'chat.dart';

class AgentWorkspace extends StatefulWidget {
  final QqQrLoginService Function()? qrServiceFactory;
  const AgentWorkspace({super.key, this.qrServiceFactory});
  @override
  State<AgentWorkspace> createState() => _AgentWorkspaceState();
}

class _AgentWorkspaceState extends State<AgentWorkspace> {
  AgentController? _controller;
  Future<void>? _loading;
  int _section = 0;
  String? _selectedConnection, _selectedSession;
  final _busy = <String>{};
  AgentController get agent => _controller!;
  static const _labels = [
    '聊天',
    '机器人连接',
    'AI 模型',
    '预设',
    'AI 插件',
    'Skills',
    '运行日志',
    '能力与资料',
  ];
  static const _icons = [
    Icons.chat_bubble_outline,
    Icons.cable_rounded,
    Icons.auto_awesome_outlined,
    Icons.face_retouching_natural,
    Icons.extension_outlined,
    Icons.psychology_outlined,
    Icons.receipt_long_outlined,
    Icons.inventory_2_outlined,
  ];
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller == null) {
      _controller = context.read<AgentController>();
      _loading = agent.initialize();
    }
  }

  Future<void> _run(Future<void> Function() action, {String key = ''}) async {
    if (_busy.contains(key)) return;
    setState(() => _busy.add(key));
    try {
      await action();
    } catch (e) {
      if (mounted) {
        await AppDialogs.show(
          context,
          agent.describeError(e),
          title: 'QQ Agent',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ) ==
      true;
  Future<void> _manual() async {
    final source = await rootBundle.loadString('docs/agent-development.md');
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(title: const Text('QQ Agent 使用与开发')),
          body: Markdown(
            data: source,
            onTapLink: (_, url, _) {
              if (url != null && url.startsWith('http')) {
                openInAppBrowser(ctx, url);
              }
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('QQ Agent'),
          Text('QQBOT / ONEBOT 11 · AI 工作区', style: TextStyle(fontSize: 11)),
        ],
      ),
      leading: IconButton(
        tooltip: '返回官方机器人',
        icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.pop(context),
      ),
      actions: [
        IconButton(
          tooltip: '数据迁移',
          icon: const Icon(Icons.inventory_2_outlined),
          onPressed: () {
            final service = context.read<DataMigrationService?>();
            if (service != null) {
              Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => DataMigrationScreen(service: service),
                ),
              );
            }
          },
        ),
        IconButton(
          tooltip: '使用与开发文档',
          onPressed: () => _run(_manual, key: 'manual'),
          icon: const Icon(Icons.help_outline),
        ),
      ],
    ),
    body: FutureBuilder<void>(
      future: _loading,
      builder: (ctx, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(agent.describeError(snapshot.error!)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () =>
                        setState(() => _loading = agent.initialize()),
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListenableBuilder(
          listenable: agent,
          builder: (context, _) => LayoutBuilder(
            builder: (context, size) {
              final desktop = size.maxWidth >= 900;
              return Row(
                children: [
                  if (desktop)
                    NavigationRail(
                      selectedIndex: _section,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (v) =>
                          setState(() => _section = v),
                      destinations: [
                        for (var i = 0; i < _labels.length; i++)
                          NavigationRailDestination(
                            icon: Icon(_icons[i]),
                            label: Text(_labels[i]),
                          ),
                      ],
                    ),
                  if (desktop) const VerticalDivider(width: 1),
                  Expanded(
                    child: Column(
                      children: [
                        if (!desktop)
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                            child: Row(
                              children: [
                                for (var i = 0; i < _labels.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: Text(_labels[i]),
                                      selected: _section == i,
                                      onSelected: (_) =>
                                          setState(() => _section = i),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: switch (_section) {
                            0 => _chat(),
                            1 => _connections(),
                            2 => _providers(),
                            3 => _presets(),
                            4 => _extensions('plugin'),
                            5 => _extensions('skill'),
                            7 => _builtinDataPage(),
                            _ => _logs(),
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    ),
  );
  Widget _page(
    String title,
    String subtitle,
    List<Widget> children, {
    Widget? action,
  }) => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        runSpacing: 12,
        spacing: 16,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 6),
            ],
          ),
          ?action,
        ],
      ),
      Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 20),
      ...children,
    ],
  );
  Widget _tile({
    required String title,
    required String subtitle,
    required IconData icon,
    required List<Widget> actions,
    Widget? details,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(subtitle),
                  ],
                ),
              ),
            ],
          ),
          if (details != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: details),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ),
    ),
  );
  Widget _empty(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Center(child: Text(message, textAlign: TextAlign.center)),
  );

  Widget _connections() => _page(
    '接入你的 QQ 机器人',
    '选择 QQBot 官方机器人，或已登录的 OneBot 11 协议端。这里的连接、聊天与 AI 配置独立保存。',
    [
      if (agent.connections.isEmpty) _empty('先添加连接，再设置模型与预设。'),
      for (final c in agent.connections)
        _tile(
          title: agent.nickname(c.id).isEmpty
              ? c.name
              : '${c.name} · ${agent.nickname(c.id)}',
          subtitle:
              '${c.protocolLabel} · ${c.isOfficial ? 'AppID' : 'QQ'} ${c.selfId} · ${c.isOfficial
                  ? '官方 WebSocket'
                  : c.mode == 'reverse'
                  ? '反向 WS 监听'
                  : '正向 WS 连接'}\n${agent.status(c.id)}',
          icon: agent.connected(c.id) ? Icons.link : Icons.link_off,
          details: !c.isOfficial && c.mode == 'reverse'
              ? SelectableText(
                  '协议端填写：ws://${c.host == '0.0.0.0' || c.host == '::' ? '本机局域网IP' : c.host}:${c.port}${c.path}',
                )
              : null,
          actions: [
            FilledButton.tonal(
              onPressed: _busy.contains(c.id)
                  ? null
                  : () => _run(() async {
                      if (agent.started(c.id)) {
                        await agent.disconnect(c.id);
                      } else {
                        await agent.connect(c.id);
                      }
                    }, key: c.id),
              child: Text(agent.started(c.id) ? '停止连接' : '启动连接'),
            ),
            OutlinedButton(
              onPressed: () => _editConnection(c),
              child: const Text('配置'),
            ),
            if (!c.isOfficial)
              TextButton(
                onPressed: agent.connected(c.id)
                    ? () => _run(() => agent.syncContacts(c.id), key: c.id)
                    : null,
                child: const Text('同步好友与群'),
              ),
            TextButton(
              onPressed: () => _run(() async {
                if (await _confirm(
                  '移除此连接？',
                  '停止连接并移除配置，历史聊天仍保留在 Agent 的独立数据库中。',
                )) {
                  await agent.deleteConnection(c.id);
                }
              }, key: c.id),
              child: const Text('移除'),
            ),
          ],
        ),
    ],
    action: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: _qrLogin,
          icon: const Icon(Icons.qr_code),
          label: const Text('QQBot 扫码'),
        ),
        FilledButton.icon(
          onPressed: () => _editConnection(null),
          icon: const Icon(Icons.add),
          label: const Text('添加连接'),
        ),
      ],
    ),
  );
  Future<void> _qrLogin() => _run(() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialog) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 620,
            maxHeight: MediaQuery.sizeOf(dialog).height * .9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('QQ Agent · 官方机器人扫码')),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.pop(dialog),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                QqQrLoginPanel(
                  serviceFactory: widget.qrServiceFactory,
                  introduction: '授权后仅保存到 QQ Agent，并连接官方机器人。',
                  confirmationDescription:
                      '授权会重置该机器人的密钥，其他使用旧密钥的程序需要同步更新。\n\n新凭证仅保存到 QQ Agent，不修改原工作区的配置。同一 AppID 可以与工作台同时运行；请确保两边使用有效的新密钥。',
                  onConfirm: (credentials) async {
                    final old = agent.connections
                        .where(
                          (c) => c.isOfficial && c.selfId == credentials.appId,
                        )
                        .firstOrNull;
                    final value = AgentConnection.fromJson({
                      ...?old?.toJson(),
                      'id': old?.id ?? const Uuid().v4(),
                      'name': old?.name ?? 'QQBot ${credentials.appId}',
                      'protocol': 'qqbot',
                      'appId': credentials.appId,
                      'clientSecret': credentials.appSecret,
                    });
                    try {
                      await agent.saveConnection(value);
                      await agent.connect(value.id);
                      return true;
                    } catch (error) {
                      if (dialog.mounted) {
                        await AppDialogs.show(
                          dialog,
                          agent.describeError(error),
                          error: true,
                        );
                      }
                      return false;
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }, key: 'qr');
  Future<void> _editConnection(AgentConnection? c) async {
    final initial =
        c?.toJson() ??
        AgentConnection(
          id: const Uuid().v4(),
          name: '我的 QQ Agent',
          selfId: '',
          token: '${const Uuid().v4()}${const Uuid().v4()}'.replaceAll('-', ''),
        ).toJson();
    await editAgent(
      context,
      title: c == null ? '添加机器人连接' : '配置机器人连接',
      initial: initial,
      description: 'QQBot 使用 AppID 与密钥；OneBot 正向连接协议端，反向由应用监听。保存后需要重新启动连接。',
      fields: [
        const AgentField('name', '连接名称'),
        const AgentField(
          'protocol',
          '机器人类型',
          type: 'choice',
          choices: {'onebot': 'OneBot 11 · QQ 协议端', 'qqbot': 'QQBot · 官方机器人'},
        ),
        const AgentField('appId', 'QQBot AppID', when: {'protocol': 'qqbot'}),
        const AgentField(
          'clientSecret',
          'QQBot ClientSecret',
          type: 'secret',
          when: {'protocol': 'qqbot'},
        ),
        const AgentField(
          'sandbox',
          '使用官方沙箱环境',
          type: 'bool',
          when: {'protocol': 'qqbot'},
        ),
        const AgentField(
          'selfId',
          '机器人 QQ 号',
          hint: '填写协议端实际登录的 QQ 号，用于校验账号和隔离数据。',
          when: {'protocol': 'onebot'},
        ),
        const AgentField(
          'mode',
          '连接方式',
          type: 'choice',
          choices: {'forward': '正向 WS · 连接协议端', 'reverse': '反向 WS · 应用监听端口'},
          when: {'protocol': 'onebot'},
        ),
        const AgentField(
          'url',
          '正向 WS 地址',
          hint: '例如 ws://127.0.0.1:3001/，使用 API 与事件共用的通用接口。',
          when: {'protocol': 'onebot', 'mode': 'forward'},
        ),
        const AgentField(
          'host',
          '反向监听 IP',
          hint: '本机使用 127.0.0.1；允许局域网连接填写 0.0.0.0。',
          when: {'protocol': 'onebot', 'mode': 'reverse'},
        ),
        const AgentField(
          'port',
          '反向监听端口',
          type: 'int',
          when: {'protocol': 'onebot', 'mode': 'reverse'},
        ),
        const AgentField(
          'path',
          '反向 WS 路径',
          hint: '如 /onebot/v11，也可使用 /。',
          when: {'protocol': 'onebot', 'mode': 'reverse'},
        ),
        const AgentField(
          'token',
          'OneBot 访问令牌',
          type: 'secret',
          hint: '与协议端一致。仅本机监听可留空；允许其他设备连接时必须填写。',
          when: {'protocol': 'onebot'},
        ),
        const AgentField('autoConnect', '打开 Agent 时自动连接', type: 'bool'),
        const AgentField('aiEnabled', '自动 AI 回复', type: 'bool'),
        AgentField(
          'presetId',
          '默认 AI 预设',
          type: 'choice',
          choices: {for (final p in agent.presets) p.id: p.name},
        ),
        const AgentField(
          'privateReply',
          '允许私聊自动处理',
          type: 'bool',
          advanced: true,
        ),
        const AgentField(
          'resolveOfficialProfiles',
          '自动同步官机会话资料',
          type: 'bool',
          advanced: true,
          when: {'protocol': 'qqbot'},
          hint: '群名 / 成员资料与原工作台使用相同官方接口；查询异步进行，不阻止 AI 回复。接口需 QQ 平台授权。',
        ),
        const AgentField(
          'useOiapiNickname',
          '补全官机单聊昵称',
          type: 'bool',
          advanced: true,
          when: {'protocol': 'qqbot'},
          hint: '事件未返回昵称时使用 OIAPI，仅提交 AppID 和 OpenID。',
        ),
        const AgentField(
          'groupTrigger',
          '群聊触发方式',
          advanced: true,
          type: 'choice',
          choices: {
            'mention': '唤醒后连续聊天 · 空闲 5 分钟结束',
            'command': '插件命令＋唤醒后连续聊天',
            'all': '全部群消息',
            'off': '关闭群聊自动处理',
          },
        ),
        const AgentField(
          'commandPrefix',
          'AI 命令前缀',
          hint: '默认 /ai，后面加空格和问题。@ 当前机器人、/ai 或额外前缀均可唤醒群聊，之后可直接聊天。',
          advanced: true,
        ),
        const AgentField(
          'extraWakePrefixes',
          '额外唤醒前缀',
          type: 'list',
          lines: 3,
          hint:
              '一行一个，例如“小助手”或“hey bot”，最多 20 个。唤醒当前群后可连续聊天，5 分钟无人发言自动休眠。关闭群聊和白名单仍有效；QQBot 需开通接收全量群消息。',
          advanced: true,
        ),
        const AgentField(
          'cooldownSeconds',
          '每个会话触发冷却（秒）',
          type: 'int',
          advanced: true,
        ),
        const AgentField(
          'batchWindowMs',
          '连发等待窗口（毫秒）',
          type: 'int',
          advanced: true,
          hint: '仅在选中并启用连发策略插件时生效，50–5000，默认 2000；封顶由插件设置控制。',
        ),
        const AgentField(
          'groupAllowlist',
          '允许的群号 / 群 OpenID',
          advanced: true,
          type: 'ids',
          hint: '逗号或空格分隔；留空表示不限群。',
        ),
        const AgentField(
          'userAllowlist',
          '允许的 QQ 号 / 用户 OpenID',
          advanced: true,
          type: 'ids',
          hint: '留空表示不限用户，群内也会检查此名单。',
        ),
        AgentField(
          'pluginIds',
          '此连接使用的 AI 插件',
          advanced: true,
          type: 'multi',
          choices: {
            for (final e in agent.extensions.where((e) => e.kind == 'plugin'))
              e.id: e.name,
          },
        ),
      ],
      save: (j) => agent.saveConnection(AgentConnection.fromJson(j)),
    );
  }

  Widget _providers() => _page(
    'AI 模型',
    '配置兼容 Chat Completions 的服务，也可连接本地模型。AI 持续等待直到返回，可在聊天中手动停止。',
    [
      if (agent.providers.isEmpty) _empty('还没有模型配置。填写接口根地址、API Key 和模型 ID。'),
      for (final p in agent.providers)
        _tile(
          title: p.name,
          subtitle: '${p.model}\n${p.baseUrl}',
          icon: Icons.auto_awesome,
          actions: [
            FilledButton.tonal(
              onPressed: () => _editProvider(p),
              child: const Text('编辑'),
            ),
            TextButton(
              onPressed: _busy.contains('model-test:${p.id}')
                  ? agent.stopModelTests
                  : () => _run(() async {
                      final r = await agent.testModel(p);
                      if (mounted) {
                        await AppDialogs.show(context, r, title: '模型测试');
                      }
                    }, key: 'model-test:${p.id}'),
              child: Text(_busy.contains('model-test:${p.id}') ? '停止测试' : '测试'),
            ),
            TextButton(
              onPressed: () => _run(() async {
                final r = await agent.listModels(p);
                if (mounted) {
                  await AppDialogs.show(
                    context,
                    r.isEmpty ? '服务未提供模型列表，可手动填写模型 ID。' : r.join('\n'),
                    title: '可用模型',
                  );
                }
              }),
              child: const Text('读取模型列表'),
            ),
            TextButton(
              onPressed: () => _run(() async {
                if (await _confirm('删除模型配置？', '对应 API Key 将从 Agent 配置中移除。')) {
                  await agent.deleteProvider(p.id);
                }
              }),
              child: const Text('删除'),
            ),
          ],
        ),
      Text(
        '累计请求 ${agent.usage['calls']} 次 · 输入 ${agent.usage['input']} / 输出 ${agent.usage['output']} tokens',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
    action: FilledButton.icon(
      onPressed: () => _editProvider(null),
      icon: const Icon(Icons.add),
      label: const Text('添加模型'),
    ),
  );
  Future<void> _editProvider(AgentProvider? p) => editAgent(
    context,
    title: 'AI 模型配置',
    initial:
        p?.toJson() ??
        AgentProvider(
          id: const Uuid().v4(),
          name: '我的模型',
          baseUrl: 'http://127.0.0.1:11434/v1',
          model: '',
        ).toJson(),
    fields: [
      const AgentField('name', '配置名称'),
      const AgentField(
        'baseUrl',
        '接口根地址',
        hint: '包含 /v1（如果服务要求），不要填写 /chat/completions。',
      ),
      const AgentField(
        'apiKey',
        'API Key',
        type: 'secret',
        hint: '本地无需鉴权的模型可留空。',
      ),
      AgentField(
        'model',
        '模型 ID',
        hint: '可直接获取列表选择，也可手动填写。',
        loadOptions: (j) => agent.listModels(AgentProvider.fromJson(j)),
      ),
      const AgentField('tools', '模型支持工具调用', type: 'bool', advanced: true),
      const AgentField(
        'vision',
        '支持图片输入（视觉模型）',
        type: 'bool',
        advanced: true,
        hint: '仅在模型确实支持图片时开启，可直接看图或供预设选择为图片转述模型。',
      ),
      const AgentField(
        'video',
        '支持原生视频输入（video_url）',
        type: 'bool',
        advanced: true,
        hint: '仅为接口实际支持视频输入的模型开启，例如兼容video_url的多模态模型；普通文本或图片模型不能直接读取视频文件。',
      ),
      const AgentField(
        'videoAudio',
        '视频模型同时理解音轨',
        type: 'bool',
        advanced: true,
        when: {'video': true},
        hint: '仅在所选原生视频模型确实能听懂音轨时开启；多帧图片识别不会读取声音。',
      ),
      const AgentField(
        'stream',
        '接口要求流式返回',
        type: 'bool',
        advanced: true,
        hint: '部分Omni模型只支持SSE。开启后接收完整流再展示，不影响工具与用量统计。',
      ),
      const AgentField(
        'inputPrice',
        '输入价格（元 / 百万 token）',
        type: 'optionalDouble',
        advanced: true,
        hint: '费用统计使用。留空为未配置，明确填写 0 表示免费。',
      ),
      const AgentField(
        'outputPrice',
        '输出价格（元 / 百万 token）',
        type: 'optionalDouble',
        advanced: true,
      ),
      const AgentField(
        'cachedPrice',
        '缓存命中价格（元 / 百万 token）',
        type: 'optionalDouble',
        advanced: true,
        hint: '留空时沿用输入价格。以你的渠道实际价格为准。',
      ),
    ],
    actionLabel: '测试模型',
    action: (j) => agent.testModel(AgentProvider.fromJson(j)),
    cancelAction: agent.stopModelTests,
    save: (j) => agent.saveProvider(AgentProvider.fromJson(j)),
  ).then((_) {});
  Widget _presets() => _page(
    '预设与人设',
    '为不同群和好友选择不同预设；会话设置可以覆盖连接默认预设。',
    [
      for (final p in agent.presets)
        _tile(
          title: p.name,
          subtitle: clipped(p.prompt, 180),
          icon: Icons.face_retouching_natural,
          details: Text(
            '模型：${agent.providers.where((v) => v.id == p.providerId).firstOrNull?.name ?? '尚未选择'} · ${p.skillIds.length} 个 Skill\n'
            '${p.builtinToolsEnabled ? '内置能力已开启，可在编辑预设中选择停用项。' : '内置能力已关闭。'}'
            '${agent.providers.any((v) => (v.id == p.providerId || v.id == p.imageDescriptionProviderId) && v.vision) ? ' 已配置看图模型。' : ' 评价头像/看图需配置视觉或图片转述模型。'}',
          ),
          actions: [
            FilledButton.tonal(
              onPressed: () => _editPreset(p),
              child: const Text('编辑预设'),
            ),
            TextButton(
              onPressed: () => _editPreset(
                AgentPreset.fromJson({
                  ...p.toJson(),
                  'id': const Uuid().v4(),
                  'name': '${p.name} 副本',
                }),
              ),
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () => _run(() async {
                if (await _confirm('删除预设？', '仅删除这个 Agent 预设。')) {
                  await agent.deletePreset(p.id);
                }
              }),
              child: const Text('删除'),
            ),
          ],
        ),
    ],
    action: FilledButton.icon(
      onPressed: () => _editPreset(null),
      icon: const Icon(Icons.add),
      label: const Text('新建预设'),
    ),
  );
  Future<void> _editPreset(AgentPreset? p) => editAgent(
    context,
    title: '编辑 AI 预设',
    initial:
        p?.toJson() ??
        AgentPreset(id: const Uuid().v4(), name: '新预设', prompt: '').toJson(),
    fields: [
      const AgentField('name', '预设名称'),
      AgentField(
        'providerId',
        '模型配置',
        type: 'choice',
        choices: {
          '': '请选择模型配置',
          for (final p in agent.providers) p.id: '${p.name} · ${p.model}',
        },
      ),
      AgentField(
        'imageDescriptionProviderId',
        '图片转述模型',
        type: 'choice',
        choices: {
          '': '不转述 · 主模型支持视觉时直接看图',
          for (final p in agent.providers.where((p) => p.vision))
            p.id: '${p.name} · ${p.model}',
        },
        hint: '转述模型先看图，再把描述交给主模型。请先在 AI 模型的高级设置开启“支持图片输入”；转述会额外调用模型。',
      ),
      const AgentField('prompt', '系统提示词 / 人设', lines: 6),
      const AgentField(
        'videoUnderstandingEnabled',
        '读取视频内容',
        type: 'bool',
        hint: '当前消息带视频时先分析内容；也可通过read_video查询本会话旧视频。会额外调用所选模型。',
      ),
      AgentField(
        'videoProviderId',
        '视频理解模型',
        type: 'choice',
        choices: {
          '': '自动 · 复用图片转述或主模型',
          for (final p in agent.providers.where((p) => p.video || p.vision))
            p.id: '${p.name} · ${p.video ? '原生视频' : '多帧图片'}',
        },
        when: const {'videoUnderstandingEnabled': true},
        hint: '原生视频模型读取视频文件；客户端也可将2–8张带时间点的画面交给视觉模型。普通DeepSeek文本模型需要另配视觉/视频模型。',
      ),
      const AgentField(
        'videoFrames',
        '视频抽帧数量',
        type: 'int',
        advanced: true,
        when: {'videoUnderstandingEnabled': true},
        hint: '2–8张，默认6。多帧模式限20MB、10分钟，不识别音轨；原生视频模式由模型处理。',
      ),
      const AgentField(
        'builtinToolsEnabled',
        '内置 Agent 能力',
        type: 'bool',
        hint: '提供头像、历史、资料、消息、记忆、表情库和提醒。无需导入额外 Skill，按当前协议和模型能力自动提供。',
      ),
      AgentField(
        'disabledBuiltinTools',
        '停用的内置工具',
        type: 'multi',
        advanced: true,
        choices: agentBuiltinToolLabels,
        when: const {'builtinToolsEnabled': true},
      ),
      const AgentField(
        'crossChatSendEnabled',
        '允许跨会话转告',
        type: 'bool',
        advanced: true,
        hint: '默认关闭。开启后，用户明确要求转告时，可发到当前机器人已有会话。',
      ),
      const AgentField(
        'maxToolCalls',
        '每轮最多调用工具次数',
        type: 'int',
        advanced: true,
        hint: '1–32，默认12。次数越高，复杂任务可执行更多步骤，也可能增加模型调用。',
      ),
      const AgentField(
        'webSearchEnabled',
        '网页搜索',
        type: 'bool',
        hint:
            '向支持工具调用的模型提供 web_search 和 web_fetch。仅搜索时访问网络；公开网页解析可能受网络、验证或改版影响。',
      ),
      const AgentField(
        'webSearchBackend',
        '搜索服务',
        type: 'choice',
        choices: {'bing': 'Bing · 公开网页', 'deepseek': 'DeepSeek · 官方内置搜索'},
        when: {'webSearchEnabled': true},
      ),
      AgentField(
        'webSearchProviderId',
        'DeepSeek搜索凭证',
        type: 'choice',
        choices: {
          '': '复用当前预设模型的官方凭证',
          for (final p in agent.providers.where(
            (p) => Uri.tryParse(p.baseUrl)?.host == 'api.deepseek.com',
          ))
            p.id: p.name,
        },
        when: const {'webSearchEnabled': true, 'webSearchBackend': 'deepseek'},
        hint:
            '先添加https://api.deepseek.com的模型配置及官方API Key。搜索和网页读取按DeepSeek规则计费，不复用其他中转站密钥。',
      ),
      const AgentField(
        'timeAwareness',
        '现实世界时间感知',
        type: 'bool',
        hint: '提供运行设备的日期、时区和消息时间，不是联网校时。',
      ),
      const AgentField(
        'readMessageContext',
        '读取引用与聊天记录',
        type: 'bool',
        hint:
            '读取平台提供的原文、作者、卡片、语音转写及可识别图片；仅在同一会话补本地引用。长记录会占用更多输入 token，超限会明确截断。',
      ),
      const AgentField(
        'showReasoning',
        '显示思考内容',
        type: 'bool',
        hint: '仅在 Agent 聊天中折叠显示模型接口实际返回的内容，不发送到 QQ；接口未提供时不显示，不会要求模型披露隐藏思考。',
      ),
      const AgentField(
        'multiMessageReply',
        '分多条消息回复',
        type: 'bool',
        hint: '用一次模型请求生成多条对话。开启后普通正文的空行分段也会拆开发送，代码、列表和表格保留完整；关闭时只发送一条。默认关闭。',
      ),
      const AgentField(
        'maxReplyMessages',
        '每轮最多发送几条',
        type: 'int',
        advanced: true,
        when: {'multiMessageReply': true},
        hint: '2–5，默认 3。官机被动回复有次数限制，剩余额度不足会合并消息。',
      ),
      const AgentField(
        'replyIntervalMs',
        '分条发送间隔（毫秒）',
        type: 'int',
        advanced: true,
        when: {'multiMessageReply': true},
        hint: '0–3000，默认 700；收到平台回执后才发送下一条，不盲目重发。',
      ),
      const AgentField(
        'imageMaxEdge',
        '输入图片最大边长（像素）',
        type: 'int',
        advanced: true,
        hint: '256–4096，默认 1536。等比缩小，不放大小图；GIF / WebP 读取首帧。对主模型看图和图片转述均生效。',
      ),
      const AgentField(
        'temperature',
        '温度',
        type: 'double',
        hint: '0–2；越低越稳定。',
        advanced: true,
      ),
      const AgentField('maxTokens', '最大输出 tokens', type: 'int', advanced: true),
      const AgentField(
        'historyMessages',
        '历史上下文条数',
        type: 'int',
        advanced: true,
      ),
      AgentField(
        'skillIds',
        '可使用的 Skill',
        type: 'multi',
        choices: {
          for (final e in agent.extensions.where((e) => e.kind == 'skill'))
            e.id: e.name,
        },
      ),
    ],
    save: (j) => agent.savePreset(AgentPreset.fromJson(j)),
  ).then((_) {});

  Widget _extensions(String kind) => _page(
    kind == 'skill' ? 'Skills' : 'AI 插件',
    kind == 'skill'
        ? '给模型增加提示词和可调用工具。启用后，还需在预设中选择使用。'
        : '支持命令处理和 JavaScript 插件能力。启用后，在机器人连接的高级设置中选择。',
    [
      for (final e in agent.extensions.where((e) => e.kind == kind))
        _tile(
          title: e.name,
          subtitle: text(e.manifest['description']),
          icon: kind == 'skill' ? Icons.psychology : Icons.extension,
          details: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                e.isJavaScript
                    ? '原包 JavaScript · 手机 / 桌面共用引擎\n${strings(e.packageManifest['permissions']).contains('web_fetch') || strings(e.compatibility['requirements']).contains('publicFetch')
                          ? strings(e.compatibility['requirements']).contains('nodeHttp')
                                ? '网络访问：公共 HTTP / HTTPS 资源'
                                : '网络访问：公共 HTTPS 资源'
                          : strings(object(e.manifest['compatibility'])['requirements']).contains('websocket')
                          ? '网络访问：公共 WSS 语音服务'
                          : '仅本地运行'}'
                    : e.origins.isEmpty
                    ? '本地执行'
                    : '网络访问：${e.origins.join('、')}',
              ),
              if (e.isJavaScript)
                ExpansionTile(
                  initiallyExpanded: e.compatibility['state'] == 'blocked',
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  title: Text(
                    e.compatibilityLabel,
                    style: const TextStyle(fontSize: 13),
                  ),
                  children: [
                    for (final reason in e.compatibilityDetails)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(reason),
                      ),
                  ],
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(e.enabled ? '已启用' : '已关闭'),
                value: e.enabled,
                onChanged: e.compatibility['state'] == 'blocked'
                    ? null
                    : (v) => _run(
                        () => agent.saveExtension(e.copyWith(enabled: v)),
                      ),
              ),
              if (agent.sourceStatus(e.id).isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    agent.sourceStatus(e.id),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
          actions: [
            if (text(e.manifest['settingsUrl']).isNotEmpty)
              OutlinedButton.icon(
                onPressed: () =>
                    openInAppBrowser(context, text(e.manifest['settingsUrl'])),
                icon: const Icon(Icons.tune_rounded),
                label: const Text('打开设置页'),
              ),
            OutlinedButton(
              onPressed: () => e.isJavaScript
                  ? _configurePackage(e)
                  : _configureDeclarative(e),
              child: const Text('插件设置'),
            ),
            OutlinedButton.icon(
              onPressed: () => isDesktopPlatform
                  ? _run(() async {
                      final directory = await agent.extensionSourceDirectory(
                        e.id,
                      );
                      await DesktopFileLocation.open(directory.path);
                    }, key: 'source:${e.id}')
                  : Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => AgentExtensionFileManager(
                          controller: agent,
                          extensionId: e.id,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.folder_open_outlined),
              label: Text(isDesktopPlatform ? '打开源码文件夹' : '文件管理'),
            ),
            if (isDesktopPlatform)
              TextButton.icon(
                onPressed: () => _run(() async {
                  await agent.reloadExtensionSource(e.id);
                  if (mounted) {
                    await AppDialogs.show(context, '源码已重新加载，后续消息使用修改后的逻辑。');
                  }
                }, key: 'source:${e.id}'),
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载源码'),
              ),
            TextButton(
              onPressed: () => _run(() async {
                await FilePicker.saveFile(
                  dialogTitle: '导出 Agent 扩展',
                  fileName: '${e.id}.${e.isJavaScript ? 'zip' : 'json'}',
                  bytes: e.isJavaScript
                      ? AgentPackageBundle.encode(e.manifest, e.config)
                      : utf8.encode(
                          const JsonEncoder.withIndent(
                            '  ',
                          ).convert(e.manifest),
                        ),
                );
              }),
              child: const Text('导出'),
            ),
            TextButton(
              onPressed: () => _run(() async {
                if (await _confirm('删除扩展？', '将立即停用此 Agent 扩展。')) {
                  await agent.deleteExtension(e.id);
                }
              }),
              child: const Text('删除'),
            ),
          ],
        ),
    ],
    action: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: () => _editExtension(null, kind),
          icon: const Icon(Icons.code),
          label: const Text('新建'),
        ),
        FilledButton.icon(
          onPressed: () => _run(() async {
            final result = await FilePicker.pickFiles(
              type: FileType.custom,
              allowedExtensions: ['zip', 'json', 'yaml', 'yml', 'md'],
              withData: true,
            );
            if (result == null) return;
            final f = result.files.single;
            final isZip = f.name.toLowerCase().endsWith('.zip');
            if (f.size > (isZip ? 16 * 1024 * 1024 : 262144) ||
                f.bytes == null) {
              throw const AgentException(
                'ZIP 不能超过 16 MB，JSON / YAML / MD 不能超过 256 KB。',
              );
            }
            var updated = false;
            if (isZip) {
              updated = await agent.importPackage(f.bytes!);
            } else {
              await agent.importExtension(
                utf8.decode(f.bytes!),
                filename: f.name,
              );
            }
            if (mounted) {
              await AppDialogs.show(
                context,
                updated
                    ? '已更新，保留原设置、启用状态与扩展数据。请在扩展卡片查看新功能和兼容情况。'
                    : '已导入，默认关闭。请在扩展卡片查看兼容情况，完善设置后再启用并选择到连接 / 预设。',
                title: updated ? '更新完成' : '导入完成',
              );
            }
          }),
          icon: const Icon(Icons.file_open_outlined),
          label: const Text('导入'),
        ),
      ],
    ),
  );
  Future<void> _configurePackage(AgentExtension e) async {
    await editAgent(
      context,
      title: '${e.name} · 设置',
      initial: {...e.config, '_enabled': e.enabled},
      description:
          'JavaScript 原包由内嵌引擎运行，不需要安装 Node.js。只能读写该扩展的独立数据，不能读取机器人密钥。主人 QQ 号识别仅适用于 OneBot QQ 号，不会将官方 OpenID 当作 QQ 号。',
      fields: [
        for (final item in e.configSchema.entries)
          AgentField(
            item.key,
            text(object(item.value)['label']).isEmpty
                ? item.key
                : text(object(item.value)['label']),
            hint: text(object(item.value)['description']),
            advanced: object(item.value)['advanced'] == true,
            lines:
                object(item.value)['type'] == 'string' &&
                    (object(item.value)['multiline'] == true ||
                        RegExp(r'Text|Rules').hasMatch(item.key))
                ? 4
                : 1,
            type: switch (object(item.value)['type']) {
              'boolean' => 'bool',
              'number' || 'slider' => 'double',
              'enum' => 'choice',
              _ =>
                object(item.value)['secret'] == true ||
                        RegExp(
                          r'token|password|secret|api.?key',
                          caseSensitive: false,
                        ).hasMatch(item.key)
                    ? 'secret'
                    : 'text',
            },
            choices: {
              for (final v in object(item.value)['values'] as List? ?? [])
                text(v):
                    (object(item.value)['options'] as List? ?? [])
                        .map(object)
                        .where((o) => text(o['value']) == text(v))
                        .map((o) => text(o['label']))
                        .firstOrNull ??
                    text(v),
            },
          ),
        const AgentField('_enabled', '启用扩展', type: 'bool'),
      ],
      save: (j) {
        final settings = {...j}..remove('_enabled');
        return agent.saveExtension(
          e.copyWith(settings: settings, enabled: j['_enabled'] == true),
        );
      },
    );
  }

  Future<void> _configureDeclarative(AgentExtension e) => editAgent(
    context,
    title: '${e.name} · 设置',
    initial: {'secrets': jsonEncode(e.secrets), 'enabled': e.enabled},
    description: isDesktopPlatform
        ? '源码请点击“打开源码文件夹”，使用自己的编辑器修改；保存后会自动重新加载。'
        : '源码请在“文件管理”中编辑；这里单独保存私有参数和启用状态。',
    fields: const [
      AgentField('secrets', '私有参数 JSON', type: 'secret'),
      AgentField('enabled', '启用扩展', type: 'bool'),
    ],
    save: (value) async {
      final raw = text(value['secrets']).trim();
      Json secrets;
      try {
        final parsed = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
        if (parsed is! Map || parsed.values.any((v) => v is! String)) {
          throw const FormatException();
        }
        secrets = object(parsed);
      } catch (_) {
        throw const AgentException(
          '私有参数需要 JSON 字符串对象，例如 {"API_KEY":"值"}，留空可清空。',
        );
      }
      final current = agent.extensions.firstWhere((v) => v.id == e.id);
      await agent.saveExtension(
        current.copyWith(
          secrets: secrets.map((k, v) => MapEntry(k, text(v))),
          enabled: value['enabled'] == true,
        ),
      );
    },
  ).then((_) {});

  Future<void> _editExtension(AgentExtension? e, String kind) => editAgent(
    context,
    title: e == null ? '新建 Agent 扩展' : '编辑 ${e.name}',
    description:
        '保存后立即生效。脚本使用独立 Hetu 沙箱；HTTP 权限由 allowedOrigins 声明。具体格式见右上角开发文档。',
    initial: {
      'source': const JsonEncoder.withIndent('  ').convert(
        e?.manifest ??
            {
              'schema': 1,
              'id': 'my_${kind}_${DateTime.now().millisecondsSinceEpoch}',
              'name': '我的扩展',
              'kind': kind,
              'description': '请填写功能说明',
              if (kind == 'skill') ...{
                'prompt': '请简洁回答。',
                'tools': [],
              } else
                'commands': [
                  {
                    'prefix': '/hello',
                    'handler': {
                      'type': 'template',
                      'text': '你好，{{sender.name}}！',
                    },
                  },
                ],
            },
      ),
      'secrets': jsonEncode(e?.secrets ?? {}),
      'enabled': e?.enabled ?? false,
    },
    fields: const [
      AgentField('source', '扩展 JSON / YAML', type: 'code', lines: 12),
      AgentField(
        'secrets',
        '私有参数 JSON',
        type: 'secret',
        hint: '例如 {"API_KEY":"..."}。仅供 HTTP 请求头中的 {{secret.API_KEY}} 使用，不会导出。',
      ),
      AgentField('enabled', '启用扩展', type: 'bool'),
    ],
    save: (j) async {
      final parsed = AgentExtension.parse(text(j['source']));
      if (e != null && e.id != parsed.id) {
        throw const AgentException('编辑时请保留原 ID；新扩展请使用新建或导入。');
      }
      if (e == null && agent.extensions.any((v) => v.id == parsed.id)) {
        throw const AgentException('扩展 ID 已存在。');
      }
      final secret = jsonDecode(text(j['secrets']));
      if (secret is! Map || secret.values.any((v) => v is! String)) {
        throw const AgentException('私有参数必须为字符串键值对象。');
      }
      await agent.saveExtension(
        AgentExtension(
          parsed.manifest,
          enabled: j['enabled'] == true,
          secrets: object(secret).map((k, v) => MapEntry(k, text(v))),
        ),
      );
    },
  ).then((_) {});

  Widget _builtinDataPage() {
    if (agent.connections.isEmpty) {
      return _page('能力与资料', '按机器人管理内置能力的数据。', [_empty('先添加一个机器人连接。')]);
    }
    final current =
        agent.connections
            .where((c) => c.id == _selectedConnection)
            .firstOrNull ??
        agent.connections.first;
    final data = agent.builtinData(current.id);
    Future<void> remove(String category, Json row) => _run(() async {
      if (await _confirm(
        category == 'reminders' ? '取消这条提醒？' : '删除这条记录？',
        '仅处理当前机器人的这条本地记录。',
      )) {
        await agent.removeBuiltinData(current.id, category, text(row['id']));
      }
    }, key: 'builtin:${row['id']}');
    Widget group(String title, String category) {
      final rows = (data[category] as List? ?? []).map(object).toList();
      return Card(
        child: ExpansionTile(
          title: Text('$title · ${rows.length}'),
          children: [
            if (rows.isEmpty)
              const Padding(padding: EdgeInsets.all(18), child: Text('暂无记录')),
            for (final row in rows.take(100))
              ListTile(
                title: Text(
                  clipped(
                    text(
                      row['content'] ?? row['text'] ?? row['note'] ?? '未备注表情',
                    ),
                    500,
                  ),
                ),
                subtitle: Text(
                  [
                    text(row['chatName']),
                    text(row['target'] ?? row['userId']),
                    text(row['at']),
                    text(row['status']),
                    text(row['error']),
                  ].where((v) => v.isNotEmpty).join(' · '),
                ),
                trailing: Wrap(
                  children: [
                    if (category == 'stickers')
                      IconButton(
                        tooltip: '预览表情',
                        icon: const Icon(Icons.image_outlined),
                        onPressed: () {
                          final bytes = agent.builtinStickerBytes(
                            current.id,
                            text(row['id']),
                          );
                          if (bytes != null) {
                            showDialog<void>(
                              context: context,
                              builder: (context) => Dialog(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Image.memory(
                                    bytes,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    if (category != 'reminders' || row['status'] == 'pending')
                      IconButton(
                        tooltip: category == 'reminders' ? '取消提醒' : '删除记录',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => remove(category, row),
                      ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    return _page('能力与资料', '内置能力在“预设”中管理开关。资料按机器人隔离，提醒在应用运行且机器人在线时执行。', [
      DropdownButtonFormField<String>(
        key: ValueKey('builtin-data:${current.id}'),
        initialValue: current.id,
        decoration: const InputDecoration(labelText: '当前机器人'),
        items: [
          for (final c in agent.connections)
            DropdownMenuItem(
              value: c.id,
              child: Text(
                '${agent.nickname(c.id).isEmpty ? c.name : agent.nickname(c.id)} · ${c.selfId}',
              ),
            ),
        ],
        onChanged: (value) => setState(() {
          _selectedConnection = value;
          _selectedSession = null;
        }),
      ),
      const SizedBox(height: 12),
      FilledButton.tonal(
        onPressed: () => setState(() => _section = 3),
        child: const Text('管理预设与工具开关'),
      ),
      group('长期印象', 'memories'),
      group('提醒任务', 'reminders'),
      group('收藏表情', 'stickers'),
      group('本地反馈', 'feedback'),
    ]);
  }

  Widget _logs() => _page(
    '运行日志',
    '按连接记录收信、触发判定、模型请求、工具与发送回执；失败保留 HTTP / 错误码，不记录密钥或聊天正文。',
    [
      if (agent.logs.isEmpty) _empty('暂无运行日志。'),
      for (final entry in agent.logs.reversed)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SelectableText(
            '${text(entry['time']).replaceFirst('T', ' ').split('.').first} [${entry['connectionName'] ?? 'Agent'}] [${entry['stage'] ?? entry['level']}] ${entry['message']}',
            style: TextStyle(
              fontSize: 13,
              color: entry['level'] == 'error'
                  ? Theme.of(context).colorScheme.error
                  : entry['level'] == 'warning'
                  ? Colors.orange.shade800
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
    ],
    action: TextButton.icon(
      onPressed: () => _run(() async {
        await Clipboard.setData(
          ClipboardData(
            text: agent.logs
                .map(
                  (v) =>
                      '${v['time']} [${v['level']}] [${v['connectionName'] ?? 'Agent'}] [${v['stage'] ?? ''}] ${v['message']}',
                )
                .join('\n'),
          ),
        );
      }),
      icon: const Icon(Icons.copy),
      label: const Text('复制日志'),
    ),
  );

  Widget _chat() => LayoutBuilder(
    builder: (context, constraints) {
      final profiles = agent.connections;
      final selected =
          profiles.where((c) => c.id == _selectedConnection).firstOrNull ??
          profiles.firstOrNull;
      if (selected == null) {
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 56),
              const SizedBox(height: 16),
              const Text('这里是独立的 Agent 聊天空间'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => setState(() => _section = 1),
                child: const Text('添加机器人连接'),
              ),
            ],
          ),
        );
      }
      final sessions = agent.sessions(selected.id);
      final current = sessions
          .where((s) => s.key == _selectedSession)
          .firstOrNull;
      final list = Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: DropdownButtonFormField<String>(
              key: ValueKey(selected.id),
              initialValue: selected.id,
              isExpanded: true,
              items: profiles
                  .map(
                    (c) => DropdownMenuItem(
                      value: c.id,
                      child: Text(
                        '${c.protocolLabel} · ${agent.nickname(c.id).isEmpty ? c.name : agent.nickname(c.id)} · ${c.selfId}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) => setState(() {
                _selectedConnection = id;
                _selectedSession = null;
              }),
              decoration: const InputDecoration(labelText: 'Agent 机器人账号'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    agent.status(selected.id),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  tooltip: '新建 Agent 会话',
                  onPressed: () => _newChat(selected.id),
                  icon: const Icon(Icons.add_comment_outlined),
                ),
              ],
            ),
          ),
          Expanded(
            child: sessions.isEmpty
                ? _empty('连接后同步好友与群，\n或接收第一条消息。')
                : ListView.builder(
                    itemCount: sessions.length,
                    itemBuilder: (context, i) {
                      final s = sessions[i];
                      return ListTile(
                        selected: s.key == current?.key,
                        leading: CircleAvatar(
                          child: Icon(
                            s.kind == 'group'
                                ? Icons.group_outlined
                                : Icons.person_outline,
                          ),
                        ),
                        title: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          s.paused
                              ? '自动回复已暂停'
                              : '${s.kind == 'group' ? '群' : 'QQ'} ${s.peerId}',
                        ),
                        trailing: s.unread > 0
                            ? Badge(
                                label: Text(
                                  s.unread > 99 ? '99+' : '${s.unread}',
                                ),
                              )
                            : null,
                        onTap: () {
                          setState(() => _selectedSession = s.key);
                          _run(() => agent.markRead(s.key));
                        },
                      );
                    },
                  ),
          ),
        ],
      );
      if (constraints.maxWidth < 760) {
        return current == null
            ? list
            : AgentChat(
                key: ValueKey(current.key),
                agent: agent,
                sessionKey: current.key,
                onBack: () => setState(() => _selectedSession = null),
              );
      }
      return Row(
        children: [
          SizedBox(width: 290, child: list),
          const VerticalDivider(width: 1),
          Expanded(
            child: current == null
                ? const Center(child: Text('选择一个 Agent 会话'))
                : AgentChat(
                    key: ValueKey(current.key),
                    agent: agent,
                    sessionKey: current.key,
                  ),
          ),
        ],
      );
    },
  );
  Future<void> _newChat(String id) => editAgent(
    context,
    title: '新建 Agent 会话',
    initial: {'kind': 'group', 'peerId': '', 'name': ''},
    fields: [
      const AgentField(
        'kind',
        '会话类型',
        type: 'choice',
        choices: {'group': '群聊', 'private': '私聊'},
      ),
      AgentField(
        'peerId',
        agent.connection(id)?.isOfficial == true
            ? '群 / 用户 OpenID'
            : '群号 / QQ 号',
      ),
      const AgentField('name', '显示名称（可选）'),
    ],
    save: (j) async {
      final s = await agent.openSession(
        id,
        text(j['kind']),
        text(j['peerId']),
        name: text(j['name']),
      );
      if (mounted) {
        setState(() {
          _selectedConnection = id;
          _selectedSession = s.key;
        });
      }
    },
  ).then((_) {});
}
