import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared physical-keyboard behavior for the text and Markdown composers.
class ComposerKeyboard extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final Widget child;

  const ComposerKeyboard({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.child,
  });

  KeyEventResult _handleKey(FocusNode _, KeyEvent event) {
    if (!focusNode.hasFocus ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter) ||
        event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    final value = controller.value;
    if (value.composing.isValid && !value.composing.isCollapsed) {
      // Let the platform IME confirm a candidate; don't send or insert a line.
      return KeyEventResult.skipRemainingHandlers;
    }

    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed || keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    if (keyboard.isShiftPressed && !keyboard.isControlPressed) {
      return KeyEventResult.ignored;
    }
    // Consume held Enter without sending a second message or inserting a line.
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    if (keyboard.isControlPressed) {
      final selection = value.selection;
      final start = selection.isValid ? selection.start : value.text.length;
      final end = selection.isValid ? selection.end : start;
      controller.value = TextEditingValue(
        text: value.text.replaceRange(start, end, '\n'),
        selection: TextSelection.collapsed(offset: start + 1),
      );
    } else {
      onSend();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _handleKey,
    child: child,
  );
}
