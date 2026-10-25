import 'models.dart';
import 'extensions.dart';

List<AgentPreset> agentPresets() => [
  AgentPreset(
    id: 'assistant',
    name: '日常助手',
    prompt: '用简洁、自然的中文回答，先说明结论。信息不足时坦诚说明，需要时询问关键条件。',
  ),
  AgentPreset(
    id: 'friendly',
    name: '轻松群友',
    prompt: '像友善的群友一样聊天，短句、自然、有分寸。不要每条都重复自我介绍，不打断他人，不编造事实。',
  ),
  AgentPreset(
    id: 'developer',
    name: '编程助手',
    prompt: '帮助理解和改进代码。先定位问题，给出可复现的步骤和必要的代码示例；不编造测试结果。',
  ),
  AgentPreset(
    id: 'translator',
    name: '双语翻译',
    prompt: '把中文翻译成自然英文，把其他语言翻译成简体中文。默认只输出译文，保留专有名词和格式。',
  ),
];
List<AgentExtension> agentExamples() => [
  AgentExtension({
    'schema': 1,
    'id': 'hello',
    'name': '问候命令',
    'kind': 'plugin',
    'description': '输入 /hello，直接回复，不消耗 AI 调用。',
    'commands': [
      {
        'prefix': '/hello',
        'handler': {
          'type': 'template',
          'text': '你好，{{sender.name}}！我是独立的 QQ Agent。',
        },
      },
    ],
  }),
  AgentExtension({
    'schema': 1,
    'id': 'clock',
    'name': '当前时间',
    'kind': 'skill',
    'description': '让 AI 查询设备当前时间。',
    'prompt': '用户问当前时间时，调用 current_time；说明这是运行设备的时间。',
    'tools': [
      {
        'name': 'current_time',
        'description': '获取 Agent 所在设备当前的日期和时间',
        'parameters': {
          'type': 'object',
          'properties': <String, dynamic>{},
          'additionalProperties': false,
        },
        'handler': {'type': 'time'},
      },
    ],
  }),
  AgentExtension({
    'schema': 1,
    'id': 'concise',
    'name': '简洁回答',
    'kind': 'skill',
    'description': '纯提示词 Skill 示例。',
    'prompt': '默认在三句话以内回答；用户明确要求细节时再展开。',
    'tools': <Json>[],
  }),
  AgentExtension({
    'schema': 1,
    'id': 'script_echo',
    'name': '脚本示例',
    'kind': 'plugin',
    'description': '/echo 内容：在独立沙箱运行 Hetu 脚本。',
    'commands': [
      {
        'prefix': '/echo',
        'handler': {
          'type': 'script',
          'source':
              'external fun json_decode(value)\nexternal fun json_encode(value)\n'
              'fun run(input) {\n  final event = json_decode(input)\n'
              '  return json_encode({text: event.args.text})\n}\n',
        },
      },
    ],
  }),
];
