import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../services/media_download_service.dart';
import '../../utils/helpers.dart';

Future<void> showFileDownload(
  BuildContext context,
  String url, {
  String? filename,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => FileDownloadDialog(url: url, filename: filename),
);

class FileDownloadDialog extends StatefulWidget {
  final String url;
  final String? filename;
  const FileDownloadDialog({super.key, required this.url, this.filename});
  @override
  State<FileDownloadDialog> createState() => _FileDownloadDialogState();
}

class _FileDownloadDialogState extends State<FileDownloadDialog> {
  final _service = MediaDownloadService();
  final _cancel = CancelToken();
  int _received = 0;
  int? _total;
  bool _saving = false, _done = false;
  String _error = '';
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  @override
  void dispose() {
    _cancel.cancel();
    _service.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    PreparedDownload? download;
    try {
      download = await _service.download(
        widget.url,
        _cancel,
        suggestedFilename: widget.filename,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() => _saving = true);
      final mobile = Platform.isAndroid || Platform.isIOS;
      final destination = await FilePicker.saveFile(
        dialogTitle: '保存下载文件',
        fileName: download.filename,
        type: FileType.any,
        bytes: mobile ? await download.file.readAsBytes() : null,
      );
      if (destination != null && !mobile) await download.file.copy(destination);
      if (!mounted) return;
      if (destination == null) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _done = true;
        _saving = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is FormatException
              ? error.message.toString()
              : '下载未完成，链接可能过期或网络中断，请重新获取后重试。';
        });
      }
    } finally {
      await download?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      _done
          ? '下载完成'
          : _error.isNotEmpty
          ? '下载失败'
          : _saving
          ? '选择保存位置'
          : '正在下载',
    ),
    content: _error.isNotEmpty
        ? Text(_error)
        : _done
        ? const Text('原文件已保存，未进行转码。')
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: (_total ?? 0) > 0
                    ? (_received / _total!).clamp(0, 1)
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                '${formatFileSize(_received)}${_total == null ? '' : ' / ${formatFileSize(_total!)}'}',
              ),
            ],
          ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(_done || _error.isNotEmpty ? '关闭' : '取消下载'),
      ),
    ],
  );
}
