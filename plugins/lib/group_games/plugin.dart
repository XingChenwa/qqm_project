import 'dart:convert';
import 'dart:math';

import '../sdk.dart';

class GroupGamesPlugin extends BotPlugin {
  final Random _random;
  final DateTime Function() _clock;
  GroupGamesPlugin(super.info, {Random? random, DateTime Function()? clock})
    : _random = random ?? Random.secure(),
      _clock = clock ?? DateTime.now;

  @override
  List<PluginCommand> get commands => const [
    PluginCommand('猜数字', '15 分钟限时游戏，1–100', usage: '猜数字 开始 / 数字 / 结束'),
    PluginCommand('投票', '每人一票、可改票，24 小时结束', usage: '投票 创建 标题 | 选项1 | 选项2'),
    PluginCommand('投票', '投票、结果、结束', usage: '投票 选择 1 / 结果 / 结束'),
  ];
  @override
  Future<void> onEnable() async {}
  @override
  Future<void> onDisable() async {}
  @override
  Future<String?> onMessage(PluginMessage message) async => null;
  @override
  Future<String?> onCommand(String command, List<String> args) async => null;

  @override
  Future<PluginReply?> execute(PluginMessage message) async {
    final parsed = parseSlashCommand(message.content);
    final callback =
        message.eventType == 'interaction' &&
        message.callbackData.startsWith('qqm:${info.id}:vote:');
    if (!callback &&
        (parsed == null ||
            !{'猜数字', 'guess', '投票', 'poll'}.contains(parsed.command))) {
      return null;
    }
    if (!message.isGroup) {
      return const PluginReply('群游戏请在群聊中使用。', format: 'text');
    }
    if (host == null || message.senderId.isEmpty || message.sessionId.isEmpty) {
      return const PluginReply('此玩法需要 QQ 群成员身份，请在 QQ 群里发送命令。', format: 'text');
    }
    final key = jsonEncode(['group', message.sessionId]);
    final now = _clock().millisecondsSinceEpoch;
    return host!.store.update<PluginReply>(key, (state) {
      if (!callback && {'猜数字', 'guess'}.contains(parsed!.command)) {
        return PluginReply(
          _guess(state, message, parsed.args, now),
          format: 'text',
        );
      }
      return _poll(state, message, parsed?.args ?? [], callback, now);
    });
  }

  bool _canClose(Map value, PluginMessage message) =>
      value['owner'] == message.senderId ||
      message.senderRole == 'admin' ||
      message.senderRole == 'owner';

  String _guess(
    Map<String, dynamic> state,
    PluginMessage message,
    List<String> args,
    int now,
  ) {
    var game = Map<String, dynamic>.from(state['guess'] as Map? ?? {});
    if ((game['expires'] as int? ?? 0) <= now) game = {};
    final action = args.join(' ').trim();
    if (action == '开始' || action == 'start') {
      if (game.isNotEmpty) return '本群已经有猜数字游戏了。发送 /猜数字 50；发起人或管理员可结束。';
      state['guess'] = {
        'answer': _random.nextInt(100) + 1,
        'owner': message.senderId,
        'attempts': 0,
        'expires': now + 900000,
      };
      return '我想了一个 1–100 的整数，15 分钟内发送 /猜数字 数字 来猜吧！最多 50 次。';
    }
    if (action == '结束' || action == 'stop') {
      if (game.isEmpty) return '当前没有进行中的猜数字游戏。';
      if (!_canClose(game, message)) return '仅发起人、群主或管理员可以结束。';
      state.remove('guess');
      return '游戏已结束，答案是 ${game['answer']}。';
    }
    final number = int.tryParse(action);
    if (number == null || number < 1 || number > 100) {
      return '用法：/猜数字 开始、/猜数字 50、/猜数字 结束。范围 1–100。';
    }
    if (game.isEmpty) return '没有进行中的游戏（可能已过期），发送 /猜数字 开始。';
    final attempts = (game['attempts'] as int) + 1;
    final answer = game['answer'] as int;
    if (number == answer || attempts >= 50) {
      state.remove('guess');
      return number == answer
          ? '猜对啦！答案是 $answer，共猜了 $attempts 次。'
          : '已达到 50 次，答案是 $answer。';
    }
    game['attempts'] = attempts;
    state['guess'] = game;
    return '${number < answer ? '小了' : '大了'}，再试试！已猜 $attempts 次。';
  }

  PluginReply _poll(
    Map<String, dynamic> state,
    PluginMessage message,
    List<String> args,
    bool callback,
    int now,
  ) {
    var poll = Map<String, dynamic>.from(state['poll'] as Map? ?? {});
    if ((poll['expires'] as int? ?? 0) <= now) poll = {};
    String text(String value) =>
        value.replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' ').trim();
    PluginReply plain(String value) => PluginReply(value, format: 'text');
    if (!callback && args.isNotEmpty && {'创建', 'create'}.contains(args.first)) {
      if (poll.isNotEmpty && poll['closed'] != true) {
        return plain('本群已有进行中的投票。发送 /投票 结果 查看。');
      }
      final parts = args
          .skip(1)
          .join(' ')
          .split(RegExp(r'[|｜]'))
          .map(text)
          .toList();
      if (parts.length < 3 ||
          parts.length > 7 ||
          parts.any((v) => v.isEmpty || v.length > 80) ||
          parts.skip(1).toSet().length != parts.length - 1) {
        return plain('用法：/投票 创建 晚上吃什么 | 火锅 | 烧烤\n支持 2–6 个不重复选项，标题和每项最多 80 字。');
      }
      poll = {
        'title': parts.first,
        'options': parts.skip(1).toList(),
        'votes': <String, dynamic>{},
        'owner': message.senderId,
        'nonce':
            '${now.toRadixString(36)}${_random.nextInt(1 << 30).toRadixString(36)}',
        'expires': now + 86400000,
      };
      state['poll'] = poll;
      return _pollView(poll, '投票已创建，24 小时内有效。');
    }
    if (poll.isEmpty) return plain('没有有效投票。发送 /投票 创建 标题 | 选项1 | 选项2');
    if (callback || args.isNotEmpty && {'选择', 'vote'}.contains(args.first)) {
      String? selection;
      if (callback) {
        final pieces = message.callbackData.split(':');
        if (pieces.length != 5 || pieces[3] != poll['nonce']) {
          return plain('此按钮属于旧投票，请发送 /投票 结果。');
        }
        selection = pieces[4];
      } else if (args.length == 2) {
        selection = args[1];
      }
      if (poll['closed'] == true) return plain('此投票已经结束。');
      final number = int.tryParse(selection ?? '');
      final options = poll['options'] as List;
      if (number == null || number < 1 || number > options.length) {
        return plain('请选择 1–${options.length}，例如：/投票 选择 1');
      }
      final votes = Map<String, dynamic>.from(poll['votes'] as Map);
      if (!votes.containsKey(message.senderId) && votes.length >= 1000) {
        return plain('此投票已达到 1000 人上限。');
      }
      votes[message.senderId] = number - 1;
      poll['votes'] = votes;
      state['poll'] = poll;
      return _pollView(poll, '已记录你的第 $number 项选择（可重新选择）。');
    }
    if (args.join(' ') == '结束' || args.join(' ') == 'close') {
      if (!_canClose(poll, message)) return plain('仅发起人、群主或管理员可以结束投票。');
      poll['closed'] = true;
      state['poll'] = poll;
      return _pollView(poll, '投票已结束。');
    }
    return _pollView(
      poll,
      poll['closed'] == true ? '投票已结束。' : '每人一票，可改票；发送 /投票 选择 序号。',
    );
  }

  PluginReply _pollView(Map<String, dynamic> poll, String status) {
    final options = List<String>.from(poll['options']);
    final votes = (poll['votes'] as Map).values.toList();
    final content =
        '$status\n${poll['title']}\n${options.indexed.map((e) => '${e.$1 + 1}. ${e.$2}：${votes.where((v) => v == e.$1).length} 票').join('\n')}\n共 ${votes.length} 人参与。';
    if (info.config['enable_buttons'] != true || poll['closed'] == true) {
      return PluginReply(content, format: 'text');
    }
    // Markdown text is escaped; plugin content cannot inject an arbitrary link or image.
    final escaped = content.replaceAllMapped(
      RegExp(r'[\\`*_{}\[\]()#+.!<>|~-]'),
      (m) => '\\${m[0]}',
    );
    return PluginReply(
      escaped,
      format: 'markdown',
      buttons: [
        for (var start = 0; start < options.length; start += 3)
          [
            for (var i = start; i < min(start + 3, options.length); i++)
              PluginButton(
                '选 ${i + 1}',
                'qqm:${info.id}:vote:${poll['nonce']}:${i + 1}',
                callback: true,
              ),
          ],
      ],
    );
  }
}
