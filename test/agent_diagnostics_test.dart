import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/redaction.dart';
import 'package:qq_bot_manager/agent/web.dart';
import 'agent_ai_features_test.dart' show FeatureHttp, page;

void main() {
  test('Cookie复用等布尔开关不能被识别为密钥，真实字符串密钥仍被识别', () {
    final e = AgentExtension({
      'id': 'test',
      'kind': 'plugin',
      'name': '测试',
      'packageManifest': {
        'settings': {
          'reuseMediaCookies': true,
          'tokenCache': false,
          'apiKey': '123',
          'bilibiliCookie': 'session=value',
        },
        'configSchema': {
          'reuseMediaCookies': {'type': 'boolean'},
          'tokenCache': {'type': 'boolean'},
          'apiKey': {'type': 'string'},
        },
      },
    });
    expect(e.privateSettingValues.toSet(), {'123', 'session=value'});
  });
  test('遮蔽数字或true字符串密钥不破坏布尔、数字、空值和JSON结构', () {
    final raw = {
      'provided': true,
      'isError': false,
      'count': 1,
      'amount': 123,
      'nothing': null,
      'content': 'secret=true; key=123',
      'nested': [true, false, 1, '123'],
      '123': 1,
    };
    final value = object(redactAgentValue(raw, ['true', '123']));
    expect(value['provided'], true);
    expect(value['isError'], false);
    expect(value['count'], 1);
    expect(value['amount'], 123);
    expect(value['nothing'], null);
    expect(value['content'], 'secret=[已隐藏]; key=[已隐藏]');
    expect(value['nested'], [true, false, 1, '[已隐藏]']);
    expect(value['[已隐藏]'], 1);
    expect(jsonDecode(jsonEncode(value)), value);
    expect(raw['content'], 'secret=true; key=123');
  });
  test('公共图片和网页请求真正移除片段，保留QQ下载查询参数及重定向校验', () async {
    final http = FeatureHttp();
    final uris = <Uri>[];
    http.handler = (uri) async {
      uris.add(uri);
      expect(
        uri.hasFragment,
        false,
        reason: 'replace(fragment:空字符串)仍然包含#，会触发真实下载器的拒绝',
      );
      expect(uri.scheme, 'https');
      expect(uri.queryParameters['rkey'], 'fixture-signature');
      if (uris.length == 1) {
        return page(
          '',
          status: 302,
          headers: {'location': '/actual.jpg?rkey=fixture-signature#preview'},
        );
      }
      return page('fixture');
    };
    try {
      await agentPublicGet(
        http,
        Uri.parse(
          'https://multimedia.fixture.test/download?rkey=fixture-signature#',
        ),
        cancel: CancelToken(),
        maxBytes: 10000,
      );
      expect(uris, hasLength(2));
      expect(uris.last.path, '/actual.jpg');
    } finally {
      http.close();
    }
  });
}
