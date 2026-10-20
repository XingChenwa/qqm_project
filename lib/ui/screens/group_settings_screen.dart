import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';

import '../../core/bot_client.dart';
import '../../models/group_notice.dart';
import '../../models/message.dart';
import '../../utils/profile_helpers.dart';
import '../widgets/app_dialogs.dart';
import '../widgets/profile_avatar.dart';
import '../widgets/group_member_actions.dart';
import 'notifications_screen.dart';

String groupDate(Object? value) {
  final time = DateTime.tryParse(groupText(value));
  return time == null
      ? '平台未提供'
      : DateFormat('yyyy-MM-dd HH:mm').format(time.toLocal());
}

String groupRole(Object? value) => switch (value) {
  'owner' => '群主',
  'admin' => '管理员',
  'member' => '普通成员',
  _ => '未知角色',
};

class GroupSettingsScreen extends StatefulWidget {
  final ChatSession session;
  const GroupSettingsScreen({super.key, required this.session});
  @override
  State<GroupSettingsScreen> createState() => _GroupSettingsScreenState();
}

class _GroupSettingsScreenState extends State<GroupSettingsScreen> {
  late final BotClient _bot;
  late final GroupTarget _target;
  bool _loading = false, _membersLoading = false, _membersLoaded = false;
  int _tab = 0;
  String _search = '', _cursor = '', _memberError = '';
  final _members = <Map<String, dynamic>>[];
  bool get _group => widget.session.sessionType == 1;
  @override
  void initState() {
    super.initState();
    _bot = context.read<BotClient>();
    _target = _bot.groups.target(widget.session.id);
    if (_group) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _overview());
    }
  }

  Future<void> _overview() async {
    if (_loading || !mounted) return;
    setState(() => _loading = true);
    await Future.wait([
      _bot.groups.loadInfo(_target).then<void>((_) {}, onError: (Object _) {}),
      _bot.groups
          .loadBotState(_target)
          .then<void>((_) {}, onError: (Object _) {}),
      _bot.groups.loadMute(_target).then<void>((_) {}, onError: (Object _) {}),
    ]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMembers({bool next = false}) async {
    if (_membersLoading) return;
    setState(() {
      _membersLoading = true;
      _memberError = '';
    });
    try {
      final oldCursor = next ? _cursor : '';
      final result = await _bot.groups.members(_target, cursor: oldCursor);
      if (!mounted || !_bot.groups.isCurrent(_target)) return;
      final rows = result['members'];
      if (rows is! List) throw StateError('平台返回的成员列表格式异常');
      final combined = <String, Map<String, dynamic>>{
        if (next)
          for (final member in _members)
            groupText(member['member_openid']): member,
        for (final member in rows.whereType<Map>())
          if (groupText(member['member_openid']).isNotEmpty)
            groupText(member['member_openid']): Map<String, dynamic>.from(
              member,
            ),
      };
      setState(() {
        _members
          ..clear()
          ..addAll(combined.values);
        _membersLoaded = true;
        final cursor = groupText(result['next_cursor']);
        _cursor = cursor == oldCursor ? '' : cursor;
      });
    } catch (error) {
      if (mounted) setState(() => _memberError = error.toString());
    } finally {
      if (mounted) setState(() => _membersLoading = false);
    }
  }

  Future<void> _memberDetails(Map<String, dynamic> summary) async {
    final id = groupText(summary['member_openid']);
    try {
      final member = await _bot.groups.member(_target, id);
      if (!mounted || !_bot.groups.isCurrent(_target)) return;
      await AppDialogs.present<void>(
        context,
        builder: (dialog) => AlertDialog(
          title: Text(
            groupText(member['username']).isEmpty
                ? id
                : groupText(member['username']),
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText('OpenID：$id'),
                  const SizedBox(height: 10),
                  Text(
                    '身份：${groupRole(member['member_role'])}${member['bot'] == true ? ' · 机器人' : ''}',
                  ),
                  Text('入群时间：${groupDate(member['joined_at'])}'),
                  if (groupText(member['union_openid']).isNotEmpty)
                    SelectableText(
                      '统一 OpenID：${groupText(member['union_openid'])}',
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('关闭'),
            ),
            if (_bot.groups.isAdministrator(_target.groupId) &&
                member['member_role'] == 'member' &&
                member['bot'] != true) ...[
              TextButton.icon(
                onPressed: () {
                  Navigator.pop(dialog);
                  GroupMemberActions.remove(context, _bot, _target, member);
                },
                icon: const Icon(Icons.person_remove_outlined),
                label: const Text('踢出群聊'),
              ),
              FilledButton(
                onPressed: () {
                  Navigator.pop(dialog);
                  _setMute(member);
                },
                child: const Text('设置禁言'),
              ),
            ],
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        await AppDialogs.show(
          context,
          error.toString(),
          title: '成员资料未获取',
          error: true,
        );
      }
    }
  }

  Future<void> _setMute(
    Map<String, dynamic> member, {
    bool remove = false,
  }) async {
    final id = groupText(member['member_openid']);
    var minutes = 10;
    final accepted = await AppDialogs.present<bool>(
      context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(remove ? '解除成员禁言？' : '设置成员禁言'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                groupText(member['username']).isEmpty
                    ? id
                    : groupText(member['username']),
              ),
              if (!remove) ...[
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: minutes,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '禁言时长'),
                  items: [
                    for (final (value, label) in [
                      (5, '5 分钟'),
                      (10, '10 分钟'),
                      (60, '1 小时'),
                      (1440, '1 天'),
                      (10080, '7 天'),
                      (43200, '30 天'),
                    ])
                      DropdownMenuItem(value: value, child: Text(label)),
                  ],
                  onChanged: (value) => update(() => minutes = value ?? 10),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(remove ? '确认解除' : '确认禁言'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    final existing = _bot.groups.muteSettings(_target.groupId)?['members'];
    final alreadyMuted =
        existing is List &&
        existing.whereType<Map>().any((item) => item['member_openid'] == id);
    try {
      await _bot.groups.setMemberMute(
        _target,
        id,
        operation: remove
            ? 'del'
            : alreadyMuted
            ? 'update'
            : 'add',
        expiresAt: remove
            ? null
            : DateTime.now().add(Duration(minutes: minutes)),
      );
      try {
        await _bot.groups.loadMute(_target);
      } catch (_) {
        /* Action succeeded; the state card shows refresh errors. */
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        await AppDialogs.show(
          context,
          error.toString(),
          title: '禁言设置未完成',
          error: true,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bot = context.watch<BotClient>();
    if (!bot.groups.isCurrent(_target)) {
      return Scaffold(
        appBar: AppBar(title: const Text('会话设置')),
        body: const Center(child: Text('机器人已切换，请返回后重新打开会话设置。')),
      );
    }
    final session =
        bot.sessions.where((s) => s.id == widget.session.id).firstOrNull ??
        widget.session;
    final info = bot.groups.info(session.id),
        state = bot.groups.botState(session.id),
        mute = bot.groups.muteSettings(session.id);
    final members = _members
        .where(
          (m) =>
              '${m['username']} ${m['member_openid']} ${groupRole(m['member_role'])}'
                  .toLowerCase()
                  .contains(_search.toLowerCase()),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(_group ? '群聊设置' : '用户设置'),
        actions: [
          if (_group)
            IconButton(
              tooltip: '刷新群状态',
              onPressed: _loading ? null : _overview,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      ProfileAvatar(
                        name: session.name,
                        url: session.avatarUrl,
                        isGroup: _group,
                        radius: 28,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              groupText(info?['group_name']).isNotEmpty
                                  ? groupText(info!['group_name'])
                                  : session.name,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            SelectableText(
                              'OpenID：${session.id}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '复制会话 OpenID',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(text: session.id),
                          );
                        },
                        icon: const Icon(Icons.copy, size: 18),
                      ),
                    ],
                  ),
                ),
              ),
              Card(
                child: SwitchListTile(
                  title: const Text('屏蔽消息提醒'),
                  value: session.isMuted,
                  subtitle: const Text('仅本地免打扰，保留聊天记录，不影响机器人与插件收发'),
                  onChanged: (value) async {
                    try {
                      await bot.setSessionMuted(
                        session.id,
                        value,
                        expected: _target,
                      );
                    } catch (_) {
                      if (context.mounted) {
                        await AppDialogs.show(
                          context,
                          '免打扰设置未能保存，请重试',
                          error: true,
                        );
                      }
                    }
                  },
                ),
              ),
              if (!_group)
                Card(
                  child: ListTile(
                    title: const Text('单聊会话'),
                    subtitle: Text(
                      '本地记录 ${bot.getMessagesForSession(session.id).length} 条消息',
                    ),
                  ),
                ),
              if (_group) ...[
                const SizedBox(height: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('群状态')),
                    ButtonSegment(value: 1, label: Text('群成员')),
                    ButtonSegment(value: 2, label: Text('禁言状态')),
                  ],
                  selected: {_tab},
                  showSelectedIcon: false,
                  onSelectionChanged: (values) {
                    setState(() => _tab = values.first);
                    if (_tab == 1 && !_membersLoaded && !_membersLoading) {
                      _loadMembers();
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (_loading) const LinearProgressIndicator(),
                if (_tab == 0) ...[
                  _dataCard(
                    '群基本信息',
                    bot.groups.error('info', session.id),
                    info == null
                        ? const []
                        : [
                            (
                              '群人数',
                              info['group_member_num'] is num
                                  ? '${info['group_member_num']} 人'
                                  : '平台未提供',
                            ),
                            ('群简介', groupText(info['group_finger_memo'])),
                            ('群分类', groupText(info['group_class_text'])),
                            (
                              '群标签',
                              info['group_tags'] is List
                                  ? (info['group_tags'] as List)
                                        .map((tag) => groupText(tag))
                                        .join(' · ')
                                  : '',
                            ),
                          ],
                  ),
                  _dataCard(
                    '机器人群内状态',
                    bot.groups.error('bot', session.id),
                    state == null
                        ? const []
                        : [
                            ('群内身份', groupRole(state['member_role'])),
                            ('入群时间', groupDate(state['joined_at'])),
                            (
                              '主动消息权限',
                              state['allow_proactive_msg'] == true
                                  ? '已允许'
                                  : state['allow_proactive_msg'] == false
                                  ? '未允许'
                                  : '平台未提供',
                            ),
                            (
                              '接收模式',
                              switch (state['recv_msg_setting']) {
                                'all' => '全部消息',
                                'only_mention' => '仅 @ 消息',
                                'mention_and_context' => '@ 及上下文',
                                _ => '平台未提供',
                              },
                            ),
                          ],
                  ),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.notifications_outlined),
                      title: const Text('入群申请与群事件'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              NotificationsScreen(groupId: session.id),
                        ),
                      ),
                    ),
                  ),
                ],
                if (_tab == 1) ...[
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索已加载的成员／OpenID／角色',
                    ),
                    onChanged: (value) => setState(() => _search = value),
                  ),
                  const SizedBox(height: 8),
                  if (_memberError.isNotEmpty)
                    _dataCard('群成员', _memberError, const []),
                  if (_membersLoaded)
                    Text(
                      '已加载 ${_members.length} 位成员${_cursor.isNotEmpty ? '，还有更多' : ''}',
                    ),
                  for (final member in members)
                    Card(
                      child: ListTile(
                        leading: IgnorePointer(
                          child: ProfileAvatar(
                            name: groupText(member['username']),
                            url: userProfileAvatar(
                              _target.appId,
                              groupText(member['member_openid']),
                              const [],
                            ),
                          ),
                        ),
                        title: Text(
                          groupText(member['username']).isEmpty
                              ? groupText(member['member_openid'])
                              : groupText(member['username']),
                        ),
                        subtitle: Text(
                          '${groupRole(member['member_role'])}${member['bot'] == true ? ' · 机器人' : ''}',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _memberDetails(member),
                        onLongPress: () => GroupMemberActions.show(
                          context,
                          _bot,
                          _target,
                          groupText(member['member_openid']),
                          name: groupText(member['username']),
                        ),
                      ),
                    ),
                  if (!_membersLoaded ||
                      _cursor.isNotEmpty ||
                      _memberError.isNotEmpty)
                    OutlinedButton(
                      onPressed: _membersLoading
                          ? null
                          : () => _loadMembers(
                              next: _membersLoaded && _memberError.isEmpty,
                            ),
                      child: Text(
                        _membersLoading
                            ? '正在加载…'
                            : _membersLoaded && _cursor.isNotEmpty
                            ? '加载更多成员'
                            : '重新加载成员',
                      ),
                    ),
                  if (_membersLoaded && members.isEmpty && _memberError.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('暂无符合条件的成员'),
                    ),
                ],
                if (_tab == 2) ...[
                  _dataCard(
                    '群禁言状态',
                    bot.groups.error('mute', session.id),
                    mute == null
                        ? const []
                        : [
                            (
                              '全员禁言',
                              switch ((mute['global_rule'] is Map
                                  ? mute['global_rule']['mode']
                                  : null)) {
                                'none' => '未开启',
                                'always' => '始终禁言',
                                'schedule' => '定时／周期禁言',
                                _ => '平台未提供',
                              },
                            ),
                          ],
                  ),
                  if (mute?['global_rule'] is Map)
                    ..._rules(mute!['global_rule'] as Map),
                  if (mute?['members'] is List) ...[
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        '当前被禁言成员',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if ((mute!['members'] as List).isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text('当前没有被禁言成员'),
                      ),
                    for (final member
                        in (mute['members'] as List).whereType<Map>())
                      Card(
                        child: ListTile(
                          title: Text(
                            groupText(member['username']).isEmpty
                                ? groupText(member['member_openid'])
                                : groupText(member['username']),
                          ),
                          subtitle: Text(
                            '到期：${groupDate(member['mute_expire_at'])}',
                          ),
                          trailing: TextButton(
                            onPressed: bot.groups.isAdministrator(session.id)
                                ? () => _setMute(
                                    Map<String, dynamic>.from(member),
                                    remove: true,
                                  )
                                : null,
                            child: const Text('解除禁言'),
                          ),
                        ),
                      ),
                  ],
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      '在“群成员”中打开普通成员资料，可选择禁言时长。群主、管理员和机器人不可禁言；全员禁言规则仅展示。',
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  '部分群管理能力需 QQ 平台内邀／白名单，审核与禁言还需要机器人是群管理员。',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _dataCard(String title, String? error, List<(String, String)> rows) =>
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              if (error != null)
                SelectableText(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                )
              else if (rows.isEmpty)
                const Text('尚未获取')
              else
                for (final (label, value) in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        SelectableText(value.isEmpty ? '平台未提供' : value),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      );
  List<Widget> _rules(Map global) => [
    for (final rule
        in (global['schedule_rules'] is List
                ? global['schedule_rules'] as List
                : const [])
            .whereType<Map>())
      Card(
        child: ListTile(
          leading: Icon(
            rule['enabled'] == true
                ? Icons.schedule
                : Icons.pause_circle_outline,
          ),
          title: Text(rule['enabled'] == true ? '定时禁言 · 已启用' : '定时禁言 · 未启用'),
          subtitle: Text(
            '${groupDate(rule['start_at'])} → ${groupDate(rule['end_at'])}',
          ),
        ),
      ),
    for (final rule
        in (global['recurring_rules'] is List
                ? global['recurring_rules'] as List
                : const [])
            .whereType<Map>())
      Card(
        child: ListTile(
          leading: const Icon(Icons.event_repeat),
          title: Text(rule['enabled'] == true ? '周期禁言 · 已启用' : '周期禁言 · 未启用'),
          subtitle: Text(
            '星期 ${(rule['weekdays'] is List ? rule['weekdays'] as List : const []).join('、')}\n${groupText(rule['start_time'])}–${groupText(rule['end_time'])}（北京时间）',
          ),
        ),
      ),
  ];
}
