import 'dart:async';

import 'package:codex_mobile_companion/features/approvals/data/approval_bridge_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final approvalsQueueControllerProvider =
    StateNotifierProvider.family<
      ApprovalsQueueController,
      ApprovalsQueueState,
      String
    >((ref, bridgeApiBaseUrl) {
      return ApprovalsQueueController(
        bridgeApiBaseUrl: bridgeApiBaseUrl,
        bridgeApi: ref.watch(approvalBridgeApiProvider),
      );
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
    this.errorMessage,
    this.isLoading = true,
  });

  final List<ApprovalItemState> items;
  final AccessMode? accessMode;
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
    bool clearAccessMode = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isLoading,
  }) {
    return ApprovalsQueueState(
      items: items ?? this.items,
      accessMode: clearAccessMode ? null : (accessMode ?? this.accessMode),
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
  }) : _bridgeApiBaseUrl = bridgeApiBaseUrl,
       _bridgeApi = bridgeApi,
       super(const ApprovalsQueueState()) {
    unawaited(loadApprovals());
  }

  final String _bridgeApiBaseUrl;
  final ApprovalBridgeApi _bridgeApi;

  Future<void> loadApprovals({bool showLoading = true}) async {
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
        clearErrorMessage: true,
        isLoading: false,
      );
    } on ApprovalBridgeException catch (error) {
      state = state.copyWith(errorMessage: error.message, isLoading: false);
    } catch (_) {
      state = state.copyWith(
        errorMessage: 'Couldn’t load approvals right now.',
        isLoading: false,
      );
    }
  }

  Future<bool> resolveApproval({
    required String approvalId,
    required bool approved,
  }) async {
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
      _updateItem(
        approvalId,
        (current) => current.copyWith(
          isResolving: false,
          nonActionableReason: error.isNonActionable ? error.message : null,
        ),
      );

      state = state.copyWith(errorMessage: error.message);
      return false;
    } catch (_) {
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
