import 'dart:async';
import 'dart:convert';

/// Per-bot, per-plugin JSON data; never put game state into an exported config.
class PluginStore {
  final Future<Map<String, dynamic>> Function() _read;
  final Future<void> Function(Map<String, dynamic>) _write;
  Future<void> _tail = Future.value();
  PluginStore(this._read, this._write);

  Future<T> update<T>(
    String key,
    T Function(Map<String, dynamic>) action, {
    bool persist = true,
  }) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        if (key.isEmpty || key.length > 256) {
          throw const FormatException('插件数据键无效。');
        }
        final all = await _read();
        final value = all[key];
        final copy =
            jsonDecode(jsonEncode(value is Map ? value : {}))
                as Map<String, dynamic>;
        final answer = action(copy);
        if (persist) {
          final next = {...all, key: copy};
          if (next.length > 256 ||
              utf8.encode(jsonEncode(next)).length > 524288) {
            throw const FormatException('此插件本地数据已达到 512 KB 上限，请先备份和清理。');
          }
          await _write(next);
        }
        result.complete(answer);
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  Future<Map<String, dynamic>> read(String key) =>
      update(key, (value) => value, persist: false);

  Future<Map<String, dynamic>> snapshot() {
    final result = Completer<Map<String, dynamic>>();
    _tail = _tail.then((_) async {
      try {
        result.complete(
          Map<String, dynamic>.from(
            jsonDecode(jsonEncode(await _read())) as Map,
          ),
        );
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }

  Future<void> clear() {
    final result = Completer<void>();
    _tail = _tail.then((_) async {
      try {
        await _write({});
        result.complete();
      } catch (e, s) {
        result.completeError(e, s);
      }
    });
    return result.future;
  }
}

class PluginCommand {
  final String name;
  final String description;
  final String usage;
  final List<String> aliases;
  final bool allowBare;
  const PluginCommand(
    this.name,
    this.description, {
    this.usage = '',
    this.aliases = const [],
    this.allowBare = false,
  });
}

class PluginHost {
  final PluginStore Function() _store;
  final String Function() help;
  factory PluginHost({
    required PluginStore Function() store,
    required String Function() help,
  }) => PluginHost._(store, help);
  PluginHost._(this._store, this.help);
  PluginStore get store => _store();
}

class PluginButton {
  final String label;
  final String data;
  final bool callback;
  const PluginButton(this.label, this.data, {this.callback = false});

  Map<String, dynamic> toMap() => {
    'label': label,
    'data': data,
    'callback': callback,
  };
}

/// A neutral SDK message. Only the host can access QQ credentials and send it.
class PluginReply {
  final String content;
  final String format;
  final String mediaUrl;
  final int mediaType;
  final List<List<PluginButton>> buttons;
  const PluginReply(
    this.content, {
    this.format = 'auto',
    this.mediaUrl = '',
    this.mediaType = 1,
    this.buttons = const [],
  });

  factory PluginReply.fromMap(Map<String, dynamic> map) {
    if (map.keys.any(
      (k) => ![
        'content',
        'format',
        'media_url',
        'media_type',
        'buttons',
      ].contains(k),
    )) {
      throw const FormatException('插件消息包含不支持的字段。');
    }
    final content = map['content'] ?? '';
    final format = map['format'] ?? 'text';
    final media = map['media_url'] ?? '';
    final mediaType = map['media_type'] ?? 1;
    final rawButtons = map['buttons'] ?? [];
    if (content is! String ||
        content.length > 16000 ||
        !['text', 'markdown', 'media'].contains(format) ||
        media is! String ||
        mediaType is! int ||
        ![1, 2, 3, 4].contains(mediaType) ||
        rawButtons is! List ||
        rawButtons.length > 5) {
      throw const FormatException('插件消息格式无效或内容过长。');
    }
    final buttons = <List<PluginButton>>[];
    for (final row in rawButtons) {
      if (row is! List || row.isEmpty || row.length > 5) {
        throw const FormatException('按钮布局最多 5 行，每行 1–5 个。');
      }
      final values = <PluginButton>[];
      for (final button in row) {
        if (button is! Map ||
            button.keys.any(
              (k) => !['label', 'data', 'callback'].contains(k),
            ) ||
            button['label'] is! String ||
            (button['label'] as String).isEmpty ||
            (button['label'] as String).runes.length > 10 ||
            button['data'] is! String ||
            (button['data'] as String).isEmpty ||
            (button['data'] as String).length > 512 ||
            button['callback'] != null && button['callback'] is! bool) {
          throw const FormatException('按钮文字或指令无效。');
        }
        values.add(
          PluginButton(
            button['label'],
            button['data'],
            callback: button['callback'] == true,
          ),
        );
      }
      buttons.add(values);
    }
    if (buttons.isNotEmpty && format != 'markdown') {
      throw const FormatException('按钮键盘需要 Markdown 消息。');
    }
    if (format == 'media') {
      final uri = Uri.tryParse(media);
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment ||
          media.length > 4096) {
        throw const FormatException('插件媒体必须使用无凭据的 HTTPS URL。');
      }
    } else if (content.trim().isEmpty || media.isNotEmpty) {
      throw const FormatException('文本/Markdown 正文不能为空，也不能同时携带媒体地址。');
    }
    return PluginReply(
      content,
      format: format,
      mediaUrl: media,
      mediaType: mediaType,
      buttons: buttons,
    );
  }

  Map<String, dynamic> toMap() => {
    'content': content,
    'format': format == 'auto' ? 'text' : format,
    if (mediaUrl.isNotEmpty) 'media_url': mediaUrl,
    if (mediaUrl.isNotEmpty) 'media_type': mediaType,
    if (buttons.isNotEmpty)
      'buttons': [
        for (final row in buttons) [for (final b in row) b.toMap()],
      ],
  };
}
