import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../services/desktop_window_controller.dart';
import '../../utils/constants.dart';
import '../themes/app_theme.dart';
import 'app_logo.dart';

class DesktopWindowFrame extends StatelessWidget {
  final DesktopWindowController controller;
  final Widget child;
  const DesktopWindowFrame({
    super.key,
    required this.controller,
    required this.child,
  });

  Widget _button({
    required String hint,
    required IconData icon,
    required VoidCallback onPressed,
    bool close = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: IconButton(
      tooltip: hint,
      onPressed: onPressed,
      icon: Icon(icon, size: 17),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(40, 32)),
        maximumSize: const WidgetStatePropertyAll(Size(40, 32)),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.pressed)
              ? (close
                    ? AppTheme.qqRed
                    : AppTheme.qqBlue.withValues(alpha: .10))
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) =>
              close &&
                  (states.contains(WidgetState.hovered) ||
                      states.contains(WidgetState.pressed))
              ? Colors.white
              : (close ? AppTheme.qqRed : null),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      if (!controller.ready) return child;
      return Overlay.wrap(
        child: DragToResizeArea(
          resizeEdgeSize: 5,
          enableResizeEdges: controller.maximized ? const [] : null,
          child: Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.fromLTRB(12, 4, 8, 4),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Theme.of(context).dividerColor),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          key: const ValueKey('window-drag-region'),
                          behavior: HitTestBehavior.opaque,
                          onPanStart: (_) => controller.drag(),
                          onDoubleTap: controller.toggleMaximize,
                          child: Row(
                            children: [
                              const AppLogo(size: 26),
                              const SizedBox(width: 9),
                              const Flexible(
                                child: Text(
                                  'QQ 机器人管理器',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 9),
                              Text(
                                'v${AppConstants.appVersion}',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Theme.of(context).hintColor,
                                ),
                              ),
                              const Spacer(),
                            ],
                          ),
                        ),
                      ),
                      if (controller.error.isNotEmpty)
                        Tooltip(
                          message: controller.error,
                          child: const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 8),
                            child: Icon(
                              Icons.warning_amber_rounded,
                              size: 18,
                              color: AppTheme.amber,
                            ),
                          ),
                        ),
                      _button(
                        hint: '最小化',
                        icon: Icons.horizontal_rule_rounded,
                        onPressed: controller.minimize,
                      ),
                      _button(
                        hint: controller.maximized ? '还原窗口' : '最大化',
                        icon: controller.maximized
                            ? Icons.filter_none_rounded
                            : Icons.crop_square_rounded,
                        onPressed: controller.toggleMaximize,
                      ),
                      _button(
                        hint: '关闭窗口',
                        icon: Icons.close_rounded,
                        close: true,
                        onPressed: controller.requestClose,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      );
    },
  );
}
