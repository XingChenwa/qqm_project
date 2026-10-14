import 'dart:convert';
import 'dart:io';

import '../../models/plugin.dart';

class TranslateCommentPlugin extends BotPlugin {
  static const _deepseekUrl = 'https://api.deepseek.com/v1/chat/completions';
  static const _model = 'deepseek-chat';
  static const _timeout = Duration(seconds: 30);

  TranslateCommentPlugin(super.info);

  @override
  Duration get executionTimeout => const Duration(minutes: 2);

  String get _apiKey => info.config['api_key']?.toString().trim() ?? '';
  String get _targetLang {
    final value = info.config['target_lang']?.toString().trim() ?? '';
    return value.isEmpty ? '中文' : value;
  }

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<String?> onMessage(PluginMessage message) async {
    if (!message.content.contains('```')) return null;
    final blocks = _extractCodeBlocks(message.content);
    if (blocks.isEmpty) return null;
    return _translateBlocks(blocks);
  }

  @override
  Future<String?> onCommand(String command, List<String> args) async {
    if (command != 'translate' && command != 'fanyi') return null;

    final blocks = _extractCodeBlocks(args.join(' '));
    if (blocks.isEmpty) {
      return '''
用法：
/translate ```python
# comment
print("hello")
```

请把代码放在 Markdown 代码块里。
''';
    }
    return _translateBlocks(blocks);
  }

  List<_CodeBlock> _extractCodeBlocks(String text) {
    final blocks = <_CodeBlock>[];
    final regex = RegExp(
      r'```([A-Za-z0-9_+-]*)\s*\n([\s\S]*?)```',
      multiLine: true,
    );

    for (final match in regex.allMatches(text)) {
      final code = match.group(2) ?? '';
      if (code.trim().isEmpty) continue;
      blocks.add(_CodeBlock(lang: (match.group(1) ?? '').trim(), code: code));
    }

    return blocks;
  }

  Future<String?> _translateBlocks(List<_CodeBlock> blocks) async {
    if (_apiKey.isEmpty) {
      return '翻译插件尚未配置 DeepSeek API Key，请先在插件配置中填写。';
    }

    final results = <String>[];
    for (final block in blocks) {
      final translated = await _callDeepSeek(block);
      if (translated == null || translated.isEmpty) continue;

      final langTag = block.lang.isEmpty ? '' : block.lang;
      results.add('```$langTag\n$translated\n```');
    }

    return results.isEmpty ? '没有收到可用的翻译结果。' : results.join('\n\n');
  }

  Future<String?> _callDeepSeek(_CodeBlock block) async {
    final client = HttpClient()..connectionTimeout = _timeout;
    try {
      final request = await client
          .postUrl(Uri.parse(_deepseekUrl))
          .timeout(_timeout);
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_apiKey');

      final body = jsonEncode({
        'model': _model,
        'messages': [
          {
            'role': 'system',
            'content':
                '你是代码注释翻译助手。只翻译代码里的注释到$_targetLang，代码本身保持不变。直接返回完整代码，不要添加解释。',
          },
          {
            'role': 'user',
            'content':
                '语言：${block.lang.isNotEmpty ? block.lang : "自动检测"}\n代码：\n${block.code}',
          },
        ],
        'temperature': 0.2,
        'max_tokens': 4096,
      });

      final bytes = utf8.encode(body);
      request.contentLength = bytes.length;
      request.add(bytes);

      final response = await request.close().timeout(_timeout);
      final responseBody = await response.transform(utf8.decoder).join();
      final decoded = _decodeJsonMap(responseBody);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = decoded?['error'] is Map
            ? (decoded!['error'] as Map)['message']?.toString()
            : null;
        return '翻译失败：${message ?? 'HTTP ${response.statusCode}'}';
      }

      final choices = decoded?['choices'];
      if (choices is! List || choices.isEmpty) {
        return '翻译失败：接口未返回 choices。';
      }

      final first = choices.first;
      if (first is! Map) return '翻译失败：接口返回格式不正确。';
      final message = first['message'];
      final content = message is Map
          ? message['content']?.toString()
          : first['text']?.toString();
      return content?.trim();
    } catch (e) {
      return '翻译出错：$e';
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic>? _decodeJsonMap(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded as Map);
    } catch (_) {
      return null;
    }
  }
}

class _CodeBlock {
  final String lang;
  final String code;

  const _CodeBlock({required this.lang, required this.code});
}
