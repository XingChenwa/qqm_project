import 'dart:async';

import '../models/group_notice.dart';
import '../services/api_service.dart';
import '../services/storage_service.dart';

typedef GroupRequester =
    Future<ApiResult<T>> Function<T>(
      GroupTarget target,
      Future<ApiResult<T>> Function(String token, String baseUrl) action,
    );

class GroupApiException implements Exception {
  final String message;
  const GroupApiException(this.message);
  @override
  String toString() => message;
}

/// Same control plane for native clients and the Linux web service. A target
/// binds every asynchronous read/write to both AppID and credential generation.
class GroupManagement {
  final StorageService storage;
  final ApiService api;
  final GroupRequester request;
  final String Function() appId;
  final int Function() epoch;
  final bool Function(String) muted;
  final String Function(String, String) memberName;
  final void Function() changed;
  final void Function(String) log;
  final _events = StreamController<GroupNotice>.broadcast();
  final _info = <String, Map<String, dynamic>>{};
  final _botState = <String, Map<String, dynamic>>{};
  final _mute = <String, Map<String, dynamic>>{};
  final _errors = <String, String>{};
  final _busy = <String>{};
  List<GroupNotice> _notices = [];
  final _accountNotices = <String, List<GroupNotice>>{};
  String _scope = '';
  bool _disposed = false;
  Future<void> _writes = Future.value();
  GroupManagement({
    required this.storage,
    required this.api,
    required this.request,
    required this.appId,
    required this.epoch,
    required this.muted,
    required this.memberName,
    required this.changed,
    required this.log,
  });

  Stream<GroupNotice> get events => _events.stream;
  String get _currentScope => '${appId()}:${epoch()}';
  void syncScope() {
    if (_scope == _currentScope) return;
    _scope = _currentScope;
    _info.clear();
    _botState.clear();
    _mute.clear();
    _errors.clear();
    _busy.clear();
    _notices = List.of(
      _accountNotices[appId()] ?? storage.getGroupNotices(appId()),
    );
  }

  GroupTarget target(String groupId) => GroupTarget(appId(), groupId, epoch());
  bool isCurrent(GroupTarget target) =>
      !_disposed && target.appId == appId() && target.epoch == epoch();
  List<GroupNotice> get notices {
    syncScope();
    return List.unmodifiable(
      [..._notices]..sort((a, b) => b.time.compareTo(a.time)),
    );
  }

  int get unreadCount => notices
      .where((notice) => !notice.isRead && !muted(notice.groupId))
      .length;
  Map<String, dynamic>? info(String group) {
    syncScope();
    return _info[group];
  }

  Map<String, dynamic>? botState(String group) {
    syncScope();
    return _botState[group];
  }

  Map<String, dynamic>? muteSettings(String group) {
    syncScope();
    return _mute[group];
  }

  String? error(String kind, String group) {
    syncScope();
    return _errors['$kind:$group'];
  }

  bool get isSaving => _busy.isNotEmpty;
  bool isAdministrator(String group) =>
      ['owner', 'admin'].contains(botState(group)?['member_role']);

  void ingest(String type, Map<String, dynamic> body, {bool emit = true}) {
    if (_disposed) return;
    syncScope();
    var notice = GroupNotice.fromEvent(
      appId(),
      type,
      body,
      fallbackName: memberName(
        groupText(body['group_openid']),
        groupText(body['member_openid']),
      ),
    );
    if (notice == null) return;
    final existing = _notices
        .where((item) => item.id == notice!.id)
        .firstOrNull;
    if (existing != null) {
      // Replayed gateway events and paginated list refreshes never revive an
      // approval already handled by the user, or generate duplicate OS alerts.
      if (notice.status == 'auto_approved' && existing.pending) {
        _replace(existing.copyWith(status: 'auto_approved'));
      }
      return;
    }
    if (muted(notice.groupId)) notice = notice.copyWith(isRead: true);
    _notices.add(notice);
    _info.remove(notice.groupId);
    _persist();
    if (emit) _events.add(notice);
    changed();
  }

  void _persist() {
    final account = appId();
    final snapshot = [..._notices]
      ..sort(
        (a, b) => a.pending != b.pending
            ? (a.pending ? -1 : 1)
            : b.time.compareTo(a.time),
      );
    _notices = snapshot.take(500).toList();
    _accountNotices[account] = List.of(_notices);
    _writes = _writes
        .then(
          (_) => storage.saveGroupNotices(account, snapshot.take(500).toList()),
        )
        .catchError((Object _) {
          log('群通知本地保存失败，现有聊天数据未清除');
        });
  }

  void _replace(GroupNotice notice) {
    final index = _notices.indexWhere((item) => item.id == notice.id);
    if (index < 0) return;
    _notices[index] = notice;
    _persist();
    changed();
  }

  void markRead(String id) {
    syncScope();
    final notice = _notices.where((value) => value.id == id).firstOrNull;
    if (notice != null && !notice.isRead) {
      _replace(notice.copyWith(isRead: true));
    }
  }

  void markAllRead() {
    syncScope();
    _notices = _notices.map((item) => item.copyWith(isRead: true)).toList();
    _persist();
    changed();
  }

  Future<Map<String, dynamic>> _read(
    GroupTarget target,
    String kind,
    Future<ApiResult<Map<String, dynamic>>> Function(String, String) action,
  ) async {
    syncScope();
    final result = await request<Map<String, dynamic>>(target, action);
    if (!isCurrent(target)) throw const GroupApiException('机器人已切换，请重新打开此页面');
    if (!result.isSuccess || result.data == null) {
      final message = result.error ?? '平台未返回数据';
      _errors['$kind:${target.groupId}'] = message;
      changed();
      throw GroupApiException(message);
    }
    _errors.remove('$kind:${target.groupId}');
    return result.data!;
  }

  Future<Map<String, dynamic>> loadInfo(GroupTarget target) async {
    final value = await _read(
      target,
      'info',
      (token, base) => api.getGroupInfo(
        baseUrl: base,
        accessToken: token,
        groupId: target.groupId,
      ),
    );
    _info[target.groupId] = value;
    changed();
    return value;
  }

  Future<Map<String, dynamic>> loadBotState(GroupTarget target) async {
    final value = await _read(
      target,
      'bot',
      (token, base) => api.getGroupBotState(
        baseUrl: base,
        accessToken: token,
        groupId: target.groupId,
      ),
    );
    _botState[target.groupId] = value;
    changed();
    return value;
  }

  Future<Map<String, dynamic>> loadMute(GroupTarget target) async {
    final value = await _read(
      target,
      'mute',
      (token, base) => api.getGroupMuteSettings(
        baseUrl: base,
        accessToken: token,
        groupId: target.groupId,
      ),
    );
    _mute[target.groupId] = value;
    changed();
    return value;
  }

  Future<Map<String, dynamic>> members(
    GroupTarget target, {
    String cursor = '',
  }) => _read(
    target,
    'members',
    (token, base) => api.getGroupMembers(
      baseUrl: base,
      accessToken: token,
      groupId: target.groupId,
      cursor: cursor,
    ),
  );
  Future<Map<String, dynamic>> member(GroupTarget target, String memberId) =>
      _read(
        target,
        'member',
        (token, base) => api.getGroupMemberInfo(
          baseUrl: base,
          accessToken: token,
          groupId: target.groupId,
          memberId: memberId,
        ),
      );
  Future<String> syncRequests(GroupTarget target, {String cursor = ''}) async {
    final data = await _read(
      target,
      'requests',
      (token, base) => api.getGroupJoinRequests(
        baseUrl: base,
        accessToken: token,
        groupId: target.groupId,
        cursor: cursor,
      ),
    );
    final rows = data['list'];
    if (rows is! List) throw const GroupApiException('平台返回的申请列表格式异常');
    for (final row in rows.whereType<Map>()) {
      ingest('GROUP_JOIN_REQUEST', {
        ...Map<String, dynamic>.from(row),
        'group_openid': target.groupId,
      }, emit: false);
    }
    return groupText(data['next_cursor']);
  }

  Future<void> approve(
    GroupNotice notice, {
    required bool approve,
    String reason = '',
    bool blacklist = false,
  }) async {
    syncScope();
    final current = _notices.where((item) => item.id == notice.id).firstOrNull;
    if (notice.appId != appId() || current == null || !current.pending) {
      throw const GroupApiException('此申请不属于当前机器人或已处理，请刷新列表');
    }
    final ref = target(current.groupId);
    final key = '$_currentScope:approval:${notice.id}';
    if (!_busy.add(key)) throw const GroupApiException('此申请正在处理，请勿重复操作');
    changed();
    try {
      final result = await request<bool>(
        ref,
        (token, base) => api.approveGroupJoinRequest(
          baseUrl: base,
          accessToken: token,
          groupId: ref.groupId,
          memberId: current.memberId,
          requestId: current.requestId,
          approve: approve,
          reason: reason,
          blacklist: blacklist,
        ),
      );
      if (!isCurrent(ref)) {
        throw const GroupApiException('机器人已切换，结果请在原机器人通知中刷新确认');
      }
      if (!result.isSuccess) throw GroupApiException(result.error ?? '审核失败');
      _replace(
        current.copyWith(
          status: approve ? 'approved' : 'declined',
          isRead: true,
        ),
      );
      log('群入群申请${approve ? '已同意' : '已拒绝'}');
    } finally {
      _busy.remove(key);
      if (!_disposed) changed();
    }
  }

  Future<void> setMemberMute(
    GroupTarget ref,
    String memberId, {
    required String operation,
    DateTime? expiresAt,
  }) async {
    syncScope();
    final key = _memberActionKey(ref, memberId);
    if (!_busy.add(key)) throw const GroupApiException('此成员的管理操作正在处理');
    try {
      await inspectModeratableMember(ref, memberId);
      final result = await request<bool>(
        ref,
        (token, base) => api.setGroupMemberMute(
          baseUrl: base,
          accessToken: token,
          groupId: ref.groupId,
          memberId: memberId,
          operation: operation,
          expiresAt: expiresAt,
        ),
      );
      if (!isCurrent(ref)) throw const GroupApiException('机器人已切换，请回原机器人刷新状态');
      if (!result.isSuccess) throw GroupApiException(result.error ?? '禁言设置失败');
      _mute.remove(ref.groupId);
      changed();
      log(operation == 'del' ? '已解除成员禁言' : '已设置成员禁言');
    } finally {
      _busy.remove(key);
    }
  }

  String _memberActionKey(GroupTarget ref, String memberId) =>
      '${ref.appId}:${ref.epoch}:moderation:${ref.groupId}:$memberId';

  /// Never elevate the bot using a message author's claimed role or a stale
  /// cache. Recheck official roles before presenting and before committing.
  Future<Map<String, dynamic>> inspectModeratableMember(
    GroupTarget ref,
    String memberId,
  ) async {
    if (!isCurrent(ref) || ref.groupId.isEmpty || memberId.trim().isEmpty) {
      throw const GroupApiException('机器人已切换或成员信息无效，请重新打开成员菜单');
    }
    final state = await loadBotState(ref);
    if (!['owner', 'admin'].contains(state['member_role'])) {
      throw const GroupApiException('机器人需要是此群的群主或管理员，才能管理群成员');
    }
    if (memberId == state['member_openid']) {
      throw const GroupApiException('不能对机器人自身执行禁言或移除');
    }
    final value = await member(ref, memberId);
    if (value['member_openid'] != memberId ||
        value['member_role'] != 'member' ||
        value['bot'] == true) {
      throw const GroupApiException('仅可管理普通群成员，不能禁言或移除群主、管理员和机器人');
    }
    return value;
  }

  Future<void> removeMember(GroupTarget ref, String memberId) async {
    syncScope();
    final key = _memberActionKey(ref, memberId);
    if (!_busy.add(key)) throw const GroupApiException('此成员的管理操作正在处理');
    try {
      await inspectModeratableMember(ref, memberId);
      final result = await request<bool>(
        ref,
        (token, base) => api.removeGroupMembers(
          baseUrl: base,
          accessToken: token,
          groupId: ref.groupId,
          memberIds: [memberId],
        ),
      );
      if (!isCurrent(ref)) {
        throw const GroupApiException('机器人已切换，请回原机器人刷新群成员确认结果');
      }
      if (!result.isSuccess || result.data != true) {
        throw GroupApiException(result.error ?? '平台未确认成员移除成功');
      }
      _info.remove(ref.groupId);
      _mute.remove(ref.groupId);
      changed();
      log('已移除群成员（未加入黑名单）');
    } finally {
      _busy.remove(key);
    }
  }

  Future<void> flush() => _writes;
  void dispose() {
    _disposed = true;
    unawaited(_events.close());
  }
}
