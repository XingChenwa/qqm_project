import 'dart:math';

import '../../models/plugin.dart';

class DicePlugin extends BotPlugin {
  static final RegExp _dicePattern = RegExp(
    r'^(\d{1,3})d(\d{1,4})$',
    caseSensitive: false,
  );
  final Random _random = Random.secure();

  DicePlugin(super.info);

  @override
  Future<void> onEnable() async {}

  @override
  Future<void> onDisable() async {}

  @override
  Future<String?> onMessage(PluginMessage message) async {
    return _rollExpression(message.content.trim());
  }

  @override
  Future<String?> onCommand(String command, List<String> args) async {
    if (command != 'dice' && command != 'roll') return null;
    if (args.isEmpty) return _roll(1, 6);
    return _rollExpression(args.first.trim()) ?? '骰子格式不正确，请使用 2d6、1d20 这类格式。';
  }

  String? _rollExpression(String expression) {
    final match = _dicePattern.firstMatch(expression);
    if (match == null) return null;

    final count = int.parse(match.group(1)!);
    final sides = int.parse(match.group(2)!);
    if (count < 1 || sides < 2) {
      return '骰子数量至少为 1，面数至少为 2。';
    }
    if (count > 100 || sides > 1000) {
      return '骰子参数过大，请使用 100d1000 以内的格式。';
    }

    return _roll(count, sides);
  }

  String _roll(int count, int sides) {
    final results = List.generate(count, (_) => _random.nextInt(sides) + 1);
    final total = results.fold<int>(0, (sum, value) => sum + value);
    final visibleResults = results.length > 20
        ? '${results.take(20).join(', ')} ...'
        : results.join(', ');
    final detail = count > 1 ? ' [$visibleResults]' : '';
    return '掷骰结果：${count}d$sides = $total$detail';
  }
}
