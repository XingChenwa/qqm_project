import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// Build the source fixture in memory, without a developer's ignored dist ZIP
/// or a separate companion checkout. Network and QQ delivery remain mocked.
Future<List<int>> remoteCoverPackageBytes() async {
  final override = Platform.environment['QQM_COVER_SKILL_ZIP'];
  if (override != null) return File(override).readAsBytes();
  final archive = Archive();
  for (final name in ['skill.json', 'index.js', 'tools.js', 'LICENSE']) {
    final bytes = await File(
      'test/fixtures/remote_cover_skill/$name',
    ).readAsBytes();
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }
  return ZipEncoder().encode(archive);
}

Uint8List audioFixture() {
  final bytes = Uint8List(16044);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, ascii.encode('RIFF'));
  data.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 16, ascii.encode('WAVEfmt '));
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 8000, Endian.little);
  data.setUint32(28, 16000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  bytes.setRange(36, 40, ascii.encode('data'));
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}
