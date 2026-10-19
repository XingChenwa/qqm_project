// Synthetic offline QA only; never contacts QQ or uses a real bot credential.
import 'package:qq_bot_manager/services/api_service.dart';

class ServerFixtureApi extends ApiService {
  final approvals = <Map<String, dynamic>>[];
  final recalls = <String>[];
  final mutes = <String, String>{};
  @override
  Future<ApiResult<AccessTokenResult>> getAccessToken({
    required String appId,
    required String clientSecret,
  }) async => ApiResult.success(
    AccessTokenResult(accessToken: 'offline-qa-token', expiresIn: 7200),
  );
  @override
  Future<ApiResult<Map<String, dynamic>>> getBotProfile({
    required String baseUrl,
    required String accessToken,
  }) async => ApiResult.success({'username': '离线测试机器人'});
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.success({
    'group_openid': groupId,
    'group_name': '机器人开发交流群',
    'group_member_num': 123,
    'group_finger_memo': '仅供离线自动测试',
    'group_class_text': '兴趣',
    'group_tags': ['测试', '开发'],
  });
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupBotState({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.success({
    'member_openid': 'qa-bot',
    'member_role': 'admin',
    'recv_msg_setting': 'all',
    'allow_proactive_msg': true,
    'joined_at': '2026-10-01T00:00:00+08:00',
  });
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMembers({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    String cursor = '',
  }) async => ApiResult.success({
    'members': [member(cursor.isEmpty ? 'member-a' : 'member-b')],
    'next_cursor': cursor.isEmpty ? 'fixture-page-2' : '',
  });
  Map<String, dynamic> member(String id) => {
    'member_openid': id,
    'username': id == 'member-a' ? '薯条同学' : '测试群主',
    'member_role': id == 'member-a' ? 'member' : 'owner',
    'bot': false,
    'joined_at': '2026-10-01T00:00:00+08:00',
  };
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMemberInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
  }) async => ApiResult.success(member(memberId));
  Map<String, dynamic> joinRequest(String group, {bool next = false}) => {
    'group_openid': group,
    'member_openid': next ? 'applicant-b' : 'applicant-a',
    'join_request_id': next ? 'fixture-request-2' : 'fixture-request-1',
    'username': next ? '申请人乙' : '申请人甲',
    'apply_at': '2026-10-20T10:00:00+08:00',
    'risk_tips': '离线安全提示',
    'verify_info': {
      'method': 'verify_message',
      'verify_message': '这是离线测试的申请内容',
    },
  };
  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupJoinRequests({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    String cursor = '',
    int limit = 20,
  }) async => ApiResult.success({
    'list': [joinRequest(groupId, next: cursor.isNotEmpty)],
    'next_cursor': cursor.isEmpty ? 'fixture-request-page-2' : '',
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
  }) async {
    approvals.add({
      'group': groupId,
      'member': memberId,
      'requestId': requestId,
      'approve': approve,
      'blacklist': blacklist,
    });
    return ApiResult.success(true);
  }

  @override
  Future<ApiResult<Map<String, dynamic>>> getGroupMuteSettings({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) async => ApiResult.success({
    'global_rule': {'mode': 'none'},
    'members': [
      for (final value in mutes.entries)
        {
          'member_openid': value.key,
          'username': '薯条同学',
          'mute_expire_at': value.value,
        },
    ],
  });
  @override
  Future<ApiResult<bool>> setGroupMemberMute({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
    required String operation,
    DateTime? expiresAt,
  }) async {
    if (operation == 'del') {
      mutes.remove(memberId);
    } else {
      mutes[memberId] = expiresAt!.toUtc().toIso8601String();
    }
    return ApiResult.success(true);
  }

  @override
  Future<ApiResult<bool>> recallMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String messageId,
    bool isGroup = false,
  }) async {
    recalls.add(messageId);
    return ApiResult.success(true);
  }
}
