import 'dart:convert';
import 'models.dart';

const agentPackageHostVersion = 4;

/// Describe real host boundaries separately from ZIP validity. A package can be
/// retained and edited without pretending unavailable services were activated.
Json packageCompatibility(Json manifest, Json inspection) {
  final sources = object(manifest['files']).entries
      .where((e) => e.key.endsWith('.js'))
      .map((e) => utf8.decode(base64Decode(text(e.value))))
      .join('\n');
  final hooks = strings(inspection['hooks']);
  final providers = strings(
    inspection['providers'],
  ).where((p) => p != 'message.owner-check').toList();
  final blockers = <String>[];
  final warnings = <String>[];
  final requirements = <String>[];
  final availability = object(inspection['available']);
  if (availability['ok'] == false) {
    final reason = clipped(text(availability['reason']), 500);
    blockers.add(
      '扩展自检未通过：${reason.isEmpty ? '缺少运行环境或配置，请检查插件设置和配套文件。' : reason}',
    );
  }
  if (RegExp(r'(?<![.\w])fetch\s*\(|globalThis\.fetch').hasMatch(sources)) {
    requirements.add('publicFetch');
    if (!strings(
      object(manifest['packageManifest'])['permissions'],
    ).contains('web_fetch')) {
      warnings.add('原包使用全局 fetch，启用后可访问公共 HTTPS 服务；请求仍受地址、体积、超时和鉴权范围限制。');
    }
  }
  if (sources.contains('globalThis.WebSocket')) requirements.add('websocket');
  const supportedHooks = {
    'before-context',
    'before-llm-messages',
    'before-tool',
    'after-tool',
    'after-response',
  };
  const supportedProviders = {
    'message.owner-check',
    'wake.burst-policy',
    'llm.request-params',
    'friend.request',
    'group.request',
    'share-card.status',
    'knowledge.hot-trends',
  };
  if (RegExp(
    r'''(?:from\s*|import\s*\()['"](?:node:)?child_process['"]''',
  ).hasMatch(sources)) {
    if (sources.contains('globalThis.WebSocket')) {
      warnings.add(
        '语音优先通过内嵌 WSS 接口合成；原包的本地 PowerShell 备用路径不执行。网络服务失败会明确报告，未收到发送回执不算成功。',
      );
    } else {
      blockers.add('此包必须启动外部系统程序，尚无可用的跨平台接口。');
    }
  }
  if (RegExp(r'\b(?:ctx|context)\??\.onebot\b').hasMatch(sources)) {
    requirements.add('onebot');
    warnings.add('资料 / 空间操作使用当前机器人的 OneBot 连接，需协议端实现相应接口；QQBot 官方连接不可使用此能力。');
  }
  if (sources.contains('model-prices.js')) {
    requirements.add('usageLedger');
    warnings.add('费用统计读取当前账号、本会话的真实用量。请在 AI 模型高级设置填写输入 / 输出价格；未配置时不会编造金额。');
  }
  if (RegExp(
    r'\bnew\s+(?:FormData|Blob)\b|\.sendMedia(?:Url)?\s*\(',
  ).hasMatch(sources)) {
    requirements.add('media');
    warnings.add(
      '语音等待真实协议回执；可按公共 HTTPS 链接交由适配器获取，或上传不超过 5 MB 的音频。URL 的格式与大小限制由协议端执行；本机单次下载最长 120 秒。',
    );
  }
  final unknownHooks = hooks.where((h) => !supportedHooks.contains(h)).toList();
  if (unknownHooks.isNotEmpty) {
    warnings.add('未识别的生命周期钩子：${unknownHooks.join('、')}。');
  }
  final unknownProviders = providers
      .where((p) => !supportedProviders.contains(p))
      .toList();
  if (unknownProviders.isNotEmpty) {
    warnings.add('未识别的插件服务：${unknownProviders.join('、')}。');
  }
  if ((inspection['tools'] as List? ?? []).isEmpty &&
      (unknownHooks.isNotEmpty || unknownProviders.isNotEmpty) &&
      hooks.every((h) => !supportedHooks.contains(h)) &&
      providers.every((p) => !supportedProviders.contains(p))) {
    blockers.add('此包只依赖上述钩子 / 服务，当前没有可独立调用的工具，先保留为关闭状态。');
  }
  if (sources.contains('config.json') && sources.contains('readFileSync')) {
    warnings.add('OCR 请求通过当前 OneBot 连接转发，脚本不读取机器人密钥；实际能力以协议端返回为准。');
  }
  if (object(
    object(manifest['packageManifest'])['configSchema'],
  ).keys.any((k) => k.toLowerCase().contains('cookie'))) {
    warnings.add('登录网页可使用本插件配置的 Cookie，仅向对应站点发送；未配置或登录失效时会返回读取失败。');
  }
  return {
    'hostVersion': agentPackageHostVersion,
    'availability': {
      'ok': availability['ok'] != false,
      if (availability['ok'] == false)
        'reason': clipped(text(availability['reason']), 500),
    },
    'state': blockers.isNotEmpty
        ? 'blocked'
        : unknownHooks.isNotEmpty || unknownProviders.isNotEmpty
        ? 'partial'
        : 'ready',
    'blockers': blockers,
    'warnings': warnings,
    'hooks': hooks,
    'providers': strings(inspection['providers']),
    'requirements': requirements,
  };
}
