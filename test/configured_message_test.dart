import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/models/outgoing_message.dart';
import 'package:qq_bot_manager/services/api_service.dart';

import 'api_service_test.dart' show RecordingAdapter;
import 'support/fakes.dart';

void main() {
  late RecordingAdapter adapter;
  late ApiService api;
  setUp(() {
    adapter = RecordingAdapter();
    api = ApiService(
      dio: Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = adapter,
    );
  });

  test('Markdown + 键盘 + 图片校验 + 事件回复 + 引用一次发送，字段互斥正确', () async {
    const request = OutgoingMessage(
      type: 2,
      content: '## 每日签到',
      options: MessageSendOptions(
        replyMode: ReplyMode.event,
        eventId: 'event-id',
        referenceId: 'REFIDX_quote',
        forceVerifyImage: true,
        keyboard: MessageKeyboard(
          rows: [
            [
              MessageButton(
                id: 'sign',
                label: '签到',
                actionType: 2,
                data: '/签到',
                style: 4,
              ),
            ],
          ],
        ),
      ),
    );
    final result = await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'group',
      isGroup: true,
      message: request,
      eventId: 'event-id',
      msgSeq: 3,
    );
    expect(result.isSuccess, isTrue);
    final body = adapter.requests.single.data as Map;
    expect(body['markdown'], {
      'content': '## 每日签到',
      'force_verify_image_resource': true,
    });
    expect(
      body['keyboard']['content']['rows'][0]['buttons'][0]['render_data']['style'],
      4,
    );
    expect(body['event_id'], 'event-id');
    expect(body['msg_seq'], 3);
    expect(body['message_reference'], {'message_id': 'REFIDX_quote'});
    expect(body.containsKey('content'), isFalse);
    expect(body.containsKey('msg_id'), isFalse);
  });

  test('按钮模板短格式与自定义按钮不混用，回调分组、权限和确认弹窗完整序列化', () async {
    const button = MessageButton(
      id: 'confirm',
      label: '确认操作',
      visitedLabel: '已确认',
      style: 3,
      actionType: 1,
      data: 'action:confirm',
      permissionType: 0,
      userIds: ['user-a', 'user-b'],
      groupId: 'mutex',
      confirmContent: '确定继续操作吗？',
      confirmText: '继续',
      cancelText: '返回',
    );
    expect(button.validate(isGroup: true), isNull);
    final json = button.toJson();
    expect(json['group_id'], 'mutex');
    expect(json['action']['permission'], {
      'type': 0,
      'specify_user_ids': ['user-a', 'user-b'],
    });
    expect(json['action']['modal'], {
      'content': '确定继续操作吗？',
      'confirm_text': '继续',
      'cancel_text': '返回',
    });
    await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'group',
      isGroup: true,
      message: const OutgoingMessage(
        type: 2,
        content: '# 模板',
        options: MessageSendOptions(
          keyboard: MessageKeyboard(templateId: 'keyboard-123'),
        ),
      ),
    );
    expect(adapter.requests.single.data['keyboard'], {'id': 'keyboard-123'});
  });

  test('群聊拦截单聊专用按钮，选图 anchor 会取代自动发送参数', () async {
    const button = MessageButton(
      id: 'pick',
      label: '选图',
      data: '/图片',
      enter: true,
      reply: true,
      openImagePicker: true,
    );
    final result = await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'group',
      isGroup: true,
      message: const OutgoingMessage(
        type: 2,
        content: '# 选图',
        options: MessageSendOptions(
          keyboard: MessageKeyboard(
            rows: [
              [button],
            ],
          ),
        ),
      ),
    );
    expect(result.isSuccess, isFalse);
    expect(adapter.requests, isEmpty);
    final action = button.toJson()['action'] as Map;
    expect(action['anchor'], 1);
    expect(action['reply'], isTrue);
    expect(action.containsKey('enter'), isFalse);
  });

  test('按钮超限、重复 ID、超长确认和互斥回复字段不会发出网络请求', () async {
    final rows = List.generate(
      6,
      (index) => [MessageButton(id: 'b$index', label: '按钮', data: '/test')],
    );
    final tooMany = await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'g',
      isGroup: true,
      message: OutgoingMessage(
        type: 2,
        content: '# 测试',
        options: MessageSendOptions(keyboard: MessageKeyboard(rows: rows)),
      ),
    );
    expect(tooMany.isSuccess, isFalse);
    const duplicate = MessageKeyboard(
      rows: [
        [
          MessageButton(id: 'a', label: 'A', data: '/a'),
          MessageButton(id: 'a', label: 'B', data: '/b'),
        ],
      ],
    );
    expect(duplicate.validate(isGroup: true), contains('不能重复'));
    expect(
      const MessageButton(
        id: 'a',
        label: '操作',
        data: '/a',
        confirmContent: 'https://example.com',
      ).validate(isGroup: true),
      contains('URL'),
    );
    final conflicting = await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'g',
      message: const OutgoingMessage(content: '测试'),
      msgId: 'm',
      eventId: 'e',
    );
    expect(conflicting.isSuccess, isFalse);
    expect(adapter.requests, isEmpty);
  });

  test('视频、语音、文件使用各自 file_type 上传，再发送 file_info', () async {
    adapter.response = {'file_info': 'uploaded-info', 'id': 'media-id'};
    for (final type in [2, 3, 4]) {
      final result = await api.sendConfiguredMessage(
        baseUrl: 'https://api.bot.qq.com',
        accessToken: 'token',
        targetId: 'user',
        message: OutgoingMessage(
          type: 7,
          mediaFileType: type,
          mediaSource: 'https://example.com/media-$type',
        ),
      );
      expect(result.isSuccess, isTrue);
      expect(
        adapter.requests[adapter.requests.length - 2].data['file_type'],
        type,
      );
      expect(adapter.requests.last.data['media'], {
        'file_info': 'uploaded-info',
      });
    }
  });

  test('已有 file_info 跳过上传，发送响应的引用索引保留给后续引用', () async {
    adapter.response = {
      'id': 'sent',
      'ext_info': {'ref_idx': 'REFIDX_saved=='},
    };
    final result = await api.sendConfiguredMessage(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      targetId: 'user',
      message: const OutgoingMessage(
        type: 7,
        mediaFileType: 4,
        fileInfo: 'existing-info',
      ),
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.data['media']['file_info'], 'existing-info');
    expect(result.metadata?['ext_info']['ref_idx'], 'REFIDX_saved==');
  });

  test('引用索引从 msg_idx 提取，保持末尾等号，并可从保存响应中恢复', () {
    final userMessage = MessageModel(
      id: 'm',
      sessionId: 's',
      senderId: 'u',
      senderName: '用户',
      content: '正文',
      messageType: 0,
      timestamp: DateTime.now(),
      extra: {
        'extra': {
          'message_scene': {
            'ext': [
              'auth_token=abc',
              'msg_idx=REFIDX_user==',
              'ref_msg_idx=older',
            ],
          },
        },
      },
    );
    expect(
      MessageModel.fromMap(userMessage.toMap()).referenceIndex,
      'REFIDX_user==',
    );
  });

  test('引用机器人消息时使用 ref_idx 而非机器人消息 ID，预览不消耗序号', () async {
    final storage = MemoryStorage(config: validConfig());
    final fakeApi = RecordingApi();
    final bot = BotClient(storage, apiService: fakeApi);
    addTearDown(bot.dispose);
    final source = incoming('user-message');
    await storage.saveMessage(source);
    await bot.sendTextMessage(
      'group-1',
      '原机器人消息',
      isGroup: true,
      replyTo: source,
    );
    final quote = bot.messages.single;
    const request = OutgoingMessage(type: 2, content: '# 引用自己的消息');
    final first = bot.previewConfiguredMessage(
      'group-1',
      request,
      isGroup: true,
      replyTo: quote,
    );
    final second = bot.previewConfiguredMessage(
      'group-1',
      request,
      isGroup: true,
      replyTo: quote,
    );
    expect(first['msg_seq'], 2);
    expect(second['msg_seq'], 2);
    expect(first['message_reference']['message_id'], 'REFIDX_sent-1');
    expect(
      await bot.sendConfiguredMessage(
        'group-1',
        request,
        isGroup: true,
        replyTo: quote,
      ),
      isTrue,
    );
    expect(fakeApi.calls.last['msgId'], 'user-message');
    expect(fakeApi.calls.last['msgSeq'], 2);
    expect(fakeApi.calls.last['referenceId'], 'REFIDX_sent-1');
    expect(bot.messages.last.referenceIndex, 'REFIDX_sent-2');
  });

  test('事件回复序号可手动指定后自动递增，主动模式不携带任何回复 ID', () async {
    final storage = MemoryStorage(config: validConfig());
    final fakeApi = RecordingApi();
    final bot = BotClient(storage, apiService: fakeApi);
    addTearDown(bot.dispose);
    const manual = OutgoingMessage(
      content: '事件回复',
      options: MessageSendOptions(
        replyMode: ReplyMode.event,
        eventId: 'event',
        sequence: 4,
      ),
    );
    const automaticSequence = OutgoingMessage(
      content: '后续回复',
      options: MessageSendOptions(replyMode: ReplyMode.event, eventId: 'event'),
    );
    expect(await bot.sendConfiguredMessage('g', manual, isGroup: true), isTrue);
    expect(
      await bot.sendConfiguredMessage('g', automaticSequence, isGroup: true),
      isTrue,
    );
    expect(fakeApi.calls.last['msgSeq'], 5);
    expect(
      await bot.sendConfiguredMessage('g', manual, isGroup: true),
      isFalse,
    );
    await storage.saveMessage(incoming('fresh', session: 'g'));
    await bot.sendConfiguredMessage(
      'g',
      const OutgoingMessage(
        content: '主动发送',
        options: MessageSendOptions(replyMode: ReplyMode.active),
      ),
      isGroup: true,
    );
    final body = fakeApi.calls.last['body'] as Map;
    expect(body.containsKey('msg_id'), isFalse);
    expect(body.containsKey('event_id'), isFalse);
    expect(body.containsKey('msg_seq'), isFalse);
  });

  test('回调自动确认仅处理 11/12 类型，回应 ID 与事件回复 ID 分别取正确字段', () async {
    final storage = MemoryStorage(config: validConfig());
    final fakeApi = RecordingApi();
    final gateway = TestGateway();
    final bot = BotClient(
      storage,
      apiService: fakeApi,
      webSocketService: gateway,
    );
    addTearDown(bot.dispose);
    final data = {
      'id': 'interaction-id',
      '_eventId': 'outer-event-id',
      'group_openid': 'g',
      'type': 11,
      'data': {
        'resolved': {'button_data': 'confirm'},
      },
    };
    gateway.onDispatch!('INTERACTION_CREATE', data);
    gateway.onDispatch!('INTERACTION_CREATE', data);
    gateway.onDispatch!('INTERACTION_CREATE', {
      ...data,
      'id': 'feedback-id',
      'type': 13,
    });
    await Future<void>.delayed(Duration.zero);
    expect(fakeApi.interactionAcks, ['interaction-id']);
    expect(bot.latestReplyEventId('g'), 'outer-event-id');
    await api.acknowledgeInteraction(
      baseUrl: 'https://api.bot.qq.com',
      accessToken: 'token',
      interactionId: 'interaction-id',
    );
    expect(adapter.requests.single.method, 'PUT');
    expect(adapter.requests.single.uri.path, '/interactions/interaction-id');
    expect(adapter.requests.single.data, {'code': 0});
  });
}
