import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/runtime_notification_delivery_controller.dart';
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
    if (!mounted || state.pendingNotifications.isEmpty) {
      return;
    }

    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      return;
    }

    for (final notification in state.pendingNotifications) {
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('${notification.title}: ${notification.message}'),
          duration: const Duration(seconds: 4),
        ),
      );
    }

    controller.acknowledgeAllPending();
  }
}
