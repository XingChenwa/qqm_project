import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import '../utils/constants.dart';
import '../models/outgoing_message.dart';
import 'image_upload_service.dart';
import 'ip_whitelist_service.dart';
import '../utils/qq_mentions.dart';

class ApiResult<T> {
  final T? data;
  final String? error;
  final int? statusCode;
  final int? errorCode;
  final String? traceId;
  final Map<String, dynamic>? metadata;
  ApiResult.success(this.data, {this.metadata})
    : error = null,
      statusCode = 200,
      errorCode = null,
      traceId = null;
  ApiResult.failure(
    this.error, {
    this.statusCode,
    this.data,
    this.errorCode,
    this.traceId,
    this.metadata,
  });
  bool get isSuccess => error == null;
}

class ApiService {
  final Dio _dio;
  final ImageUploadService _images;

  ApiService({Dio? dio, ImageUploadService? images})
    : _images = images ?? const ImageUploadService(),
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'Content-Type': 'application/json'},
              validateStatus: (_) => true, // Don't throw on non-200
            ),
          );

  /// QQ Bot API: Get access_token.
  Future<ApiResult<AccessTokenResult>> getAccessToken({
    required String appId,
    required String clientSecret,
  }) async {
    try {
      final response = await _dio.post(
        AppConstants.qqTokenUrl,
        data: {'appId': appId, 'clientSecret': clientSecret},
      );
      if (_isSuccessfulResponse(response) && response.data is Map) {
        final token = response.data['access_token']?.toString() ?? '';
        if (token.isNotEmpty) {
          return ApiResult.success(
            AccessTokenResult(
              accessToken: token,
              expiresIn:
                  int.tryParse(
                    response.data['expires_in']?.toString() ?? '7200',
                  ) ??
                  7200,
            ),
          );
        }
        return ApiResult.failure(
          '返回的 access_token 为空',
          statusCode: response.statusCode,
          data: response.data,
        );
      }
      return _failure(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('请求失败: $e');
    }
  }

  /// Fetch a random emoji from meme APIs.
  Future<ApiResult<String>> fetchRandomEmoji(int apiIndex) async {
    final result = await fetchEmojiUrls(apiIndex, limit: 1);
    if (!result.isSuccess || result.data == null || result.data!.isEmpty) {
      return ApiResult.failure(result.error ?? '表情接口未返回图片');
    }
    return ApiResult.success(result.data!.first);
  }

  /// Fetch image URLs from meme APIs. Some APIs return a page/list of URLs.
  Future<ApiResult<List<String>>> fetchEmojiUrls(
    int apiIndex, {
    int limit = 40,
  }) async {
    if (apiIndex < 0 || apiIndex >= AppConstants.emojiApis.length) {
      return ApiResult.failure('无效的API索引');
    }
    try {
      final response = await _dio.get(
        AppConstants.emojiApis[apiIndex],
        options: Options(
          responseType: ResponseType.plain,
          followRedirects: true,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) QQBotManager/1.0',
            'Accept': 'application/json,text/plain,image/*,*/*',
          },
        ),
      );
      if (response.statusCode == 200) {
        final contentType =
            response.headers.value(Headers.contentTypeHeader) ?? '';
        final finalUri = response.realUri.toString();
        if (contentType.startsWith('image/') && _isHttpUrl(finalUri)) {
          return ApiResult.success([finalUri]);
        }

        if (response.data is Map) {
          final urls = _collectEmojiUrls(response.data).take(limit).toList();
          if (urls.isNotEmpty) return ApiResult.success(urls);
        }

        if (response.data is String) {
          final body = (response.data as String).trim();
          final urls = _extractEmojiUrls(body).take(limit).toList();
          if (urls.isNotEmpty) return ApiResult.success(urls);
        }
      }
      return ApiResult.failure('表情API返回格式异常: HTTP ${response.statusCode}');
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('请求失败: $e');
    }
  }

  /// Official group profile API (requires platform whitelist permission).
  Future<ApiResult<Map<String, dynamic>>> getGroupInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
  }) => _getProfile(
    baseUrl,
    accessToken,
    '/v2/groups/${Uri.encodeComponent(groupId)}/info',
  );

  Future<ApiResult<Map<String, dynamic>>> getGroupMemberInfo({
    required String baseUrl,
    required String accessToken,
    required String groupId,
    required String memberId,
  }) => _getProfile(
    baseUrl,
    accessToken,
    '/v2/groups/${Uri.encodeComponent(groupId)}/members/${Uri.encodeComponent(memberId)}',
  );

  Future<ApiResult<Map<String, dynamic>>> getBotProfile({
    required String baseUrl,
    required String accessToken,
  }) => _getProfile(baseUrl, accessToken, '/users/@me');

  Future<ApiResult<Map<String, dynamic>>> _getProfile(
    String baseUrl,
    String token,
    String endpoint,
  ) async {
    try {
      final response = await _dio.get(
        '$baseUrl$endpoint',
        options: Options(
          headers: {'Authorization': 'QQBot $token'},
          followRedirects: false,
        ),
      );
      if (_isSuccessfulResponse(response) && response.data is Map) {
        return ApiResult.success(Map<String, dynamic>.from(response.data));
      }
      return _failure(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (_) {
      return ApiResult.failure('资料返回格式异常');
    }
  }

  Future<ApiResult<String>> getGatewayUrl({
    required String baseUrl,
    required String accessToken,
  }) async {
    try {
      final response = await _dio.get(
        '$baseUrl/gateway',
        options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
      );
      if (_isSuccessfulResponse(response) && response.data is Map) {
        final url = response.data['url']?.toString();
        if (url != null && url.isNotEmpty) return ApiResult.success(url);
        return ApiResult.failure(
          '网关返回的URL为空',
          statusCode: response.statusCode,
          data: response.data,
        );
      }
      return _failure(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('请求失败: $e');
    }
  }

  Future<ApiResult<String>> sendConfiguredMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required OutgoingMessage message,
    bool isGroup = false,
    String? msgId,
    String? eventId,
    int? msgSeq,
    String? referenceId,
  }) async {
    message = message.withMarkdownMentions();
    final error = message.validate(isGroup: isGroup);
    if (error != null) return ApiResult.failure(error);
    if ((msgId?.isNotEmpty ?? false) && (eventId?.isNotEmpty ?? false)) {
      return ApiResult.failure('消息 ID 和事件 ID 不能同时发送');
    }
    try {
      String? uploadedFileInfo;
      if (message.type == 7 && message.fileInfo.trim().isEmpty) {
        final source = message.mediaSource.trim();
        final result = await uploadMedia(
          baseUrl: baseUrl,
          accessToken: accessToken,
          targetId: targetId,
          isGroup: isGroup,
          imageUrl: _isHttpUrl(source) ? source : null,
          file: _isHttpUrl(source) ? null : File(source),
          fileType: message.mediaFileType,
        );
        if (!result.isSuccess) return result;
        uploadedFileInfo = result.data;
      }
      final body = message.toPayload(
        messageId: msgId,
        eventId: eventId,
        sequence: msgSeq,
        referenceId: referenceId,
        uploadedFileInfo: uploadedFileInfo,
      );
      if (body.containsKey('msg_id') && body.containsKey('event_id')) {
        return ApiResult.failure('消息回复和事件回复不能同时使用');
      }
      final endpoint = isGroup
          ? '/v2/groups/$targetId/messages'
          : '/v2/users/$targetId/messages';
      final response = await _dio.post(
        '$baseUrl$endpoint',
        options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
        data: body,
      );
      return _toMessageIdResult(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('消息发送失败: $e');
    }
  }

  Future<ApiResult<bool>> acknowledgeInteraction({
    required String baseUrl,
    required String accessToken,
    required String interactionId,
    int code = 0,
  }) async {
    try {
      final response = await _dio.put(
        '$baseUrl/interactions/${Uri.encodeComponent(interactionId)}',
        options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
        data: {'code': code},
      );
      return _toBoolResult(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('按钮回调确认失败: $e');
    }
  }

  /// Send a text message.
  Future<ApiResult<String>> sendQQMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String content,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async {
    if (containsQqUserMention(content)) {
      return sendQQMarkdown(
        baseUrl: baseUrl,
        accessToken: accessToken,
        targetId: targetId,
        markdownContent: content,
        isGroup: isGroup,
        msgId: msgId,
        msgSeq: msgSeq,
      );
    }
    if (content.trim().isEmpty) return ApiResult.failure('消息内容不能为空');
    try {
      final endpoint = isGroup
          ? '/v2/groups/$targetId/messages'
          : '/v2/users/$targetId/messages';

      final response = await _dio.post(
        '$baseUrl$endpoint',
        options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
        data: _withReplyFields(
          {'content': content, 'msg_type': 0},
          msgId: msgId,
          msgSeq: msgSeq,
        ),
      );
      return _toMessageIdResult(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('发送失败: $e');
    }
  }

  Future<ApiResult<String>> sendQQMarkdown({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    String? markdownContent,
    String? templateId,
    List<Map<String, String>>? templateParams,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async {
    try {
      final endpoint = isGroup
          ? '/v2/groups/$targetId/messages'
          : '/v2/users/$targetId/messages';

      final Map<String, dynamic> markdownData;

      if (templateId != null) {
        if (templateId.trim().isEmpty) {
          return ApiResult.failure('请填写 Markdown 模板 ID，或切换到自定义 Markdown');
        }
        final keys = <String>{};
        for (final param in templateParams ?? <Map<String, String>>[]) {
          final key = param['key']?.trim() ?? '';
          final value = param['value'] ?? '';
          if (key.isEmpty || value.trim().isEmpty || !keys.add(key)) {
            return ApiResult.failure('模板参数名和参数值不能为空，参数名不能重复');
          }
          if (value.contains('\n') || value.contains('\r')) {
            return ApiResult.failure('QQ 模板参数不支持换行；发送多行代码请使用自定义 Markdown');
          }
        }
        // Template mode
        markdownData = {'custom_template_id': templateId.trim()};
        if (templateParams != null && templateParams.isNotEmpty) {
          markdownData['params'] = templateParams
              .map(
                (e) => {
                  'key': e['key']!.trim(),
                  'values': [e['value'] ?? ''],
                },
              )
              .toList();
        }
      } else {
        // Custom content mode
        if (markdownContent == null || markdownContent.trim().isEmpty) {
          return ApiResult.failure('Markdown 内容不能为空');
        }
        markdownData = {'content': markdownContent};
      }

      final response = await _dio.post(
        '$baseUrl$endpoint',
        options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
        data: _withReplyFields(
          {'markdown': markdownData, 'msg_type': 2},
          msgId: msgId,
          msgSeq: msgSeq,
        ),
      );
      return _toMessageIdResult(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('Markdown 发送失败: $e');
    }
  }

  Future<ApiResult<String>> sendQQImage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String imageUrl,
    bool isGroup = false,
    String? msgId,
    int? msgSeq,
  }) async {
    try {
      final mediaResult = await uploadMedia(
        baseUrl: baseUrl,
        accessToken: accessToken,
        targetId: targetId,
        imageUrl: imageUrl,
        file: _isHttpUrl(imageUrl) ? null : File(imageUrl),
        fileType: 1,
        isGroup: isGroup,
      );
      final fileInfo = mediaResult.data;
      if (!mediaResult.isSuccess || fileInfo == null || fileInfo.isEmpty) {
        return ApiResult.failure(
          mediaResult.error ?? '富媒体上传失败',
          statusCode: mediaResult.statusCode,
          errorCode: mediaResult.errorCode,
          traceId: mediaResult.traceId,
          metadata: mediaResult.metadata,
        );
      }

      final endpoint = isGroup
          ? '/v2/groups/$targetId/messages'
          : '/v2/users/$targetId/messages';

      final response = await _dio.post(
        '$baseUrl$endpoint',
        options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
        data: _withReplyFields(
          {
            'content': ' ',
            'msg_type': 7,
            'media': {'file_info': fileInfo},
          },
          msgId: msgId,
          msgSeq: msgSeq,
        ),
      );
      return _toMessageIdResult(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('图片发送失败: $e');
    }
  }

  Future<ApiResult<String>> uploadMedia({
    required String baseUrl,
    required String accessToken,
    String? imageUrl,
    File? file,
    int fileType = 1,
    bool isGroup = false,
    required String targetId,
  }) async {
    try {
      final endpoint = isGroup
          ? '/v2/groups/$targetId/files'
          : '/v2/users/$targetId/files';

      final isRemoteUrl = imageUrl != null && _isHttpUrl(imageUrl);
      Future<ApiResult<String>> postUpload(Object body) async {
        final response = await _dio.post(
          '$baseUrl$endpoint',
          options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
          data: body,
        );
        if (_isSuccessfulResponse(response) && response.data is Map) {
          final fileInfo = response.data['file_info']?.toString();
          if (fileInfo != null && fileInfo.isNotEmpty) {
            return ApiResult.success(fileInfo);
          }
          return ApiResult.failure(
            '上传成功但 file_info 为空',
            statusCode: response.statusCode,
          );
        }
        return _failure(response);
      }

      Map<String, Object> imageBody(PreparedImage image) => {
        'file_type': 1,
        'file_name': image.filename,
        'file_data': base64Encode(image.bytes),
        'srv_send_msg': false,
      };

      final needsConversion =
          isRemoteUrl &&
          fileType == 1 &&
          RegExp(
            r'\.(gif|webp|bmp|ico|tiff?|heic|avif)$',
            caseSensitive: false,
          ).hasMatch(Uri.parse(imageUrl).path);
      if (needsConversion) {
        return await postUpload(imageBody(await _images.fromUrl(imageUrl)));
      }
      final Object data;
      if (isRemoteUrl) {
        data = {'file_type': fileType, 'url': imageUrl, 'srv_send_msg': false};
      } else if (file != null && fileType == 1) {
        data = imageBody(await _images.fromFile(file));
      } else if (file != null) {
        if (!await file.exists()) {
          return ApiResult.failure('本地文件不存在: ${file.path}');
        }
        if (await file.length() > 5 * 1024 * 1024) {
          return ApiResult.failure('本地文件直传不能超过 5 MB，请压缩文件或使用公网 URL');
        }
        data = {
          'file_type': fileType,
          'file_name': file.uri.pathSegments.last,
          'file_data': base64Encode(await file.readAsBytes()),
          'srv_send_msg': false,
        };
      } else {
        return ApiResult.failure('请提供网络图片 URL 或本地文件');
      }

      final result = await postUpload(data);
      if (!result.isSuccess &&
          isRemoteUrl &&
          fileType == 1 &&
          {
            850026,
            850019,
            304082,
            304083,
            40034004,
          }.contains(result.errorCode)) {
        try {
          return await postUpload(imageBody(await _images.fromUrl(imageUrl)));
        } catch (error) {
          return ApiResult.failure(
            '${result.error}\n本地直传重试失败：${error is FormatException ? error.message : '图片下载或转换失败'}',
            statusCode: result.statusCode,
            errorCode: result.errorCode,
            traceId: result.traceId,
          );
        }
      }
      return result;
    } on FormatException catch (e) {
      return ApiResult.failure(e.message.toString());
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('上传失败: $e');
    }
  }

  Future<ApiResult<bool>> recallMessage({
    required String baseUrl,
    required String accessToken,
    required String targetId,
    required String messageId,
    bool isGroup = false,
  }) async {
    try {
      final endpoint = isGroup
          ? '/v2/groups/$targetId/messages/$messageId'
          : '/v2/users/$targetId/messages/$messageId';
      final response = await _dio.delete(
        '$baseUrl$endpoint',
        options: Options(headers: {'Authorization': 'QQBot $accessToken'}),
      );
      return _toBoolResult(response);
    } on DioException catch (e) {
      return ApiResult.failure(_dioErrorMsg(e));
    } catch (e) {
      return ApiResult.failure('撤回失败: $e');
    }
  }

  // --- helpers ---

  int? _businessCode(dynamic data) => data is Map
      ? int.tryParse((data['err_code'] ?? data['code'])?.toString() ?? '')
      : null;

  bool _isSuccessfulResponse(Response response) {
    final status = response.statusCode ?? 0;
    final code = _businessCode(response.data);
    return status >= 200 && status < 300 && (code == null || code == 0);
  }

  ApiResult<T> _failure<T>(Response response) {
    final code = _businessCode(response.data);
    final traceId =
        response.headers.value('x-tps-trace-id') ??
        response.headers.value('x-trace-id') ??
        (response.data is Map ? response.data['trace_id']?.toString() : null);
    final hint = switch (code) {
      11253 => '应用无资料查询权限，该接口需要 QQ 平台白名单授权',
      100007 || 10004 => 'AppID 无效或机器人不存在，请检查开放平台配置',
      100016 => 'AppID 或机器人密钥错误',
      22006 => '消息类型与内容不匹配',
      22009 || 40034100 => '消息发送超频，请稍后再试',
      304103 || 40034005 || 40034128 => '被动回复已过期或次数已用完，请等待对方发送新消息',
      40034008 => 'Markdown 模板参数存在空值',
      40034009 => '模板参数不能含换行；多行代码请用自定义 Markdown',
      40034010 => '模板参数不能含 Markdown 语法，请用自定义 Markdown',
      40034011 || 40034124 => 'Markdown 内容或参数无效，请检查格式',
      40034127 => '无 Markdown 模板权限，请切换到自定义 Markdown',
      40034024 => '回复消息 ID 无效或不属于当前会话',
      40034025 => '事件 ID 无效，请选择可回复事件',
      40034026 => '事件回复已过期，请等待新的事件',
      40034027 => '该事件不支持消息回复',
      305007 => '按钮样式或键盘参数错误，请检查消息设置',
      40034029 => '按钮数量超限，最多 5 行、每行 5 个',
      40034101 || 40054003 => '机器人不在该群聊中，请先添加机器人',
      40054002 => '机器人已被禁言，请解除禁言后重试',
      40054010 => '不允许发送此 URL，请检查开放平台消息 URL 配置',
      40054005 => '消息被去重，请使用新的回复序号',
      40054007 || 40054018 => '消息内容过长，请分段发送',
      40054013 => '对方已关闭机器人消息接收',
      40034105 => '没有主动消息权限，请先让对方给机器人发送消息',
      40054004 => '尚未建立好友关系，请先添加机器人',
      40054016 => '机器人已下线，请重新连接',
      304082 || 304083 || 40034004 => '图片资源拉取或转存失败，请换用可公开访问的图片',
      850018 => '群或机器人被禁言，无法发送表情图片',
      850019 => 'QQ 不支持该图片格式，图片请使用 PNG / JPG',
      850026 => 'QQ 服务端下载表情图片失败',
      850031 => '上传文件超过 QQ 大小限制',
      850027 => 'QQ 富媒体上传超时，请稍后重试',
      _ => null,
    };
    final detail = _extractMsg(response.data);
    return ApiResult.failure(
      '${hint == null ? '' : '$hint。'}HTTP ${response.statusCode}'
      '${code == null ? '' : ' / 错误码 $code'}: $detail'
      '${traceId == null ? '' : '（追踪 ID: $traceId）'}',
      statusCode: response.statusCode,
      errorCode: code,
      traceId: traceId,
      metadata: {'sourceIp': reportedSourceIp(response.data)},
    );
  }

  String _extractMsg(dynamic data) {
    if (data is Map) {
      return data['message']?.toString() ??
          data['msg']?.toString() ??
          data['error']?.toString() ??
          jsonEncode(data);
    }
    return data?.toString() ?? '无响应';
  }

  String _dioErrorMsg(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return '连接超时';
      case DioExceptionType.receiveTimeout:
        return '响应超时';
      case DioExceptionType.connectionError:
        return '网络连接失败: ${e.message}';
      case DioExceptionType.badResponse:
        return '服务器错误 ${e.response?.statusCode}: ${_extractMsg(e.response?.data)}';
      default:
        return '请求失败: ${e.message}';
    }
  }

  ApiResult<bool> _toBoolResult(Response response) {
    if (_isSuccessfulResponse(response)) return ApiResult.success(true);
    return _failure(response);
  }

  ApiResult<String> _toMessageIdResult(Response response) {
    if (_isSuccessfulResponse(response)) {
      final id = response.data is Map ? response.data['id']?.toString() : null;
      if (id != null && id.isNotEmpty) {
        return ApiResult.success(
          id,
          metadata: Map<String, dynamic>.from(response.data),
        );
      }
      return ApiResult.failure(
        '接口未返回消息 ID，无法确认消息已发送',
        statusCode: response.statusCode,
      );
    }
    return _failure(response);
  }

  Map<String, dynamic> _withReplyFields(
    Map<String, dynamic> data, {
    String? msgId,
    int? msgSeq,
  }) {
    if (msgId != null && msgId.isNotEmpty) {
      data['msg_id'] = msgId;
      data['msg_seq'] = msgSeq ?? 1;
    }
    return data;
  }

  bool _isImageUrl(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    return path.endsWith('.jpg') ||
        path.endsWith('.jpeg') ||
        path.endsWith('.png') ||
        path.endsWith('.gif') ||
        path.endsWith('.webp') ||
        path.endsWith('.bmp');
  }

  List<String> _extractEmojiUrls(String body) {
    final urls = <String>{};
    if (_isHttpUrl(body)) return [body];
    try {
      final decoded = jsonDecode(body);
      urls.addAll(_collectEmojiUrls(decoded));
    } catch (_) {
      // Third-party emoji APIs may return plain text or HTML with many links.
    }

    final matches = RegExp(r'https?://[^\s"<>\\]+').allMatches(body);
    for (final match in matches) {
      final raw = match.group(0);
      if (raw == null) continue;
      final url = raw.replaceAll(RegExp(r'[,\]\}\)]+$'), '');
      if (_isHttpUrl(url) && _isImageUrl(url)) urls.add(url);
    }

    final list = urls.toList();
    list.sort((a, b) {
      final imageWeight = (_isImageUrl(b) ? 1 : 0) - (_isImageUrl(a) ? 1 : 0);
      return imageWeight == 0 ? a.compareTo(b) : imageWeight;
    });
    return list;
  }

  List<String> _collectEmojiUrls(dynamic value) {
    final urls = <String>{};

    void walk(dynamic node) {
      if (node == null) return;
      if (node is String) {
        if (_isHttpUrl(node)) {
          urls.add(node);
        } else if (node.contains('http')) {
          urls.addAll(_extractEmojiUrls(node));
        }
        return;
      }
      if (node is Map) {
        for (final child in node.values) {
          walk(child);
        }
        return;
      }
      if (node is Iterable) {
        for (final child in node) {
          walk(child);
        }
      }
    }

    walk(value);
    final list = urls.toList();
    list.sort((a, b) {
      final imageWeight = (_isImageUrl(b) ? 1 : 0) - (_isImageUrl(a) ? 1 : 0);
      return imageWeight == 0 ? a.compareTo(b) : imageWeight;
    });
    return list;
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !RegExp(r'\s').hasMatch(value);
  }
}

class AccessTokenResult {
  final String accessToken;
  final int expiresIn;
  AccessTokenResult({required this.accessToken, required this.expiresIn});
}
