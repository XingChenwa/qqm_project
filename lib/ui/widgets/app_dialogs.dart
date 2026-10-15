import 'dart:async';

import 'package:flutter/material.dart';

/// One queue per application navigator; repeated notices share one dialog.
class AppDialogs {
  static final _queues = Expando<_DialogQueue>();

  static Future<T?> present<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    String? key,
    bool barrierDismissible = true,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final queue = _queues[navigator] ??= _DialogQueue();
    final existing = key == null ? null : queue.pending[key];
    if (existing != null) return existing.then((value) => value as T?);
    final result = Completer<Object?>();
    if (key != null) queue.pending[key] = result.future;
    queue.tail = queue.tail.then((_) async {
      try {
        if (!navigator.mounted) {
          result.complete(null);
          return;
        }
        final target = navigator.overlay?.context ?? navigator.context;
        if (!target.mounted) {
          result.complete(null);
          return;
        }
        final value = await showDialog<T>(
          context: target,
          useRootNavigator: false,
          barrierDismissible: barrierDismissible,
          builder: builder,
        );
        result.complete(value);
      } catch (error, stack) {
        result.completeError(error, stack);
      } finally {
        if (key != null) queue.pending.remove(key);
      }
    });
    return result.future.then((value) => value as T?);
  }

  static Future<void> show(
    BuildContext context,
    String message, {
    String title = '提示',
    bool error = false,
  }) async {
    await present<void>(
      context,
      key: 'notice:$title:$error:$message',
      builder: (dialog) => AlertDialog(
        title: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.info_outline,
              color: error ? Theme.of(dialog).colorScheme.error : null,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(title)),
          ],
        ),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }
}

class _DialogQueue {
  Future<void> tail = Future.value();
  final pending = <String, Future<Object?>>{};
}
