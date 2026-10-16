import 'dart:convert';

import '../sdk.dart';

/// Local entertainment points, not currency. Every mutation is serialized by host storage.
class DailyClubPlugin extends BotPlugin {
  final DateTime Function() _clock;
  DailyClubPlugin(super.info, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  @override
  List<PluginCommand> get commands => const [
    PluginCommand('签到', '每日签到、连续天数和积分', aliases: ['sign']),
    PluginCommand('积分', '查看当前会话积分', aliases: ['points']),
    PluginCommand('排行', '当前会话前十名', aliases: ['rank']),
    PluginCommand('今日运势', '每天固定的娱乐运势', aliases: ['fortune']),
    PluginCommand('抽签', '抽一张娱乐签', aliases: ['draw']),
  ];

  @override
  Future<void> onEnable() async {}
  @override
  Future<void> onDisable() async {}
  @override
  Future<String?> onMessage(PluginMessage message) async => null;
  @override
  Future<String?> onCommand(String command, List<String> args) async =>
      '请在 QQ 会话中发送 /$command，玩法需要真实的发送者身份。';

  @override
  Future<PluginReply?> execute(PluginMessage message) async {
    final parsed = parseSlashCommand(message.content);
    const names = {
      '签到',
      'sign',
      '积分',
      'points',
      '排行',
      'rank',
      '今日运势',
      'fortune',
      '抽签',
      'draw',
    };
    if (parsed == null || !names.contains(parsed.command)) return null;
    if (host == null || message.senderId.isEmpty || message.sessionId.isEmpty) {
      return const PluginReply(
        '请在 QQ 会话中使用此命令；操作员没有 QQ 发送者身份。',
        format: 'text',
      );
    }
    final now = _clock().toUtc().add(const Duration(hours: 8));
    final today = now.toIso8601String().substring(0, 10);
    final yesterday = now
        .subtract(const Duration(days: 1))
        .toIso8601String()
        .substring(0, 10);
    final key = jsonEncode([
      message.isGroup ? 'group' : 'private',
      message.sessionId,
    ]);
    final command = parsed.command;
    if (command == '今日运势' ||
        command == 'fortune' ||
        command == '抽签' ||
        command == 'draw') {
      final seed = _hash('$today:${message.sessionId}:${message.senderId}');
      if (command == '抽签' || command == 'draw') {
        const sayings = [
          '保持好奇，今天适合学一点新东西。',
          '先完成最小的一步，进度自然会来。',
          '休息也是计划的一部分。',
          '把难题拆开，你会找到入口。',
          '和朋友聊聊，或许会有新思路。',
          '认真做的事情，值得慢慢来。',
        ];
        return PluginReply(
          '今日签：${sayings[seed % sayings.length]}\n$today · 仅供娱乐，不作为现实决策依据。',
          format: 'text',
        );
      }
      const activities = ['整理桌面', '读一页书', '散步', '写点代码', '听听音乐', '和朋友聊聊'];
      return PluginReply(
        '$today 今日运势：${seed % 101}/100\n今日小建议：${activities[(seed ~/ 101) % activities.length]}\n仅供娱乐，每天固定；不代表真实运气。',
        format: 'text',
      );
    }
    final text = await host!.store.update<String>(key, (state) {
      final users = Map<String, dynamic>.from(state['users'] as Map? ?? {});
      final raw = users[message.senderId];
      final user = Map<String, dynamic>.from(raw is Map ? raw : {});
      final points = (user['points'] as int? ?? 0).clamp(0, 1000000000);
      if (command == '排行' || command == 'rank') {
        final sorted = users.entries.where((e) => e.value is Map).toList()
          ..sort(
            (a, b) => ((b.value as Map)['points'] as int? ?? 0).compareTo(
              (a.value as Map)['points'] as int? ?? 0,
            ),
          );
        return sorted.isEmpty
            ? '这里还没有签到记录，发送 /签到 试试吧。'
            : '本会话积分榜\n${sorted.take(10).indexed.map((e) => '${e.$1 + 1}. ${_name((e.$2.value as Map)['name']?.toString() ?? 'QQ 用户')} · ${(e.$2.value as Map)['points'] ?? 0} 分').join('\n')}';
      }
      if (command == '积分' || command == 'points') {
        return '${_name(message.senderName)}：$points 分，累计签到 ${user['days'] ?? 0} 天。';
      }
      if (user['date'] == today) {
        return '今天已经签到过啦。当前 $points 分，连续 ${user['streak'] ?? 1} 天。';
      }
      if (!users.containsKey(message.senderId) && users.length >= 1000) {
        return '本会话签到人数已达 1000 人，请管理员先备份、清理插件数据。';
      }
      final reward = (int.tryParse('${info.config['daily_points']}') ?? 10)
          .clamp(1, 100);
      final streak = user['date'] == yesterday
          ? (user['streak'] as int? ?? 0) + 1
          : 1;
      users[message.senderId] = {
        'name': _name(message.senderName),
        'points': (points + reward).clamp(0, 1000000000),
        'date': today,
        'streak': streak,
        'days': (user['days'] as int? ?? 0) + 1,
      };
      state['users'] = users;
      return '${_name(message.senderName)}，签到成功！+$reward 分\n连续 $streak 天，当前 ${points + reward} 分。';
    }, persist: command == '签到' || command == 'sign');
    return PluginReply(text, format: 'text');
  }

  static String _name(String name) {
    final safe = name.replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ').trim();
    return safe.isEmpty ? 'QQ 用户' : String.fromCharCodes(safe.runes.take(30));
  }

  static int _hash(String value) {
    var hash = 2166136261;
    for (final byte in utf8.encode(value)) {
      hash = ((hash ^ byte) * 16777619) & 0x7fffffff;
    }
    return hash;
  }
}
