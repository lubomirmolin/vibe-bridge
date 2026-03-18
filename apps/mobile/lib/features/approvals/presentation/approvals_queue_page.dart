import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_detail_page.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      appBar: AppBar(
        title: Text('Approvals (${state.pendingCount})'),
        actions: [
          IconButton(
            onPressed: () {
              controller.loadApprovals(showLoading: false);
            },
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh approvals',
          ),
          IconButton(
            key: const Key('open-device-settings-from-approvals'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      SettingsPage(bridgeApiBaseUrl: bridgeApiBaseUrl),
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Open device settings',
          ),
        ],
      ),
      body: SafeArea(
        child: _buildBody(
          context,
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          state: state,
          onRetry: controller.loadApprovals,
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
          CircularProgressIndicator(),
          SizedBox(height: 12),
          Text('Loading approvals…'),
        ],
      ),
    );
  }

  if (state.errorMessage != null && !state.hasApprovals) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded, size: 36),
            const SizedBox(height: 12),
            const Text('Couldn’t load approvals'),
            const SizedBox(height: 8),
            Text(state.errorMessage!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () {
                onRetry(showLoading: true);
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  if (!state.hasApprovals) {
    return const Padding(
      padding: EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.task_alt_rounded, size: 36),
            SizedBox(height: 12),
            Text('No approvals yet'),
            SizedBox(height: 8),
            Text(
              'When dangerous actions are gated, they will appear here.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  return RefreshIndicator(
    onRefresh: () => onRetry(showLoading: false),
    child: ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        _AccessModeBanner(accessMode: state.accessMode),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 12),
          _InlineWarning(message: state.errorMessage!),
        ],
        const SizedBox(height: 12),
        ...state.items.map(
          (item) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
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
    final colorScheme = Theme.of(context).colorScheme;
    final label = switch (accessMode) {
      AccessMode.fullControl =>
        'Full control mode: approve/reject actions are enabled.',
      AccessMode.controlWithApprovals =>
        'Control-with-approvals mode: approvals are visible but not actionable from mobile.',
      AccessMode.readOnly =>
        'Read-only mode: approvals are visible but approve/reject is blocked.',
      null => 'Loading access mode…',
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Text(label),
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

    return Card(
      child: InkWell(
        key: Key('approval-card-${approval.approvalId}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (context) => ApprovalDetailPage(
                bridgeApiBaseUrl: bridgeApiBaseUrl,
                approvalId: approval.approvalId,
              ),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      approvalActionLabel(approval.action),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  _StatusBadge(status: approval.status),
                ],
              ),
              const SizedBox(height: 8),
              Text('Reason: ${approval.reason}'),
              const SizedBox(height: 6),
              Text('Thread: ${approval.threadId}'),
              Text(
                '${approval.repository.repository} • ${approval.repository.branch}',
              ),
              Text(approval.repository.workspace),
              const SizedBox(height: 6),
              Text(approvalTargetLabel(approval)),
              if (nonActionableMessage != null) ...[
                const SizedBox(height: 8),
                Text(
                  nonActionableMessage,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});

  final ApprovalStatus status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (foreground, background) = switch (status) {
      ApprovalStatus.pending => (
        colorScheme.primary,
        colorScheme.primaryContainer,
      ),
      ApprovalStatus.approved => (
        colorScheme.tertiary,
        colorScheme.tertiaryContainer,
      ),
      ApprovalStatus.rejected => (
        colorScheme.error,
        colorScheme.errorContainer,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        approvalStatusLabel(status),
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
  }
}

class _InlineWarning extends StatelessWidget {
  const _InlineWarning({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.errorContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.error),
      ),
      child: Text(message),
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
