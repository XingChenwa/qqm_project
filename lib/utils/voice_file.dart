import 'dart:typed_data';

/// Detect the received format without changing the original audio bytes.
String voiceFileExtension(Uint8List bytes) {
  final prefix = String.fromCharCodes(bytes.take(12));
  if (bytes.length > 24 &&
      String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp' &&
      RegExp(
        r'M4A |isom|mp4[12]',
      ).hasMatch(String.fromCharCodes(bytes.sublist(8, 24)))) {
    return 'm4a';
  }
  if (prefix.startsWith('RIFF') && prefix.endsWith('WAVE')) return 'wav';
  if (prefix.startsWith('OggS')) return 'ogg';
  if (prefix.contains('#!SILK_V3')) return 'silk';
  if (prefix.startsWith('ID3') ||
      (bytes.length >= 2 && bytes[0] == 255 && (bytes[1] & 0xe6) == 0xe2)) {
    return 'mp3';
  }
  return 'bin';
}
