import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/received_message.dart';
import '../../services/voice_attachment_service.dart';
import 'app_dialogs.dart';

class VoiceAttachment extends StatefulWidget {
  final ReceivedAttachment attachment;
  final bool allowLocalFile;
  const VoiceAttachment({
    super.key,
    required this.attachment,
    this.allowLocalFile = false,
  });
  @override
  State<VoiceAttachment> createState() => _VoiceAttachmentState();
}

class _VoiceAttachmentState extends State<VoiceAttachment> {
  static AudioPlayer? _active;
  final _service = VoiceAttachmentService();
  final _cancel = CancelToken();
  final _subscriptions = <StreamSubscription>[];
  Future<PreparedVoice>? _voice;
  AudioPlayer? _player;
  bool _busy = false, _playing = false;
  Duration _position = Duration.zero, _duration = Duration.zero;

  Future<PreparedVoice> _prepare() => _voice ??= _service
      .prepare(
        widget.attachment,
        _cancel,
        allowLocalFile: widget.allowLocalFile,
      )
      .catchError((Object error) {
        _voice = null;
        throw error;
      });

  @override
  void dispose() {
    _cancel.cancel();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    if (_active == _player) _active = null;
    final release =
        _player?.dispose().catchError((Object _) {}) ?? Future<void>.value();
    final pending = _voice;
    if (pending != null) {
      unawaited(
        (() async {
          await release;
          final voice = await pending;
          await voice.dispose();
        })().catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  Future<void> _play() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (_playing) {
        await _player?.pause();
        return;
      }
      final voice = await _prepare();
      if (!mounted) return;
      var player = _player;
      if (player == null) {
        _player = player = AudioPlayer();
        _subscriptions.addAll([
          player.onPlayerStateChanged.listen((state) {
            if (mounted) {
              setState(() {
                _playing = state == PlayerState.playing;
                if (state == PlayerState.completed) _position = Duration.zero;
              });
            }
          }),
          player.onDurationChanged.listen((value) {
            if (mounted) setState(() => _duration = value);
          }),
          player.onPositionChanged.listen((value) {
            if (mounted) setState(() => _position = value);
          }),
        ]);
        await player.setSource(DeviceFileSource(voice.source.path));
      }
      if (!mounted) return;
      if (_active != player) await _active?.pause();
      _active = player;
      await player.resume();
    } catch (_) {
      final failed = _player;
      if (_active == failed) _active = null;
      _player = null;
      for (final subscription in _subscriptions) {
        await subscription.cancel();
      }
      _subscriptions.clear();
      try {
        await failed?.dispose();
      } catch (_) {}
      if (mounted) {
        await AppDialogs.show(
          context,
          '语音暂时无法播放。链接可能已过期，或 QQ 未提供通用音频格式；可以尝试下载原文件。',
          title: '播放失败',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // openUrl prefers QQ's voice_wav_url. Download these exact bytes;
      // never transcode or rename SILK data to WAV.
      final voice = await _prepare();
      final file = voice.source;
      if (!mounted) return;
      final ext = voice.extension;
      final path = await FilePicker.saveFile(
        dialogTitle: '保存语音',
        fileName: 'QQ语音-${DateTime.now().millisecondsSinceEpoch}.$ext',
        type: FileType.custom,
        allowedExtensions: [ext],
        bytes: await file.readAsBytes(),
      );
      if (path != null && mounted) {
        await AppDialogs.show(context, '语音已保存。', title: '下载完成');
      }
    } catch (error) {
      if (mounted) {
        await AppDialogs.show(
          context,
          error is FormatException
              ? error.message.toString()
              : '语音下载失败，链接可能已过期，请重试。',
          title: '下载失败',
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _time(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 6),
    constraints: const BoxConstraints(maxWidth: 340),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton.filledTonal(
              tooltip: _playing ? '暂停语音' : '播放语音',
              onPressed: _busy ? null : _play,
              icon: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.attachment.filename.isEmpty
                        ? '语音消息'
                        : widget.attachment.filename,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    '${_time(_position)} / ${_time(_duration)}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: widget.attachment.voiceWavUrl.isNotEmpty
                  ? '下载官方 WAV'
                  : '下载语音原文件',
              onPressed: _busy ? null : _download,
              icon: const Icon(Icons.download_rounded, size: 20),
            ),
          ],
        ),
        if (_duration > Duration.zero)
          SizedBox(
            height: 30,
            child: Slider(
              value: _position.inMilliseconds.toDouble().clamp(
                0,
                _duration.inMilliseconds.toDouble(),
              ),
              max: _duration.inMilliseconds.toDouble(),
              onChanged: _busy
                  ? null
                  : (value) =>
                        _player?.seek(Duration(milliseconds: value.round())),
            ),
          ),
        if (widget.attachment.transcript.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              '语音转写：${widget.attachment.transcript}',
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
          ),
      ],
    ),
  );
}
