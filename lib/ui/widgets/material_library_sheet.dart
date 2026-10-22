import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/bot_client.dart';
import '../../core/media_library.dart';
import '../../models/media_image.dart';
import 'app_dialogs.dart';

Future<BotMediaImage?> showMaterialLibrary(
  BuildContext context,
  BotClient bot,
) {
  final appId = bot.config.appId;
  final epoch = bot.accountEpoch;
  return showModalBottomSheet<BotMediaImage>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 1040),
    builder: (_) =>
        MaterialLibrarySheet(bot: bot, target: MaterialTarget(appId, epoch)),
  ).then(
    (image) =>
        bot.config.appId == appId && bot.accountEpoch == epoch ? image : null,
  );
}

class MaterialLibrarySheet extends StatefulWidget {
  final BotClient bot;
  final MaterialTarget target;
  final Future<File?> Function()? pickImage;
  const MaterialLibrarySheet({
    super.key,
    required this.bot,
    required this.target,
    this.pickImage,
  });
  @override
  State<MaterialLibrarySheet> createState() => _MaterialLibrarySheetState();
}

class _MaterialLibrarySheetState extends State<MaterialLibrarySheet> {
  final _search = TextEditingController();
  MediaLibrary get library => widget.bot.materials;
  bool get current => library.isCurrent(widget.target);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && current) unawaited(library.refresh());
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _upload() async {
    if (!current || library.busy) return;
    try {
      final File? file;
      if (widget.pickImage != null) {
        file = await widget.pickImage!();
      } else {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['png', 'jpg', 'jpeg', 'gif', 'webp'],
          allowMultiple: false,
          withData: false,
        );
        final path = result?.files.single.path;
        file = path == null ? null : File(path);
      }
      if (!mounted || !current || file == null) return;
      final image = await library.upload(file);
      if (!mounted || !current) return;
      if (image == null) {
        await AppDialogs.show(
          context,
          library.error.isEmpty ? '素材上传未完成，请重试' : library.error,
          title: '上传失败',
          error: true,
        );
      } else {
        // Reconcile server-side idempotence/quota and obtain fresh preview URLs.
        await library.refresh();
      }
    } catch (_) {
      if (mounted && current) {
        await AppDialogs.show(context, '无法读取所选图片，请检查文件权限后重试', error: true);
      }
    }
  }

  Future<void> _copy(BotMediaImage image, {bool markdown = false}) async {
    if (!current) return;
    await Clipboard.setData(
      ClipboardData(text: markdown ? image.markdown : image.reference),
    );
    if (mounted && current) {
      await AppDialogs.show(
        context,
        markdown ? '已复制 Markdown 图片代码' : '已复制素材引用',
      );
    }
  }

  Future<void> _delete(BotMediaImage image) async {
    if (!current || library.busy) return;
    final confirmed = await AppDialogs.present<bool>(
      context,
      builder: (dialog) => AlertDialog(
        title: const Text('删除图片素材？'),
        content: Text(
          '删除“${image.displayName}”会立即使素材引用失效，草稿中的引用也将无法再发送。QQ 中已发送的消息不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !current) return;
    final ok = await library.delete(image);
    if (!ok && mounted && current) {
      await AppDialogs.show(
        context,
        library.error.isEmpty ? '素材删除未完成，请刷新后重试' : library.error,
        title: '删除失败',
        error: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.bot,
    builder: (context, _) {
      final items = library.images;
      final filter = _search.text.trim().toLowerCase();
      final visible = items
          .where((image) => image.displayName.toLowerCase().contains(filter))
          .toList();
      final theme = Theme.of(context);
      return SizedBox(
        key: const ValueKey('material-library'),
        height: math.min(800, MediaQuery.sizeOf(context).height * .88),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 6, 0),
              child: Row(
                children: [
                  const Icon(Icons.photo_library_outlined, size: 23),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '图片素材 · ${library.total}/100',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '刷新素材库',
                    onPressed: !current || library.busy
                        ? null
                        : () => library.refresh(),
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                  IconButton(
                    tooltip: '关闭素材库',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            if (!current) ...[
              const Expanded(child: Center(child: Text('机器人已切换，请关闭后重新打开素材库。'))),
            ] else ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '当前 AppID：${widget.target.appId}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      key: const ValueKey('upload-material'),
                      onPressed: library.busy ? null : _upload,
                      icon: const Icon(
                        Icons.add_photo_alternate_outlined,
                        size: 18,
                      ),
                      label: const Text('上传图片'),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: TextField(
                  controller: _search,
                  onChanged: (value) {
                    setState(() {});
                    if (value.trim().isNotEmpty) unawaited(library.loadAll());
                  },
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '搜索素材文件名',
                    prefixIcon: Icon(Icons.search_rounded),
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline_rounded,
                      size: 15,
                      color: theme.hintColor,
                    ),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        '支持 PNG/JPEG/GIF/WebP，单张 ≤10 MB；90 天未使用会失效。',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
              if (library.uploading)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Column(
                    children: [
                      LinearProgressIndicator(value: library.progress),
                      const SizedBox(height: 6),
                      Text(
                        '${library.stage} ${(library.progress * 100).round()}%',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              if (library.error.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
                  child: Text(
                    library.error,
                    style: TextStyle(
                      color: theme.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(
                child: library.loading && items.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : visible.isEmpty
                    ? Center(
                        child: Text(
                          library.error.isNotEmpty
                              ? '点击右上角刷新重试'
                              : items.isEmpty
                              ? '还没有图片素材，上传后即可在聊天中引用'
                              : '没有匹配的素材',
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) => GridView.builder(
                          padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: (constraints.maxWidth / 185)
                                    .floor()
                                    .clamp(2, 5),
                                mainAxisExtent: 220,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                          itemCount: visible.length,
                          itemBuilder: (context, index) =>
                              _tile(visible[index]),
                        ),
                      ),
              ),
              if (library.cursor.isNotEmpty)
                TextButton(
                  onPressed: library.busy
                      ? null
                      : () => library.refresh(more: true),
                  child: Text(library.loading ? '正在加载…' : '加载更多素材'),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 4, 18, 12),
                child: Text(
                  '插入后可在 Markdown 中编辑、预览；不会立即发送。',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );

  Widget _tile(BotMediaImage image) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: InkWell(
              onTap: image.previewUrl.isEmpty
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (dialog) => Dialog.fullscreen(
                        child: Scaffold(
                          appBar: AppBar(
                            title: Text(image.displayName),
                            leading: IconButton(
                              tooltip: '关闭素材预览',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => Navigator.pop(dialog),
                            ),
                          ),
                          body: SizedBox.expand(
                            child: InteractiveViewer(
                              minScale: 1,
                              maxScale: 6,
                              child: MaterialPreview(
                                image: image,
                                highResolution: true,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
              child: MaterialPreview(
                image: image,
                onRefresh: () => library.refresh(),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    image.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: '素材操作',
                  onSelected: (value) {
                    if (value == 'delete') {
                      _delete(image);
                    } else {
                      _copy(image, markdown: value == 'markdown');
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'reference', child: Text('复制素材引用')),
                    PopupMenuItem(
                      value: 'markdown',
                      child: Text('复制 Markdown'),
                    ),
                    PopupMenuItem(value: 'delete', child: Text('删除素材')),
                  ],
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 3),
            child: Text(
              image.expiresAt == null
                  ? '平台图片素材'
                  : '有效至 ${image.expiresAt!.toLocal().toString().substring(0, 10)}',
              style: TextStyle(
                fontSize: 10,
                color: image.expired
                    ? theme.colorScheme.error
                    : theme.hintColor,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: FilledButton.tonal(
              onPressed: image.expired || library.busy
                  ? null
                  : () => Navigator.pop(context, image),
              child: const Text('插入 Markdown'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Do not use CachedNetworkImage here: the platform explicitly forbids
/// persisting short-lived preview URLs. Flutter's in-memory cache is enough.
class MaterialPreview extends StatelessWidget {
  final BotMediaImage image;
  final VoidCallback? onRefresh;
  final bool highResolution;
  const MaterialPreview({
    super.key,
    required this.image,
    this.onRefresh,
    this.highResolution = false,
  });
  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: image.previewUrl.isEmpty
        ? const Center(child: Icon(Icons.image_outlined, size: 34))
        : Image.network(
            image.previewUrl,
            fit: BoxFit.contain,
            cacheWidth: highResolution ? 2048 : 640,
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
            errorBuilder: (_, _, _) => Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '预览已失效，刷新重试',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11),
                    ),
                    if (onRefresh != null)
                      TextButton(
                        onPressed: onRefresh,
                        child: const Text('刷新预览'),
                      ),
                  ],
                ),
              ),
            ),
          ),
  );
}
