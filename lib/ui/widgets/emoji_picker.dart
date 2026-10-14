import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../../models/message.dart';
import '../../services/api_service.dart';
import '../../services/storage_service.dart';
import '../../utils/constants.dart';
import '../../utils/helpers.dart';
import '../themes/app_theme.dart';

class EmojiPicker extends StatefulWidget {
  final ValueChanged<EmojiItem>? onEmojiSelected;

  const EmojiPicker({super.key, this.onEmojiSelected});

  @override
  State<EmojiPicker> createState() => _EmojiPickerState();
}

class _EmojiPickerState extends State<EmojiPicker> {
  static const String _allCategory = '全部';

  final ApiService _apiService = ApiService();
  final ScrollController _categoryScrollController = ScrollController();

  List<EmojiItem> _remoteEmojis = [];
  String _selectedCategory = _allCategory;
  bool _isLoading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchAllEmojis();
  }

  @override
  void dispose() {
    _categoryScrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchAllEmojis() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final results = <EmojiItem>[];
    final names = [
      'mingfengouo',
      'nachoneko3',
      'majosaiban',
      'czemojibot',
      'hu_goal_capoo',
      'catearniang',
      'zimaomao',
    ];

    try {
      for (var i = 0; i < AppConstants.emojiApis.length; i++) {
        final result = await _apiService.fetchEmojiUrls(i, limit: 48);
        if (!mounted) return;

        if (result.isSuccess && result.data != null) {
          final category = names.length > i ? names[i] : 'api_$i';
          var count = 0;
          for (final url in result.data!) {
            if (results.any((emoji) => emoji.url == url)) continue;
            count++;
            results.add(
              EmojiItem(
                id: 'api_${i}_$count',
                name: '$category $count',
                url: url,
                category: category,
                isCustom: false,
              ),
            );
          }
          if (count > 0) {
            setState(() => _remoteEmojis = List.of(results));
          }
        }
      }

      if (results.isEmpty) {
        for (var i = 0; i < AppConstants.emojiApis.length; i++) {
          final category = names.length > i ? names[i] : 'api_$i';
          results.add(
            EmojiItem(
              id: 'fallback_$i',
              name: category,
              url: AppConstants.emojiApis[i],
              category: category,
              isCustom: false,
            ),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _remoteEmojis = results;
        _isLoading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = '表情加载失败：$error';
      });
    }
  }

  Future<void> _addCustomEmoji() async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '添加自定义表情',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final picker = ImagePicker();
                  final file = await picker.pickImage(
                    source: ImageSource.gallery,
                  );
                  if (file == null || !mounted) return;
                  await _saveCustomEmoji(
                    EmojiItem(
                      id: generateId(),
                      name: '自定义 ${DateTime.now().millisecond}',
                      url: file.path,
                      category: '自定义',
                      isCustom: true,
                      localPath: file.path,
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.link_rounded),
                title: const Text('输入图片 URL'),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  final result = await _askEmojiUrl();
                  if (result == null || !mounted) return;
                  final url = result['url']?.trim() ?? '';
                  if (url.isEmpty) return;
                  await _saveCustomEmoji(
                    EmojiItem(
                      id: generateId(),
                      name: (result['name']?.trim().isNotEmpty ?? false)
                          ? result['name']!.trim()
                          : '未命名',
                      url: url,
                      category: '自定义',
                      isCustom: true,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<Map<String, String>?> _askEmojiUrl() {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    return showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('添加表情'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(
                  labelText: '表情名称',
                  hintText: '给表情起个名字',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: '图片 URL',
                  hintText: 'https://...',
                ),
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
            onPressed: () => Navigator.pop(dialogContext, {
              'name': nameController.text,
              'url': urlController.text,
            }),
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCustomEmoji(EmojiItem emoji) async {
    await context.read<StorageService>().saveEmoji(emoji);
    if (!mounted) return;
    setState(() => _selectedCategory = '自定义');
  }

  @override
  Widget build(BuildContext context) {
    final customEmojis = context.watch<StorageService>().getEmojis();
    final allEmojis = [..._remoteEmojis, ...customEmojis];
    final categories = <String>{
      _allCategory,
      ..._remoteEmojis.map((emoji) => emoji.category),
      ...customEmojis.map((emoji) => emoji.category),
    }.toList();
    final filtered = _selectedCategory == _allCategory
        ? allEmojis
        : allEmojis
              .where((emoji) => emoji.category == _selectedCategory)
              .toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
          child: Row(
            children: [
              Expanded(child: _categoryScroller(categories)),
              IconButton(
                tooltip: '添加自定义表情',
                icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
                onPressed: _addCustomEmoji,
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: _fetchAllEmojis,
              ),
            ],
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(child: _body(allEmojis, filtered)),
      ],
    );
  }

  Widget _body(List<EmojiItem> allEmojis, List<EmojiItem> filtered) {
    if (_isLoading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(strokeWidth: 2),
            SizedBox(height: 12),
            Text('正在加载表情包...'),
          ],
        ),
      );
    }

    if (_error != null && allEmojis.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 42,
                color: Theme.of(context).hintColor.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _fetchAllEmojis,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    if (filtered.isEmpty) {
      return Center(
        child: Text(
          '该分类暂无表情',
          style: TextStyle(color: Theme.of(context).hintColor),
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.88,
      ),
      itemCount: filtered.length,
      itemBuilder: (context, index) => _emojiTile(filtered[index]),
    );
  }

  Widget _categoryScroller(List<String> categories) {
    return SizedBox(
      height: 38,
      child: Listener(
        onPointerSignal: (event) {
          if (event is! PointerScrollEvent ||
              !_categoryScrollController.hasClients) {
            return;
          }
          final position = _categoryScrollController.position;
          final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
              ? event.scrollDelta.dx
              : event.scrollDelta.dy;
          final next = (_categoryScrollController.offset + delta).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          _categoryScrollController.jumpTo(next);
        },
        child: ScrollConfiguration(
          behavior: const _EmojiCategoryScrollBehavior(),
          child: ListView.separated(
            controller: _categoryScrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, index) {
              final category = categories[index];
              final selected = _selectedCategory == category;
              return Center(
                child: ChoiceChip(
                  label: Text(category),
                  selected: selected,
                  onSelected: (_) =>
                      setState(() => _selectedCategory = category),
                  visualDensity: VisualDensity.compact,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _emojiTile(EmojiItem emoji) {
    return InkWell(
      onTap: () => widget.onEmojiSelected?.call(emoji),
      onLongPress: () => _showEmojiOptions(emoji),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: AppTheme.qqBlue.withValues(alpha: 0.04),
                child: _emojiPreview(emoji),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
              child: Text(
                emoji.name,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emojiPreview(EmojiItem emoji) {
    if (isValidUrl(emoji.url)) {
      return CachedNetworkImage(
        imageUrl: emoji.url,
        fit: BoxFit.cover,
        placeholder: (_, _) =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        errorWidget: (_, _, _) => _fallbackEmojiPreview(),
      );
    }

    if (emoji.localPath != null) {
      return Image.file(
        File(emoji.localPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallbackEmojiPreview(),
      );
    }

    return _fallbackEmojiPreview();
  }

  Widget _fallbackEmojiPreview() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: const [
        Icon(Icons.emoji_emotions_outlined, color: AppTheme.qqBlue),
        SizedBox(height: 4),
        Text(
          '预览',
          style: TextStyle(
            fontSize: 11,
            color: AppTheme.qqBlue,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  void _showEmojiOptions(EmojiItem emoji) {
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.send_rounded),
              title: const Text('发送此表情'),
              onTap: () {
                Navigator.pop(sheetContext);
                widget.onEmojiSelected?.call(emoji);
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_copy_rounded),
              title: const Text('复制 URL'),
              onTap: () {
                Navigator.pop(sheetContext);
                Clipboard.setData(ClipboardData(text: emoji.url));
              },
            ),
            if (emoji.isCustom)
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: AppTheme.qqRed,
                ),
                title: const Text(
                  '删除',
                  style: TextStyle(color: AppTheme.qqRed),
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await context.read<StorageService>().deleteEmoji(emoji.id);
                  if (!mounted) return;
                  setState(() {});
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _EmojiCategoryScrollBehavior extends MaterialScrollBehavior {
  const _EmojiCategoryScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
    ...super.dragDevices,
    PointerDeviceKind.mouse,
  };
}
