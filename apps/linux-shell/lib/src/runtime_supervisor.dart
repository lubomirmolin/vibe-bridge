import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class RuntimeLaunchSnapshot {
  const RuntimeLaunchSnapshot({
    required this.statusLabel,
    required this.detail,
    required this.isLaunching,
  });

  final String statusLabel;
  final String detail;
  final bool isLaunching;
}

abstract class RuntimeSupervisorException implements Exception {
  const RuntimeSupervisorException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BridgeBinaryNotFoundException extends RuntimeSupervisorException {
  const BridgeBinaryNotFoundException(super.message);
}

class RuntimeLaunchFailedException extends RuntimeSupervisorException {
  const RuntimeLaunchFailedException(super.message);
}

abstract interface class BridgeHealthProbe {
  Future<bool> isReachable({required String host, required int port});
}

abstract interface class ManagedProcessHandle {
  int? get pid;
  bool get isRunning;
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

abstract interface class ProcessLauncher {
  Future<ManagedProcessHandle> start({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required String workingDirectory,
  });
}

abstract interface class RuntimeBinaryResolver {
  String resolveBridgeBinaryPath();
  String? resolveCodexBinaryPath();
}

class CodexCliStatus {
  const CodexCliStatus({
    required this.isReady,
    required this.statusLabel,
    required this.detail,
    required this.nextStep,
    this.binaryPath,
    this.sourceLabel,
  });

  final bool isReady;
  final String statusLabel;
  final String detail;
  final String nextStep;
  final String? binaryPath;
  final String? sourceLabel;
}

abstract interface class CodexCliChecker {
  Future<CodexCliStatus> check();
  Future<CodexCliStatus> savePreferredBinaryPath(String path);
}

class TailscaleCliStatus {
  const TailscaleCliStatus({
    required this.isInstalled,
    required this.isAuthenticated,
    required this.statusLabel,
    required this.detail,
    required this.installHint,
    this.binaryPath,
  });

  final bool isInstalled;
  final bool isAuthenticated;
  final String statusLabel;
  final String detail;
  final String installHint;
  final String? binaryPath;
}

abstract interface class TailscaleCliChecker {
  Future<TailscaleCliStatus> check();
}

abstract interface class StateDirectoryProvider {
  Directory resolveStateDirectory();
}

class ShellSettingsStore {
  ShellSettingsStore({StateDirectoryProvider? stateDirectoryProvider})
    : _stateDirectoryProvider =
          stateDirectoryProvider ?? XdgStateDirectoryProvider();

  final StateDirectoryProvider _stateDirectoryProvider;

  String? readPreferredCodexBinaryPathSync() {
    final file = _settingsFile();
    if (!file.existsSync()) {
      return null;
    }

    try {
      final payload =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final path = (payload['preferred_codex_binary_path'] as String?)?.trim();
      if (path == null || path.isEmpty) {
        return null;
      }
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<void> savePreferredCodexBinaryPath(String path) async {
    final trimmed = path.trim();
    final file = _settingsFile();
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(<String, dynamic>{'preferred_codex_binary_path': trimmed}),
    );
  }

  File _settingsFile() {
    final directory = _stateDirectoryProvider.resolveStateDirectory();
    return File('${directory.path}/linux-shell-settings.json');
  }
}

class _BinaryMatch {
  const _BinaryMatch({required this.path, required this.sourceLabel});

  final String path;
  final String sourceLabel;
}

class HttpBridgeHealthProbe implements BridgeHealthProbe {
  const HttpBridgeHealthProbe();

  @override
  Future<bool> isReachable({required String host, required int port}) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      for (final path in const ['/healthz', '/health']) {
        final uri = Uri.parse('http://$host:$port$path');
        try {
          final request = await client.getUrl(uri);
          request.headers.set(HttpHeaders.acceptHeader, 'application/json');
          final response = await request.close();
          if (response.statusCode >= 200 && response.statusCode < 300) {
            return true;
          }
        } catch (_) {
          continue;
        }
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }
}

class DartProcessLauncher implements ProcessLauncher {
  const DartProcessLauncher();

  @override
  Future<ManagedProcessHandle> start({
    required String executable,
    required List<String> arguments,
    required Map<String, String> environment,
    required String workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
    );
    return OperatingSystemProcessHandle(process);
  }
}

class OperatingSystemProcessHandle implements ManagedProcessHandle {
  OperatingSystemProcessHandle(this._process) {
    _process.exitCode.then((code) {
      _isRunning = false;
      _resolvedExitCode = code;
    });
  }

  final Process _process;
  var _isRunning = true;
  int? _resolvedExitCode;

  @override
  int? get pid => _process.pid;

  @override
  bool get isRunning => _isRunning;

  @override
  Stream<String> get stdoutLines =>
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Stream<String> get stderrLines =>
      _process.stderr.transform(utf8.decoder).transform(const LineSplitter());

  @override
  Future<int> get exitCode async =>
      _resolvedExitCode ?? await _process.exitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    return _process.kill(signal);
  }
}

class XdgStateDirectoryProvider implements StateDirectoryProvider {
  XdgStateDirectoryProvider({Map<String, String>? environment})
    : _environment = environment ?? Platform.environment;

  final Map<String, String> _environment;

  @override
  Directory resolveStateDirectory() {
    final xdgDataHome = _environment['XDG_DATA_HOME']?.trim();
    final home = _environment['HOME']?.trim();

    final root = xdgDataHome != null && xdgDataHome.isNotEmpty
        ? xdgDataHome
        : home != null && home.isNotEmpty
        ? '$home/.local/share'
        : '.';

    return Directory('$root/CodexMobileCompanion/bridge-core');
  }
}

class LinuxRuntimeBinaryResolver implements RuntimeBinaryResolver {
  LinuxRuntimeBinaryResolver({
    Map<String, String>? environment,
    String? currentDirectory,
    String? executablePath,
    ShellSettingsStore? settingsStore,
  }) : _environment = environment ?? Platform.environment,
       _currentDirectory = currentDirectory ?? Directory.current.path,
       _executablePath = executablePath ?? Platform.resolvedExecutable,
       _settingsStore =
           settingsStore ??
           ShellSettingsStore(
             stateDirectoryProvider: XdgStateDirectoryProvider(
               environment: environment ?? Platform.environment,
             ),
           );

  final Map<String, String> _environment;
  final String _currentDirectory;
  final String _executablePath;
  final ShellSettingsStore _settingsStore;

  @override
  String resolveBridgeBinaryPath() {
    final candidates = <String>[
      _environment['CODEX_MOBILE_COMPANION_BRIDGE_BINARY'] ?? '',
      _bundledBridgePath(),
      ..._workspaceBridgeCandidates(),
      ..._pathExecutableCandidates('bridge-server'),
      '/usr/local/bin/bridge-server',
    ];

    for (final candidate in _deduplicate(candidates)) {
      if (_isExecutable(candidate)) {
        return candidate;
      }
    }

    throw BridgeBinaryNotFoundException(
      'bridge helper binary was not found. Set '
      'CODEX_MOBILE_COMPANION_BRIDGE_BINARY or build the bundled helper.',
    );
  }

  @override
  String? resolveCodexBinaryPath() {
    return _inspectCodexBinary()?.path;
  }

  _BinaryMatch? _inspectCodexBinary() {
    for (final candidate in _codexBinaryCandidates()) {
      if (_isExecutable(candidate.path)) {
        return candidate;
      }
    }
    return null;
  }

  String _bundledBridgePath() {
    final executableDir = File(_executablePath).parent.path;
    return '$executableDir/data/bin/bridge-server';
  }

  List<String> _workspaceBridgeCandidates() {
    final workspaceRoot = _findWorkspaceRoot();
    if (workspaceRoot == null) {
      return const [];
    }
    return [
      '$workspaceRoot/target/debug/bridge-server',
      '$workspaceRoot/target/release/bridge-server',
    ];
  }

  String? _findWorkspaceRoot() {
    for (final seed in [
      Directory(_currentDirectory),
      File(_executablePath).parent,
    ]) {
      Directory? current = seed.absolute;
      for (var depth = 0; depth < 10 && current != null; depth += 1) {
        final cargoToml = File('${current.path}/Cargo.toml');
        final bridgeCore = Directory('${current.path}/crates/bridge-core');
        if (cargoToml.existsSync() && bridgeCore.existsSync()) {
          return current.path;
        }
        final parent = current.parent;
        if (parent.path == current.path) {
          break;
        }
        current = parent;
      }
    }
    return null;
  }

  List<String> _pathExecutableCandidates(String executable) {
    final rawPath = _environment['PATH'] ?? '';
    if (rawPath.isEmpty) {
      return const [];
    }
    return rawPath
        .split(':')
        .where((segment) => segment.trim().isNotEmpty)
        .map((segment) => '${segment.trim()}/$executable')
        .toList(growable: false);
  }

  List<String> _deduplicate(List<String> candidates) {
    final seen = <String>{};
    final unique = <String>[];
    for (final candidate in candidates) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      unique.add(trimmed);
    }
    return unique;
  }

  bool _isExecutable(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return false;
    }
    return (file.statSync().mode & 0x49) != 0;
  }

  List<_BinaryMatch> _codexBinaryCandidates() {
    final home = _environment['HOME']?.trim();
    final preferredPath = _settingsStore.readPreferredCodexBinaryPathSync();

    return _deduplicateMatches(<_BinaryMatch>[
      if ((_environment['CODEX_MOBILE_COMPANION_CODEX_BINARY'] ?? '')
          .trim()
          .isNotEmpty)
        _BinaryMatch(
          path: _environment['CODEX_MOBILE_COMPANION_CODEX_BINARY']!.trim(),
          sourceLabel: 'Environment Override',
        ),
      if (preferredPath != null && preferredPath.isNotEmpty)
        _BinaryMatch(path: preferredPath, sourceLabel: 'Saved Path'),
      ..._pathExecutableCandidates(
        'codex',
      ).map((path) => _BinaryMatch(path: path, sourceLabel: 'PATH')),
      ..._nvmCodexCandidates(),
      if (home != null && home.isNotEmpty) ...[
        _BinaryMatch(path: '$home/.bun/bin/codex', sourceLabel: 'Bun'),
        _BinaryMatch(path: '$home/.cargo/bin/codex', sourceLabel: 'Cargo Bin'),
        _BinaryMatch(path: '$home/.local/bin/codex', sourceLabel: 'Local Bin'),
      ],
      const _BinaryMatch(
        path: '/usr/local/bin/codex',
        sourceLabel: 'System Install',
      ),
    ]);
  }

  List<_BinaryMatch> _nvmCodexCandidates() {
    final home = _environment['HOME']?.trim();
    if (home == null || home.isEmpty) {
      return const [];
    }

    final versionsDir = Directory('$home/.nvm/versions/node');
    if (!versionsDir.existsSync()) {
      return const [];
    }

    final versionDirs =
        versionsDir
            .listSync(followLinks: false)
            .whereType<Directory>()
            .toList(growable: false)
          ..sort((a, b) => b.path.compareTo(a.path));

    return versionDirs
        .map(
          (directory) => _BinaryMatch(
            path: '${directory.path}/bin/codex',
            sourceLabel: 'NVM',
          ),
        )
        .toList(growable: false);
  }

  List<_BinaryMatch> _deduplicateMatches(List<_BinaryMatch> matches) {
    final seen = <String>{};
    final unique = <_BinaryMatch>[];
    for (final candidate in matches) {
      final trimmed = candidate.path.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      unique.add(
        _BinaryMatch(path: trimmed, sourceLabel: candidate.sourceLabel),
      );
    }
    return unique;
  }
}

class LinuxTailscaleCliChecker implements TailscaleCliChecker {
  LinuxTailscaleCliChecker({Map<String, String>? environment})
    : _environment = environment ?? Platform.environment;

  static const _installHint =
      'curl -fsSL https://tailscale.com/install.sh | sh';
  final Map<String, String> _environment;

  @override
  Future<TailscaleCliStatus> check() async {
    final binaryPath = _resolveBinaryPath();
    if (binaryPath == null) {
      return const TailscaleCliStatus(
        isInstalled: false,
        isAuthenticated: false,
        statusLabel: 'Not Installed',
        detail:
            'Tailscale CLI was not found. Install it and then run `sudo tailscale up` to enable the private pairing route.',
        installHint: _installHint,
      );
    }

    try {
      final result = await Process.run(binaryPath, const [
        'status',
        '--json',
      ], environment: Map<String, String>.from(_environment));

      if (result.exitCode != 0) {
        final stderr = (result.stderr as String?)?.trim();
        final summary = stderr == null || stderr.isEmpty
            ? 'Run `sudo tailscale up` and make sure the daemon is active.'
            : stderr;
        return TailscaleCliStatus(
          isInstalled: true,
          isAuthenticated: false,
          statusLabel: 'Installed, Not Connected',
          detail: 'Tailscale CLI was found at $binaryPath. $summary',
          installHint: 'sudo tailscale up',
          binaryPath: binaryPath,
        );
      }

      final payload =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final backendState =
          (payload['BackendState'] as String?)?.trim() ?? 'Unknown';
      final self = payload['Self'] as Map<String, dynamic>?;
      final hostName = (self?['HostName'] as String?)?.trim();
      final isAuthenticated = backendState.toLowerCase() == 'running';

      return TailscaleCliStatus(
        isInstalled: true,
        isAuthenticated: isAuthenticated,
        statusLabel: isAuthenticated ? 'Connected' : backendState,
        detail: isAuthenticated
            ? 'Tailscale is connected${hostName == null || hostName.isEmpty ? '' : ' as $hostName'}.'
            : 'Tailscale CLI was found at $binaryPath, but the tailnet is not connected yet. Run `sudo tailscale up`.',
        installHint: isAuthenticated ? '' : 'sudo tailscale up',
        binaryPath: binaryPath,
      );
    } catch (error) {
      return TailscaleCliStatus(
        isInstalled: true,
        isAuthenticated: false,
        statusLabel: 'Installed',
        detail:
            'Tailscale CLI was found at $binaryPath, but status could not be checked: $error',
        installHint: 'sudo tailscale up',
        binaryPath: binaryPath,
      );
    }
  }

  String? _resolveBinaryPath() {
    final home = _environment['HOME']?.trim();
    final candidates = <String>[
      _environment['CODEX_MOBILE_COMPANION_TAILSCALE_BIN'] ?? '',
      ..._pathExecutableCandidates('tailscale'),
      if (home != null && home.isNotEmpty) '$home/.local/bin/tailscale',
      '/usr/bin/tailscale',
      '/usr/local/bin/tailscale',
    ];

    for (final candidate in _deduplicate(candidates)) {
      if (_isExecutable(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  List<String> _pathExecutableCandidates(String executable) {
    final rawPath = _environment['PATH'] ?? '';
    if (rawPath.isEmpty) {
      return const [];
    }
    return rawPath
        .split(':')
        .where((segment) => segment.trim().isNotEmpty)
        .map((segment) => '${segment.trim()}/$executable')
        .toList(growable: false);
  }

  List<String> _deduplicate(List<String> candidates) {
    final seen = <String>{};
    final unique = <String>[];
    for (final candidate in candidates) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      unique.add(trimmed);
    }
    return unique;
  }

  bool _isExecutable(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      return false;
    }
    return (file.statSync().mode & 0x49) != 0;
  }
}

class LinuxCodexCliChecker implements CodexCliChecker {
  LinuxCodexCliChecker({
    Map<String, String>? environment,
    ShellSettingsStore? settingsStore,
  }) : _settingsStore =
           settingsStore ??
           ShellSettingsStore(
             stateDirectoryProvider: XdgStateDirectoryProvider(
               environment: environment ?? Platform.environment,
             ),
           ),
       _binaryResolver = LinuxRuntimeBinaryResolver(
         environment: environment,
         settingsStore: settingsStore,
       );

  final ShellSettingsStore _settingsStore;
  final LinuxRuntimeBinaryResolver _binaryResolver;

  @override
  Future<CodexCliStatus> check() async {
    final match = _binaryResolver._inspectCodexBinary();
    if (match == null) {
      return const CodexCliStatus(
        isReady: false,
        statusLabel: 'Codex Not Found',
        detail:
            'Codex CLI is not available to the Linux shell yet. Choose the `codex` binary so the bridge can start the local runtime for threads and approvals.',
        nextStep: 'Choose the codex binary',
      );
    }

    return CodexCliStatus(
      isReady: true,
      statusLabel: 'Codex Ready',
      detail:
          'Codex CLI is available from ${match.sourceLabel.toLowerCase()}. The Linux shell can use it to start the local runtime.',
      nextStep: '',
      binaryPath: match.path,
      sourceLabel: match.sourceLabel,
    );
  }

  @override
  Future<CodexCliStatus> savePreferredBinaryPath(String path) async {
    final file = File(path.trim());
    if (!file.existsSync()) {
      throw const RuntimeLaunchFailedException(
        'the selected Codex binary does not exist',
      );
    }
    if ((file.statSync().mode & 0x49) == 0) {
      throw const RuntimeLaunchFailedException(
        'the selected Codex binary is not executable',
      );
    }

    await _settingsStore.savePreferredCodexBinaryPath(file.path);
    return check();
  }
}

class RuntimeSupervisor {
  RuntimeSupervisor({
    BridgeHealthProbe? healthProbe,
    ProcessLauncher? processLauncher,
    RuntimeBinaryResolver? binaryResolver,
    StateDirectoryProvider? stateDirectoryProvider,
    Map<String, String>? processEnvironment,
    this.bridgeHost = '127.0.0.1',
    this.bridgePort = 3110,
    this.adminPort = 3111,
  }) : _healthProbe = healthProbe ?? const HttpBridgeHealthProbe(),
       _processLauncher = processLauncher ?? const DartProcessLauncher(),
       _binaryResolver = binaryResolver ?? LinuxRuntimeBinaryResolver(),
       _stateDirectoryProvider =
           stateDirectoryProvider ?? XdgStateDirectoryProvider(),
       _processEnvironment = processEnvironment ?? Platform.environment;

  final BridgeHealthProbe _healthProbe;
  final ProcessLauncher _processLauncher;
  final RuntimeBinaryResolver _binaryResolver;
  final StateDirectoryProvider _stateDirectoryProvider;
  final Map<String, String> _processEnvironment;
  final String bridgeHost;
  final int bridgePort;
  final int adminPort;

  ManagedProcessHandle? _managedProcess;
  final List<String> _recentLogLines = <String>[];
  String? _lastExitSummary;

  bool get managesProcess => _managedProcess != null;

  Future<RuntimeLaunchSnapshot> prepareBridgeForConnection() async {
    final reachable = await _healthProbe.isReachable(
      host: bridgeHost,
      port: bridgePort,
    );

    if (reachable) {
      final managedProcess = _managedProcess;
      if (managedProcess != null && managedProcess.isRunning) {
        return RuntimeLaunchSnapshot(
          statusLabel: 'Managed locally',
          detail: 'Linux shell owns the local bridge process.',
          isLaunching: false,
        );
      }

      if (managedProcess != null && !managedProcess.isRunning) {
        _managedProcess = null;
      }

      return RuntimeLaunchSnapshot(
        statusLabel: 'Attached to existing bridge',
        detail:
            'An existing bridge is already listening on $bridgeHost:$bridgePort.',
        isLaunching: false,
      );
    }

    final managedProcess = _managedProcess;
    if (managedProcess != null) {
      if (managedProcess.isRunning) {
        return RuntimeLaunchSnapshot(
          statusLabel: 'Launching bridge',
          detail:
              'Linux shell started the bridge helper (pid ${managedProcess.pid ?? 0}). '
              'Waiting for health on $bridgeHost:$bridgePort…',
          isLaunching: true,
        );
      }

      final exitSummary =
          _lastExitSummary ?? 'bridge helper exited before reporting healthy';
      _managedProcess = null;
      _recentLogLines.clear();
      _lastExitSummary = null;
      throw RuntimeLaunchFailedException(exitSummary);
    }

    return _startBridgeProcess();
  }

  Future<RuntimeLaunchSnapshot> restartBridge() async {
    final reachable = await _healthProbe.isReachable(
      host: bridgeHost,
      port: bridgePort,
    );
    if (_managedProcess == null && reachable) {
      throw const RuntimeLaunchFailedException(
        'linux shell cannot restart the bridge because it is attached to an external process '
        'on 127.0.0.1:3110',
      );
    }

    await shutdownBridgeIfManaged();
    return _startBridgeProcess();
  }

  Future<void> shutdownBridgeIfManaged() async {
    final managedProcess = _managedProcess;
    if (managedProcess == null) {
      return;
    }

    if (managedProcess.isRunning) {
      managedProcess.kill(ProcessSignal.sigterm);
      try {
        await managedProcess.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        managedProcess.kill(ProcessSignal.sigkill);
        try {
          await managedProcess.exitCode.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          // Ignore hard-stop failure on shutdown.
        }
      }
    }

    _managedProcess = null;
  }

  Future<RuntimeLaunchSnapshot> _startBridgeProcess() async {
    final stateDirectory = _stateDirectoryProvider.resolveStateDirectory();
    await stateDirectory.create(recursive: true);

    final bridgeBinaryPath = _binaryResolver.resolveBridgeBinaryPath();
    final codexBinaryPath = _binaryResolver.resolveCodexBinaryPath();

    final arguments = <String>[
      '--host',
      bridgeHost,
      '--port',
      '$bridgePort',
      '--admin-port',
      '$adminPort',
      '--state-directory',
      stateDirectory.path,
      '--codex-mode',
      'auto',
      if (codexBinaryPath != null) ...['--codex-command', codexBinaryPath],
    ];

    final process = await _processLauncher.start(
      executable: bridgeBinaryPath,
      arguments: arguments,
      environment: Map<String, String>.from(_processEnvironment),
      workingDirectory: stateDirectory.path,
    );

    _wireLogs(process.stdoutLines, source: 'stdout');
    _wireLogs(process.stderrLines, source: 'stderr');
    unawaited(
      process.exitCode.then((code) {
        final summary = _recentLogLines.isNotEmpty
            ? _recentLogLines.last
            : 'bridge helper exited with code $code';
        _lastExitSummary = 'bridge helper exited with code $code. $summary';
      }),
    );

    _managedProcess = process;
    return RuntimeLaunchSnapshot(
      statusLabel: 'Launching bridge',
      detail:
          'Linux shell launched the bridge helper (pid ${process.pid ?? 0}). '
          'Waiting for health on $bridgeHost:$bridgePort…',
      isLaunching: true,
    );
  }

  void _wireLogs(Stream<String> lines, {required String source}) {
    unawaited(
      lines.listen((line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          return;
        }
        final entry = '[$source] $trimmed';
        _recentLogLines.add(entry);
        if (_recentLogLines.length > 25) {
          _recentLogLines.removeAt(0);
        }
        debugPrint('bridge-server $entry');
      }).asFuture<void>(),
    );
  }
}
