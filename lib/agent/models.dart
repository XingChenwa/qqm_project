import 'dart:convert';

typedef Json = Map<String, dynamic>;

Json object(Object? value) => value is Map
    ? value.map((key, value) => MapEntry(key.toString(), value))
    : <String, dynamic>{};
List<String> strings(Object? value) => value is List
    ? value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
    : [];
int integer(Object? value, int fallback) => int.tryParse('$value') ?? fallback;
String text(Object? value) => value?.toString() ?? '';
bool qqId(String value) =>
    RegExp(r'^[1-9][0-9]{4,18}$').hasMatch(value) &&
    int.tryParse(value) != null;
bool safeId(String value) => RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(value);
bool openId(String value) => RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(value);
String clipped(String value, int length) =>
    value.length <= length ? value : value.substring(0, length);

/// Chinese nicknames may directly precede a question. Latin prefixes use a word
/// boundary so a wake word "bot" doesn't accidentally trigger on "bottle".
bool matchesAgentWakePrefix(String content, String prefix) {
  prefix = prefix.trim();
  content = content.trimLeft();
  if (prefix.isEmpty ||
      !content.toLowerCase().startsWith(prefix.toLowerCase())) {
    return false;
  }
  if (content.length == prefix.length) return true;
  final word = RegExp(r'[a-zA-Z0-9_]');
  return !word.hasMatch(prefix[prefix.length - 1]) ||
      !word.hasMatch(content[prefix.length]);
}

class AgentException implements Exception {
  final String message;
  const AgentException(this.message);
  @override
  String toString() => message;
}

Uri httpEndpoint(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const AgentException('请填写有效的 HTTP / HTTPS 地址，不要在地址内填写密码。');
  }
  return uri;
}

/// Protocol identity is explicit: QQ number for OneBot, AppID for QQBot.
class AgentConnection {
  final String id, name, selfId, mode, url, host, path, token, presetId;
  final String protocol, clientSecret;
  final bool sandbox, resolveOfficialProfiles, useOiapiNickname;
  bool get isOfficial => protocol == 'qqbot';
  bool acceptsPeer(String value) => isOfficial ? openId(value) : qqId(value);
  String get protocolLabel => isOfficial ? 'QQBot 官方' : 'OneBot 11';
  final int port, cooldownSeconds, batchWindowMs;
  final bool autoConnect, aiEnabled, privateReply;
  final String groupTrigger, commandPrefix;
  final List<String> groupAllowlist,
      userAllowlist,
      pluginIds,
      extraWakePrefixes;
  AgentConnection({
    required this.id,
    required this.name,
    required this.selfId,
    this.protocol = 'onebot',
    this.clientSecret = '',
    this.sandbox = false,
    this.resolveOfficialProfiles = true,
    this.useOiapiNickname = true,
    this.mode = 'forward',
    this.url = 'ws://127.0.0.1:3001/',
    this.host = '127.0.0.1',
    this.port = 23337,
    this.path = '/onebot/v11',
    this.token = '',
    this.autoConnect = false,
    this.aiEnabled = false,
    this.privateReply = true,
    this.groupTrigger = 'mention',
    this.commandPrefix = '/ai',
    this.presetId = 'assistant',
    this.cooldownSeconds = 3,
    this.batchWindowMs = 2000,
    this.groupAllowlist = const [],
    this.userAllowlist = const [],
    this.pluginIds = const [],
    this.extraWakePrefixes = const [],
  });
  factory AgentConnection.fromJson(Json j) => AgentConnection(
    id: text(j['id']),
    name: text(j['name']),
    selfId: text(j['protocol']) == 'qqbot'
        ? text(j['appId']).isEmpty
              ? text(j['selfId'])
              : text(j['appId'])
        : text(j['selfId']),
    protocol: text(j['protocol']).isEmpty ? 'onebot' : text(j['protocol']),
    clientSecret: text(j['clientSecret']),
    sandbox: j['sandbox'] == true,
    resolveOfficialProfiles: j['resolveOfficialProfiles'] != false,
    useOiapiNickname: j['useOiapiNickname'] != false,
    mode: text(j['mode']).isEmpty ? 'forward' : text(j['mode']),
    url: text(j['url']),
    host: text(j['host']).isEmpty ? '127.0.0.1' : text(j['host']),
    port: integer(j['port'], 23337),
    path: text(j['path']).isEmpty ? '/onebot/v11' : text(j['path']),
    token: text(j['token']),
    autoConnect: j['autoConnect'] == true,
    aiEnabled: j['aiEnabled'] == true,
    privateReply: j['privateReply'] != false,
    groupTrigger: text(j['groupTrigger']).isEmpty
        ? 'mention'
        : text(j['groupTrigger']),
    commandPrefix: text(j['commandPrefix']).isEmpty
        ? '/ai'
        : text(j['commandPrefix']),
    presetId: text(j['presetId']).isEmpty ? 'assistant' : text(j['presetId']),
    cooldownSeconds: integer(j['cooldownSeconds'], 3),
    batchWindowMs: integer(j['batchWindowMs'], 2000),
    groupAllowlist: List.unmodifiable(strings(j['groupAllowlist'])),
    userAllowlist: List.unmodifiable(strings(j['userAllowlist'])),
    pluginIds: List.unmodifiable(strings(j['pluginIds'])),
    extraWakePrefixes: List.unmodifiable(strings(j['extraWakePrefixes'])),
  );
  Json toJson({bool secrets = true}) => {
    'id': id,
    'name': name,
    'selfId': selfId,
    'protocol': protocol,
    'appId': isOfficial ? selfId : '',
    'clientSecret': secrets ? clientSecret : '',
    'hasClientSecret': clientSecret.isNotEmpty,
    'sandbox': sandbox,
    'resolveOfficialProfiles': resolveOfficialProfiles,
    'useOiapiNickname': useOiapiNickname,
    'mode': mode,
    'url': url,
    'host': host,
    'port': port,
    'path': path,
    'token': secrets ? token : '',
    'hasToken': token.isNotEmpty,
    'autoConnect': autoConnect,
    'aiEnabled': aiEnabled,
    'privateReply': privateReply,
    'groupTrigger': groupTrigger,
    'commandPrefix': commandPrefix,
    'presetId': presetId,
    'cooldownSeconds': cooldownSeconds,
    'batchWindowMs': batchWindowMs,
    'groupAllowlist': groupAllowlist,
    'userAllowlist': userAllowlist,
    'pluginIds': pluginIds,
    'extraWakePrefixes': extraWakePrefixes,
  };
  void validate() {
    if (!safeId(id) ||
        name.trim().isEmpty ||
        name.length > 100 ||
        !qqId(selfId) ||
        !{'onebot', 'qqbot'}.contains(protocol)) {
      throw const AgentException('请填写连接名称和有效的 QQ 号 / AppID。');
    }
    if (isOfficial &&
        (clientSecret.isEmpty ||
            clientSecret.length > 4096 ||
            clientSecret.contains(RegExp(r'[\r\n]')))) {
      throw const AgentException('请填写官方机器人 ClientSecret。');
    }
    if (!{'forward', 'reverse'}.contains(mode)) {
      throw const AgentException('连接方式无效。');
    }
    if (!isOfficial && mode == 'forward') {
      final u = Uri.tryParse(url);
      if (u == null ||
          !{'ws', 'wss'}.contains(u.scheme) ||
          u.host.isEmpty ||
          u.userInfo.isNotEmpty ||
          u.hasFragment ||
          u.query.isNotEmpty ||
          RegExp(r'/(api|event)/?$').hasMatch(u.path)) {
        throw const AgentException(
          '正向连接请填写通用 WS 地址（通常以 / 结尾），不要使用仅 API / event 地址；令牌填写到专用输入框。',
        );
      }
    } else if (!isOfficial &&
        (host.isEmpty ||
            port < 1 ||
            port > 65535 ||
            !RegExp(r'^/[A-Za-z0-9/_-]*$').hasMatch(path) ||
            (path != '/' && path.endsWith('/')) ||
            path.contains('//') ||
            (token.isEmpty &&
                !{'127.0.0.1', '::1', 'localhost'}.contains(host)))) {
      throw const AgentException('监听地址、端口或路径无效；允许其他设备连接时必须设置访问令牌。');
    }
    if (token.contains(RegExp(r'[\r\n]')) ||
        token.length > 4096 ||
        !{'mention', 'command', 'all', 'off'}.contains(groupTrigger) ||
        commandPrefix.trim().isEmpty ||
        commandPrefix.length > 40 ||
        cooldownSeconds < 0 ||
        cooldownSeconds > 3600 ||
        batchWindowMs < 50 ||
        batchWindowMs > 5000 ||
        extraWakePrefixes.length > 20 ||
        extraWakePrefixes.any(
          (p) =>
              p.trim().isEmpty ||
              p.length > 40 ||
              p.contains(RegExp(r'[\x00-\x1f\x7f]')),
        ) ||
        [...groupAllowlist, ...userAllowlist].any((e) => !acceptsPeer(e))) {
      throw const AgentException('触发规则、账号白名单或令牌格式无效。');
    }
  }
}

class AgentProvider {
  final String id, name, baseUrl, apiKey, model;
  final bool tools, vision;
  final int timeoutSeconds;
  final double? inputPrice, outputPrice, cachedPrice;
  AgentProvider({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
    this.tools = true,
    this.vision = false,
    this.timeoutSeconds = 60,
    this.inputPrice,
    this.outputPrice,
    this.cachedPrice,
  });
  factory AgentProvider.fromJson(Json j) => AgentProvider(
    id: text(j['id']),
    name: text(j['name']),
    baseUrl: text(j['baseUrl']),
    model: text(j['model']),
    apiKey: text(j['apiKey']),
    tools: j['tools'] != false,
    vision: j['vision'] == true,
    timeoutSeconds: integer(j['timeoutSeconds'], 60),
    inputPrice: j['inputPrice'] is num
        ? (j['inputPrice'] as num).toDouble()
        : null,
    outputPrice: j['outputPrice'] is num
        ? (j['outputPrice'] as num).toDouble()
        : null,
    cachedPrice: j['cachedPrice'] is num
        ? (j['cachedPrice'] as num).toDouble()
        : null,
  );
  Json toJson({bool secrets = true}) => {
    'id': id,
    'name': name,
    'baseUrl': baseUrl,
    'model': model,
    'apiKey': secrets ? apiKey : '',
    'hasApiKey': apiKey.isNotEmpty,
    'tools': tools,
    'vision': vision,
    'timeoutSeconds': timeoutSeconds,
    'inputPrice': inputPrice,
    'outputPrice': outputPrice,
    'cachedPrice': cachedPrice,
  };
  void validate({bool requireModel = true}) {
    if (!safeId(id) ||
        name.trim().isEmpty ||
        (requireModel && model.trim().isEmpty) ||
        timeoutSeconds < 5 ||
        timeoutSeconds > 180 ||
        apiKey.contains(RegExp(r'[\r\n]'))) {
      throw const AgentException('模型名称、模型 ID、超时或密钥格式无效。');
    }
    final u = httpEndpoint(baseUrl);
    if ([
      inputPrice,
      outputPrice,
      cachedPrice,
    ].whereType<double>().any((v) => !v.isFinite || v < 0 || v > 1000000)) {
      throw const AgentException('模型价格须为非负数；单位：人民币 / 百万 token。');
    }
    if (u.query.isNotEmpty) throw const AgentException('接口根地址不能含查询参数。');
  }

  Uri endpoint(String resource) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/$resource');
}

class AgentPreset {
  final String id, name, prompt, providerId, imageDescriptionProviderId;
  final List<String> skillIds;
  final double temperature;
  final int maxTokens,
      historyMessages,
      imageMaxEdge,
      maxReplyMessages,
      replyIntervalMs;
  final bool webSearchEnabled, showReasoning, timeAwareness;
  final bool multiMessageReply;
  final bool readMessageContext;
  AgentPreset({
    required this.id,
    required this.name,
    required this.prompt,
    this.providerId = '',
    this.skillIds = const [],
    this.temperature = .7,
    this.maxTokens = 2048,
    this.historyMessages = 16,
    this.imageDescriptionProviderId = '',
    this.imageMaxEdge = 1536,
    this.webSearchEnabled = false,
    this.showReasoning = false,
    this.timeAwareness = true,
    this.multiMessageReply = false,
    this.readMessageContext = true,
    this.maxReplyMessages = 3,
    this.replyIntervalMs = 700,
  });
  factory AgentPreset.fromJson(Json j) => AgentPreset(
    id: text(j['id']),
    name: text(j['name']),
    prompt: text(j['prompt']),
    providerId: text(j['providerId']),
    skillIds: List.unmodifiable(strings(j['skillIds'])),
    temperature: (j['temperature'] is num
        ? (j['temperature'] as num).toDouble()
        : .7),
    maxTokens: integer(j['maxTokens'], 2048),
    historyMessages: integer(j['historyMessages'], 16),
    imageDescriptionProviderId: text(j['imageDescriptionProviderId']),
    imageMaxEdge: integer(j['imageMaxEdge'], 1536),
    webSearchEnabled: j['webSearchEnabled'] == true,
    showReasoning: j['showReasoning'] == true,
    timeAwareness: j['timeAwareness'] != false,
    multiMessageReply: j['multiMessageReply'] == true,
    readMessageContext: j['readMessageContext'] != false,
    maxReplyMessages: integer(j['maxReplyMessages'], 3),
    replyIntervalMs: integer(j['replyIntervalMs'], 700),
  );
  Json toJson() => {
    'id': id,
    'name': name,
    'prompt': prompt,
    'providerId': providerId,
    'skillIds': skillIds,
    'temperature': temperature,
    'maxTokens': maxTokens,
    'historyMessages': historyMessages,
    'imageDescriptionProviderId': imageDescriptionProviderId,
    'imageMaxEdge': imageMaxEdge,
    'webSearchEnabled': webSearchEnabled,
    'showReasoning': showReasoning,
    'timeAwareness': timeAwareness,
    'multiMessageReply': multiMessageReply,
    'readMessageContext': readMessageContext,
    'maxReplyMessages': maxReplyMessages,
    'replyIntervalMs': replyIntervalMs,
  };
  void validate() {
    if (imageMaxEdge < 256 || imageMaxEdge > 4096) {
      throw const AgentException('输入图片最大边长须为 256–4096 像素。');
    }
    if (maxReplyMessages < 2 ||
        maxReplyMessages > 5 ||
        replyIntervalMs < 0 ||
        replyIntervalMs > 3000) {
      throw const AgentException('分条回复上限须为 2–5 条，间隔须为 0–3000 毫秒。');
    }
    if (!safeId(id) ||
        name.trim().isEmpty ||
        prompt.trim().isEmpty ||
        prompt.length > 32000 ||
        !temperature.isFinite ||
        temperature < 0 ||
        temperature > 2 ||
        maxTokens < 64 ||
        maxTokens > 16384 ||
        historyMessages < 0 ||
        historyMessages > 80 ||
        (imageDescriptionProviderId.isNotEmpty &&
            !safeId(imageDescriptionProviderId))) {
      throw const AgentException('预设参数无效：上下文 0–80 条，温度 0–2，输出长度 64–16384。');
    }
  }
}

/// Full account identity in every key, including identical group/private IDs.
class AgentSession {
  final String connectionId, selfId, kind, peerId;
  final String protocol;
  String name, memory, presetId;
  bool paused, nameIsManual;
  int unread;
  DateTime updated;
  AgentSession({
    required this.connectionId,
    required this.selfId,
    required this.kind,
    required this.peerId,
    required this.name,
    this.protocol = 'onebot',
    this.memory = '',
    this.presetId = '',
    this.paused = false,
    this.nameIsManual = false,
    this.unread = 0,
    DateTime? updated,
  }) : updated = updated ?? DateTime.now();
  String get key => base64Url.encode(
    utf8.encode(
      jsonEncode([
        if (protocol != 'onebot') protocol,
        connectionId,
        selfId,
        kind,
        peerId,
      ]),
    ),
  );
  factory AgentSession.fromJson(Json j) => AgentSession(
    connectionId: text(j['connectionId']),
    selfId: text(j['selfId']),
    kind: text(j['kind']),
    peerId: text(j['peerId']),
    name: text(j['name']),
    protocol: text(j['protocol']).isEmpty ? 'onebot' : text(j['protocol']),
    memory: text(j['memory']),
    presetId: text(j['presetId']),
    paused: j['paused'] == true,
    nameIsManual: j['nameIsManual'] == true,
    unread: integer(j['unread'], 0),
    updated: DateTime.tryParse(text(j['updated'])),
  );
  Json toJson() => {
    'key': key,
    'connectionId': connectionId,
    'selfId': selfId,
    'protocol': protocol,
    'kind': kind,
    'peerId': peerId,
    'name': name,
    'memory': memory,
    'presetId': presetId,
    'paused': paused,
    'nameIsManual': nameIsManual,
    'unread': unread,
    'updated': updated.toIso8601String(),
  };
}

class AgentMessage {
  final String id, sessionKey, senderId, senderName, source;

  /// Optional provider-returned reasoning, local only; never a QQ message segment.
  final String reasoning;
  final String referenceIndex;
  final bool outgoing,
      addressed,
      autoHandled,
      senderNameIsFallback,
      senderIsBot;
  final DateTime time;
  final List<Json> segments;
  AgentMessage({
    required this.id,
    required this.sessionKey,
    required this.senderId,
    required this.senderName,
    required this.segments,
    this.outgoing = false,
    this.source = 'onebot',
    this.reasoning = '',
    this.referenceIndex = '',
    this.addressed = false,
    this.autoHandled = false,
    this.senderNameIsFallback = false,
    this.senderIsBot = false,
    DateTime? time,
  }) : time = time ?? DateTime.now();
  String get plain => segments.map(segmentText).join();
  String get inputText => segments.map((s) {
    if (s['type'] != 'qq_body') return segmentText(s);
    final body = object(object(s['data'])['body']);
    final type = integer(body['message_type'], 0);
    return '${text(body['content'])}\n[${type == 102
        ? '聊天记录'
        : type == 103
        ? '引用消息'
        : '消息附加资料'}]';
  }).join();
  String get quotedContext => segments
      .where((s) => s['type'] == 'qq_body')
      .map((s) => text(object(s['data'])['context']))
      .where((s) => s.isNotEmpty)
      .join('\n');
  List<Json> get contextImages => [
    for (final s in segments.where((s) => s['type'] == 'qq_body'))
      ...parseSegments(object(s['data'])['images']),
  ];
  factory AgentMessage.fromJson(Json j) => AgentMessage(
    id: text(j['id']),
    sessionKey: text(j['sessionKey']),
    senderId: text(j['senderId']),
    senderName: text(j['senderName']),
    segments: parseSegments(j['segments']),
    outgoing: j['outgoing'] == true,
    source: text(j['source']),
    reasoning: clipped(text(j['reasoning']), 16000),
    referenceIndex: clipped(text(j['referenceIndex']), 512),
    addressed: j['addressed'] == true,
    autoHandled: j['autoHandled'] == true,
    senderNameIsFallback: j['senderNameIsFallback'] == true,
    senderIsBot: j['senderIsBot'] == true,
    time: DateTime.tryParse(text(j['time'])),
  );
  Json toJson() => {
    'id': id,
    'sessionKey': sessionKey,
    'senderId': senderId,
    'senderName': senderName,
    'segments': segments,
    'outgoing': outgoing,
    'source': source,
    if (reasoning.isNotEmpty) 'reasoning': reasoning,
    if (referenceIndex.isNotEmpty) 'referenceIndex': referenceIndex,
    if (addressed) 'addressed': true,
    if (autoHandled) 'autoHandled': true,
    if (senderNameIsFallback) 'senderNameIsFallback': true,
    if (senderIsBot) 'senderIsBot': true,
    'time': time.toIso8601String(),
  };
  AgentMessage copyWith({
    String? senderName,
    String? referenceIndex,
    List<Json>? segments,
    bool? addressed,
    bool? autoHandled,
    bool? senderNameIsFallback,
  }) => AgentMessage(
    id: id,
    sessionKey: sessionKey,
    senderId: senderId,
    senderName: senderName ?? this.senderName,
    segments: segments ?? this.segments,
    outgoing: outgoing,
    source: source,
    reasoning: reasoning,
    referenceIndex: referenceIndex ?? this.referenceIndex,
    time: time,
    addressed: addressed ?? this.addressed,
    autoHandled: autoHandled ?? this.autoHandled,
    senderNameIsFallback: senderNameIsFallback ?? this.senderNameIsFallback,
    senderIsBot: senderIsBot,
  );
}

String _cqDecode(String s, {bool parameter = false}) =>
    (parameter ? s.replaceAll('&#44;', ',') : s)
        .replaceAll('&#91;', '[')
        .replaceAll('&#93;', ']')
        .replaceAll('&amp;', '&');
List<Json> parseSegments(Object? value) {
  if (value is List) {
    return value
        .take(100)
        .whereType<Map>()
        .map(
          (e) => <String, dynamic>{
            'type': text(e['type']),
            'data': object(e['data']),
          },
        )
        .toList();
  }
  final source = text(value);
  final result = <Json>[];
  var cursor = 0;
  for (final match in RegExp(
    r'\[CQ:([a-zA-Z_]+)((?:,[^\]]*)?)\]',
  ).allMatches(source).take(100)) {
    if (match.start > cursor) {
      result.add(textSegment(_cqDecode(source.substring(cursor, match.start))));
    }
    final data = <String, dynamic>{};
    for (final part in match[2]!.split(',').skip(1)) {
      final at = part.indexOf('=');
      if (at > 0) {
        data[part.substring(0, at)] = _cqDecode(
          part.substring(at + 1),
          parameter: true,
        );
      }
    }
    result.add({'type': match[1], 'data': data});
    cursor = match.end;
  }
  if (cursor < source.length) {
    result.add(textSegment(_cqDecode(source.substring(cursor))));
  }
  return result;
}

Json textSegment(String value) => {
  'type': 'text',
  'data': {'text': value},
};
String segmentText(Json segment) {
  final d = object(segment['data']);
  return switch (segment['type']) {
    'text' => text(d['text']),
    'at' => d['qq'] == 'all' ? '@全体成员 ' : '@${d['qq']} ',
    'image' => '[图片]',
    'record' => '[语音]',
    'video' => '[视频]',
    'face' => '[表情 ${d['id']}]',
    'reply' => '[引用 ${d['id']}]',
    'forward' => '[聊天记录]',
    'qq_body' => text(d['preview']),
    'file' => '[文件 ${d['name'] ?? ''}]',
    _ => '[${segment['type']}]',
  };
}
