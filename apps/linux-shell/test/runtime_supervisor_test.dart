import 'dart:async';
import 'dart:io';

import 'package:codex_linux_shell/src/runtime_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RuntimeSupervisor', () {
    late FakeHealthProbe healthProbe;
    late FakeProcessLauncher processLauncher;
    late FakeBinaryResolver binaryResolver;
    late FakeStateDirectoryProvider stateDirectoryProvider;
    late RuntimeSupervisor supervisor;

    setUp(() {
      healthProbe = FakeHealthProbe();
      processLauncher = FakeProcessLauncher();
      binaryResolver = FakeBinaryResolver();
      stateDirectoryProvider = FakeStateDirectoryProvider();
      supervisor = RuntimeSupervisor(
        healthProbe: healthProbe,
        processLauncher: processLauncher,
        binaryResolver: binaryResolver,
        stateDirectoryProvider: stateDirectoryProvider,
        portProcessInspector: FakePortProcessInspector(),
        processEnvironment: const {'HOME': '/tmp/test-home'},
      );
    });

    test('launches managed bridge when no listener exists', () async {
      healthProbe.reachable = false;
      final process = FakeManagedProcessHandle(pid: 4242, running: true);
      processLauncher.nextProcess = process;

      final snapshot = await supervisor.prepareBridgeForConnection();

      expect(snapshot.statusLabel, 'Launching bridge');
      expect(snapshot.isLaunching, isTrue);
      expect(processLauncher.calls, hasLength(1));
      expect(processLauncher.calls.single.executable, '/bundle/bridge-server');
      expect(
        processLauncher.calls.single.arguments,
        containsAllInOrder([
          '--host',
          '127.0.0.1',
          '--port',
          '3110',
          '--admin-port',
          '3111',
          '--state-directory',
          stateDirectoryProvider.directory.path,
          '--codex-mode',
          'auto',
          '--codex-command',
          '/usr/local/bin/codex',
        ]),
      );
      expect(
        processLauncher.calls.single.environment['PATH'],
        '/usr/local/bin',
      );
    });

    test('attaches cleanly when bridge is already healthy', () async {
      healthProbe.reachable = true;

      final snapshot = await supervisor.prepareBridgeForConnection();

      expect(snapshot.statusLabel, 'Attached to existing bridge');
      expect(processLauncher.calls, isEmpty);
    });

    test('restart refuses to kill externally owned bridge', () async {
      healthProbe.reachable = true;

      await expectLater(
        supervisor.restartBridge(),
        throwsA(
          isA<RuntimeLaunchFailedException>().having(
            (error) => error.message,
            'message',
            contains('attached to an external process'),
          ),
        ),
      );
      expect(processLauncher.calls, isEmpty);
    });

    test('stopManagedBridge stops managed child processes', () async {
      healthProbe.reachable = false;
      final process = FakeManagedProcessHandle(pid: 7, running: true);
      processLauncher.nextProcess = process;
      await supervisor.prepareBridgeForConnection();

      await supervisor.stopManagedBridge();

      expect(process.killSignals, contains(ProcessSignal.sigterm));
    });

    test('shutdownBridgeIfManaged detaches without killing', () async {
      healthProbe.reachable = false;
      final process = FakeManagedProcessHandle(pid: 7, running: true);
      processLauncher.nextProcess = process;
      await supervisor.prepareBridgeForConnection();

      await supervisor.shutdownBridgeIfManaged();

      expect(process.killSignals, isEmpty);
    });

    test('shutdown after external attach does not kill anything', () async {
      healthProbe.reachable = true;

      await supervisor.prepareBridgeForConnection();
      await supervisor.shutdownBridgeIfManaged();

      expect(processLauncher.calls, isEmpty);
    });

    test('persists bridge crash logs and surfaces recent log tail', () async {
      healthProbe.reachable = false;
      final process = FakeManagedProcessHandle(pid: 4242, running: true);
      processLauncher.nextProcess = process;

      await supervisor.prepareBridgeForConnection();
      process.emitStdout('bridge booted');
      process.emitStderr('panic: bind failed');
      process.completeExit(101);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await expectLater(
        supervisor.prepareBridgeForConnection(),
        throwsA(
          isA<RuntimeLaunchFailedException>().having(
            (error) => error.message,
            'message',
            allOf([
              contains('bridge helper exited with code 101'),
              contains('[stdout] bridge booted'),
              contains('[stderr] panic: bind failed'),
              contains('bridge-supervisor.log'),
            ]),
          ),
        ),
      );

      final logFile = File(
        '${stateDirectoryProvider.directory.path}/bridge-supervisor.log',
      );
      expect(logFile.existsSync(), isTrue);
      final contents = await logFile.readAsString();
      expect(contents, contains('[supervisor] bridge helper launched'));
      expect(contents, contains('[stdout] bridge booted'));
      expect(contents, contains('[stderr] panic: bind failed'));
      expect(contents, contains('bridge helper exited with code 101'));
    });

    test('codex resolver discovers nvm installs automatically', () async {
      final home = Directory.systemTemp.createTempSync('linux-shell-home-');
      addTearDown(() {
        if (home.existsSync()) {
          home.deleteSync(recursive: true);
        }
      });
      final binary = File('${home.path}/.nvm/versions/node/v24.14.0/bin/codex')
        ..createSync(recursive: true);
      binary.writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', <String>['755', binary.path]);

      final resolver = LinuxRuntimeBinaryResolver(
        environment: <String, String>{'HOME': home.path, 'PATH': '/usr/bin'},
      );

      expect(
        resolver.resolveCodexBinaryPath(),
        '${home.path}/.nvm/versions/node/v24.14.0/bin/codex',
      );
    });

    test('codex checker prefers a saved binary path', () async {
      final home = Directory.systemTemp.createTempSync('linux-shell-home-');
      addTearDown(() {
        if (home.existsSync()) {
          home.deleteSync(recursive: true);
        }
      });
      final stateDirectoryProvider = _FixedStateDirectoryProvider(
        Directory('${home.path}/state')..createSync(recursive: true),
      );
      final settingsStore = ShellSettingsStore(
        stateDirectoryProvider: stateDirectoryProvider,
      );
      final binary = File('${home.path}/custom/codex')
        ..createSync(recursive: true)
        ..writeAsStringSync('#!/bin/sh\n');
      Process.runSync('chmod', <String>['755', binary.path]);

      final checker = LinuxCodexCliChecker(
        environment: <String, String>{'HOME': home.path, 'PATH': '/usr/bin'},
        settingsStore: settingsStore,
      );

      final status = await checker.savePreferredBinaryPath(binary.path);

      expect(status.isReady, isTrue);
      expect(status.binaryPath, binary.path);
      expect(status.sourceLabel, 'Saved Path');
    });

    test(
      'codex checker validates nvm wrapper binaries via adjusted path',
      () async {
        final home = Directory.systemTemp.createTempSync('linux-shell-home-');
        addTearDown(() {
          if (home.existsSync()) {
            home.deleteSync(recursive: true);
          }
        });
        final binDir = Directory('${home.path}/.nvm/versions/node/v24.14.0/bin')
          ..createSync(recursive: true);
        final nodeBinary = File('${binDir.path}/node')
          ..writeAsStringSync('#!/bin/sh\nexit 0\n');
        final codexBinary = File('${binDir.path}/codex')
          ..writeAsStringSync('#!/usr/bin/env node\n');
        Process.runSync('chmod', <String>['755', nodeBinary.path]);
        Process.runSync('chmod', <String>['755', codexBinary.path]);

        final checker = LinuxCodexCliChecker(
          environment: <String, String>{'HOME': home.path, 'PATH': '/usr/bin'},
        );

        final status = await checker.check();

        expect(status.isReady, isTrue);
        expect(status.binaryPath, codexBinary.path);
        expect(status.sourceLabel, 'NVM');
      },
    );
  });
}

class FakeHealthProbe implements BridgeHealthProbe {
  bool reachable = false;

  @override
  Future<bool> isReachable({required String host, required int port}) async {
    return reachable;
  }
}

class FakeProcessLauncher implements ProcessLauncher {
  final List<ProcessLaunchCall> calls = <ProcessLaunchCall>[];
  FakeManagedProcessHandle? nextProcess;

  @override
  Future<ManagedProcessHandle> start({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required String workingDirectory,
  }) async {
    calls.add(
      ProcessLaunchCall(
        executable: executable,
        arguments: List<String>.from(arguments),
        environment: Map<String, String>.from(environment),
        workingDirectory: workingDirectory,
      ),
    );
    return nextProcess ?? FakeManagedProcessHandle(pid: 1000, running: true);
  }
}

class ProcessLaunchCall {
  ProcessLaunchCall({
    required this.executable,
    required this.arguments,
    required this.environment,
    required this.workingDirectory,
  });

  final String executable;
  final List<String> arguments;
  final Map<String, String> environment;
  final String workingDirectory;
}

class FakeManagedProcessHandle implements ManagedProcessHandle {
  FakeManagedProcessHandle({required this.pid, required bool running})
    : _running = running;

  @override
  final int? pid;

  final List<ProcessSignal> killSignals = <ProcessSignal>[];
  bool _running;
  final Completer<int> _exitCode = Completer<int>();
  final StreamController<String> _stdoutController = StreamController<String>();
  final StreamController<String> _stderrController = StreamController<String>();

  @override
  bool get isRunning => _running;

  @override
  Stream<String> get stdoutLines => _stdoutController.stream;

  @override
  Stream<String> get stderrLines => _stderrController.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  void emitStdout(String line) {
    _stdoutController.add(line);
  }

  void emitStderr(String line) {
    _stderrController.add(line);
  }

  void completeExit(int code) {
    _running = false;
    if (!_exitCode.isCompleted) {
      _exitCode.complete(code);
    }
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killSignals.add(signal);
    completeExit(signal == ProcessSignal.sigkill ? -9 : 0);
    return true;
  }
}

class FakeBinaryResolver implements RuntimeBinaryResolver {
  @override
  String resolveBridgeBinaryPath() => '/bundle/bridge-server';

  @override
  String? resolveCodexBinaryPath() => '/usr/local/bin/codex';
}

class FakeStateDirectoryProvider implements StateDirectoryProvider {
  FakeStateDirectoryProvider()
    : directory = Directory.systemTemp.createTempSync('linux-shell-test-');

  final Directory directory;

  @override
  Directory resolveStateDirectory() => directory;
}

class _FixedStateDirectoryProvider implements StateDirectoryProvider {
  _FixedStateDirectoryProvider(this.directory);

  final Directory directory;

  @override
  Directory resolveStateDirectory() => directory;
}

class FakePortProcessInspector implements PortProcessInspector {
  BridgePortProcess? nextListener;

  @override
  BridgePortProcess? listenerOnPort(int port) => nextListener;
}
