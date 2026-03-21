import 'dart:async';

import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_access_mode.dart';
import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_live_stream.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final approvalsQueueControllerProvider =
    StateNotifierProvider.family<
      ApprovalsQueueController,
      ApprovalsQueueState,
      String
    >((ref, bridgeApiBaseUrl) {
      final controller = ApprovalsQueueController(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        bridgeApi: ref.watch(approvalBridgeApiProvider),
        liveStream: ref.watch(threadLiveStreamProvider),
        initialAccessMode: ref.read(
          runtimeAccessModeProvider(bridgeApiBaseUrl),
        ),
        onAccessModeObserved: (accessMode) {
          ref.read(runtimeAccessModeProvider(bridgeApiBaseUrl).notifier).state =
              accessMode;
        },
      );

      ref.listen<AccessMode?>(runtimeAccessModeProvider(bridgeApiBaseUrl), (
        previous,
        next,
      ) {
        controller.overrideAccessMode(next);
      });

      return controller;
    });

class ApprovalItemState {
  const ApprovalItemState({
    required this.approval,
    this.isResolving = false,
    this.nonActionableReason,
    this.resolutionMessage,
  });

  final ApprovalRecordDto approval;
  final bool isResolving;
  final String? nonActionableReason;
  final String? resolutionMessage;

  bool get isActionable => approval.isPending && nonActionableReason == null;

  ApprovalItemState copyWith({
    ApprovalRecordDto? approval,
    bool? isResolving,
    String? nonActionableReason,
    bool clearNonActionableReason = false,
    String? resolutionMessage,
    bool clearResolutionMessage = false,
  }) {
    return ApprovalItemState(
      approval: approval ?? this.approval,
      isResolving: isResolving ?? this.isResolving,
      nonActionableReason: clearNonActionableReason
          ? null
          : (nonActionableReason ?? this.nonActionableReason),
      resolutionMessage: clearResolutionMessage
          ? null
          : (resolutionMessage ?? this.resolutionMessage),
    );
  }
}

class ApprovalsQueueState {
  const ApprovalsQueueState({
    this.items = const <ApprovalItemState>[],
    this.accessMode,
    this.liveConnectionState = LiveConnectionState.connected,
    this.errorMessage,
    this.isLoading = true,
  });

  final List<ApprovalItemState> items;
  final AccessMode? accessMode;
  final LiveConnectionState liveConnectionState;
  final String? errorMessage;
  final bool isLoading;

  bool get hasApprovals => items.isNotEmpty;

  bool get canResolveApprovals => accessMode == AccessMode.fullControl;

  int get pendingCount {
    return items.where((item) => item.approval.isPending).length;
  }

  ApprovalItemState? byApprovalId(String approvalId) {
    for (final item in items) {
      if (item.approval.approvalId == approvalId) {
        return item;
      }
    }
    return null;
  }

  List<ApprovalItemState> forThread(String threadId) {
    return items
        .where((item) => item.approval.threadId == threadId)
        .toList(growable: false);
  }

  ApprovalsQueueState copyWith({
    List<ApprovalItemState>? items,
    AccessMode? accessMode,
    LiveConnectionState? liveConnectionState,
    bool clearAccessMode = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isLoading,
  }) {
    return ApprovalsQueueState(
      items: items ?? this.items,
      accessMode: clearAccessMode ? null : (accessMode ?? this.accessMode),
      liveConnectionState: liveConnectionState ?? this.liveConnectionState,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class ApprovalsQueueController extends StateNotifier<ApprovalsQueueState> {
  ApprovalsQueueController({
    required String bridgeApiBaseUrl,
    required ApprovalBridgeApi bridgeApi,
    required ThreadLiveStream liveStream,
    required void Function(AccessMode accessMode) onAccessModeObserved,
    AccessMode? initialAccessMode,
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _bridgeApi = bridgeApi,
       _liveStream = liveStream,
       _onAccessModeObserved = onAccessModeObserved,
       super(ApprovalsQueueState(accessMode: initialAccessMode)) {
    unawaited(loadApprovals());
    unawaited(_startLiveSubscription());
  }

  final String _bridgeApiBaseUrl;
  final ApprovalBridgeApi _bridgeApi;
  final ThreadLiveStream _liveStream;
  final void Function(AccessMode accessMode) _onAccessModeObserved;
  final Set<String> _seenLiveEventIds = <String>{};

  ThreadLiveSubscription? _liveSubscription;
  StreamSubscription<BridgeEventEnvelope<Map<String, dynamic>>>?
  _liveEventSubscription;
  Timer? _reconnectTimer;
  bool _isDisposed = false;
  bool _isReconnectInProgress = false;

  bool get _canMutateState => mounted && !_isDisposed;

  void overrideAccessMode(AccessMode? accessMode) {
    if (accessMode == null) {
      return;
    }

    if (state.accessMode == accessMode) {
      return;
    }

    state = state.copyWith(accessMode: accessMode);
  }

  Future<void> loadApprovals({bool showLoading = true}) async {
    if (!_canMutateState) {
      return;
    }
    if (showLoading) {
      state = state.copyWith(isLoading: true, clearErrorMessage: true);
    }

    try {
      final values = await Future.wait<dynamic>([
        _bridgeApi.fetchAccessMode(bridgeApiBaseUrl: _bridgeApiBaseUrl),
        _bridgeApi.fetchApprovals(bridgeApiBaseUrl: _bridgeApiBaseUrl),
      ]);

      final accessMode = values[0] as AccessMode;
      final approvals = values[1] as List<ApprovalRecordDto>;
      if (!_canMutateState) {
        return;
      }
      _onAccessModeObserved(accessMode);

      final previousItemsById = {
        for (final item in state.items) item.approval.approvalId: item,
      };

      final nextItems =
          approvals
              .map((approval) {
                final previous = previousItemsById[approval.approvalId];
                return ApprovalItemState(
                  approval: approval,
                  nonActionableReason: approval.isPending
                      ? previous?.nonActionableReason
                      : null,
                  resolutionMessage: approval.isPending
                      ? previous?.resolutionMessage
                      : _defaultResolutionMessage(approval.status),
                );
              })
              .toList(growable: false)
            ..sort(_compareApprovalItems);

      state = state.copyWith(
        items: nextItems,
        accessMode: accessMode,
        liveConnectionState: LiveConnectionState.connected,
        clearErrorMessage: true,
        isLoading: false,
      );
    } on ApprovalBridgeException catch (error) {
      if (!_canMutateState) {
        return;
      }
      state = state.copyWith(
        errorMessage: error.message,
        isLoading: false,
        liveConnectionState: error.isConnectivityError
            ? LiveConnectionState.disconnected
            : state.liveConnectionState,
      );
    } catch (_) {
      if (!_canMutateState) {
        return;
      }
      state = state.copyWith(
        errorMessage: 'Couldn’t load approvals right now.',
        isLoading: false,
        liveConnectionState: LiveConnectionState.disconnected,
      );
    }
  }

  Future<bool> resolveApproval({
    required String approvalId,
    required bool approved,
  }) async {
    if (!_canMutateState) {
      return false;
    }
    final item = state.byApprovalId(approvalId);
    if (item == null) {
      return false;
    }

    if (!state.canResolveApprovals) {
      state = state.copyWith(
        errorMessage:
            'Approval resolution is only available in full-control mode.',
      );
      return false;
    }

    if (!item.approval.isPending) {
      _updateItem(
        approvalId,
        (current) => current.copyWith(
          nonActionableReason: _defaultResolutionMessage(
            current.approval.status,
          ),
        ),
      );
      return false;
    }

    if (item.nonActionableReason != null) {
      return false;
    }

    _updateItem(
      approvalId,
      (current) =>
          current.copyWith(isResolving: true, clearResolutionMessage: true),
    );
    state = state.copyWith(clearErrorMessage: true);

    try {
      final response = approved
          ? await _bridgeApi.approve(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              approvalId: approvalId,
            )
          : await _bridgeApi.reject(
              bridgeApiBaseUrl: _bridgeApiBaseUrl,
              approvalId: approvalId,
            );
      if (!_canMutateState) {
        return false;
      }

      _updateItem(
        approvalId,
        (current) => current.copyWith(
          approval: response.approval,
          isResolving: false,
          clearNonActionableReason: true,
          resolutionMessage:
              response.mutationResult?.message ??
              _defaultResolutionMessage(response.approval.status),
        ),
      );

      await loadApprovals(showLoading: false);
      return true;
    } on ApprovalResolutionBridgeException catch (error) {
      if (!_canMutateState) {
        return false;
      }
      _updateItem(
        approvalId,
        (current) => current.copyWith(
          isResolving: false,
          nonActionableReason: error.isNonActionable ? error.message : null,
        ),
      );

      if (error.isNonActionable) {
        await loadApprovals(showLoading: false);
      }

      state = state.copyWith(errorMessage: error.message);
      return false;
    } catch (_) {
      if (!_canMutateState) {
        return false;
      }
      _updateItem(
        approvalId,
        (current) => current.copyWith(isResolving: false),
      );
      state = state.copyWith(
        errorMessage: 'Couldn’t resolve approval right now.',
      );
      return false;
    }
  }

  void _updateItem(
    String approvalId,
    ApprovalItemState Function(ApprovalItemState current) transform,
  ) {
    if (!_canMutateState) {
      return;
    }
    final index = state.items.indexWhere(
      (item) => item.approval.approvalId == approvalId,
    );
    if (index < 0) {
      return;
    }

    final nextItems = List<ApprovalItemState>.from(state.items);
    nextItems[index] = transform(nextItems[index]);
    state = state.copyWith(items: nextItems..sort(_compareApprovalItems));
  }

  Future<void> _startLiveSubscription() async {
    try {
      final subscription = await _liveStream.subscribe(
        bridgeApiBaseUrl: _bridgeApiBaseUrl,
      );
      if (!_canMutateState) {
        await subscription.close();
        return;
      }
      _liveSubscription = subscription;
      if (state.errorMessage == null && !state.isLoading) {
        state = state.copyWith(
          liveConnectionState: LiveConnectionState.connected,
        );
      }

      _liveEventSubscription = subscription.events.listen(
        _handleLiveEvent,
        onError: (_) {
          _handleLiveStreamDisconnected();
        },
        onDone: _handleLiveStreamDisconnected,
      );
    } catch (_) {
      _handleLiveStreamDisconnected();
    }
  }

  void _handleLiveEvent(BridgeEventEnvelope<Map<String, dynamic>> event) {
    if (_seenLiveEventIds.contains(event.eventId)) {
      return;
    }
    _seenLiveEventIds.add(event.eventId);

    if (event.kind == BridgeEventKind.approvalRequested) {
      unawaited(loadApprovals(showLoading: false));
    }
  }

  void _handleLiveStreamDisconnected() {
    if (_isDisposed) {
      return;
    }
    state = state.copyWith(
      liveConnectionState: LiveConnectionState.disconnected,
    );
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_isDisposed ||
        _isReconnectInProgress ||
        _reconnectTimer?.isActive == true) {
      return;
    }

    _reconnectTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_runReconnect());
    });
  }

  Future<void> _runReconnect() async {
    if (_isDisposed || _isReconnectInProgress) {
      return;
    }

    _isReconnectInProgress = true;
    try {
      if (_canMutateState &&
          state.liveConnectionState == LiveConnectionState.disconnected) {
        state = state.copyWith(
          liveConnectionState: LiveConnectionState.reconnecting,
        );
      }
      await _closeLiveSubscription();
      await _startLiveSubscription();
    } catch (_) {
      if (_canMutateState) {
        state = state.copyWith(
          liveConnectionState: LiveConnectionState.disconnected,
        );
      }
      _scheduleReconnect();
    } finally {
      _isReconnectInProgress = false;
    }
  }

  Future<void> _closeLiveSubscription() async {
    await _liveEventSubscription?.cancel();
    _liveEventSubscription = null;

    final subscription = _liveSubscription;
    _liveSubscription = null;
    if (subscription == null) {
      return;
    }

    try {
      await subscription.close();
    } catch (_) {
      // Ignore already-closed websocket teardown failures.
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    unawaited(_closeLiveSubscription());
    super.dispose();
  }
}

int _compareApprovalItems(ApprovalItemState left, ApprovalItemState right) {
  if (left.approval.isPending != right.approval.isPending) {
    return left.approval.isPending ? -1 : 1;
  }

  return right.approval.requestedAt.compareTo(left.approval.requestedAt);
}

String _defaultResolutionMessage(ApprovalStatus status) {
  switch (status) {
    case ApprovalStatus.pending:
      return 'Approval is pending.';
    case ApprovalStatus.approved:
      return 'Approval was already resolved as approved.';
    case ApprovalStatus.rejected:
      return 'Approval was already resolved as rejected.';
  }
}
