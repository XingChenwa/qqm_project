import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../utils/profile_helpers.dart';
import 'api_service.dart';

/// Optional third-party nickname lookup. This client is deliberately separate
/// from QQ's authenticated client and accepts no bot secrets / access tokens.
class OiapiService {
  static const endpoint = 'https://oiapi.net/api/Openid';
  final Dio _dio;
  final _pending = <CancelToken>{};

  OiapiService({HttpClientAdapter? adapter})
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
          followRedirects: false,
          validateStatus: (_) => true,
          headers: {'Accept': 'application/json'},
        ),
      ) {
    if (adapter != null) _dio.httpClientAdapter = adapter;
  }

  Future<ApiResult<Map<String, dynamic>>> getNickname({
    required String appId,
    required String openId,
  }) async {
    final app = appId.trim();
    final user = openId.trim();
    if (qqOpenIdAvatar(app, user).isEmpty) {
      return ApiResult.failure('OIAPI 查询需要有效的机器人 AppID 和用户 OpenID');
    }
    final cancel = CancelToken();
    _pending.add(cancel);
    try {
      return await _request(app, user, cancel).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          cancel.cancel();
          return ApiResult.failure('OIAPI 昵称查询超时');
        },
      );
    } on DioException {
      return ApiResult.failure('OIAPI 昵称服务暂时无法连接');
    } catch (_) {
      return ApiResult.failure('OIAPI 返回的昵称数据无效');
    } finally {
      _pending.remove(cancel);
    }
  }

  Future<ApiResult<Map<String, dynamic>>> _request(
    String appId,
    String openId,
    CancelToken cancel,
  ) async {
    final response = await _dio.get<ResponseBody>(
      endpoint,
      queryParameters: {'appid': appId, 'openid': openId},
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancel,
    );
    if (response.statusCode != 200 || response.data == null) {
      cancel.cancel();
      return ApiResult.failure('OIAPI 昵称服务返回 HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.data!.stream) {
      if (bytes.length + chunk.length > 64 * 1024) {
        cancel.cancel();
        return ApiResult.failure('OIAPI 返回的数据超过大小限制');
      }
      bytes.addAll(chunk);
    }
    final body = jsonDecode(utf8.decode(bytes));
    if (body is! Map || body['code'] != 1 || body['data'] is! Map) {
      return ApiResult.failure('OIAPI 暂未查询到用户昵称');
    }
    final data = body['data'] as Map;
    if (data['openid'] != openId) {
      return ApiResult.failure('OIAPI 返回的用户 OpenID 不匹配，已忽略');
    }
    final nickname = profileName(data['nickname']);
    if (nickname.isEmpty || nickname.length > 128) {
      return ApiResult.failure('OIAPI 返回的用户昵称为空或过长');
    }
    return ApiResult.success({'openid': openId, 'nickname': nickname});
  }

  void cancelPending() {
    for (final cancel in _pending.toList()) {
      cancel.cancel();
    }
  }

  void dispose() {
    cancelPending();
    _dio.close(force: true);
  }
}
