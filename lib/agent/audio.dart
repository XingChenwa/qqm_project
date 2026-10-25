import 'dart:convert';
import 'dart:typed_data';
import '../utils/voice_file.dart';
import 'models.dart';

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
