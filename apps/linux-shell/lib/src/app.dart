import 'dart:async';

import 'package:codex_linux_shell/src/shell_controller.dart';
import 'package:codex_linux_shell/src/shell_view.dart';
import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:codex_ui/codex_ui.dart';

class CodexLinuxShellApp extends StatefulWidget {
  const CodexLinuxShellApp({super.key});

  @override
  State<CodexLinuxShellApp> createState() => _CodexLinuxShellAppState();
}

class _CodexLinuxShellAppState extends State<CodexLinuxShellApp>
    with WindowListener, TrayListener {
  late final ShellController _controller;
  var _isQuitting = false;

  @override
  void initState() {
    super.initState();
    _controller = ShellController()..startRuntimeSupervision();
    windowManager.addListener(this);
    trayManager.addListener(this);
    unawaited(_initializeDesktopShell());
  }

  @override
  void dispose() {
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    _controller.dispose();
    super.dispose();
  }

  Future<void> _initializeDesktopShell() async {
    await windowManager.setPreventClose(true);
    try {
      await trayManager.setIcon('assets/tray/codex_tray_icon.xpm');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(
              key: 'open_window',
              label: 'Open',
              onClick: (_) => unawaited(_showWindow()),
            ),
            MenuItem(
              key: 'restart_runtime',
              label: 'Restart Runtime',
              onClick: (_) => unawaited(_controller.restartLocalRuntime()),
            ),
            MenuItem.separator(),
            MenuItem(
              key: 'quit_app',
              label: 'Quit',
              onClick: (_) => unawaited(_shutdownApp()),
            ),
          ],
        ),
      );
      _controller.setTrayAvailability(
        available: true,
        detail:
            'Tray integration is active. Closing the window hides the shell and keeps the managed bridge alive.',
      );
    } catch (error) {
      _controller.setTrayAvailability(
        available: false,
        detail:
            'Tray integration is unavailable on this desktop. Closing the window exits the shell.',
      );
      debugPrint('tray initialization failed: $error');
    }
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _shutdownApp() async {
    if (_isQuitting) {
      return;
    }
    _isQuitting = true;
    try {
      await trayManager.destroy();
    } catch (_) {
      // Ignore tray teardown failures during quit.
    }
    await _controller.shutdown();
    await windowManager.destroy();
  }

  Future<void> _chooseCodexBinary() async {
    final file = await openFile(confirmButtonText: 'Use Codex Binary');
    if (file == null) {
      return;
    }
    await _controller.savePreferredCodexBinaryPath(file.path);
  }

  @override
  void onWindowClose() {
    if (_isQuitting) {
      return;
    }
    if (_controller.state.trayAvailable) {
      unawaited(windowManager.hide());
      return;
    }
    unawaited(_shutdownApp());
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Codex Mobile Companion',
      theme: AppTheme.darkTheme,
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return ShellView(
            state: _controller.state,
            onCheckTailscale: _controller.checkTailscaleAvailability,
            onCheckCodex: _controller.checkCodexAvailability,
            onChooseCodexBinary: _chooseCodexBinary,
            onRefreshQr: _controller.refreshPairingSession,
            onRestartRuntime: _controller.restartLocalRuntime,
            onRevokeTrust: _controller.revokeTrustedPhoneFromDesktop,
          );
        },
      ),
    );
  }
}
