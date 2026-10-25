import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:dio/io.dart';
import 'package:dio/dio.dart';
import 'models.dart';
import 'gradio_events.dart';
import '../services/ip_whitelist_service.dart'
    show isIpWhitelistError, reportedSourceIp;

class AgentHttpException extends AgentException {
  final int statusCode;
  final int? errorCode;
  final String traceId;
  final bool ipWhitelist;
  final String? sourceIp;
  const AgentHttpException(
    super.message, {
    required this.statusCode,
    this.errorCode,
    this.traceId = '',
    this.ipWhitelist = false,
    this.sourceIp,
  });
}

/// Bounded requests with no redirects, so credentials cannot follow a redirect.
class AgentHttp {
  final Dio _dio;
  final Dio Function()? downloadDioFactory;
  AgentHttp({Dio? dio, this.downloadDioFactory}) : _dio = dio ?? Dio();

  /// Shared public-address check for both downloads and protocol image URLs.
  Future<List<InternetAddress>> validatePublicUri(Uri uri) async {
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const AgentException('扩展只允许公共 HTTPS 地址。');
    }
    final literal = InternetAddress.tryParse(uri.host);
    if (literal != null &&
        literal.type == InternetAddressType.IPv4 &&
        literal.rawAddress[0] == 198 &&
        {18, 19}.contains(literal.rawAddress[1])) {
      throw const AgentException('不能直接请求基准测试网段地址。');
    }
    final addresses = await InternetAddress.lookup(
      uri.host,
    ).timeout(const Duration(seconds: 5));
    if (addresses.isEmpty || addresses.any(_privateAddress)) {
      throw const AgentException('扩展不能请求本地、内网或保留地址。');
    }
    return addresses;
  }

  Future<AgentWebSocket> openWebSocket(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    if (uri.scheme != 'wss' || uri.userInfo.isNotEmpty) {
      throw const AgentException('扩展 WebSocket 只允许公共 WSS 地址。');
    }
    final target = uri.replace(scheme: 'https');
    final addresses = await validatePublicUri(target);
    final pinned =
        addresses
            .where((a) => a.type == InternetAddressType.IPv4)
            .firstOrNull ??
        addresses.first;
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    client.connectionFactory = (url, proxyHost, proxyPort) async {
      if (url.scheme != 'https' ||
          url.host != target.host ||
          url.port != target.port ||
          proxyHost != null) {
        throw const AgentException('WebSocket 目标已改变。');
      }
      final task = await Socket.startConnect(pinned, target.port);
      Socket? raw;
      return ConnectionTask.fromSocket<Socket>(
        task.socket.then((socket) {
          raw = socket;
          return SecureSocket.secure(socket, host: target.host);
        }),
        () {
          task.cancel();
          raw?.destroy();
        },
      );
    };
    try {
      final socket = await WebSocket.connect(
        uri.toString(),
        headers: headers,
        customClient: client,
        compression: CompressionOptions.compressionOff,
      ).timeout(const Duration(seconds: 15));
      return _PublicWebSocket(socket, client);
    } catch (_) {
      client.close(force: true);
      throw const AgentException('语音 WebSocket 连接失败或超时。');
    }
  }

  Future<({Uint8List bytes, int status, Map<String, String> headers})>
  fetchBytes(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    CancelToken? cancel,
    int maxBytes = 12 * 1024 * 1024,
    int timeoutSeconds = 15,
  }) async {
    if (cancel?.isCancelled == true) throw const AgentException('任务已停止。');
    final addresses = await validatePublicUri(uri);
    final pinned =
        addresses
            .where((a) => a.type == InternetAddressType.IPv4)
            .firstOrNull ??
        addresses.first;
    // Pin the verified DNS answer for this request. A second DNS resolution or
    // an environment proxy must not turn a public URL into an internal request.
    final download =
        downloadDioFactory?.call() ??
        (Dio()
          ..httpClientAdapter = IOHttpClientAdapter(
            createHttpClient: () {
              final client = HttpClient()..findProxy = (_) => 'DIRECT';
              client.connectionFactory = (url, proxyHost, proxyPort) async {
                if (url.host != uri.host ||
                    url.port != uri.port ||
                    proxyHost != null) {
                  throw const AgentException('扩展下载目标已改变。');
                }
                final task = await Socket.startConnect(pinned, uri.port);
                Socket? raw;
                final secure = task.socket.then((socket) {
                  raw = socket;
                  // connectionFactory replaces HttpClient's TLS setup too. Preserve
                  // the ORIGINAL hostname for SNI and certificate verification while
                  // connecting to the validated address. Never send plaintext to 443.
                  return SecureSocket.secure(socket, host: uri.host);
                });
                return ConnectionTask.fromSocket<Socket>(secure, () {
                  task.cancel();
                  raw?.destroy();
                });
              };
              return client;
            },
          ));
    final token = CancelToken();
    var done = false;
    unawaited(
      cancel?.whenCancel.then((_) {
        if (!done) token.cancel();
      }),
    );
    if (cancel?.isCancelled == true) {
      download.close(force: true);
      throw const AgentException('任务已停止。');
    }
    final budget = Duration(seconds: timeoutSeconds.clamp(1, 120));
    var timedOut = false;
    final timer = Timer(budget, () {
      timedOut = true;
      token.cancel();
    });
    try {
      final response = await download.requestUri<ResponseBody>(
        uri,
        data: body,
        cancelToken: token,
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.stream,
          followRedirects: false,
          sendTimeout: budget,
          receiveTimeout: budget,
          validateStatus: (s) => s != null,
        ),
      );
      final declared =
          int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      if (declared > maxBytes) throw const AgentException('下载文件超过大小限制。');
      final bytes = BytesBuilder(copy: false);
      final gradioEvents =
          method == 'GET' &&
              (uri.path.endsWith('/queue/data') ||
                  RegExp(r'/call/[^/]+/[^/]+/?$').hasMatch(uri.path)) &&
              response.headers
                      .value('content-type')
                      ?.split(';')
                      .first
                      .trim()
                      .toLowerCase() ==
                  'text/event-stream'
          ? GradioEventBoundary()
          : null;
      await for (final chunk in response.data!.stream) {
        if (token.isCancelled) throw const AgentException('下载已停止。');
        if (bytes.length + chunk.length > maxBytes) {
          throw const AgentException('下载文件超过大小限制。');
        }
        bytes.add(chunk);
        if (gradioEvents?.add(chunk) == true) break;
      }
      return (
        bytes: bytes.takeBytes(),
        status: response.statusCode ?? 0,
        headers: response.headers.map.map(
          (k, v) => MapEntry(k.toLowerCase(), v.join(', ')),
        ),
      );
    } on AgentException {
      rethrow;
    } catch (error) {
      if (cancel?.isCancelled == true) {
        throw const AgentException('任务已停止。');
      }
      final reason = timedOut
          ? '达到请求时限'
          : error is DioException
          ? switch (error.type) {
              DioExceptionType.connectionTimeout => '连接超时',
              DioExceptionType.sendTimeout => '上传超时',
              DioExceptionType.receiveTimeout => '读取超时',
              DioExceptionType.badCertificate => '证书校验失败',
              DioExceptionType.connectionError => '连接中断',
              DioExceptionType.cancel => '请求取消',
              _ => '响应连接异常',
            }
          : error is HandshakeException
          ? 'TLS 连接失败'
          : error is SocketException || error is HttpException
          ? '连接中断'
          : '响应读取异常';
      // Do not include remote bodies, headers or exception URLs in diagnostics.
      throw AgentException('扩展网络请求失败或超时（$reason）。');
    } finally {
      done = true;
      timer.cancel();
      token.cancel();
      download.close(force: true);
    }
  }

  Future<dynamic> request(
    Uri uri, {
    String method = 'GET',
    Json? body,
    Map<String, String> headers = const {},
    Json? query,
    CancelToken? cancel,
    int timeoutSeconds = 60,
    int maxBytes = 1048576,
  }) async {
    final requestCancel = CancelToken();
    var finished = false;
    var timedOut = false;
    if (cancel?.isCancelled == true) throw const AgentException('任务已停止。');
    unawaited(
      cancel?.whenCancel.then((_) {
        if (!finished) requestCancel.cancel();
      }),
    );
    final deadline = Timer(Duration(seconds: timeoutSeconds), () {
      timedOut = true;
      requestCancel.cancel();
    });
    try {
      final response = await _dio
          .requestUri<ResponseBody>(
            query == null
                ? uri
                : uri.replace(
                    queryParameters: {
                      ...uri.queryParameters,
                      ...query.map((k, v) => MapEntry(k, text(v))),
                    },
                  ),
            data: body,
            cancelToken: requestCancel,
            options: Options(
              method: method,
              headers: headers,
              responseType: ResponseType.stream,
              followRedirects: false,
              sendTimeout: Duration(seconds: timeoutSeconds),
              receiveTimeout: Duration(seconds: timeoutSeconds),
              validateStatus: (s) => s != null,
            ),
          )
          .timeout(Duration(seconds: timeoutSeconds));
      final bytes = <int>[];
      await for (final chunk in response.data!.stream.timeout(
        Duration(seconds: timeoutSeconds),
      )) {
        if (requestCancel.isCancelled) {
          throw const AgentException('任务已停止。');
        }
        if (bytes.length + chunk.length > maxBytes) {
          throw const AgentException('接口返回的数据过大，已停止读取。');
        }
        bytes.addAll(chunk);
      }
      final content = utf8.decode(bytes);
      Object? decoded;
      try {
        decoded = jsonDecode(content);
      } catch (_) {}
      final status = response.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        final data = object(decoded);
        final code = int.tryParse(text(data['err_code'] ?? data['code']));
        final candidate =
            response.headers.value('x-tps-trace-id') ??
            response.headers.value('x-trace-id') ??
            text(data['trace_id']);
        final trace = RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(candidate)
            ? candidate
            : '';
        throw AgentHttpException(
          '接口请求失败（HTTP $status${code == null ? '' : ' / 错误码 $code'}）${trace.isEmpty ? '' : '，追踪 ID：$trace'}。',
          statusCode: status,
          errorCode: code,
          traceId: trace,
          ipWhitelist: isIpWhitelistError(
            text(data['message'] ?? data['msg'] ?? data['error']),
          ),
          sourceIp: reportedSourceIp(data),
        );
      }
      return decoded ?? content;
    } on AgentException {
      rethrow;
    } on DioException catch (e) {
      if (timedOut) throw const AgentException('接口请求超时，已停止。');
      if (CancelToken.isCancel(e)) throw const AgentException('任务已停止。');
      final code = e.response?.statusCode;
      throw AgentException(
        code == null
            ? '网络请求失败，请检查接口地址和网络。'
            : '接口请求失败（HTTP $code），请检查密钥、模型 ID 和服务状态。',
      );
    } catch (_) {
      throw const AgentException('接口连接超时或响应格式无效。');
    } finally {
      finished = true;
      deadline.cancel();
      requestCancel.cancel();
    }
  }

  void close() => _dio.close(force: true);
}

abstract class AgentWebSocket {
  Stream<Object> get messages;
  void add(Object value);
  Future<void> close();
}

class _PublicWebSocket implements AgentWebSocket {
  final WebSocket socket;
  final HttpClient client;
  _PublicWebSocket(this.socket, this.client);
  @override
  Stream<Object> get messages => socket.cast<Object>();
  @override
  void add(Object value) => socket.add(value);
  @override
  Future<void> close() async {
    try {
      await socket.close().timeout(const Duration(seconds: 1));
    } catch (_) {
    } finally {
      client.close(force: true);
    }
  }
}

bool _privateAddress(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final b = a.rawAddress;
  if (b.length == 4) {
    // A trusted system VPN can assign 198.18/15 Fake-IP answers to PUBLIC
    // hostnames. Keep TLS verification/SNI and pin that answer, but do not
    // mistake this transport mapping for an RFC1918 destination. Direct IP
    // access to that range is rejected above. The system VPN is outside the
    // extension isolation boundary, just like the OS certificate store.
    return b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        b[0] >= 224 ||
        b[0] == 169 && b[1] == 254 ||
        b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
        b[0] == 192 && b[1] == 168 ||
        b[0] == 100 && b[1] >= 64 && b[1] <= 127 ||
        b[0] == 192 && b[1] == 0 ||
        b[0] == 198 && b[1] == 51 ||
        b[0] == 203 && b[1] == 0 && b[2] == 113;
  }
  return b[0] & 0xfe == 0xfc ||
      b.take(12).every((v) => v == 0) ||
      b.take(10).every((v) => v == 0) && b[10] == 255 && b[11] == 255;
}
