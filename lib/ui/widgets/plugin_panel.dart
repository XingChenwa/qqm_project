import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../../core/plugin_manager.dart';
import '../../models/plugin.dart';
import '../../models/plugin_manifest.dart';
import '../../services/plugin_workspace.dart';
import '../themes/app_theme.dart';
import 'plugin_config_dialog.dart';
import 'plugin_developer_dialog.dart';
import 'plugin_import_dialog.dart';
import 'plugin_workshop.dart';
import 'weather_config_dialog.dart';
import 'app_dialogs.dart';

class PluginPanel extends StatefulWidget {
  const PluginPanel({super.key});
  @override
  State<PluginPanel> createState() => _PluginPanelState();
}

class _PluginPanelState extends State<PluginPanel> {
  String _query = '';
  int _filter = 0;

  Future<void> _import([String initialSource = '']) async {
    final installed = await showDialog<bool>(
      context: context,
      builder: (_) => PluginImportDialog(
        manager: context.read<PluginManager>(),
        initialSource: initialSource,
      ),
    );
    if (mounted && installed == true) {
      AppDialogs.show(context, '插件已安装并停用，请检查配置后手动启用。');
    }
  }

  Future<void> _developer() async {
    late final List<String> contents;
    try {
      contents = await Future.wait(
        PluginDeveloperDialog.assetPaths.map(rootBundle.loadString),
      );
    } catch (_) {
      if (mounted) {
        AppDialogs.show(
          context,
          '开发资源读取失败，请查看仓库中的 docs/plugin-development.md。',
          error: true,
        );
      }
      return;
    }
    if (!mounted) return;
    final source = await showDialog<String>(
      context: context,
      builder: (_) => PluginDeveloperDialog(contents: contents),
    );
    if (source != null && mounted) await _import(source);
  }

  Future<void> _workshop({String? id, String? source}) async {
    try {
      final directory = Directory(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'plugin_workspace',
        ),
      );
      final workspace = PluginWorkspace(directory);
      await workspace.ensureRoot();
      if (id != null && source != null) {
        if (!(await workspace.files(id)).contains('plugin.json')) {
          await workspace.write(id, 'plugin.json', source, createOnly: true);
        }
      }
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PluginWorkshop(
          manager: context.read<PluginManager>(),
          root: directory,
          initialId: id,
        ),
      );
    } catch (error) {
      if (mounted) {
        AppDialogs.show(
          context,
          error is PluginManifestException
              ? error.message
              : '无法打开插件文件管理器，请检查目录权限和磁盘空间。',
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final manager = context.watch<PluginManager>();
    final plugins = manager.plugins
        .where(
          (p) =>
              (_filter == 0 ||
                  manager.isBundled(p.info.id) == (_filter == 1)) &&
              '${p.info.name} ${p.info.id} ${p.info.description}'
                  .toLowerCase()
                  .contains(_query.toLowerCase()),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '插件中心',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.5,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${manager.enabledCount} 个运行中 · ${manager.plugins.length} 个已安装',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '开发者文档与示例',
                onPressed: _developer,
                icon: const Icon(Icons.code_rounded),
              ),
              const SizedBox(width: 4),
              OutlinedButton.icon(
                onPressed: _workshop,
                icon: const Icon(Icons.edit_note, size: 18),
                label: const Text('写插件'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('导入'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: TextField(
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(
              hintText: '搜索名称、ID 或功能',
              prefixIcon: Icon(Icons.search, size: 19),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              for (final entry in const {0: '全部插件', 1: '内置', 2: '第三方'}.entries)
                ChoiceChip(
                  label: Text(entry.value),
                  selected: _filter == entry.key,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _filter = entry.key),
                ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1120
                  ? 3
                  : constraints.maxWidth >= 740
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - 40 - (columns - 1) * 16) / columns;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: AppTheme.qqBlue.withValues(alpha: .06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.integration_instructions_outlined,
                            color: AppTheme.qqBlue,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  '为机器人添加你自己的能力',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  '用「写插件」按命令和回复生成清单，也可以管理插件文件夹里的文本。导入 JSON / YAML 仍然可用。',
                                  style: TextStyle(
                                    fontSize: 12,
                                    height: 1.6,
                                    color: Theme.of(context).hintColor,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (plugins.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(28),
                        child: Center(child: Text('没有匹配的插件，试试导入一个示例。')),
                      )
                    else
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          for (final plugin in plugins)
                            SizedBox(
                              width: width,
                              child: _PluginCard(
                                plugin: plugin,
                                manager: manager,
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PluginCard extends StatelessWidget {
  final BotPlugin plugin;
  final PluginManager manager;
  const _PluginCard({required this.plugin, required this.manager});
  PluginInfo get info => plugin.info;

  @override
  Widget build(BuildContext context) {
    final bundled = manager.isBundled(info.id);
    final runtime = info.manifest['runtime'];
    final accent = runtime == 'http'
        ? const Color(0xFF7C5CDA)
        : AppTheme.qqBlue;
    final error = manager.errorFor(info.id);
    return Card(
      key: ValueKey('plugin-card-${info.id}'),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    _iconFor(info.id, runtime),
                    color: accent,
                    size: 23,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'v${info.version} · ${bundled
                            ? '内置 Dart'
                            : runtime == 'http'
                            ? 'HTTP 服务'
                            : '规则插件'}',
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Transform.scale(
                  scale: .82,
                  child: Switch(
                    value: info.isEnabled,
                    onChanged: (value) async {
                      final success = value
                          ? await manager.enablePlugin(info.id)
                          : await manager.disablePlugin(info.id);
                      if (!success && context.mounted) {
                        AppDialogs.show(
                          context,
                          manager.errorFor(info.id) ?? '操作失败',
                          error: true,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              info.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.7,
                color: Theme.of(context).hintColor,
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  color: info.isEnabled ? AppTheme.qqGreen : AppTheme.muted,
                  size: 7,
                ),
                const SizedBox(width: 6),
                Text(
                  info.isEnabled ? '已启用' : '已停用',
                  style: const TextStyle(fontSize: 11),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    info.id,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  error,
                  style: const TextStyle(color: AppTheme.qqRed, fontSize: 12),
                ),
              ),
            const Divider(height: 26),
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: info.id == 'weather_plugin'
                        ? '配置高德天气与 IP 查询'
                        : '插件配置',
                    child: OutlinedButton.icon(
                      onPressed:
                          (info.manifest['config_schema'] as List? ?? [])
                              .isEmpty
                          ? null
                          : () => _configure(context),
                      icon: const Icon(Icons.tune, size: 16),
                      label: Text(
                        (info.manifest['config_schema'] as List? ?? []).isEmpty
                            ? '无需配置'
                            : '配置',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                PopupMenuButton<String>(
                  tooltip: '插件命令、清单与数据',
                  icon: const Icon(Icons.more_horiz, size: 19),
                  onSelected: (action) async {
                    if (action == 'manifest') {
                      _viewManifest(context);
                      return;
                    }
                    if (action == 'commands') {
                      await showDialog<void>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: Text('${info.name} · 命令'),
                          content: SingleChildScrollView(
                            child: SelectableText(
                              manager.plugins
                                  .firstWhere((p) => p.info.id == info.id)
                                  .commands
                                  .map(
                                    (c) =>
                                        '/${c.usage.isEmpty ? c.name : c.usage} — ${c.description}',
                                  )
                                  .join('\n'),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('关闭'),
                            ),
                          ],
                        ),
                      );
                      return;
                    }
                    await _data(context, clear: action == 'clear');
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'commands', child: Text('查看命令')),
                    PopupMenuItem(value: 'manifest', child: Text('查看和复制插件清单')),
                    PopupMenuItem(value: 'data', child: Text('导出本地玩法数据')),
                    PopupMenuItem(value: 'clear', child: Text('清空本地玩法数据')),
                  ],
                ),
                if (!bundled)
                  IconButton(
                    tooltip: '在工作台编辑',
                    onPressed: () {
                      final panel = context
                          .findAncestorStateOfType<_PluginPanelState>();
                      panel?._workshop(
                        id: info.id,
                        source: manager.exportPlugin(info.id),
                      );
                    },
                    icon: const Icon(Icons.edit_outlined, size: 19),
                  ),
                if (!bundled)
                  IconButton(
                    tooltip: '卸载插件',
                    onPressed: () => _uninstall(context),
                    icon: const Icon(Icons.delete_outline, size: 19),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String id, dynamic runtime) => switch (id) {
    'weather_plugin' => Icons.cloud_outlined,
    'dice_plugin' => Icons.casino_outlined,
    'translate_comment' => Icons.translate_rounded,
    'example_plugin' => Icons.waving_hand_outlined,
    'daily_club' => Icons.auto_awesome_outlined,
    'group_games' => Icons.sports_esports_outlined,
    _ => runtime == 'http' ? Icons.hub_outlined : Icons.extension_outlined,
  };

  Future<void> _data(BuildContext context, {required bool clear}) async {
    try {
      if (clear) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('清空此插件的玩法数据？'),
            content: const Text(
              '仅清除当前机器人下此插件的积分、游戏与投票记录，不删除配置或密钥。请先停用插件并导出备份；此操作无法撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('确认清空'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        await manager.clearPluginData(info.id);
        if (context.mounted) AppDialogs.show(context, '已清空此机器人下的插件玩法数据，配置仍保留。');
      } else {
        final source = await manager.exportPluginData(info.id);
        if (!context.mounted) return;
        await showDialog<void>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: const Text('本地玩法数据（包含参与者 OpenID）'),
            content: SizedBox(
              width: 620,
              height: MediaQuery.sizeOf(context).height * .5,
              child: SingleChildScrollView(child: SelectableText(source)),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: source)),
                child: const Text('复制 JSON'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        AppDialogs.show(
          context,
          e is PluginManifestException ? e.message : '插件数据操作失败。',
          error: true,
        );
      }
    }
  }

  Future<void> _configure(BuildContext context) async {
    try {
      final definition = PluginManifest.parse(
        jsonEncode(info.manifest),
        allowBuiltin: true,
      );
      if (definition.fields.isEmpty) {
        AppDialogs.show(context, '这个插件没有可配置项。');
        return;
      }
      final config = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (_) => info.id == 'weather_plugin'
            ? WeatherConfigDialog(config: info.config)
            : PluginConfigDialog(info: info, definition: definition),
      );
      if (config == null) return;
      final saved = await manager.updatePluginConfig(info.id, config);
      if (context.mounted) {
        AppDialogs.show(
          context,
          saved ? '${info.name}配置已保存' : '保存失败',
          error: !saved,
        );
      }
    } catch (_) {
      if (context.mounted) {
        AppDialogs.show(context, '配置无效，请检查必填项和类型。', error: true);
      }
    }
  }

  void _viewManifest(BuildContext context) {
    final source = manager.exportPlugin(info.id);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        insetPadding: const EdgeInsets.all(16),
        title: const Text('插件清单（不包含本机密钥）'),
        content: SizedBox(
          width: 640,
          height: MediaQuery.sizeOf(context).height * .55,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (manager.isBundled(info.id))
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('内置 Dart 清单只供查看；修改源码后需重新编译应用。'),
                  ),
                SelectableText(
                  source,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: source));
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('复制清单'),
          ),
        ],
      ),
    );
  }

  Future<void> _uninstall(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载第三方插件'),
        content: Text('将移除“${info.name}”及其本机配置。原始 JSON/YAML 文件不会删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );
    if (confirmed == true) await manager.uninstallPlugin(info.id);
  }
}
