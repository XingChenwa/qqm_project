import 'dart:convert';
import 'models.dart';

/// Some role cards return this envelope even with the UI's split switch off.
/// This check is only for model output; manual JSON messages stay untouched.
bool agentReplyEnvelope(String source) => RegExp(
  r'^\s*(?:```(?:json)?\s*)?\{\s*"messages"\s*:',
  caseSensitive: false,
).hasMatch(source);

/// A single model completion can contain several QQ bubbles. Combining overflow
/// preserves the answer when QQBot has fewer passive replies left than planned.
List<String> agentReplyMessages(
  String answer, {
  required bool enabled,
  int maxParts = 3,
}) {
  if (!enabled) return [clipped(answer.trim(), 12000)];
  var source = answer.trim();
  final fence = RegExp(
    r'^```(?:json)?\s*([\s\S]*?)\s*```$',
    caseSensitive: false,
  ).firstMatch(source);
  if (fence != null) source = fence[1]!;
  List<String>? parts;
  Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (_) {
    // Plain text is valid too. Split ordinary paragraphs below instead of
    // depending on every compatible model obeying the JSON instruction.
    if (agentReplyEnvelope(source)) {
      throw const AgentException(
        '模型的分条回复 JSON 未完整返回，请增加最大输出长度或关闭分条回复后重试；本轮未发送残缺 JSON。',
      );
    }
  }
  if (decoded is Map && decoded.containsKey('messages')) {
    final values = decoded['messages'];
    if (values is! List || values.any((value) => value is! String)) {
      throw const AgentException('模型的分条回复messages格式无效；本轮未发送原始JSON。');
    }
    parts = values
        .cast<String>()
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
  }
  parts ??= [answer.trim()];
  if (parts.length == 1) parts = _plainReplyParagraphs(parts.single);
  if (parts.isEmpty) throw const AgentException('模型返回的分条回复为空。');
  final limit = maxParts.clamp(1, 5);
  if (parts.length > limit) {
    parts = [...parts.take(limit - 1), parts.skip(limit - 1).join('\n\n')];
  }
  var remaining = 12000;
  final result = <String>[];
  for (final part in parts) {
    if (remaining <= 0) break;
    final value = clipped(part, remaining);
    remaining -= value.length;
    if (value.isNotEmpty) result.add(value);
  }
  return result;
}

/// A blank line between plain chat paragraphs is a fallback bubble boundary.
/// Structured replies with several explicit messages retain their boundaries.
/// Be conservative with Markdown: a list, code sample or table may contain
/// blank lines internally and must remain a single, complete message.
List<String> _plainReplyParagraphs(String source) {
  if (source.startsWith('{') ||
      source.startsWith('[') ||
      RegExp(
        r'^(?:[ \t]{4}|\t)|^[ \t]*(?:`{3,}|~{3,}|#{1,6}(?:[ \t]|$)|>|[-+*][ \t]+|\d{1,9}[.)][ \t]+|(?:[-*_][ \t]*){3,}$|={2,}[ \t]*$|\$\$|\\\[|<[/!A-Za-z]|!?\[[^\]\r\n]+\]:)|^[^\r\n]*\|[^\r\n]*$',
        multiLine: true,
      ).hasMatch(source)) {
    return [source];
  }
  return source
      .split(RegExp(r'\r?\n(?:[ \t]*\r?\n)+'))
      .map((part) => part.trim())
      .where((part) => part.isNotEmpty)
      .toList();
}
