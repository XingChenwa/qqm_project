/// 保留多行命令中的代码缩进；代码块作为完整参数传递给插件。
({String command, List<String> args})? parseSlashCommand(String text) {
  final match = RegExp(
    r'^[/#]([^\s/#]+)(?:\s+([\s\S]*))?$',
  ).firstMatch(text.trim());
  if (match == null) return null;
  final body = match.group(2) ?? '';
  return (
    command: match.group(1)!.toLowerCase(),
    args: body.isEmpty
        ? <String>[]
        : body.contains('```')
        ? [body]
        : body.split(RegExp(r'\s+')),
  );
}
