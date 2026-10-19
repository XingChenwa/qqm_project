import 'dart:io';
import 'package:path/path.dart' as p;

class ServerAssetBundle {
  Directory root = Directory.current;
  Future<String> loadString(String key) async {
    final target = p.normalize(p.join(root.absolute.path, key));
    if (!p.isWithin(root.absolute.path, target) || p.isAbsolute(key)) {
      throw const FormatException('资源路径无效');
    }
    return File(target).readAsString();
  }
}

final rootBundle = ServerAssetBundle();
