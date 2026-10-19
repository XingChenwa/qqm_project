import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../screens/browser_screen.dart';
import 'composer_keyboard.dart';
import 'qq_mention_preview.dart';

/// An independent Markdown draft, with a live preview that never sends messages.
class MarkdownWorkbench extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final bool sending;
  final bool templateMode;
  final Map<String, String> mentionNames;
  const MarkdownWorkbench({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.sending,
    this.templateMode = false,
    this.mentionNames = const {},
  });

  @override
  State<MarkdownWorkbench> createState() => _MarkdownWorkbenchState();
}

class _MarkdownWorkbenchState extends State<MarkdownWorkbench> {
  bool _preview = false;

  void _insert(String before, [String after = '']) {
    final value = widget.controller.value;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : value.text.length;
    final end = selection.isValid ? selection.end : start;
    final selected = value.text.substring(start, end);
    widget.controller.value = TextEditingValue(
      text: value.text.replaceRange(start, end, '$before$selected$after'),
      selection: TextSelection.collapsed(
        offset: start + before.length + selected.length,
      ),
    );
    setState(() => _preview = false);
    widget.focusNode.requestFocus();
  }

  Widget _editor() => ComposerKeyboard(
    controller: widget.controller,
    focusNode: widget.focusNode,
    onSend: widget.onSend,
    child: TextField(
      key: const ValueKey('markdown-editor'),
      controller: widget.controller,
      focusNode: widget.focusNode,
      expands: true,
      minLines: null,
      maxLines: null,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.send,
      onEditingComplete: () {},
      onSubmitted: (_) => widget.onSend(),
      style: const TextStyle(
        fontFamily: 'Consolas',
        fontFamilyFallback: [
          'Microsoft YaHei',
          'PingFang SC',
          'Noto Sans CJK SC',
          'sans-serif',
        ],
        fontSize: 13,
        height: 1.5,
      ),
      decoration: const InputDecoration(
        hintText: '# 标题\n\n输入 Markdown，支持代码块、列表和链接…',
        border: InputBorder.none,
        filled: false,
        contentPadding: EdgeInsets.all(12),
      ),
    ),
  );

  Widget _rendered() => ValueListenableBuilder<TextEditingValue>(
    valueListenable: widget.controller,
    builder: (context, value, _) => value.text.trim().isEmpty
        ? const Center(child: Text('预览会随编辑内容实时更新'))
        : KeyedSubtree(
            key: ValueKey(
              Object.hashAll(
                widget.mentionNames.entries.map(
                  (entry) => Object.hash(entry.key, entry.value),
                ),
              ),
            ),
            child: Markdown(
              key: const ValueKey('markdown-live-preview'),
              data: value.text,
              inlineSyntaxes: [QqMentionPreviewSyntax(widget.mentionNames)],
              blockSyntaxes: [QqMentionPreviewBlockSyntax()],
              builders: {'qqmention': QqMentionPreviewBuilder()},
              selectable: true,
              styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context))
                  .copyWith(
                    code: const TextStyle(
                      fontFamily: 'Consolas',
                      fontFamilyFallback: [
                        'Microsoft YaHei',
                        'PingFang SC',
                        'Noto Sans CJK SC',
                        'sans-serif',
                      ],
                      fontSize: 13,
                    ),
                  ),
              padding: const EdgeInsets.all(12),
              onTapLink: (_, href, _) {
                if (href != null) openInAppBrowser(context, href);
              },
            ),
          ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 620;
      final available =
          MediaQuery.sizeOf(context).height -
          MediaQuery.viewInsetsOf(context).bottom;
      final height = math.min(250.0, math.max(100.0, available * .30));
      return Container(
        key: const ValueKey('markdown-workbench'),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: .04),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Markdown 工作区',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    if (!wide)
                      SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: false, label: Text('编辑')),
                          ButtonSegment(value: true, label: Text('预览')),
                        ],
                        selected: {_preview},
                        showSelectedIcon: false,
                        onSelectionChanged: (value) =>
                            setState(() => _preview = value.first),
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                    else
                      const Text('编辑  /  实时预览', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
            SizedBox(
              height: height,
              child: wide
                  ? Row(
                      children: [
                        Expanded(child: _editor()),
                        const VerticalDivider(width: 1),
                        Expanded(child: _rendered()),
                      ],
                    )
                  // Keep the editor mounted so its focus, selection and undo history survive tab changes.
                  : IndexedStack(
                      index: _preview ? 1 : 0,
                      children: [_editor(), _rendered()],
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '插入标题',
                            onPressed: () => _insert('## '),
                            icon: const Icon(Icons.title, size: 18),
                          ),
                          IconButton(
                            tooltip: '插入粗体',
                            onPressed: () => _insert('**', '**'),
                            icon: const Icon(Icons.format_bold, size: 18),
                          ),
                          IconButton(
                            tooltip: '插入代码块',
                            onPressed: () => _insert('```dart\n', '\n```'),
                            icon: const Icon(Icons.code, size: 18),
                          ),
                          IconButton(
                            tooltip: '插入链接',
                            onPressed: () =>
                                _insert('[', '](https://example.com)'),
                            icon: const Icon(Icons.link, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Tooltip(
                    message: '发送',
                    child: FilledButton.icon(
                      onPressed: widget.sending ? null : widget.onSend,
                      icon: widget.sending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send, size: 16),
                      label: Text(widget.templateMode ? '发送模板' : '发送 Markdown'),
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                '本地预览仅供参考，实际显示和可用语法以 QQ 客户端为准。',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      );
    },
  );
}
