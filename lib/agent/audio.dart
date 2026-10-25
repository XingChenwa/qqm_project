import 'dart:convert';
import 'dart:typed_data';
import '../utils/voice_file.dart';
import 'models.dart';
import 'http.dart';

/// Validate before delegating a remote record to a protocol adapter. No local
/// audio download is made; the adapter/platform enforces its format/size limits.
Future<Uri> validateAgentAudioUrl(AgentHttp http, String value) async {
  final uri = Uri.tryParse(value);
  if (value.length > 8192 ||
      uri == null ||
      uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.host.isEmpty) {
    throw const AgentException('URL 语音需要不含账号和片段的公共 HTTPS 地址。');
  }
  await http.validatePublicUri(uri);
  return uri;
}

class AgentAudio {
  final Uint8List bytes;
  final String extension;
  const AgentAudio._(this.bytes, this.extension);
  factory AgentAudio(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const AgentException('语音文件不能为空，且不能超过 5 MB。');
    }
    final ext = voiceFileExtension(bytes);
    if (!{'wav', 'mp3', 'silk', 'ogg', 'm4a'}.contains(ext)) {
      throw const AgentException('无法识别音频文件；需要真实的 WAV、MP3、SILK、OGG 或 M4A 数据。');
    }
    return AgentAudio._(bytes, ext);
  }
  String get name => 'voice.$extension';
  String get mime => switch (extension) {
    'wav' => 'audio/wav',
    'mp3' => 'audio/mpeg',
    'ogg' => 'audio/ogg',
    'm4a' => 'audio/mp4',
    _ => 'audio/silk',
  };
  Json get segment => {
    'type': 'record',
    'data': {
      'file': 'base64://${base64Encode(bytes)}',
      'name': name,
      'mime': mime,
    },
  };
}

int packageExecutionSeconds(Json settings) =>
    (integer(settings['timeoutSec'], 10) + 30).clamp(40, 160);
