import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../../utils/qq_mentions.dart';

/// A standalone QQ tag would otherwise be swallowed as an HTML block.
class QqMentionPreviewBlockSyntax extends md.BlockSyntax {
  @override
  RegExp get pattern => RegExp('^ {0,3}$qqMentionPattern');
  @override
  bool canEndBlock(md.BlockParser parser) => false;
  @override
  md.Node parse(md.BlockParser parser) {
    final line = parser.current.content;
    parser.advance();
    return md.Element('p', parser.document.parseInline(line));
  }
}

/// Inline parsing leaves fenced/inline code and the original draft untouched.
class QqMentionPreviewSyntax extends md.InlineSyntax {
  final Map<String, String> names;
  QqMentionPreviewSyntax(this.names) : super(qqMentionPattern);

  @override
  bool onMatch(md.InlineParser parser, Match match) {
    final id = match.group(1);
    if (id == null) {
      parser.addNode(md.Element.text('qqmention', '@全体成员'));
      return true;
    }
    final name = names[id]?.trim();
    final node = md.Element.text(
      'qqmention',
      '@${name == null || name.isEmpty ? '群成员' : name}（$id）',
    );
    node.attributes['openid'] = id;
    parser.addNode(node);
    return true;
  }
}

class QqMentionPreviewBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Tooltip(
    message: element.attributes['openid'] == null
        ? '@ 全体成员，发送权限由 QQ 平台校验'
        : '成员 OpenID：${element.attributes['openid']}',
    child: Text(
      element.textContent,
      style: (parentStyle ?? preferredStyle ?? const TextStyle()).copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
