import 'dart:convert';

/// Gradio 4 keeps queue/data open between jobs. Stop after a WHOLE terminal
/// SSE frame, rather than waiting for EOF and turning completed jobs into
/// timeouts. This parser only finds a boundary; callers retain original bytes.
class GradioEventBoundary {
  String _line = '', _event = '';
  final _data = <String>[];
  int _size = 0;
  bool _overflow = false;

  bool add(List<int> bytes) {
    // Only the ASCII protocol keys/event names are inspected. Original UTF-8
    // bytes remain untouched for the actual result parser.
    _line += ascii.decode(bytes, allowInvalid: true);
    for (;;) {
      final at = _line.indexOf('\n');
      if (at < 0) {
        if (_line.length > 262144) {
          _line = '';
          _overflow = true;
        }
        return false;
      }
      var line = _line.substring(0, at);
      _line = _line.substring(at + 1);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (line.isEmpty) {
        final terminal = !_overflow && _terminal();
        _event = '';
        _data.clear();
        _size = 0;
        _overflow = false;
        if (terminal) return true;
      } else if (line.startsWith('event:')) {
        _event = line.substring(6).trim();
      } else if (line.startsWith('data:') && !_overflow) {
        _size += line.length;
        if (_size > 262144) {
          _overflow = true;
          _data.clear();
        } else {
          _data.add(line.substring(5).trimLeft());
        }
      }
    }
  }

  bool _terminal() {
    if (_event == 'complete' || _event == 'error') return true;
    try {
      final value = jsonDecode(_data.join('\n'));
      return value is Map &&
          const {
            'process_completed',
            'queue_full',
            'unexpected_error',
            'close_stream',
          }.contains(value['msg']);
    } catch (_) {
      return false;
    }
  }
}
