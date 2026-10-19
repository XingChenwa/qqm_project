import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/core/bot_client.dart';
import 'package:qq_bot_manager/services/api_service.dart';
import 'package:qq_bot_manager/services/ip_whitelist_service.dart';
import 'package:qq_bot_manager/ui/widgets/ip_whitelist_dialog.dart';
import 'app_update_test.dart' show UpdateAdapter;
import 'support/fakes.dart';

class BlockedGateway extends RecordingApi {
  Completer<ApiResult<String>>? pending;
  String message = '接口访问源IP不在白名单';
  @override
  Future<ApiResult<String>> getGatewayUrl({
    required String baseUrl,
    required String accessToken,
  }) async => pending != null
      ? pending!.future
      : ApiResult.failure(message, errorCode: 11298);
}

class FakePublicIp extends PublicIpService {
  final List<String> ips;
  int calls = 0;
  FakePublicIp(this.ips);
  @override
  Future<List<String>> lookup() async {
    calls++;
    return ips;
  }
}

void main() {
  test('只识别 IP 白名单拒绝，不混淆接口或群聊权限白名单', () {
    expect(isIpWhitelistError('接口访问源 IP 不在白名单'), isTrue);
    expect(isIpWhitelistError('source IP is not in whitelist'), isTrue);
    expect(isIpWhitelistError('应用无资料查询权限，该接口需要 QQ 平台白名单授权'), isFalse);
    for (final ip in [
      '127.0.0.1',
      '192.168.1.4',
      '10.0.0.1',
      '172.16.0.2',
      '100.64.1.2',
      '::1',
      '::',
      'fe80::1',
      'fc00::1',
      '::ffff:192.168.1.2',
    ]) {
      expect(validPublicIp(ip), isNull, reason: ip);
    }
    expect(reportedSourceIp({'source_ip': '9.8.7.6'}), '9.8.7.6');
    expect(reportedSourceIp('source IP: 9.8.7.6'), '9.8.7.6');
    expect(
      reportedSourceIp('源IP：[2001:4860:4860::8888]'),
      '2001:4860:4860::8888',
    );
    expect(reportedSourceIp('trace-id: abcdef1234567890'), isNull);
  });
  test('公网 IP 仅按需查询，无 QQ Token、AppID 或请求正文，禁止重定向', () async {
    final adapter = UpdateAdapter(
      (request) async => ResponseBody.fromString(
        request.uri.host == 'api.ipify.org'
            ? '9.8.7.6'
            : '2001:4860:4860::8888',
        200,
      ),
    );
    final service = PublicIpService(http: Dio()..httpClientAdapter = adapter);
    addTearDown(service.dispose);
    expect(adapter.requests, isEmpty);
    expect(await service.lookup(), ['9.8.7.6', '2001:4860:4860::8888']);
    expect(
      adapter.requests.every(
        (r) =>
            r.method == 'GET' &&
            r.data == null &&
            r.uri.query.isEmpty &&
            r.headers['Authorization'] == null &&
            r.followRedirects == false,
      ),
      isTrue,
    );
  });
  test('查询异常或本地地址不会冒充公网源 IP', () async {
    final service = PublicIpService(
      http: Dio()
        ..httpClientAdapter = UpdateAdapter(
          (request) async => ResponseBody.fromString(
            request.uri.host == 'api.ipify.org'
                ? '192.168.0.1'
                : '<html>bad</html>',
            200,
          ),
        ),
    );
    addTearDown(service.dispose);
    expect(await service.lookup(), isEmpty);
  });
  test('凭据或网关报 IP 错误会携带当前 AppID，权限白名单不会弹 IP 引导', () async {
    final api = BlockedGateway();
    final bot = BotClient(
      MemoryStorage(config: validConfig()),
      apiService: api,
      webSocketService: TestGateway(),
    );
    addTearDown(bot.dispose);
    expect(await bot.connect(), isFalse);
    expect(bot.ipWhitelistProblem!.appId, bot.config.appId);
    expect(
      bot.ipWhitelistProblem!.settingsUri.toString(),
      'https://q.qq.com/qqbot/dashboard/manage/${bot.config.appId}?sec=dev-settings',
    );
    bot.dismissIpWhitelistProblem(bot.ipWhitelistProblem!);
    api.message = '该接口需要 QQ 平台白名单授权';
    await bot.connect();
    expect(bot.ipWhitelistProblem, isNull);
  });
  test('切换 AppID 后，旧请求失败不会打开新账号的白名单设置', () async {
    final api = BlockedGateway()..pending = Completer<ApiResult<String>>();
    final config = validConfig();
    final bot = BotClient(
      MemoryStorage(config: config),
      apiService: api,
      webSocketService: TestGateway(),
    );
    addTearDown(bot.dispose);
    final connection = bot.connect();
    await Future<void>.delayed(Duration.zero);
    final next = validConfig()..appId = 'another-app';
    await bot.updateConfig(next);
    api.pending!.complete(ApiResult.failure('接口访问源IP不在白名单'));
    await connection;
    expect(bot.ipWhitelistProblem, isNull);
  });
  for (final width in [320.0, 390.0]) {
    testWidgets('白名单弹窗 $width 宽提供可复制 IP、正确机器人链接与指导', (tester) async {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final lookup = FakePublicIp(['9.8.7.6']);
      addTearDown(lookup.dispose);
      String? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IpWhitelistDialog(
              problem: const IpWhitelistProblem(
                appId: '10000001',
                message: '接口访问源IP不在白名单',
                sourceIp: '9.8.7.6',
              ),
              lookup: lookup,
              openSettings: (url) async {
                opened = url;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(lookup.calls, 0);
      expect(find.text('9.8.7.6'), findsOneWidget);
      await tester.tap(find.text('前往开发设置'));
      await tester.pump();
      expect(
        opened,
        'https://q.qq.com/qqbot/dashboard/manage/10000001?sec=dev-settings',
      );
      expect(tester.takeException(), isNull);
    });
  }
}
