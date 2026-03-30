import 'dart:async';

import 'package:vibe_bridge/features/threads/data/thread_diff_bridge_api.dart';
import 'package:vibe_bridge/features/threads/data/thread_live_stream.dart';
import 'package:vibe_bridge/features/threads/domain/parsed_command_output.dart';
import 'package:vibe_bridge/foundation/connectivity/live_connection_state.dart';
import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final threadDiffControllerProvider = StateNotifierProvider.autoDispose
    .family<ThreadDiffController, ThreadDiffState, ThreadDiffControllerArgs>((
      ref,
      args,
    ) {
      return ThreadDiffController(
        bridgeApiBaseUrl: args.bridgeApiBaseUrl,
        threadId: args.threadId,
        bridgeApi: ref.watch(threadDiffBridgeApiProvider),
        liveStream: ref.watch(threadLiveStreamProvider),
      );
    });

class ThreadDiffControllerArgs {
  const ThreadDiffControllerArgs({
    required this.bridgeApiBaseUrl,
    required this.threadId,
  });

  final String bridgeApiBaseUrl;
  final String threadId;

  @override
  bool operator ==(Object other) {
    return other is ThreadDiffControllerArgs &&
        other.bridgeApiBaseUrl == bridgeApiBaseUrl &&
        other.threadId == threadId;
  }

  @override
  int get hashCode => Object.hash(bridgeApiBaseUrl, threadId);
}

class ThreadDiffState {
  const ThreadDiffState({
    required this.threadId,
    this.mode = ThreadGitDiffMode.workspace,
    this.liveConnectionState = LiveConnectionState.connected,
    this.diff,
    this.document,
    this.selectedFilePath,
    this.errorMessage,
    this.isLoading = true,
    this.isRefreshing = false,
  });

  final String threadId;
  final ThreadGitDiffMode mode;
  final LiveConnectionState liveConnectionState;
  final ThreadGitDiffDto? diff;
  final ParsedDiffDocument? document;
  final String? selectedFilePath;
  final String? errorMessage;
  final bool isLoading;
  final bool isRefreshing;

  List<ParsedDiffFile> get parsedFiles =>
      document?.files ?? const <ParsedDiffFile>[];

  ParsedDiffFile? get selectedFile {
    final selectedFilePath = this.selectedFilePath;
    if (selectedFilePath == null || selectedFilePath.isEmpty) {
      return parsedFiles.isEmpty ? null : parsedFiles.first;
    }
    for (final file in parsedFiles) {
      if (file.path == selectedFilePath) {
        return file;
      }
    }
    return parsedFiles.isEmpty ? null : parsedFiles.first;
  }

  ThreadDiffState copyWith({
    ThreadGitDiffMode? mode,
    LiveConnectionState? liveConnectionState,
    ThreadGitDiffDto? diff,
    bool clearDiff = false,
    ParsedDiffDocument? document,
    bool clearDocument = false,
    String? selectedFilePath,
    bool clearSelectedFilePath = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isLoading,
    bool? isRefreshing,
  }) {
    return ThreadDiffState(
      threadId: threadId,
      mode: mode ?? this.mode,
      liveConnectionState: liveConnectionState ?? this.liveConnectionState,
      diff: clearDiff ? null : (diff ?? this.diff),
      document: clearDocument ? null : (document ?? this.document),
      selectedFilePath: clearSelectedFilePath
          ? null
          : (selectedFilePath ?? this.selectedFilePath),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      isLoading: isLoading ?? this.isLoading,
      isRefreshing: isRefreshing ?? this.isRefreshing,
    );
  }
}

class ThreadDiffController extends StateNotifier<ThreadDiffState> {
  ThreadDiffController({
    required String bridgeApiBaseUrl,
    required String threadId,
    required ThreadDiffBridgeApi bridgeApi,
    required ThreadLiveStream liveStream,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _bridgeApi = bridgeApi,
       _liveStream = liveStream,
       super(ThreadDiffState(threadId: threadId)) {
    unawaited(_load());
    unawaited(_startLiveSubscription());
  }

  final String _bridgeApiBaseUrl;
  final ThreadDiffBridgeApi _bridgeApi;
  final ThreadLiveStream _liveStream;

  ThreadLiveSubscription? _liveSubscription;
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  Timer? _refreshDebounceTimer;
  bool _isDisposed = false;

  Future<void> setMode(ThreadGitDiffMode mode) async {
    if (state.mode == mode) {
      return;
    }
    state = state.copyWith(
      mode: mode,
      isLoading: true,
      clearDiff: true,
      clearDocument: true,
      clearSelectedFilePath: true,
      clearErrorMessage: true,
    );
    await _load();
  }

  void selectFile(String path) {
    final normalized = path.trim();
    if (normalized.isEmpty || state.selectedFilePath == normalized) {
      return;
    }
    state = state.copyWith(selectedFilePath: normalized);
  }

  Future<void> refreshNow() => _load(isRefresh: true);

  Future<void> _load({bool isRefresh = false}) async {
    if (_isDisposed) {
      return;
    }

    state = state.copyWith(
      isLoading: !isRefresh && state.diff == null,
      isRefreshing: isRefresh,
      clearErrorMessage: true,
    );

    try {
      final diff = await _bridgeApi.fetchThreadGitDiff(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
        mode: state.mode,
      );
      if (_isDisposed) {
        return;
      }
      final document = ParsedDiffDocument.parse(diff.unifiedDiff);
      final files = document?.files ?? const <ParsedDiffFile>[];
      final selectedFilePath = _resolveSelectedFilePath(
        previous: state.selectedFilePath,
        parsedFiles: files,
        summaryPaths: diff.files
            .map((file) => file.path)
            .toList(growable: false),
      );
      state = state.copyWith(
        diff: diff,
        document: document,
        clearDocument: document == null,
        selectedFilePath: selectedFilePath,
        clearSelectedFilePath: selectedFilePath == null,
        isLoading: false,
        isRefreshing: false,
        clearErrorMessage: true,
        liveConnectionState: LiveConnectionState.connected,
      );
    } on ThreadGitDiffBridgeException catch (error) {
      if (_isDisposed) {
        return;
      }
      state = state.copyWith(
        errorMessage: error.message,
        isLoading: false,
        isRefreshing: false,
        liveConnectionState: error.isConnectivityError
            ? LiveConnectionState.disconnected
            : state.liveConnectionState,
      );
    } catch (_) {
      if (_isDisposed) {
        return;
      }
      state = state.copyWith(
        errorMessage: 'Couldn’t load the git diff right now.',
        isLoading: false,
        isRefreshing: false,
        liveConnectionState: LiveConnectionState.disconnected,
      );
    }
  }

  String? _resolveSelectedFilePath({
    required String? previous,
    required List<ParsedDiffFile> parsedFiles,
    required List<String> summaryPaths,
  }) {
    final availablePaths = summaryPaths.isNotEmpty
        ? summaryPaths
        : parsedFiles.map((file) => file.path).toList(growable: false);
    if (availablePaths.isEmpty) {
      return null;
    }
    if (previous != null && previous.isNotEmpty) {
      for (final path in availablePaths) {
        if (path == previous) {
          return previous;
        }
      }
    }
    return availablePaths.first;
  }

  Future<void> _startLiveSubscription() async {
    try {
      final subscription = await _liveStream.subscribe(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
        threadId: state.threadId,
      );
      if (_isDisposed) {
        await subscription.close();
        return;
      }
      _liveSubscription = subscription;
      _liveEventSubscription = subscription.events.listen(
        _handleLiveEvent,
        onError: (_) => _handleDisconnected(),
        onDone: _handleDisconnected,
        cancelOnError: false,
      );
      state = state.copyWith(
        liveConnectionState: LiveConnectionState.connected,
      );
    } catch (_) {
      if (_isDisposed) {
        return;
      }
      state = state.copyWith(
        liveConnectionState: LiveConnectionState.disconnected,
      );
    }
  }

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (_isDisposed) {
      return;
    }
    if (!_shouldRefreshForEvent(event)) {
      return;
    }
    _refreshDebounceTimer?.cancel();
    _refreshDebounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (_isDisposed) {
        return;
      }
      unawaited(_load(isRefresh: true));
    });
  }

  bool _shouldRefreshForEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    switch (event.kind) {
      case BridgeEventKind.fileChange:
      case BridgeEventKind.commandDelta:
      case BridgeEventKind.threadStatusChanged:
        return true;
      case BridgeEventKind.messageDelta:
      case BridgeEventKind.planDelta:
      case BridgeEventKind.userInputRequested:
      case BridgeEventKind.approvalRequested:
      case BridgeEventKind.securityAudit:
        return false;
    }
  }

  void _handleDisconnected() {
    if (_isDisposed) {
      return;
    }
    state = state.copyWith(
      liveConnectionState: LiveConnectionState.disconnected,
    );
  }

  @override
  void dispose() {
    _isDisposed = true;
    _refreshDebounceTimer?.cancel();
    unawaited(_liveEventSubscription?.cancel());
    unawaited(_liveSubscription?.close());
    super.dispose();
  }
}
