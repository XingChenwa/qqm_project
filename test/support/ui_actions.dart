import 'package:flutter_test/flutter_test.dart';

Future<void> revealComposerTools(WidgetTester tester) async {
  final more = find.byTooltip('更多消息功能');
  if (more.evaluate().isNotEmpty) {
    await tester.tap(more);
    await tester.pumpAndSettle();
  }
}
