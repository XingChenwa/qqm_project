/// Conservative comment extraction. The model never receives permission to rewrite code.
/// Complex raw strings/JS regex-template constructs are rejected rather than guessed.
class CommentDocument {
  final String source;
  final List<({int start, int end})> _spans;
  CommentDocument._(this.source, this._spans);
  List<String> get comments => [
    for (final span in _spans) source.substring(span.start, span.end),
  ];

  factory CommentDocument.parse(String code, String language) {
    final lang = language.toLowerCase();
    final python = {'py', 'python'}.contains(lang);
    final js = {'js', 'javascript', 'ts', 'typescript'}.contains(lang);
    if (!python &&
        !{
          'js',
          'javascript',
          'ts',
          'typescript',
          'c',
          'cpp',
          'c++',
          'java',
          'dart',
          'go',
          'cs',
          'csharp',
          'rust',
          'rs',
        }.contains(lang)) {
      throw const CommentParseException(
        '注释翻译支持 Python、C/C++、Java、Dart、Go、C#、Rust 和基础 JS/TS；其他语言请用 /翻译。',
      );
    }
    if (RegExp(r'R"|r#+"|\$"|@"').hasMatch(code) ||
        code.contains('\\\n') ||
        code.contains('\\\r\n') ||
        (js || lang == 'dart') && code.contains(r'${')) {
      throw const CommentParseException(
        '这段代码包含暂不支持的原始/插值字符串。为保护代码，未执行注释替换；可单独使用 /翻译。',
      );
    }
    final spans = <({int start, int end})>[];
    void addLines(int start, int end) {
      var position = start;
      while (position < end) {
        var stop = code.indexOf('\n', position);
        if (stop < 0 || stop > end) stop = end;
        final line = code.substring(position, stop);
        final left = line.length - line.trimLeft().length;
        final right = line.trimRight().length;
        if (right > left) {
          spans.add((start: position + left, end: position + right));
        }
        position = stop + 1;
      }
    }

    var i = 0;
    while (i < code.length) {
      final ch = code[i];
      if (ch == '"' || ch == "'" || ch == '`') {
        final triple = python && code.startsWith(ch * 3, i);
        final delimiter = triple ? ch * 3 : ch;
        i += delimiter.length;
        var closed = false;
        while (i < code.length) {
          if (code[i] == '\\') {
            i += 2;
            continue;
          }
          if (code.startsWith(delimiter, i)) {
            i += delimiter.length;
            closed = true;
            break;
          }
          i++;
        }
        if (!closed) throw const CommentParseException('代码字符串没有闭合，请先补全代码。');
      } else if (python && ch == '#' || !python && code.startsWith('//', i)) {
        final end = code.indexOf('\n', i);
        final stop = end < 0 ? code.length : end;
        final bodyStart = i + (python ? 1 : 2);
        final body = code.substring(bodyStart, stop).trimLeft();
        if (!RegExp(
          r'^(?:!|@|#|coding\s*[:=]|-\*-|type:|noqa|pylint:|fmt:|pragma|go:|ignore:|ignore_for_file:|sourceMappingURL|sourceURL)',
          caseSensitive: false,
        ).hasMatch(body)) {
          addLines(bodyStart, stop);
        }
        i = stop;
      } else if (!python && code.startsWith('/*', i)) {
        final end = code.indexOf('*/', i + 2);
        if (end < 0) throw const CommentParseException('块注释没有闭合，请先补全代码。');
        addLines(i + 2, end);
        i = end + 2;
      } else {
        if (js && ch == '/') {
          throw const CommentParseException(
            'JS/TS 中的正则或除法表达式暂不做注释替换，请拆出注释使用 /翻译。',
          );
        }
        i++;
      }
    }
    return CommentDocument._(code, spans);
  }

  String replace(List<String> values) {
    if (values.length != _spans.length) throw const FormatException('注释数量不一致。');
    var result = source;
    for (var i = _spans.length - 1; i >= 0; i--) {
      if (values[i].contains(RegExp(r'[\r\n]')) || values[i].contains('*/')) {
        throw const FormatException('注释不能引入换行或结束符。');
      }
      result = result.replaceRange(_spans[i].start, _spans[i].end, values[i]);
    }
    return result;
  }
}

class CommentParseException implements Exception {
  final String message;
  const CommentParseException(this.message);
}
