import 'dart:math';

import '../sdk.dart';

class DicePlugin extends BotPlugin {
  static final RegExp _dicePattern = RegExp(
    r'^(\d{1,3})d(\d{1,4})([+-]\d{1,6})?$',
    caseSensitive: false,
  );
  final Random _random;

  DicePlugin(super.info, {Random? random})
    : _random = random ?? Random.secure();

  @override
  List<PluginCommand> get commands => const [
    PluginCommand(
      '骰子',
      '掷骰子，可带修正值',
      usage: '骰子 2d6+3',
      aliases: ['dice', 'roll'],
    ),
    PluginCommand('硬币', '抛硬币（1–20 次）', usage: '硬币 3', aliases: ['coin']),
    PluginCommand(
      '选择',
      '随机选一项',
      usage: '选择 火锅 | 烧烤 | 面条',
      aliases: ['choose', '转盘'],
    ),
    PluginCommand(
      '打乱',
      '随机排列选项',
      usage: '打乱 小明 | 小红 | 小华',
      aliases: ['shuffle'],
    ),
    PluginCommand('随机数', '生成范围内整数', usage: '随机数 1 100', aliases: ['random']),
    PluginCommand('猜拳', '和机器人石头剪刀布', usage: '猜拳 石头', aliases: ['rps']),
  ];

  @override
  bool acceptsUnmentioned(PluginMessage message) =>
      super.acceptsUnmentioned(message) ||
      _dicePattern.hasMatch(message.content.trim());

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
    switch (command) {
      case 'dice' || 'roll' || '骰子':
        if (args.isEmpty) return _rollExpression('1d6');
        return _rollExpression(args.join('')) ?? '骰子格式不正确，请使用 2d6、1d20、2d6+3。';
      case '硬币' || 'coin':
        final count = args.isEmpty ? 1 : int.tryParse(args.join(' '));
        if (count == null || count < 1 || count > 20) return '用法：/硬币 [1–20 次]';
        return '抛硬币：${List.generate(count, (_) => _random.nextBool() ? '正面' : '反面').join('、')}';
      case '选择' || '转盘' || 'choose' || '打乱' || 'shuffle':
        final values = args
            .join(' ')
            .split(RegExp(r'[|｜]'))
            .map((v) => v.trim())
            .toList();
        if (values.length < 2 ||
            values.length > 20 ||
            values.any((v) => v.isEmpty || v.length > 80)) {
          return '请提供 2–20 个选项，每项最多 80 字，用 | 隔开，例如：/选择 火锅 | 烧烤';
        }
        if (command == '打乱' || command == 'shuffle') {
          values.shuffle(_random);
          return '随机排序：\n${[for (var i = 0; i < values.length; i++) '${i + 1}. ${values[i]}'].join('\n')}';
        }
        return '我选：${values[_random.nextInt(values.length)]}';
      case '随机数' || 'random':
        final low = args.length == 2 ? int.tryParse(args[0]) : null;
        final high = args.length == 2 ? int.tryParse(args[1]) : null;
        if (low == null ||
            high == null ||
            low > high ||
            low.abs() > 1000000000 ||
            high.abs() > 1000000000) {
          return '用法：/随机数 最小值 最大值（整数，范围 ±10 亿）';
        }
        return '随机数：${low + _random.nextInt(high - low + 1)}';
      case '猜拳' || 'rps':
        const choices = ['石头', '剪刀', '布'];
        final chosen = choices.indexOf(args.join(' '));
        if (chosen < 0) return '用法：/猜拳 石头（也可选剪刀、布）';
        final mine = _random.nextInt(3);
        final result = chosen == mine
            ? '平局！'
            : (chosen + 1) % 3 == mine
            ? '你赢了！'
            : '我赢了！';
        return '你出${choices[chosen]}，我出${choices[mine]}。$result';
      default:
        return null;
    }
  }

  String? _rollExpression(String expression) {
    final match = _dicePattern.firstMatch(expression);
    if (match == null) return null;

    final count = int.parse(match.group(1)!);
    final sides = int.parse(match.group(2)!);
    if (count < 1 || sides < 2) {
      return '骰子数量至少为 1，面数至少为 2。';
    }
    final maxCount = (int.tryParse('${info.config['max_dice']}') ?? 100).clamp(
      1,
      100,
    );
    final maxSides = (int.tryParse('${info.config['max_sides']}') ?? 1000)
        .clamp(2, 1000);
    if (count > maxCount || sides > maxSides) {
      return '骰子参数过大，请使用 ${maxCount}d$maxSides 以内的格式。';
    }

    return _roll(count, sides, int.tryParse(match.group(3) ?? '0') ?? 0);
  }

  String _roll(int count, int sides, int modifier) {
    final results = List.generate(count, (_) => _random.nextInt(sides) + 1);
    final total = results.fold<int>(modifier, (sum, value) => sum + value);
    final visibleResults = results.length > 20
        ? '${results.take(20).join(', ')} ...'
        : results.join(', ');
    final detail = count > 1 ? ' [$visibleResults]' : '';
    final adjustment = modifier == 0
        ? ''
        : modifier > 0
        ? '+$modifier'
        : '$modifier';
    return '掷骰结果：${count}d$sides$adjustment = $total$detail';
  }
}
