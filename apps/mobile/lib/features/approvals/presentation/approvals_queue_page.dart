import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_detail_page.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

class ApprovalsQueuePage extends ConsumerWidget {
  const ApprovalsQueuePage({super.key, required this.bridgeApiBaseUrl});

  final String bridgeApiBaseUrl;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(approvalsQueueControllerProvider(bridgeApiBaseUrl));
    final controller = ref.read(
      approvalsQueueControllerProvider(bridgeApiBaseUrl).notifier,
    );

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
                    icon: PhosphorIcon(
                      PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                      size: 20,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Approvals (${state.pendingCount})',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: -0.5,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () =>
                        controller.loadApprovals(showLoading: false),
                    icon: PhosphorIcon(PhosphorIcons.arrowsClockwise()),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            SettingsPage(bridgeApiBaseUrl: bridgeApiBaseUrl),
                      ),
                    ),
                    icon: PhosphorIcon(PhosphorIcons.gear()),
                  ),
                ],
              ),
            ),

            Expanded(
              child: _buildBody(
                context,
                bridgeApiBaseUrl: bridgeApiBaseUrl,
                state: state,
                onRetry: controller.loadApprovals,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _buildBody(
  BuildContext context, {
  required String bridgeApiBaseUrl,
  required ApprovalsQueueState state,
  required Future<void> Function({bool showLoading}) onRetry,
}) {
  if (state.isLoading && !state.hasApprovals) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(color: AppTheme.amber),
          SizedBox(height: 16),
          Text(
            'Loading approvals...',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 13,
              fontFamily: 'JetBrains Mono',
            ),
          ),
        ],
      ),
    );
  }

  if (state.errorMessage != null && !state.hasApprovals) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhosphorIcon(PhosphorIcons.wifiX(), size: 48, color: AppTheme.rose),
            const SizedBox(height: 16),
            const Text(
              'Couldn\'t load approvals',
              style: TextStyle(
                color: AppTheme.textMain,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              state.errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.surfaceZinc800,
                foregroundColor: AppTheme.textMain,
              ),
              onPressed: () => onRetry(showLoading: true),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  if (!state.hasApprovals) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhosphorIcon(
              PhosphorIcons.checkCircle(),
              size: 48,
              color: AppTheme.emerald,
            ),
            const SizedBox(height: 16),
            const Text(
              'No approvals pending',
              style: TextStyle(
                color: AppTheme.textMain,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'When dangerous actions are gated, they will appear here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  return RefreshIndicator(
    color: AppTheme.amber,
    backgroundColor: AppTheme.surfaceZinc800,
    onRefresh: () => onRetry(showLoading: false),
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: const BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      children: [
        _AccessModeBanner(accessMode: state.accessMode),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 16),
          _InlineWarning(message: state.errorMessage!),
        ],
        const SizedBox(height: 16),
        ...state.items.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: _ApprovalCard(
              bridgeApiBaseUrl: bridgeApiBaseUrl,
              item: item,
            ),
          ),
        ),
      ],
    ),
  );
}

class _AccessModeBanner extends StatelessWidget {
  const _AccessModeBanner({required this.accessMode});

  final AccessMode? accessMode;

  @override
  Widget build(BuildContext context) {
    final String label;
    final PhosphorIcon icon;
    final Color color;

    switch (accessMode) {
      case AccessMode.readOnly:
        label = 'Read Only: Approvals cannot be actionable from mobile.';
        icon = PhosphorIcon(PhosphorIcons.lock(), color: AppTheme.textSubtle);
        color = AppTheme.textSubtle;
        break;
      case AccessMode.controlWithApprovals:
        label = 'Approvals are visible but not actionable from mobile.';
        icon = PhosphorIcon(
          PhosphorIcons.shieldCheck(),
          color: AppTheme.textMain,
        );
        color = AppTheme.textMain;
        break;
      case AccessMode.fullControl:
        label = 'Full control mode: Approve/reject is enabled.';
        icon = PhosphorIcon(PhosphorIcons.lightning(), color: AppTheme.emerald);
        color = AppTheme.emerald;
        break;
      case null:
      default:
        label = 'Loading access mode...';
        icon = PhosphorIcon(PhosphorIcons.spinner(), color: AppTheme.textMuted);
        color = AppTheme.textMuted;
        break;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ApprovalCard extends StatelessWidget {
  const _ApprovalCard({required this.bridgeApiBaseUrl, required this.item});

  final String bridgeApiBaseUrl;
  final ApprovalItemState item;

  @override
  Widget build(BuildContext context) {
    final approval = item.approval;
    final nonActionableMessage =
        item.nonActionableReason ??
        (!approval.isPending ? _resolvedStatusMessage(approval.status) : null);

    BadgeVariant variant = BadgeVariant.defaultVariant;
    String statusStr = 'UNKNOWN';

    switch (approval.status) {
      case ApprovalStatus.pending:
        variant = BadgeVariant.warning;
        statusStr = 'PENDING';
        break;
      case ApprovalStatus.approved:
        variant = BadgeVariant.active;
        statusStr = 'APPROVED';
        break;
      case ApprovalStatus.rejected:
        variant = BadgeVariant.danger;
        statusStr = 'REJECTED';
        break;
    }

    return GestureDetector(
      key: Key('approval-card-${approval.approvalId}'),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ApprovalDetailPage(
              bridgeApiBaseUrl: bridgeApiBaseUrl,
              approvalId: approval.approvalId,
            ),
          ),
        );
      },
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: LiquidStyles.liquidGlass.copyWith(
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    approvalActionLabel(approval.action),
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                StatusBadge(text: statusStr, variant: variant),
              ],
            ),
            const SizedBox(height: 16),

            Text(
              'Reason: ${approval.reason}',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 16),

            // Sub details using Phosphor icons
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(
                  icon: PhosphorIcons.chatTeardrop(),
                  text: approval.threadId,
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  icon: PhosphorIcons.folderSimple(),
                  text:
                      '${approval.repository.repository} • ${approval.repository.branch}',
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  icon: PhosphorIcons.terminalWindow(),
                  text: approval.repository.workspace,
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  icon: PhosphorIcons.target(),
                  text: approvalTargetLabel(approval),
                ),
              ],
            ),

            if (nonActionableMessage != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.rose.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  nonActionableMessage,
                  style: const TextStyle(color: AppTheme.rose, fontSize: 13),
                ),
              ),
            ],
          ],
        ),
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
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.textSubtle,
              fontSize: 12,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _InlineWarning extends StatelessWidget {
  const _InlineWarning({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.rose.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.rose.withOpacity(0.3)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppTheme.rose, fontSize: 13),
      ),
    );
  }
}

String _resolvedStatusMessage(ApprovalStatus status) {
  switch (status) {
    case ApprovalStatus.pending:
      return 'Approval is pending.';
    case ApprovalStatus.approved:
      return 'Approval was already resolved as approved.';
    case ApprovalStatus.rejected:
      return 'Approval was already resolved as rejected.';
  }
}
