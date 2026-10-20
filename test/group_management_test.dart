import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/core/group_management.dart';
import 'package:qq_bot_manager/models/group_notice.dart';
import 'package:qq_bot_manager/models/message.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'api_service_test.dart' show RecordingAdapter;
import 'support/fakes.dart';

class GroupFixtureApi extends RecordingApi {
  final approvals = <Map<String, dynamic>>[];
  final mutes = <Map<String, dynamic>>[];
  final removals = <Map<String, dynamic>>[];
  String botRole = 'admin', memberRole = 'member';
  String? returnedMemberId;
  bool memberIsBot = false, failRemoval = false;
  Completer<ApiResult<bool>>? delayedRemoval;
  int botStateCalls = 0;
  Completer<ApiResult<Map<String, dynamic>>>? delayedState;
  Completer<ApiResult<bool>>? delayedApproval;
  bool failApproval = false;
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.success({
    'group_openid': groupId,
    'group_name': '测试群',
    'group_member_num': 123,
    'group_finger_memo': '群简介',
    'group_tags': ['阅读'],
  });
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupBotState({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) {
    botStateCalls++;
    return delayedState?.future ??
        Future.value(
          ApiResult.success({
            'member_role': botRole,
            'member_openid': 'fixture-bot',
            'recv_msg_setting': 'all',
            'allow_proactive_msg': true,
          }),
        );
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMuteSettings({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.success({
    'global_rule': {'mode': 'none'},
    'members': [],
  });
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMembers({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    String cursor = '',
  }) async => ApiResult.success({
    'members': [
      {
        'member_openid': cursor.isEmpty ? 'm1' : 'm2',
        'username': '群成员',
        'member_role': 'member',
        'bot': false,
      },
    ],
    'next_cursor': cursor.isEmpty ? 'page2' : '',
  });
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMemberInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
  }) async => ApiResult.success({
    'member_openid': returnedMemberId ?? memberId,
    'username': '群成员',
    'member_role': memberRole,
    'bot': memberIsBot,
  });
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupJoinRequests({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    String cursor = '',
    int limit = 20,
  }) async => ApiResult.success({
    'list': [joinBody()],
    'next_cursor': cursor.isEmpty ? 'next-request-page' : '',
  });
  @override
  Future<ApiResult<bool>> approveGroupJoinRequest({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
    required String requestId,
    required bool approve,
    String reason = '',
    bool blacklist = false,
  }) {
    approvals.add({
      'group': groupId,
      'member': memberId,
      'requestId': requestId,
      'approve': approve,
      'reason': reason,
      'blacklist': blacklist,
    });
    return delayedApproval?.future ??
        Future.value(
          failApproval ? ApiResult.failure('无管理员权限') : ApiResult.success(true),
        );
  }

  @override
  Future<ApiResult<bool>> setGroupMemberMute({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
    required String operation,
    DateTime? expiresAt,
  }) async {
    mutes.add({'group': groupId, 'member': memberId, 'op': operation});
    return ApiResult.success(true);
  }

  @override
  Future<ApiResult<bool>> removeGroupMembers({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required List<String> memberIds,
  }) {
    removals.add({
      'group': groupId,
      'members': List.of(memberIds),
      'token': accessToken,
    });
    return delayedRemoval?.future ??
        Future.value(
          failRemoval
              ? ApiResult.failure('应用无接口访问权限：11253')
              : ApiResult.success(true),
        );
  }
}

Map<String, dynamic> joinBody({String request = 'request1'}) => {
  'group_openid': 'g',
  'member_openid': 'm1',
  'join_request_id': request,
  'username': '新成员',
  'apply_at': '2026-10-20T10:00:00+08:00',
  'risk_tips': '安全提示',
  'verify_info': {
    'method': 'admin_review_qa',
    'review_qa_list': [
      {'question': '问题', 'answer': '答案'},
    ],
  },
};

void main() {
  group('官方群管理请求契约', () {
    late RecordingAdapter adapter;
    late ApiService api;
    setUp(() {
      adapter = RecordingAdapter()..response = <String, dynamic>{};
      api = ApiService(
        dio: Dio(BaseOptions(validateStatus: (_) => true))
          ..httpClientAdapter = adapter,
      );
    });
    const base = 'https://api.bot.qq.com', token = 'fixture-token';
    test('移除使用官方POST单人列表、路径编码且不拉黑，只有明确success才成功', () async {
      adapter.response = {
        'remove_members_result': 'success',
        'add_to_member_blacklist_fail_openids': [],
      };
      final result = await api.removeGroupMembers(
        baseUrl: base,
        accessToken: token,
        groupId: 'g/path',
        memberIds: ['m'],
      );
      expect(result.isSuccess, true);
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(
        request.path,
        endsWith('/v2/groups/g%2Fpath/batch_remove_members'),
      );
      expect(request.headers['Authorization'], 'QQBot $token');
      expect(request.followRedirects, false);
      expect(request.data, {
        'member_openids': ['m'],
        'add_to_member_blacklist': false,
      });
      adapter.response = {'remove_members_result': 'failed'};
      expect(
        (await api.removeGroupMembers(
          baseUrl: base,
          accessToken: token,
          groupId: 'g',
          memberIds: ['m'],
        )).isSuccess,
        false,
      );
      adapter.response = {'err_code': 11253, 'message': '应用无接口访问权限'};
      final denied = await api.removeGroupMembers(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
        memberIds: ['m'],
      );
      expect(denied.isSuccess, false);
      expect(denied.errorCode, 11253);
      for (final ids in [
        <String>[],
        [''],
        ['m', 'm'],
        List.generate(21, (i) => 'm$i'),
      ]) {
        expect(
          (await api.removeGroupMembers(
            baseUrl: base,
            accessToken: token,
            groupId: 'g',
            memberIds: ids,
          )).isSuccess,
          false,
        );
      }
      expect(adapter.requests.length, 3);
    });
    test('列表分页使用 GET 查询参数，AppID Token 仅发送至官方地址', () async {
      await api.getGroupMembers(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
        cursor: 'next+/=',
      );
      await api.getGroupJoinRequests(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
        cursor: 'cursor2',
        limit: 50,
      );
      await api.getGroupMuteSettings(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
      );
      await api.getGroupBotState(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
      );
      expect(adapter.requests.map((r) => r.method), everyElement('GET'));
      expect(adapter.requests.first.queryParameters['cursor'], 'next+/=');
      expect(adapter.requests[1].queryParameters, {
        'cursor': 'cursor2',
        'limit': 50,
      });
      expect(
        adapter.requests.map((r) => r.headers['Authorization']),
        everyElement('QQBot $token'),
      );
      expect(
        adapter.requests.map((r) => r.followRedirects),
        everyElement(false),
      );
      expect(
        (await api.getGroupJoinRequests(
          baseUrl: base,
          accessToken: token,
          groupId: 'g',
          limit: 51,
        )).isSuccess,
        isFalse,
      );
      expect(adapter.requests.length, 4);
    });
    test('审核回传申请ID，拒绝与群黑名单操作不能混淆', () async {
      expect(
        (await api.approveGroupJoinRequest(
          baseUrl: base,
          accessToken: token,
          groupId: 'g',
          memberId: 'm',
          requestId: 'rid',
          approve: true,
        )).isSuccess,
        isTrue,
      );
      expect(adapter.requests.last.data, {
        'op': 'approve',
        'join_request_id': 'rid',
      });
      await api.approveGroupJoinRequest(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
        memberId: 'm',
        requestId: 'rid',
        approve: false,
        reason: '理由',
      );
      expect(adapter.requests.last.data, {
        'op': 'decline',
        'join_request_id': 'rid',
        'reject_reason': '理由',
        'add_to_member_blacklist': false,
      });
      await api.approveGroupJoinRequest(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
        memberId: 'm',
        requestId: 'rid',
        approve: false,
        blacklist: true,
      );
      expect(adapter.requests.last.data['add_to_member_blacklist'], isTrue);
      expect(
        (await api.approveGroupJoinRequest(
          baseUrl: base,
          accessToken: token,
          groupId: 'g',
          memberId: 'm',
          requestId: '',
          approve: true,
        )).isSuccess,
        isFalse,
      );
      expect(adapter.requests.length, 3);
    });
    test('禁言限制30天并使用add/update/del与RFC3339；撤回路径编码', () async {
      await api.setGroupMemberMute(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
        memberId: 'm',
        operation: 'add',
        expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      );
      final body = (adapter.requests.last.data['members'] as List).single;
      expect(body['op'], 'add');
      expect(DateTime.parse(body['mute_expire_at']).isUtc, isTrue);
      await api.setGroupMemberMute(
        baseUrl: base,
        accessToken: token,
        groupId: 'g',
        memberId: 'm',
        operation: 'del',
      );
      expect(adapter.requests.last.data['members'], [
        {'op': 'del', 'member_openid': 'm', 'mute_expire_at': ''},
      ]);
      expect(
        (await api.setGroupMemberMute(
          baseUrl: base,
          accessToken: token,
          groupId: 'g',
          memberId: 'm',
          operation: 'add',
          expiresAt: DateTime.now().add(const Duration(days: 31)),
        )).isSuccess,
        isFalse,
      );
      expect(adapter.requests.length, 2);
      await api.recallMessage(
        baseUrl: base,
        accessToken: token,
        targetId: 'g/path',
        messageId: 'id/path',
        isGroup: true,
      );
      expect(adapter.requests.last.method, 'DELETE');
      expect(
        adapter.requests.last.uri.toString(),
        contains('/groups/g%2Fpath/messages/id%2Fpath'),
      );
    });
    test('HTTP200业务错误仍失败并保留权限和超时错误码', () async {
      adapter.response = {'err_code': 40062003, 'message': 'no permission'};
      final result = await api.recallMessage(
        baseUrl: base,
        accessToken: token,
        targetId: 'g',
        messageId: 'm',
        isGroup: true,
      );
      expect(result.isSuccess, isFalse);
      expect(result.errorCode, 40062003);
      expect(result.error, contains('管理员'));
    });
  });

  group('群事件、审核与多机器人隔离', () {
    late MemoryStorage storage;
    late GroupFixtureApi api;
    late TestGateway gateway;
    late BotClient bot;
    setUp(() {
      storage = MemoryStorage(config: validConfig());
      api = GroupFixtureApi();
      gateway = TestGateway();
      bot = BotClient(storage, apiService: api, webSocketService: gateway);
    });
    tearDown(() async {
      await bot.groups.flush();
      bot.dispose();
    });
    test('群事件与聊天分开，重连回放去重，自动通过事件不再展示审核按钮', () async {
      final received = <GroupNotice>[];
      final sub = bot.groups.events.listen(received.add);
      addTearDown(sub.cancel);
      gateway.onDispatch!('GROUP_JOIN_REQUEST', joinBody());
      gateway.onDispatch!('GROUP_JOIN_REQUEST', joinBody());
      gateway.onDispatch!('GROUP_MEMBER_ADD', {
        'group_openid': 'g',
        'member_openid': 'm1',
        'timestamp': 1792454400,
      });
      gateway.onDispatch!('GROUP_MEMBER_REMOVE', {
        'group_openid': 'g',
        'member_openid': 'm1',
        'timestamp': 1792454401,
      });
      gateway.onDispatch!('GROUP_JOIN_REQUEST', {
        ...joinBody(request: 'auto'),
        'auto_approved': {'strategy_id': 'strategy'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(bot.messages, isEmpty);
      expect(bot.groups.notices.length, 4);
      expect(received.length, 4);
      expect(bot.groups.notices.where((n) => n.pending).length, 1);
      expect(
        bot.groups.notices.firstWhere((n) => n.requestId == 'auto').status,
        'auto_approved',
      );
      final notice = bot.groups.notices.firstWhere((n) => n.pending);
      expect(
        (notice.details['verify_info']['review_qa_list'] as List)
            .single['answer'],
        '答案',
      );
      expect(bot.groups.unreadCount, 4);
      bot.groups.markAllRead();
      expect(bot.groups.unreadCount, 0);
    });
    test('禁言和移除必须重新获取角色，不能信任缓存的管理员身份', () async {
      final target = bot.groups.target('g');
      await bot.groups.loadBotState(target);
      api.botRole = 'member';
      await expectLater(
        bot.groups.removeMember(target, 'm1'),
        throwsA(isA<GroupApiException>()),
      );
      await expectLater(
        bot.groups.setMemberMute(target, 'm1', operation: 'del'),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.removals, isEmpty);
      expect(api.mutes, isEmpty);
      api.botRole = 'admin';
      for (final role in ['owner', 'admin', '']) {
        api.memberRole = role;
        await expectLater(
          bot.groups.removeMember(target, 'm1'),
          throwsA(isA<GroupApiException>()),
        );
      }
      api.memberRole = 'member';
      api.memberIsBot = true;
      await expectLater(
        bot.groups.removeMember(target, 'm1'),
        throwsA(isA<GroupApiException>()),
      );
      api.memberIsBot = false;
      api.returnedMemberId = 'another-member';
      await expectLater(
        bot.groups.removeMember(target, 'm1'),
        throwsA(isA<GroupApiException>()),
      );
      api.returnedMemberId = null;
      await expectLater(
        bot.groups.removeMember(target, 'fixture-bot'),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.removals, isEmpty);
      await bot.groups.removeMember(target, 'm1');
      expect(api.removals.single['members'], ['m1']);
    });
    test('移除不重复提交，失败不伪造成功，切换后旧菜单不能移除另一机器人成员', () async {
      final target = bot.groups.target('g');
      api.delayedRemoval = Completer();
      final first = bot.groups.removeMember(target, 'm1');
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        bot.groups.removeMember(target, 'm1'),
        throwsA(isA<GroupApiException>()),
      );
      await expectLater(
        bot.groups.setMemberMute(target, 'm1', operation: 'del'),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.removals.length, 1);
      api.delayedRemoval!.complete(ApiResult.failure('11253 未授权'));
      await expectLater(first, throwsA(isA<GroupApiException>()));
      api.delayedRemoval = null;
      api.failRemoval = true;
      await expectLater(
        bot.groups.removeMember(target, 'm1'),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.removals.length, 2);
      await bot.updateConfig(validConfig()..appId = 'another-app');
      await expectLater(
        bot.groups.removeMember(target, 'm1'),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.removals.length, 2);
    });
    test('审核请求只执行一次，成功后再同步不会恢复为待处理', () async {
      gateway.onDispatch!('GROUP_JOIN_REQUEST', joinBody());
      final notice = bot.groups.notices.single;
      api.delayedApproval = Completer();
      final first = bot.groups.approve(notice, approve: false, reason: '测试拒绝');
      await Future<void>.delayed(Duration.zero);
      await expectLater(
        bot.groups.approve(notice, approve: true),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.approvals.single['requestId'], 'request1');
      expect(api.approvals.single['blacklist'], isFalse);
      api.delayedApproval!.complete(ApiResult.success(true));
      await first;
      expect(bot.groups.notices.single.status, 'declined');
      await bot.groups.syncRequests(bot.groups.target('g'));
      expect(bot.groups.notices.single.pending, isFalse);
      expect(bot.groups.notices.single.isRead, isTrue);
    });
    test('平台拒绝审核时仍保留待处理，不伪造已同意', () async {
      gateway.onDispatch!('GROUP_JOIN_REQUEST', joinBody());
      api.failApproval = true;
      await expectLater(
        bot.groups.approve(bot.groups.notices.single, approve: true),
        throwsA(isA<GroupApiException>()),
      );
      expect(bot.groups.notices.single.pending, isTrue);
      expect(bot.groups.notices.single.isRead, isFalse);
    });
    test('同一个群和申请ID按AppID隔离，切换后不能误批另一机器人', () async {
      gateway.onDispatch!('GROUP_JOIN_REQUEST', joinBody());
      final aNotice = bot.groups.notices.single;
      await bot.groups.flush();
      final aId = bot.config.appId;
      await bot.updateConfig(validConfig()..appId = 'another-app');
      expect(bot.groups.notices, isEmpty);
      await expectLater(
        bot.groups.approve(aNotice, approve: true),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.approvals, isEmpty);
      gateway.onDispatch!('GROUP_JOIN_REQUEST', joinBody());
      await bot.groups.flush();
      expect(bot.groups.notices.single.appId, 'another-app');
      await bot.switchBot(aId);
      expect(bot.groups.notices.single.appId, aId);
    });
    test('异步资料跨机器人／凭据世代返回时丢弃，旧页面不能发起请求', () async {
      final target = bot.groups.target('g');
      api.delayedState = Completer();
      final pending = bot.groups.loadBotState(target);
      await Future<void>.delayed(Duration.zero);
      await bot.updateConfig(validConfig()..clientSecret = 'rotated-secret');
      api.delayedState!.complete(ApiResult.success({'member_role': 'admin'}));
      await expectLater(pending, throwsA(isA<GroupApiException>()));
      expect(bot.groups.botState('g'), isNull);
      await expectLater(
        bot.groups.loadBotState(target),
        throwsA(isA<GroupApiException>()),
      );
      expect(api.botStateCalls, 1);
    });
    test('群管理员可撤回普通成员2分钟内消息；管理员、群主与过期消息仍不可撤回', () async {
      storage.storedSessions['g'] = ChatSession(
        id: 'g',
        name: '群',
        sessionType: 1,
        lastMessageTime: DateTime.now(),
      );
      bot.refresh();
      MessageModel message(String role, {bool expired = false}) => MessageModel(
        id: 'msg',
        sessionId: 'g',
        senderId: 'm',
        senderName: '成员',
        senderRole: role,
        content: '内容',
        messageType: 0,
        timestamp: DateTime.now().subtract(Duration(minutes: expired ? 3 : 1)),
      );
      expect(bot.canRecallMessage(message('member')), isFalse);
      await bot.groups.loadBotState(bot.groups.target('g'));
      expect(bot.canRecallMessage(message('member')), isTrue);
      expect(bot.canRecallMessage(message('owner')), isFalse);
      expect(bot.canRecallMessage(message('admin')), isFalse);
      expect(bot.canRecallMessage(message('member', expired: true)), isFalse);
    });
    test('屏蔽会话保留收消息和插件处理，但不产生提醒和未读数，按机器人保存', () async {
      await bot.addSession('g', isGroup: true, name: '群');
      await bot.setSessionMuted('g', true);
      final incoming = <MessageModel>[];
      final sub = bot.incomingNotices.listen(incoming.add);
      addTearDown(sub.cancel);
      var pluginCalls = 0;
      bot.onMessageReceived = (_) async {
        pluginCalls++;
        return true;
      };
      gateway.events.add({
        'id': 'msg',
        'sessionId': 'g',
        'senderId': 'm',
        'senderName': '成员',
        'isGroup': true,
        'content': '/测试',
        'timestamp': DateTime.now(),
        'eventType': 'GROUP_AT_MESSAGE_CREATE',
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      gateway.onDispatch!('GROUP_MEMBER_ADD', {
        'group_openid': 'g',
        'member_openid': 'm',
        'timestamp': 1792454400,
      });
      expect(bot.messages.length, 1);
      expect(incoming, isEmpty);
      expect(pluginCalls, 1);
      expect(bot.sessions.single.isMuted, isTrue);
      expect(bot.sessions.single.unreadCount, 0);
      expect(bot.groups.unreadCount, 0);
      final aId = bot.config.appId;
      await bot.updateConfig(validConfig()..appId = 'another-app');
      await bot.addSession('g', isGroup: true);
      expect(bot.sessions.single.isMuted, isFalse);
      await bot.switchBot(aId);
      expect(bot.sessions.single.isMuted, isTrue);
    });
  });
}
