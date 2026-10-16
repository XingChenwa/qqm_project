import 'package:flutter/material.dart';
import 'app_dialogs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

class PluginDeveloperDialog extends StatefulWidget {
  final List<String> contents;
  static const assetPaths = [
    'docs/plugin-development.md',
    'plugins/examples/hello_json/plugin.json',
    'plugins/examples/hello_yaml/plugin.yaml',
    'plugins/examples/http_echo/plugin.json',
    'plugins/examples/buttons/plugin.json',
    'plugins/examples/media/plugin.json',
  ];
  const PluginDeveloperDialog({super.key, required this.contents});
  @override
  State<PluginDeveloperDialog> createState() => _PluginDeveloperDialogState();
}

class _PluginDeveloperDialogState extends State<PluginDeveloperDialog> {
  int _tab = 0;
  String get _content => widget.contents[_tab];
  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: PluginDeveloperDialog.assetPaths.length,
    child: AlertDialog(
      insetPadding: const EdgeInsets.all(12),
      title: Row(
        children: [
          const Expanded(child: Text('开发者中心')),
          IconButton(
            tooltip: '关闭开发者中心',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      content: SizedBox(
        width: 740,
        height: MediaQuery.sizeOf(context).height * .62,
        child: Column(
          children: [
            TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              onTap: (index) => setState(() {
                _tab = index;
              }),
              tabs: const [
                Tab(text: '开发文档'),
                Tab(text: 'JSON 示例'),
                Tab(text: 'YAML 示例'),
                Tab(text: 'HTTP 示例'),
                Tab(text: '按钮示例'),
                Tab(text: '媒体示例'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: _tab == 0
                    ? MarkdownBody(data: _content, selectable: true)
                    : SelectableText(
                        _content,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          height: 1.7,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            final content = _content;
            await Clipboard.setData(ClipboardData(text: content));
            if (context.mounted) {
              AppDialogs.show(context, '已复制');
            }
          },
          icon: const Icon(Icons.copy_outlined),
          label: Text(_tab == 0 ? '复制文档' : '复制示例'),
        ),
        if (_tab != 0)
          FilledButton(
            onPressed: () async {
              final content = _content;
              if (context.mounted) Navigator.pop(context, content);
            },
            child: const Text('使用这个示例'),
          ),
      ],
    ),
  );
}
