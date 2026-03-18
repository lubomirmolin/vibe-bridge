import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/application/device_settings_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/notification_preferences_controller.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key, required this.bridgeApiBaseUrl});

  final String bridgeApiBaseUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairingState = ref.watch(pairingControllerProvider);
    final pairingController = ref.read(pairingControllerProvider.notifier);
    final settingsState = ref.watch(
      deviceSettingsControllerProvider(bridgeApiBaseUrl),
    );
    final settingsController = ref.read(
      deviceSettingsControllerProvider(bridgeApiBaseUrl).notifier,
    );
    final notificationState = ref.watch(
      notificationPreferencesControllerProvider,
    );
    final notificationController = ref.read(
      notificationPreferencesControllerProvider.notifier,
    );

    final trustedBridge = pairingState.trustedBridge;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device settings'),
        actions: [
          IconButton(
            key: const Key('refresh-device-settings'),
            onPressed: () {
              settingsController.refresh();
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh settings',
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            _PairedBridgeCard(
              trustedBridge: trustedBridge,
              bridgeConnectionState: pairingState.bridgeConnectionState,
            ),
            const SizedBox(height: 12),
            _AccessModeCard(
              trustedBridge: trustedBridge,
              accessMode: settingsState.accessMode,
              isLoading: settingsState.isAccessModeLoading,
              isUpdating: settingsState.isAccessModeUpdating,
              errorMessage: settingsState.accessModeErrorMessage,
              onChangeMode: (mode) {
                if (trustedBridge == null) {
                  return;
                }
                settingsController.setAccessMode(
                  accessMode: mode,
                  trustedBridge: trustedBridge,
                );
              },
            ),
            const SizedBox(height: 12),
            _NotificationPreferencesCard(
              approvalNotificationsEnabled:
                  notificationState.approvalNotificationsEnabled,
              liveActivityNotificationsEnabled:
                  notificationState.liveActivityNotificationsEnabled,
              onToggleApprovals:
                  notificationController.setApprovalNotificationsEnabled,
              onToggleLiveActivity:
                  notificationController.setLiveActivityNotificationsEnabled,
            ),
            const SizedBox(height: 12),
            _SecurityEventsCard(
              events: settingsState.securityEvents,
              isLoading: settingsState.isSecurityEventsLoading,
              errorMessage: settingsState.securityEventsErrorMessage,
              onRefresh: () {
                settingsController.refreshSecurityEvents(showLoading: true);
              },
            ),
            const SizedBox(height: 12),
            _UnpairCard(
              canUnpair: trustedBridge != null,
              onUnpair: () async {
                await pairingController.unpairFromMobileSettings();
                if (!context.mounted) {
                  return;
                }

                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _PairedBridgeCard extends StatelessWidget {
  const _PairedBridgeCard({
    required this.trustedBridge,
    required this.bridgeConnectionState,
  });

  final TrustedBridgeIdentity? trustedBridge;
  final BridgeConnectionState bridgeConnectionState;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isConnected =
        bridgeConnectionState == BridgeConnectionState.connected;
    final bridge = trustedBridge;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paired bridge',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (bridge == null)
              const Text('No trusted bridge is currently paired.')
            else ...[
              Text('Name: ${bridge.bridgeName}'),
              Text('Bridge id: ${bridge.bridgeId}'),
              Text('Bridge URL: ${bridge.bridgeApiBaseUrl}'),
              Text('Trusted session: ${bridge.sessionId}'),
            ],
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: isConnected
                    ? colorScheme.tertiaryContainer
                    : colorScheme.errorContainer,
              ),
              child: Text(
                isConnected
                    ? 'Connection: Connected'
                    : 'Connection: Disconnected',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessModeCard extends StatelessWidget {
  const _AccessModeCard({
    required this.trustedBridge,
    required this.accessMode,
    required this.isLoading,
    required this.isUpdating,
    required this.errorMessage,
    required this.onChangeMode,
  });

  final TrustedBridgeIdentity? trustedBridge;
  final AccessMode? accessMode;
  final bool isLoading;
  final bool isUpdating;
  final String? errorMessage;
  final ValueChanged<AccessMode> onChangeMode;

  @override
  Widget build(BuildContext context) {
    final canEdit = trustedBridge != null && !isLoading && !isUpdating;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Access mode',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                if (isLoading || isUpdating)
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(_accessModeDescription(accessMode)),
            const SizedBox(height: 10),
            SegmentedButton<AccessMode>(
              segments: const [
                ButtonSegment<AccessMode>(
                  value: AccessMode.readOnly,
                  label: Text('Read-only'),
                ),
                ButtonSegment<AccessMode>(
                  value: AccessMode.controlWithApprovals,
                  label: Text('Control + approvals'),
                ),
                ButtonSegment<AccessMode>(
                  value: AccessMode.fullControl,
                  label: Text('Full control'),
                ),
              ],
              selected: {accessMode ?? AccessMode.controlWithApprovals},
              onSelectionChanged: canEdit
                  ? (selection) {
                      if (selection.isEmpty) {
                        return;
                      }
                      onChangeMode(selection.first);
                    }
                  : null,
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                errorMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NotificationPreferencesCard extends StatelessWidget {
  const _NotificationPreferencesCard({
    required this.approvalNotificationsEnabled,
    required this.liveActivityNotificationsEnabled,
    required this.onToggleApprovals,
    required this.onToggleLiveActivity,
  });

  final bool approvalNotificationsEnabled;
  final bool liveActivityNotificationsEnabled;
  final ValueChanged<bool> onToggleApprovals;
  final ValueChanged<bool> onToggleLiveActivity;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Text(
                'Notification preferences',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            SwitchListTile(
              key: const Key('approval-notification-toggle'),
              value: approvalNotificationsEnabled,
              onChanged: onToggleApprovals,
              title: const Text('Approval notifications'),
              subtitle: Text(
                approvalNotificationsEnabled
                    ? 'Approval alerts are delivered.'
                    : 'Approval alerts are suppressed.',
              ),
            ),
            SwitchListTile(
              key: const Key('live-activity-notification-toggle'),
              value: liveActivityNotificationsEnabled,
              onChanged: onToggleLiveActivity,
              title: const Text('Live activity notifications'),
              subtitle: Text(
                liveActivityNotificationsEnabled
                    ? 'Turn and activity alerts are delivered.'
                    : 'Turn and activity alerts are suppressed.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecurityEventsCard extends StatelessWidget {
  const _SecurityEventsCard({
    required this.events,
    required this.isLoading,
    required this.errorMessage,
    required this.onRefresh,
  });

  final List<SecurityEventRecordDto> events;
  final bool isLoading;
  final String? errorMessage;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Recent security events',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const Key('refresh-security-events'),
                  onPressed: onRefresh,
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh security events',
                ),
              ],
            ),
            if (isLoading)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              )
            else if (errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  errorMessage!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else if (events.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('No security events were captured yet.'),
              )
            else
              ...events
                  .take(8)
                  .map(
                    (event) => Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: _SecurityEventTile(event: event),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

class _SecurityEventTile extends StatelessWidget {
  const _SecurityEventTile({required this.event});

  final SecurityEventRecordDto event;

  @override
  Widget build(BuildContext context) {
    final payload = event.auditEvent;
    final actor = payload?.actor ?? 'unknown actor';
    final target = payload?.target ?? 'unknown target';
    final outcome = payload?.outcome ?? 'unknown outcome';
    final action = payload?.action ?? 'security event';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        color: Theme.of(context).colorScheme.surfaceContainerLow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$action • $outcome'),
          const SizedBox(height: 4),
          Text('Actor: $actor'),
          Text('Target: $target'),
          Text('Event id: ${event.event.eventId}'),
        ],
      ),
    );
  }
}

class _UnpairCard extends StatelessWidget {
  const _UnpairCard({required this.canUnpair, required this.onUnpair});

  final bool canUnpair;
  final Future<void> Function() onUnpair;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Device trust reset',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            const Text(
              'Unpair this phone from the current Mac. The app clears local trust and requires fresh QR pairing before reconnecting.',
            ),
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              key: const Key('unpair-device-button'),
              onPressed: canUnpair
                  ? () async {
                      await onUnpair();
                    }
                  : null,
              icon: const Icon(Icons.link_off),
              label: const Text('Unpair device'),
            ),
          ],
        ),
      ),
    );
  }
}

String _accessModeDescription(AccessMode? mode) {
  switch (mode) {
    case AccessMode.readOnly:
      return 'Read-only mode allows browsing but blocks mutating actions.';
    case AccessMode.controlWithApprovals:
      return 'Control-with-approvals mode allows turn controls while dangerous actions are approval-gated.';
    case AccessMode.fullControl:
      return 'Full-control mode enables approve/reject and direct git mutations.';
    case null:
      return 'Loading current access mode…';
  }
}
