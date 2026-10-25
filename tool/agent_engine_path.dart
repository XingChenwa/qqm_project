import 'dart:io';
import 'dart:isolate';

Future<void> main() async {
  final uri = await Isolate.resolvePackageUri(
    Uri.parse('package:flutter_qjs_next/quickjs/ffi.dart'),
  );
  if (uri == null) {
    exitCode = 1;
    return;
  }
  stdout.writeln(File.fromUri(uri).parent.parent.parent.path);
}
