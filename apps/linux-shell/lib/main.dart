import 'dart:async';

import 'package:codex_linux_shell/src/app.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(1120, 780),
    minimumSize: Size(640, 720),
    center: true,
    title: 'Codex Mobile Companion',
    backgroundColor: Colors.transparent,
  );

  unawaited(
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    }),
  );

  runApp(const CodexLinuxShellApp());
}
