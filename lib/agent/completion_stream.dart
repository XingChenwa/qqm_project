import 'dart:convert';
import 'models.dart';

/// Assemble a bounded Chat Completions SSE response. The HTTP layer retains its
/// deadline, cancellation, size and no-redirect rules. Incomplete streams fail.
Json agentStreamCompletion(String source) {
  if (source.startsWith('\uFEFF')) source = source.substring(1);
  final content = StringBuffer(), reasoning = StringBuffer();
  final calls = <int, Json>{};
  Json usage = {};
  String? finish;
  var seen = false, done = false;
  for (final event in source.split(RegExp(r'\r?\n\r?\n'))) {
    final data = event
        .split(RegExp(r'\r?\n'))
        .where((line) => line.startsWith('data:'))
        .map((line) => line.substring(5).trimLeft())
        .join('\n')
        .trim();
    if (data.isEmpty) continue;
    if (data == '[DONE]') {
      done = true;
      break;
    }
    Json chunk;
    try {
      chunk = object(jsonDecode(data));
    } catch (_) {
      throw const AgentException('模型流式响应格式无效。');
    }
    if (chunk['error'] != null) {
      throw const AgentException('模型流式请求未完成，请检查服务和模型配置。');
    }
    if (chunk['usage'] is Map) usage = object(chunk['usage']);
    final choices = chunk['choices'];
    if (choices is! List) throw const AgentException('模型流式响应缺少choices。');
    final first = choices
        .map(object)
        .where((c) => integer(c['index'], 0) == 0)
        .firstOrNull;
    if (first == null) continue;
    seen = true;
    final delta = object(first['delta']);
    if (delta['content'] is String) content.write(delta['content']);
    if (delta['reasoning_content'] is String) {
      reasoning.write(delta['reasoning_content']);
    }
    for (final part in (delta['tool_calls'] as List? ?? []).map(object)) {
      final index = integer(part['index'], 0);
      if (index < 0 || index >= 64) throw const AgentException('模型流式工具数量超限。');
      final call = calls.putIfAbsent(
        index,
        () => {
          'id': '',
          'type': 'function',
          'function': {'name': '', 'arguments': ''},
        },
      );
      if (part['id'] != null) call['id'] = '${call['id']}${text(part['id'])}';
      final fn = object(part['function']), stored = object(call['function']);
      stored['name'] = '${stored['name']}${text(fn['name'])}';
      stored['arguments'] = '${stored['arguments']}${text(fn['arguments'])}';
      call['function'] = stored;
    }
    if (first['finish_reason'] != null) finish = text(first['finish_reason']);
  }
  if (!seen || (!done && finish == null)) {
    throw const AgentException('模型流式连接提前中断，未取得完整回复。');
  }
  return {
    'choices': [
      {
        'index': 0,
        'finish_reason': finish ?? (calls.isEmpty ? 'stop' : 'tool_calls'),
        'message': {
          'role': 'assistant',
          'content': content.toString(),
          if (reasoning.isNotEmpty) 'reasoning_content': reasoning.toString(),
          if (calls.isNotEmpty)
            'tool_calls': [
              for (final index in calls.keys.toList()..sort()) calls[index],
            ],
        },
      },
    ],
    'usage': usage,
  };
}
