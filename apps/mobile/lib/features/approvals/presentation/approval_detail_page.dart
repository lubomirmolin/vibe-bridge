import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ApprovalDetailPage extends ConsumerStatefulWidget {
  const ApprovalDetailPage({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.approvalId,
  });

  final String bridgeApiBaseUrl;
  final String approvalId;

  @override
  ConsumerState<ApprovalDetailPage> createState() => _ApprovalDetailPageState();
}

class _ApprovalDetailPageState extends ConsumerState<ApprovalDetailPage> {
  final Map<String, Future<_ApprovalThreadContext>> _contextFuturesByThreadId =
      <String, Future<_ApprovalThreadContext>>{};

  Future<_ApprovalThreadContext> _contextFutureForThread(String threadId) {
    return _contextFuturesByThreadId.putIfAbsent(
      threadId,
      () => _loadThreadContext(threadId),
    );
  }

  Future<_ApprovalThreadContext> _loadThreadContext(String threadId) async {
    final api = ref.read(threadDetailBridgeApiProvider);

    try {
      final detail = await api.fetchThreadDetail(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
        threadId: threadId,
      );
      final timeline = await api.fetchThreadTimeline(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
        threadId: threadId,
      );
      return _ApprovalThreadContext(
        detail: detail,
        latestCommandEvent: _latestEvent(
          timeline,
          BridgeEventKind.commandDelta,
        ),
        latestFileChangeEvent: _latestEvent(
          timeline,
          BridgeEventKind.fileChange,
        ),
      );
    } on ThreadDetailBridgeException catch (error) {
      return _ApprovalThreadContext(errorMessage: error.message);
    } catch (_) {
      return const _ApprovalThreadContext(
        errorMessage: 'Couldn’t load additional thread context right now.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      approvalsQueueControllerProvider(widget.bridgeApiBaseUrl),
    );
    final controller = ref.read(
      approvalsQueueControllerProvider(widget.bridgeApiBaseUrl).notifier,
    );
    final item = state.byApprovalId(widget.approvalId);

    if (item == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Approval detail')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.gpp_bad_outlined, size: 36),
                const SizedBox(height: 12),
                const Text('Approval not found.'),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    controller.loadApprovals(showLoading: true);
                  },
                  child: const Text('Refresh approvals'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final approval = item.approval;
    final canResolve =
        state.canResolveApprovals && item.isActionable && !item.isResolving;
    final nonActionableMessage =
        item.nonActionableReason ??
        (!approval.isPending ? _resolvedStatusMessage(approval.status) : null);

    return Scaffold(
      appBar: AppBar(title: const Text('Approval detail')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      approvalActionLabel(approval.action),
                      key: const Key('approval-detail-action'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(approvalTargetLabel(approval)),
                    const SizedBox(height: 6),
                    Text('Reason: ${approval.reason}'),
                    const SizedBox(height: 6),
                    Text(
                      'Approval id: ${approval.approvalId}',
                      key: const Key('approval-detail-id'),
                      style: Theme.of(
                        context,
                      ).textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Git and repo context',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Text('Workspace: ${approval.repository.workspace}'),
                    Text('Repository: ${approval.repository.repository}'),
                    Text('Current branch: ${approval.repository.branch}'),
                    Text('Remote: ${approval.repository.remote}'),
                    const SizedBox(height: 6),
                    Text(
                      'Git status: dirty=${approval.gitStatus.dirty}, ahead=${approval.gitStatus.aheadBy}, behind=${approval.gitStatus.behindBy}',
                    ),
                    const SizedBox(height: 6),
                    Text('Thread: ${approval.threadId}'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            FutureBuilder<_ApprovalThreadContext>(
              future: _contextFutureForThread(approval.threadId),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Card(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Row(
                        children: [
                          SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          SizedBox(width: 8),
                          Text('Loading thread context…'),
                        ],
                      ),
                    ),
                  );
                }

                final contextSnapshot = snapshot.data;
                if (contextSnapshot == null) {
                  return const SizedBox.shrink();
                }

                return _ThreadContextCard(
                  bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
                  threadId: approval.threadId,
                  contextSnapshot: contextSnapshot,
                );
              },
            ),
            const SizedBox(height: 12),
            if (state.errorMessage != null)
              _InlineWarning(message: state.errorMessage!),
            if (item.resolutionMessage != null) ...[
              if (state.errorMessage != null) const SizedBox(height: 12),
              _InlineInfo(message: item.resolutionMessage!),
            ],
            if (nonActionableMessage != null) ...[
              const SizedBox(height: 12),
              _InlineWarning(message: nonActionableMessage),
            ],
            if (!state.canResolveApprovals && approval.isPending) ...[
              const SizedBox(height: 12),
              const _InlineInfo(
                message:
                    'Approve/reject actions are available only in full-control mode.',
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('approve-approval-button'),
                    onPressed: canResolve
                        ? () {
                            controller.resolveApproval(
                              approvalId: approval.approvalId,
                              approved: true,
                            );
                          }
                        : null,
                    icon: item.isResolving
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: const Text('Approve'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('reject-approval-button'),
                    onPressed: canResolve
                        ? () {
                            controller.resolveApproval(
                              approvalId: approval.approvalId,
                              approved: false,
                            );
                          }
                        : null,
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Reject'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ThreadContextCard extends StatelessWidget {
  const _ThreadContextCard({
    required this.bridgeApiBaseUrl,
    required this.threadId,
    required this.contextSnapshot,
  });

  final String bridgeApiBaseUrl;
  final String threadId;
  final _ApprovalThreadContext contextSnapshot;

  @override
  Widget build(BuildContext context) {
    final detail = contextSnapshot.detail;
    final commandDescription = _describeCommand(
      contextSnapshot.latestCommandEvent,
    );
    final fileChangeDescription = _describeFileChange(
      contextSnapshot.latestFileChangeEvent,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Originating thread context',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (contextSnapshot.errorMessage != null)
              Text(contextSnapshot.errorMessage!)
            else ...[
              if (detail != null) ...[
                Text('Title: ${detail.title}'),
                Text('Workspace: ${detail.workspace}'),
                Text('Repository: ${detail.repository}'),
                Text('Branch: ${detail.branch}'),
                const SizedBox(height: 8),
              ],
              Text('Recent command context: $commandDescription'),
              const SizedBox(height: 6),
              Text('Recent file-change context: $fileChangeDescription'),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const Key('open-origin-thread-button'),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (context) => ThreadDetailPage(
                      bridgeApiBaseUrl: bridgeApiBaseUrl,
                      threadId: threadId,
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.forum_outlined),
              label: const Text('Open originating thread'),
            ),
          ],
        ),
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

class _InlineInfo extends StatelessWidget {
  const _InlineInfo({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Text(message),
    );
  }
}

class _ApprovalThreadContext {
  const _ApprovalThreadContext({
    this.detail,
    this.latestCommandEvent,
    this.latestFileChangeEvent,
    this.errorMessage,
  });

  final ThreadDetailDto? detail;
  final ThreadTimelineEntryDto? latestCommandEvent;
  final ThreadTimelineEntryDto? latestFileChangeEvent;
  final String? errorMessage;
}

ThreadTimelineEntryDto? _latestEvent(
  List<ThreadTimelineEntryDto> timeline,
  BridgeEventKind kind,
) {
  for (var index = timeline.length - 1; index >= 0; index -= 1) {
    final event = timeline[index];
    if (event.kind == kind) {
      return event;
    }
  }
  return null;
}

String _describeCommand(ThreadTimelineEntryDto? event) {
  if (event == null) {
    return 'No recent command output was captured for this thread.';
  }

  final command = _optionalString(event.payload, 'command');
  final delta =
      _optionalString(event.payload, 'delta') ??
      _optionalString(event.payload, 'output') ??
      _optionalString(event.payload, 'text');

  if (command != null && delta != null) {
    return '`$command` → $delta';
  }
  return command ?? delta ?? event.summary;
}

String _describeFileChange(ThreadTimelineEntryDto? event) {
  if (event == null) {
    return 'No recent file-change summary was captured for this thread.';
  }

  final path =
      _optionalString(event.payload, 'path') ??
      _optionalString(event.payload, 'file') ??
      _optionalString(event.payload, 'file_path') ??
      _optionalString(event.payload, 'target');
  final summary =
      _optionalString(event.payload, 'summary') ??
      _optionalString(event.payload, 'change') ??
      _optionalString(event.payload, 'delta');

  if (path != null && summary != null) {
    return '$path → $summary';
  }
  return path ?? summary ?? event.summary;
}

String _resolvedStatusMessage(ApprovalStatus status) {
  switch (status) {
    case ApprovalStatus.pending:
      return 'Approval is pending.';
    case ApprovalStatus.approved:
      return 'Approval is already resolved as approved.';
    case ApprovalStatus.rejected:
      return 'Approval is already resolved as rejected.';
  }
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    return null;
  }
  return value.trim();
}
