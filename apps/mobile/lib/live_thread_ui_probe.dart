import 'dart:async';
import 'dart:io';

import 'package:vibe_bridge/features/approvals/data/approval_bridge_api.dart';
import 'package:vibe_bridge/features/settings/data/settings_bridge_api.dart';
import 'package:vibe_bridge/features/threads/application/thread_detail_controller.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_detail_page.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:vibe_bridge/foundation/storage/secure_store_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  runApp(
    ProviderScope(
      overrides: [
        appSecureStoreProvider.overrideWithValue(InMemorySecureStore()),
        approvalBridgeApiProvider.overrideWithValue(
          const _ProbeApprovalBridgeApi(),
        ),
        settingsBridgeApiProvider.overrideWithValue(
          const _ProbeSettingsBridgeApi(),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: _LiveThreadUiProbePage(
          bridgeApiBaseUrl: _resolveBridgeApiBaseUrl(),
          threadId: _resolveThreadId(),
          promptToken: _resolvePromptToken(),
        ),
      ),
    ),
  );
}

class _LiveThreadUiProbePage extends ConsumerStatefulWidget {
  const _LiveThreadUiProbePage({
    required this.bridgeApiBaseUrl,
    required this.threadId,
    required this.promptToken,
  });

  final String bridgeApiBaseUrl;
  final String threadId;
  final String promptToken;

  @override
  ConsumerState<_LiveThreadUiProbePage> createState() =>
      _LiveThreadUiProbePageState();
}

class _LiveThreadUiProbePageState
    extends ConsumerState<_LiveThreadUiProbePage> {
  late final Stopwatch _stopwatch;
  late final ThreadDetailControllerArgs _args;
  late final ProviderSubscription<ThreadDetailState> _subscription;
  Timer? _timeoutTimer;

  int? _loadedMs;
  int? _runningMs;
  int? _assistantVisibleMs;
  int? _completedMs;
  bool _submitted = false;
  bool _printed = false;
  String _statusText = 'booting';

  @override
  void initState() {
    super.initState();
    _stopwatch = Stopwatch()..start();
    _args = ThreadDetailControllerArgs(
      bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
      threadId: widget.threadId,
    );

    _subscription = ref.listenManual<ThreadDetailState>(
      threadDetailControllerProvider(_args),
      (previous, next) {
        _handleState(next);
      },
      fireImmediately: true,
    );

    unawaited(_runConnectivityProbe());

    _timeoutTimer = Timer(const Duration(seconds: 45), () {
      _emitResult('timeout');
    });
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _subscription.close();
    super.dispose();
  }

  void _handleState(ThreadDetailState state) {
    if (!mounted || _printed) {
      return;
    }

    if (_loadedMs == null && state.thread != null && !state.isLoading) {
      _loadedMs = _stopwatch.elapsedMilliseconds;
      _statusText = 'loaded';
      setState(() {});
    }

    if (_loadedMs != null &&
        !_submitted &&
        state.thread != null &&
        !state.isTurnActive &&
        !state.isComposerMutationInFlight) {
      _submitted = true;
      _statusText = 'submitting';
      setState(() {});
      unawaited(
        ref
            .read(threadDetailControllerProvider(_args).notifier)
            .submitComposerInput('Reply with exactly ${widget.promptToken}'),
      );
    }

    if (_submitted && _runningMs == null && state.isTurnActive) {
      _runningMs = _stopwatch.elapsedMilliseconds;
      _statusText = 'running';
      setState(() {});
    }

    if (_submitted &&
        _assistantVisibleMs == null &&
        state.items.any((item) => item.body.contains(widget.promptToken))) {
      _assistantVisibleMs = _stopwatch.elapsedMilliseconds;
      _statusText = 'assistant_visible';
      setState(() {});
    }

    if (_submitted &&
        _assistantVisibleMs != null &&
        _completedMs == null &&
        !state.isTurnActive &&
        !state.isComposerMutationInFlight) {
      _completedMs = _stopwatch.elapsedMilliseconds;
      _statusText = 'completed';
      setState(() {});
      _emitResult('ok');
    }

    if (state.errorMessage != null) {
      _emitResult('error:${state.errorMessage}');
    }
  }

  Future<void> _runConnectivityProbe() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(
        Uri.parse('${widget.bridgeApiBaseUrl}/threads'),
      );
      final response = await request.close();
      final body = await response.transform(SystemEncoding().decoder).join();
      final preview = body.length > 120 ? body.substring(0, 120) : body;
      debugPrint(
        'REWRITE_LIVE_THREAD_UI_PROBE_CONNECTIVITY '
        'status=${response.statusCode} '
        'body_preview=${preview.replaceAll('\n', ' ')}',
      );
    } catch (error) {
      debugPrint(
        'REWRITE_LIVE_THREAD_UI_PROBE_CONNECTIVITY '
        'error=$error '
        'type=${error.runtimeType}',
      );
    } finally {
      client.close();
    }
  }

  void _emitResult(String outcome) {
    if (_printed) {
      return;
    }
    _printed = true;
    _timeoutTimer?.cancel();

    final result =
        'REWRITE_LIVE_THREAD_UI_PROBE_RESULT '
        'outcome=$outcome '
        'thread_id=${widget.threadId} '
        'bridge=${widget.bridgeApiBaseUrl} '
        'loaded_ms=${_loadedMs ?? -1} '
        'running_ms=${_runningMs ?? -1} '
        'assistant_visible_ms=${_assistantVisibleMs ?? -1} '
        'completed_ms=${_completedMs ?? -1} '
        'loading_expected=${_runningMs != null && (_assistantVisibleMs == null || _runningMs! <= _assistantVisibleMs!)} '
        'token=${widget.promptToken}';
    debugPrint(result);

    Future<void>.delayed(const Duration(milliseconds: 300), () async {
      await SystemNavigator.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        ThreadDetailPage(
          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
          threadId: widget.threadId,
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                'probe=$_statusText ${_stopwatch.elapsedMilliseconds}ms',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _resolveBridgeApiBaseUrl() {
  const configured = String.fromEnvironment('LIVE_THREAD_UI_BRIDGE_BASE_URL');
  if (configured.isNotEmpty) {
    return configured;
  }

  if (Platform.isAndroid) {
    return 'http://10.0.2.2:3216';
  }

  return 'http://127.0.0.1:3216';
}

String _resolveThreadId() {
  const configured = String.fromEnvironment('LIVE_THREAD_UI_THREAD_ID');
  if (configured.isNotEmpty) {
    return configured;
  }

  return '019d1013-945b-7b92-8028-d816b12c58d3';
}

String _resolvePromptToken() {
  const configured = String.fromEnvironment('LIVE_THREAD_UI_PROMPT_TOKEN');
  if (configured.isNotEmpty) {
    return configured;
  }

  return 'UI_STREAM_TOKEN_${DateTime.now().millisecondsSinceEpoch}';
}

class _ProbeApprovalBridgeApi implements ApprovalBridgeApi {
  const _ProbeApprovalBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<ApprovalRecordDto>> fetchApprovals({
    required String bridgeApiBaseUrl,
  }) async {
    return const <ApprovalRecordDto>[];
  }

  @override
  Future<ApprovalResolutionResponseDto> approve({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<ApprovalResolutionResponseDto> reject({
    required String bridgeApiBaseUrl,
    required String approvalId,
  }) {
    throw UnimplementedError();
  }
}

class _ProbeSettingsBridgeApi implements SettingsBridgeApi {
  const _ProbeSettingsBridgeApi();

  @override
  Future<AccessMode> fetchAccessMode({required String bridgeApiBaseUrl}) async {
    return AccessMode.controlWithApprovals;
  }

  @override
  Future<List<SecurityEventRecordDto>> fetchSecurityEvents({
    required String bridgeApiBaseUrl,
  }) async {
    return const <SecurityEventRecordDto>[];
  }

  @override
  Future<AccessMode> setAccessMode({
    required String bridgeApiBaseUrl,
    required AccessMode accessMode,
    String? phoneId,
    String? bridgeId,
    String? sessionToken,
    String? localSessionKind,
    String actor = 'mobile-device',
  }) async {
    return accessMode;
  }
}
