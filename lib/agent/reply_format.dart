import 'dart:convert';
import 'models.dart';

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
  try {
    final decoded = jsonDecode(source);
    if (decoded is Map &&
        decoded['messages'] is List &&
        (decoded['messages'] as List).isNotEmpty &&
        (decoded['messages'] as List).every((v) => v is String)) {
      parts = (decoded['messages'] as List)
          .cast<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    }
  } catch (_) {
    // A plain-text reply is valid fallback, not a reason to call the model again.
    if (RegExp(r'^\{\s*"messages"\s*:').hasMatch(source)) {
      throw const AgentException(
        '模型的分条回复 JSON 未完整返回，请增加最大输出长度或关闭分条回复后重试；本轮未发送残缺 JSON。',
      );
    }
  }
  parts ??= [answer.trim()];
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
