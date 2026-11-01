// Read-only live service check through the exact installed JSON Skill handler.
// Uses a synthetic scope, no bot connection, no real QQ messages or model calls.
import 'dart:convert';
import 'dart:io';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/script.dart';

Future<void> main() async {
  final skill = AgentExtension.parse(
    await File('agent_examples/local-rvc-cover/skill.json').readAsString(),
    filename: 'skill.json',
  );
  final http = AgentHttp();
  final runner = AgentExtensions(http, AgentScripts());
  Future<Json> call(String name, Json args) => runner.execute(
    skill,
    object(skill.tools.singleWhere((tool) => tool['name'] == name)['handler']),
    {
      'args': args,
      'scope': 'installation-probe',
      'chatKey': 'setup-only:no-qq-recipient',
      'caller': {
        'id': 'setup-probe-user',
        'name': '安装检查',
        'messageId': 'setup-readonly-1',
        'text': '唱一下唯一',
      },
    },
    active: () => true,
  );
  try {
    final health = object(
      jsonDecode(text((await call('rvc_cover_health', {}))['text'])),
    );
    if (health['ok'] != true || health['device'] != 'cpu') {
      throw const AgentException('本地翻唱服务未能按真实 Skill 契约连接。');
    }
    final models = object(
      jsonDecode(text((await call('rvc_cover_models', {}))['text'])),
    );
    if ((models['items'] as List).isEmpty) {
      final blocked = await call('rvc_cover_start', {
        'song': 'no-fixture-song',
        'model': 'no-user-model',
      });
      if (blocked['isError'] != true) {
        throw const AgentException('缺少音色时错误地接受了翻唱任务。');
      }
    }
    final searchResult = await call('rvc_cover_search_qq', {'query': '唯一'});
    if (searchResult['isError'] == true) {
      throw AgentException(text(searchResult['text']));
    }
    final search = object(jsonDecode(text(searchResult['text'])));
    final choices = (search['candidates'] as List).map(object).toList();
    if (choices.length < 2 || search['needs_selection'] != true) {
      throw const AgentException('当前搜索未返回可核验的多版本歌曲列表。');
    }
    final blocked = await call('rvc_cover_select_qq', {
      'search_id': search['search_id'],
    });
    if (blocked['isError'] != true) {
      throw const AgentException('多版本搜索后在同一条消息内被错误地确认导入。');
    }
    stdout.writeln(
      jsonEncode({
        'skill': skill.id,
        'tools': skill.tools.length,
        'serviceConnected': true,
        'canCover': health['canCover'],
        'missing': health['missing'],
        'models': (models['items'] as List).length,
        'realQqMessagesSent': 0,
        'searchCandidates': choices
            .map((row) => {'name': row['name'], 'singer': row['singer']})
            .toList(),
        'sameTurnSelectionBlocked': true,
        'songDownloadsStarted': 0,
      }),
    );
  } finally {
    http.close();
  }
}
