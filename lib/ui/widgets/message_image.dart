import 'dart:io';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

/// Local files are allowed only for messages sent from this manager.
class MessageImage extends StatelessWidget {
  final String source;
  final bool allowLocalFile;
  final double maxWidth, maxHeight;

  const MessageImage({
    super.key,
    required this.source,
    this.allowLocalFile = false,
    this.maxWidth = 320,
    this.maxHeight = 220,
  });

  static File? localFile(String source) {
    final uri = Uri.tryParse(source);
    if (uri?.scheme == 'file') {
      if (uri!.host.isNotEmpty && uri.host != 'localhost') return null;
      try {
        return File.fromUri(uri);
      } catch (_) {
        return null;
      }
    }
    if (!path.isAbsolute(source) || source.startsWith(r'\\')) return null;
    return File(source);
  }

  bool get _network {
    final uri = Uri.tryParse(source);
    return uri != null &&
        ['https', 'http'].contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty;
  }

  Widget _error(String text) => Center(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12),
      ),
    ),
  );

  Widget _image({
    required double width,
    required double height,
    bool preview = false,
  }) {
    if (_network) {
      return CachedNetworkImage(
        imageUrl: source,
        width: width,
        height: height,
        fit: BoxFit.contain,
        memCacheWidth: preview ? null : 960,
        placeholder: (_, _) =>
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        errorWidget: (_, _, _) => _error('图片暂时无法加载，请稍后重试'),
      );
    }
    final file = allowLocalFile ? localFile(source) : null;
    if (file == null) return _error('没有可用的图片预览地址');
    return Image.file(
      file,
      width: width,
      height: height,
      fit: BoxFit.contain,
      cacheWidth: preview ? null : 960,
      errorBuilder: (_, _, _) => _error('本地图片无法读取，可能已移动或删除'),
    );
  }

  Future<void> _preview(BuildContext context) => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '关闭图片预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
                const Text('图片预览'),
                const Spacer(),
                const Flexible(
                  child: Text(
                    '滚轮或双指缩放 · 拖动查看',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 16),
              ],
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (_, constraints) => InteractiveViewer(
                  minScale: 1,
                  maxScale: 8,
                  child: _image(
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    preview: true,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = math.min(maxWidth, constraints.maxWidth);
      return Semantics(
        label: '查看图片原图',
        button: true,
        child: InkWell(
          onTap: _network || (allowLocalFile && localFile(source) != null)
              ? () => _preview(context)
              : null,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _image(width: width, height: maxHeight),
          ),
        ),
      );
    },
  );
}
