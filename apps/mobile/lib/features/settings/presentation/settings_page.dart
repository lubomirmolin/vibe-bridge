import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/domain/pairing_qr_payload.dart';
import 'package:codex_mobile_companion/features/settings/application/device_settings_controller.dart';
import 'package:codex_mobile_companion/features/settings/application/notification_preferences_controller.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key, required this.bridgeApiBaseUrl});

  final String bridgeApiBaseUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pairingState = ref.watch(pairingControllerProvider);
    final pairingController = ref.read(pairingControllerProvider.notifier);
    final settingsState = ref.watch(deviceSettingsControllerProvider(bridgeApiBaseUrl));
    final settingsController = ref.read(deviceSettingsControllerProvider(bridgeApiBaseUrl).notifier);
    final notificationState = ref.watch(notificationPreferencesControllerProvider);
    final notificationController = ref.read(notificationPreferencesControllerProvider.notifier);

    final trustedBridge = pairingState.trustedBridge;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              color: AppTheme.background.withOpacity(0.8),
              child: Row(
                children: [
                   IconButton(
                     onPressed: () => Navigator.of(context).pop(),
                     icon: PhosphorIcon(PhosphorIcons.caretLeft(PhosphorIconsStyle.bold), size: 20, color: AppTheme.textMuted),
                   ),
                   const SizedBox(width: 8),
                   Expanded(child: Text('Device settings', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500, letterSpacing: -0.5))),
                   IconButton(
                     onPressed: () => settingsController.refresh(),
                     icon: PhosphorIcon(PhosphorIcons.arrowsClockwise()),
                   ),
                ],
              ),
            ),
            
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                children: [
                  _PairedBridgeCard(trustedBridge: trustedBridge, bridgeConnectionState: pairingState.bridgeConnectionState),
                  const SizedBox(height: 16),
                  
                  _AccessModeCard(
                    trustedBridge: trustedBridge,
                    accessMode: settingsState.accessMode,
                    isLoading: settingsState.isAccessModeLoading,
                    isUpdating: settingsState.isAccessModeUpdating,
                    errorMessage: settingsState.accessModeErrorMessage,
                    onChangeMode: (mode) {
                      if (trustedBridge == null) return;
                      settingsController.setAccessMode(accessMode: mode, trustedBridge: trustedBridge);
                    },
                  ),
                  const SizedBox(height: 16),
                  
                  _NotificationPreferencesCard(
                    approvalNotificationsEnabled: notificationState.approvalNotificationsEnabled,
                    liveActivityNotificationsEnabled: notificationState.liveActivityNotificationsEnabled,
                    desktopIntegrationEnabled: notificationState.desktopIntegrationEnabled,
                    onToggleApprovals: notificationController.setApprovalNotificationsEnabled,
                    onToggleLiveActivity: notificationController.setLiveActivityNotificationsEnabled,
                    onToggleDesktopIntegration: notificationController.setDesktopIntegrationEnabled,
                  ),
                  const SizedBox(height: 16),
                  
                  _SecurityEventsCard(
                    events: settingsState.securityEvents,
                    isLoading: settingsState.isSecurityEventsLoading,
                    errorMessage: settingsState.securityEventsErrorMessage,
                    onRefresh: () => settingsController.refreshSecurityEvents(showLoading: true),
                  ),
                  const SizedBox(height: 16),
                  
                  _UnpairCard(
                    canUnpair: trustedBridge != null,
                    onUnpair: () async {
                      await pairingController.unpairFromMobileSettings();
                      if (!context.mounted) return;
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PairedBridgeCard extends StatelessWidget {
  const _PairedBridgeCard({required this.trustedBridge, required this.bridgeConnectionState});

  final TrustedBridgeIdentity? trustedBridge;
  final BridgeConnectionState bridgeConnectionState;

  @override
  Widget build(BuildContext context) {
    final isConnected = bridgeConnectionState == BridgeConnectionState.connected;
    final bridge = trustedBridge;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: LiquidStyles.liquidGlass.copyWith(borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(PhosphorIcons.laptop(), color: AppTheme.textMain),
              const SizedBox(width: 8),
              const Expanded(child: Text('Paired Bridge', style: TextStyle(color: AppTheme.textMain, fontSize: 16, fontWeight: FontWeight.w600))),
              StatusBadge(
                  text: isConnected ? 'CONNECTED' : 'DISCONNECTED',
                  variant: isConnected ? BadgeVariant.active : BadgeVariant.danger,
              ),
            ],
          ),
          const SizedBox(height: 16),
          
          if (bridge == null)
            const Text('No trusted bridge is currently paired.', style: TextStyle(color: AppTheme.textMuted))
          else ...[
            _DetailRow(icon: PhosphorIcons.identificationCard(), text: bridge.bridgeName),
            const SizedBox(height: 8),
            _DetailRow(icon: PhosphorIcons.link(), text: bridge.bridgeApiBaseUrl),
            const SizedBox(height: 8),
             Row(
               children: [
                 PhosphorIcon(PhosphorIcons.fingerprint(), size: 14, color: AppTheme.textSubtle),
                 const SizedBox(width: 8),
                 Expanded(
                   child: Text('Session: ${bridge.sessionId}', style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 10)),
                 ),
               ],
             ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _DetailRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        PhosphorIcon(icon, size: 14, color: AppTheme.textSubtle),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: GoogleFonts.jetBrainsMono(color: AppTheme.textMain, fontSize: 12),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: LiquidStyles.liquidGlass.copyWith(borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(PhosphorIcons.shieldCheck(), color: AppTheme.textMain),
              const SizedBox(width: 8),
              const Expanded(child: Text('Access Mode', style: TextStyle(color: AppTheme.textMain, fontSize: 16, fontWeight: FontWeight.w600))),
              if (isLoading || isUpdating)
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.emerald)),
            ],
          ),
          const SizedBox(height: 8),
          Text(_accessModeDescription(accessMode), style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
          const SizedBox(height: 16),
          
          SegmentedButton<AccessMode>(
            segments: const [
              ButtonSegment<AccessMode>(value: AccessMode.readOnly, label: Text('Read-only', style: TextStyle(fontSize: 12))),
              ButtonSegment<AccessMode>(value: AccessMode.controlWithApprovals, label: Text('+ Approvals', style: TextStyle(fontSize: 12))),
              ButtonSegment<AccessMode>(value: AccessMode.fullControl, label: Text('Full', style: TextStyle(fontSize: 12))),
            ],
            selected: {accessMode ?? AccessMode.controlWithApprovals},
            onSelectionChanged: canEdit ? (selection) {
               if (selection.isEmpty) return;
               onChangeMode(selection.first);
            } : null,
            style: SegmentedButton.styleFrom(
               backgroundColor: AppTheme.surfaceZinc800,
               selectedBackgroundColor: AppTheme.emerald.withOpacity(0.2),
               selectedForegroundColor: AppTheme.emerald,
               foregroundColor: AppTheme.textMuted,
            ),
          ),
          
          if (errorMessage != null) ...[
            const SizedBox(height: 12),
            Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: AppTheme.rose.withOpacity(0.1), borderRadius: BorderRadius.circular(8)), child: Text(errorMessage!, style: const TextStyle(color: AppTheme.rose, fontSize: 13))),
          ],
        ],
      ),
    );
  }
}

class _NotificationPreferencesCard extends StatelessWidget {
  const _NotificationPreferencesCard({
    required this.approvalNotificationsEnabled,
    required this.liveActivityNotificationsEnabled,
    required this.desktopIntegrationEnabled,
    required this.onToggleApprovals,
    required this.onToggleLiveActivity,
    required this.onToggleDesktopIntegration,
  });

  final bool approvalNotificationsEnabled;
  final bool liveActivityNotificationsEnabled;
  final bool desktopIntegrationEnabled;
  final ValueChanged<bool> onToggleApprovals;
  final ValueChanged<bool> onToggleLiveActivity;
  final ValueChanged<bool> onToggleDesktopIntegration;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: LiquidStyles.liquidGlass.copyWith(borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
               children: [
                  PhosphorIcon(PhosphorIcons.bell(), color: AppTheme.textMain),
                  const SizedBox(width: 8),
                  const Text('Notifications & UI', style: TextStyle(color: AppTheme.textMain, fontSize: 16, fontWeight: FontWeight.w600)),
               ]
            ),
          ),
          
          _CustomSwitch(title: 'Approval alerts', subtitle: 'Push notifications for pending reviews.', value: approvalNotificationsEnabled, onChanged: onToggleApprovals),
          _CustomSwitch(title: 'Live activity', subtitle: 'Alerts for agent turn updates.', value: liveActivityNotificationsEnabled, onChanged: onToggleLiveActivity),
          _CustomSwitch(title: 'Desktop integration', subtitle: 'Open-on-Mac actions on thread details.', value: desktopIntegrationEnabled, onChanged: onToggleDesktopIntegration),
        ],
      ),
    );
  }
}

class _CustomSwitch extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _CustomSwitch({required this.title, required this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      activeColor: AppTheme.emerald,
      title: Text(title, style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w500, fontSize: 15)),
      subtitle: Text(subtitle, style: const TextStyle(color: AppTheme.textMuted, fontSize: 13)),
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
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: LiquidStyles.liquidGlass.copyWith(borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(PhosphorIcons.shieldCheck(), color: AppTheme.textMain),
              const SizedBox(width: 8),
              const Expanded(child: Text('Security events', style: TextStyle(color: AppTheme.textMain, fontSize: 16, fontWeight: FontWeight.w600))),
              IconButton(onPressed: onRefresh, icon: PhosphorIcon(PhosphorIcons.arrowsClockwise(), color: AppTheme.textSubtle, size: 20)),
            ],
          ),
          
          if (isLoading) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator(color: AppTheme.emerald, backgroundColor: Colors.transparent))
          else if (errorMessage != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(errorMessage!, style: const TextStyle(color: AppTheme.rose, fontSize: 13)))
          else if (events.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: Text('No security events were captured yet.', style: TextStyle(color: AppTheme.textMuted)))
          else ...events.take(8).map((event) => Padding(padding: const EdgeInsets.only(top: 12), child: _SecurityEventTile(event: event))),
        ],
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
             children: [
               PhosphorIcon(outcome.toLowerCase().contains('success') ? PhosphorIcons.checkCircle() : PhosphorIcons.warning(), size: 14, color: outcome.toLowerCase().contains('success') ? AppTheme.emerald : AppTheme.amber),
               const SizedBox(width: 6),
               Text('$action • $outcome', style: const TextStyle(color: AppTheme.textMain, fontWeight: FontWeight.w500, fontSize: 13)),
             ]
          ),
          const SizedBox(height: 8),
          Text('Actor: $actor', style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 11)),
          Text('Target: $target', style: GoogleFonts.jetBrainsMono(color: AppTheme.textSubtle, fontSize: 11)),
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
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: AppTheme.rose.withOpacity(0.05), border: Border.all(color: AppTheme.rose.withOpacity(0.2)), borderRadius: BorderRadius.circular(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
             children: [
                PhosphorIcon(PhosphorIcons.warningOctagon(), color: AppTheme.rose),
                const SizedBox(width: 8),
                const Text('Device trust reset', style: TextStyle(color: AppTheme.rose, fontSize: 16, fontWeight: FontWeight.w600)),
             ]
          ),
          const SizedBox(height: 8),
          const Text('Unpair this phone from the current Mac. Requires fresh QR pairing before reconnecting.', style: TextStyle(color: AppTheme.rose, fontSize: 13)),
          const SizedBox(height: 16),
          
          SizedBox(
             width: double.infinity,
             child: ElevatedButton.icon(
               style: ElevatedButton.styleFrom(
                 backgroundColor: AppTheme.rose.withOpacity(0.2),
                 foregroundColor: AppTheme.rose,
                 padding: const EdgeInsets.symmetric(vertical: 14),
                 elevation: 0,
                 shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
               ),
               onPressed: canUnpair ? () async { await onUnpair(); } : null,
               icon: PhosphorIcon(PhosphorIcons.linkBreak()),
               label: const Text('Unpair device'),
             ),
          ),
        ],
      ),
    );
  }
}

String _accessModeDescription(AccessMode? mode) {
  switch (mode) {
    case AccessMode.readOnly: return 'Read-only mode blocks mutating actions.';
    case AccessMode.controlWithApprovals: return 'Turn controls enabled; dangerous actions approval-gated.';
    case AccessMode.fullControl: return 'Full-control mode gives complete raw access. Be careful.';
    case null: return 'Loading current access mode…';
  }
}
