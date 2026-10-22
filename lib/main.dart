import 'package:flutter/material.dart';
import 'bootstrap.dart';
import 'ui/widgets/startup_gate.dart';
import 'services/auxiliary_windows.dart';
import 'ui/auxiliary_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  ErrorWidget.builder = (details) => StartupFailureView(
    report: startupDiagnostic('构建应用界面', details.exception, details.stack),
    title: '界面加载失败',
  );
  // Draw a first frame before waiting on platform plugins, preferences or Hive.
  runApp(
    StartupGate(
      showBranding: AuxiliaryWindows.pendingRequest == null,
      initialize: AuxiliaryWindows.pendingRequest == null
          ? initializeApplication
          : initializeAuxiliaryApplication,
    ),
  );
}
