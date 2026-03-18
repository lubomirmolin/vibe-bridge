import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_detail_page.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_notification_delivery_controller.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/navigation/app_navigator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class RuntimeNotificationDeliverySurface extends ConsumerStatefulWidget {
  const RuntimeNotificationDeliverySurface({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<RuntimeNotificationDeliverySurface> createState() =>
      _RuntimeNotificationDeliverySurfaceState();
}

class _RuntimeNotificationDeliverySurfaceState
    extends ConsumerState<RuntimeNotificationDeliverySurface> {
  String? _activeDeliveryId;
  String? _activeLaunchRequestId;

  @override
  Widget build(BuildContext context) {
    final trustedBridge = ref.watch(pairingControllerProvider).trustedBridge;
    final bridgeApiBaseUrl = trustedBridge?.bridgeApiBaseUrl;

    if (bridgeApiBaseUrl != null && bridgeApiBaseUrl.trim().isNotEmpty) {
      final runtimeNotificationController = ref.read(
        runtimeNotificationDeliveryControllerProvider(
          bridgeApiBaseUrl,
        ).notifier,
      );

      ref.listen<RuntimeNotificationDeliveryState>(
        runtimeNotificationDeliveryControllerProvider(bridgeApiBaseUrl),
        (_, next) {
          _handleRuntimeNotificationDelivery(
            state: next,
            controller: runtimeNotificationController,
          );
        },
      );
    }

    return widget.child;
  }

  void _handleRuntimeNotificationDelivery({
    required RuntimeNotificationDeliveryState state,
    required RuntimeNotificationDeliveryController controller,
  }) {
    if (!mounted) {
      return;
    }

    _showPendingNotificationIfNeeded(state: state, controller: controller);
    _openPendingLaunchRequestIfNeeded(state: state, controller: controller);
  }

  void _showPendingNotificationIfNeeded({
    required RuntimeNotificationDeliveryState state,
    required RuntimeNotificationDeliveryController controller,
  }) {
    if (_activeDeliveryId != null || state.pendingNotifications.isEmpty) {
      return;
    }

    final notification = state.pendingNotifications.first;
    _activeDeliveryId = notification.deliveryId;

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      _activeDeliveryId = null;
      return;
    }

    final snackBar = SnackBar(
      behavior: SnackBarBehavior.floating,
      content: Text('${notification.title}: ${notification.message}'),
      duration: const Duration(seconds: 4),
      action: SnackBarAction(
        label: 'Open',
        onPressed: () {
          controller.requestOpenNotification(notification.deliveryId);
        },
      ),
    );

    messenger.showSnackBar(snackBar).closed.then((_) {
      controller.acknowledgePending(notification.deliveryId);
      if (!mounted) {
        return;
      }

      setState(() {
        if (_activeDeliveryId == notification.deliveryId) {
          _activeDeliveryId = null;
        }
      });
    });
  }

  void _openPendingLaunchRequestIfNeeded({
    required RuntimeNotificationDeliveryState state,
    required RuntimeNotificationDeliveryController controller,
  }) {
    if (_activeLaunchRequestId != null || state.pendingLaunchRequests.isEmpty) {
      return;
    }

    final request = state.pendingLaunchRequests.first;
    _activeLaunchRequestId = request.requestId;
    _openLaunchRequest(request: request, controller: controller);
  }

  Future<void> _openLaunchRequest({
    required RuntimeNotificationLaunchRequest request,
    required RuntimeNotificationDeliveryController controller,
  }) async {
    final trustedBridge = ref.read(pairingControllerProvider).trustedBridge;
    if (trustedBridge == null || !mounted) {
      await _consumeLaunchRequest(
        controller: controller,
        requestId: request.requestId,
      );
      return;
    }

    final bridgeApiBaseUrl = trustedBridge.bridgeApiBaseUrl;
    final navigatorState = appNavigatorKey.currentState;
    if (navigatorState == null) {
      await _consumeLaunchRequest(
        controller: controller,
        requestId: request.requestId,
      );
      return;
    }

    final target = request.target;
    if (target.type == RuntimeNotificationTargetType.approvalDetail &&
        target.approvalId != null) {
      final approvalsController = ref.read(
        approvalsQueueControllerProvider(bridgeApiBaseUrl).notifier,
      );
      await approvalsController.loadApprovals(showLoading: false);

      final approvalsState = ref.read(
        approvalsQueueControllerProvider(bridgeApiBaseUrl),
      );
      final approvalItem = approvalsState.byApprovalId(target.approvalId!);
      final isActionable = approvalItem != null && approvalItem.approval.isPending;

      if (!isActionable) {
        if (mounted) {
          final messenger = ScaffoldMessenger.maybeOf(context);
          messenger?.showSnackBar(
            const SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(
                'This approval notification is no longer actionable and was suppressed.',
              ),
              duration: Duration(seconds: 3),
            ),
          );
        }

        await _consumeLaunchRequest(
          controller: controller,
          requestId: request.requestId,
        );
        return;
      }

      navigatorState.push(
        MaterialPageRoute<void>(
          builder: (context) => ApprovalDetailPage(
            bridgeApiBaseUrl: bridgeApiBaseUrl,
            approvalId: target.approvalId!,
          ),
        ),
      );

      await _consumeLaunchRequest(
        controller: controller,
        requestId: request.requestId,
      );
      return;
    }

    navigatorState.push(
      MaterialPageRoute<void>(
        builder: (context) => ThreadDetailPage(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: target.threadId,
        ),
      ),
    );

    await _consumeLaunchRequest(
      controller: controller,
      requestId: request.requestId,
    );
  }

  Future<void> _consumeLaunchRequest({
    required RuntimeNotificationDeliveryController controller,
    required String requestId,
  }) async {
    await controller.acknowledgeLaunchRequest(requestId);

    if (!mounted) {
      return;
    }

    setState(() {
      if (_activeLaunchRequestId == requestId) {
        _activeLaunchRequestId = null;
      }
    });
  }
}
