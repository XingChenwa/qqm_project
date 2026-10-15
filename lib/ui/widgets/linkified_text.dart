import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../models/qq_face.dart';
import '../../services/qface_service.dart';
import '../screens/browser_screen.dart';

class LinkifiedText extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final bool qqFaces;
  final List<dynamic>? mentions;
  final QFaceService? faceService;
  const LinkifiedText(
    this.text, {
    super.key,
    this.style,
    this.qqFaces = false,
    this.mentions,
    this.faceService,
  });

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];
  Future<QFaceCatalog>? _catalog;

  @override
  void didUpdateWidget(covariant LinkifiedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.faceService, widget.faceService)) _catalog = null;
  }

  void _clear() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.qqFaces) return _render(context, [QqTextPart(widget.text)]);
    final parts = QqTextPart.parse(widget.text, mentions: widget.mentions);
    if (!parts.any((part) => part.isFace && !part.sticker)) {
      return _render(context, parts);
    }
    return FutureBuilder<QFaceCatalog>(
      future: _catalog ??= (widget.faceService ?? QFaceService.shared)
          .getCatalog(),
      builder: (context, snapshot) => _render(context, parts, snapshot.data),
    );
  }

  Widget _render(
    BuildContext context,
    List<QqTextPart> parts, [
    QFaceCatalog? catalog,
  ]) {
    _clear();
    final spans = <InlineSpan>[];
    var hasImages = false;
    for (final part in parts) {
      final face = catalog?.resolve(part);
      if (face == null) {
        _appendLinks(context, spans, part.text);
      } else {
        hasImages = true;
        final size = (widget.style?.fontSize ?? 14) * 1.8;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: 'QQ 表情：${face.label}',
              child: Tooltip(
                message: face.label,
                child: Image.network(
                  face.url,
                  key: ValueKey('qface-${face.id}'),
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) =>
                      Text(part.text, style: widget.style),
                ),
              ),
            ),
          ),
        );
      }
    }
    final span = TextSpan(children: spans, style: widget.style);
    // SelectableText.rich only accepts TextSpans. SelectionArea supports
    // WidgetSpans without treating embedded images as editable text.
    return hasImages
        ? SelectionArea(child: Text.rich(span))
        : SelectableText.rich(span);
  }

  void _appendLinks(BuildContext context, List<InlineSpan> spans, String text) {
    var start = 0;
    for (final match in RegExp(
      r'''https?://[^\s<>"\u3000]+''',
    ).allMatches(text)) {
      final url = match
          .group(0)!
          .replaceFirst(RegExp(r'[.,;!?)\]，。；！）】]+$'), '');
      if (browserUri(url) == null) continue;
      spans.add(TextSpan(text: text.substring(start, match.start)));
      final recognizer = TapGestureRecognizer()
        ..onTap = () => openInAppBrowser(context, url);
      _recognizers.add(recognizer);
      spans.add(
        TextSpan(
          text: url,
          recognizer: recognizer,
          style: const TextStyle(
            decoration: TextDecoration.underline,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
      start = match.start + url.length;
    }
    spans.add(TextSpan(text: text.substring(start)));
  }
}
