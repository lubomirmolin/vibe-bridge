import 'package:codex_mobile_companion/features/approvals/application/approvals_queue_controller.dart';
import 'package:codex_mobile_companion/features/approvals/presentation/approval_presenter.dart';
import 'package:codex_mobile_companion/features/threads/data/thread_detail_bridge_api.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/badges.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:google_fonts/google_fonts.dart';

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
  static const int _contextTimelinePageSize = 25;
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
      final firstPage = await api.fetchThreadTimelinePage(
        bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
        threadId: threadId,
        limit: _contextTimelinePageSize,
      );
      final detail = firstPage.thread;
      var latestCommandEvent = _latestEvent(
        firstPage.entries,
        BridgeEventKind.commandDelta,
      );
      var latestFileChangeEvent = _latestEvent(
        firstPage.entries,
        BridgeEventKind.fileChange,
      );
      var nextBefore = firstPage.nextBefore;
      var hasMoreBefore = firstPage.hasMoreBefore;

      while ((latestCommandEvent == null || latestFileChangeEvent == null) &&
          hasMoreBefore) {
        final page = await api.fetchThreadTimelinePage(
          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
          threadId: threadId,
          before: nextBefore,
          limit: _contextTimelinePageSize,
        );
        latestCommandEvent ??= _latestEvent(
          page.entries,
          BridgeEventKind.commandDelta,
        );
        latestFileChangeEvent ??= _latestEvent(
          page.entries,
          BridgeEventKind.fileChange,
        );
        nextBefore = page.nextBefore;
        hasMoreBefore = page.hasMoreBefore;
      }

      return _ApprovalThreadContext(
        detail: detail,
        latestCommandEvent: latestCommandEvent,
        latestFileChangeEvent: latestFileChangeEvent,
      );
    } on ThreadDetailBridgeException catch (error) {
      return _ApprovalThreadContext(errorMessage: error.message);
    } catch (_) {
      return const _ApprovalThreadContext(
        errorMessage: 'Couldn\'t load additional thread context right now.',
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
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              _Header(title: 'Approval Detail'),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PhosphorIcon(
                        PhosphorIcons.warningOctagon(),
                        size: 48,
                        color: AppTheme.amber,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Approval not found.',
                        style: TextStyle(
                          color: AppTheme.textMain,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.surfaceZinc800,
                          foregroundColor: AppTheme.textMain,
                        ),
                        onPressed: () =>
                            controller.loadApprovals(showLoading: true),
                        child: const Text('Refresh Approvals'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
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

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _Header(title: 'Approval Detail'),
            Expanded(
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                children: [
                  // Main Action Card
                  Container(
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
                                key: const Key('approval-detail-action'),
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
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 16),
                        _DetailRow(
                          icon: PhosphorIcons.target(),
                          text: approvalTargetLabel(approval),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            PhosphorIcon(
                              PhosphorIcons.fingerprint(),
                              size: 14,
                              color: AppTheme.textSubtle,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'ID: ${approval.approvalId}',
                                style: GoogleFonts.jetBrainsMono(
                                  color: AppTheme.textSubtle,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Git Context
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: LiquidStyles.liquidGlass.copyWith(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            PhosphorIcon(
                              PhosphorIcons.gitBranch(),
                              color: AppTheme.textMain,
                            ),
                            const SizedBox(width: 8),
                            const Text(
                              'Git & Repo context',
                              style: TextStyle(
                                color: AppTheme.textMain,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        _DetailRow(
                          icon: PhosphorIcons.terminalWindow(),
                          text: approval.repository.workspace,
                        ),
                        const SizedBox(height: 8),
                        _DetailRow(
                          icon: PhosphorIcons.folderSimple(),
                          text: approval.repository.repository,
                        ),
                        const SizedBox(height: 8),
                        _DetailRow(
                          icon: PhosphorIcons.gitBranch(),
                          text:
                              '${approval.repository.branch} (remote: ${approval.repository.remote})',
                        ),
                        const SizedBox(height: 12),

                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              PhosphorIcon(
                                approval.gitStatus.dirty
                                    ? PhosphorIcons.warningCircle()
                                    : PhosphorIcons.checkCircle(),
                                size: 14,
                                color: approval.gitStatus.dirty
                                    ? AppTheme.amber
                                    : AppTheme.emerald,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  approval.gitStatus.dirty
                                      ? 'Uncommitted changes'
                                      : 'Clean working tree',
                                  style: TextStyle(
                                    color: approval.gitStatus.dirty
                                        ? AppTheme.amber
                                        : AppTheme.emerald,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              Text(
                                '↑${approval.gitStatus.aheadBy} ↓${approval.gitStatus.behindBy}',
                                style: GoogleFonts.jetBrainsMono(
                                  color: AppTheme.textSubtle,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        _DetailRow(
                          icon: PhosphorIcons.chatTeardrop(),
                          text: approval.threadId,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  FutureBuilder<_ApprovalThreadContext>(
                    future: _contextFutureForThread(approval.threadId),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState != ConnectionState.done) {
                        return Container(
                          padding: const EdgeInsets.all(20),
                          decoration: LiquidStyles.liquidGlass.copyWith(
                            borderRadius: BorderRadius.circular(24),
                          ),
                          child: const Row(
                            children: [
                              SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: AppTheme.emerald,
                                ),
                              ),
                              SizedBox(width: 12),
                              Text(
                                'Loading thread context...',
                                style: TextStyle(color: AppTheme.textMuted),
                              ),
                            ],
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
                  const SizedBox(height: 16),

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
                  const SizedBox(height: 24),

                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          key: const Key('approve-approval-button'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.emerald,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: canResolve
                              ? () => controller.resolveApproval(
                                  approvalId: approval.approvalId,
                                  approved: true,
                                )
                              : null,
                          icon: item.isResolving
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : PhosphorIcon(
                                  PhosphorIcons.checkCircle(),
                                  size: 20,
                                ),
                          label: const Text(
                            'Approve',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton.icon(
                          key: const Key('reject-approval-button'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.surfaceZinc800,
                            foregroundColor: AppTheme.rose,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: canResolve
                              ? () => controller.resolveApproval(
                                  approvalId: approval.approvalId,
                                  approved: false,
                                )
                              : null,
                          icon: PhosphorIcon(PhosphorIcons.xCircle(), size: 20),
                          label: const Text(
                            'Reject',
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                    ],
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

class _Header extends StatelessWidget {
  final String title;

  const _Header({required this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      color: AppTheme.background.withValues(alpha: 0.8),
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
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w500,
                letterSpacing: -0.5,
              ),
            ),
          ),
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
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.textMuted,
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

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(
                PhosphorIcons.chatTeardrop(),
                color: AppTheme.textMain,
              ),
              const SizedBox(width: 8),
              const Text(
                'Originating thread',
                style: TextStyle(
                  color: AppTheme.textMain,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          if (contextSnapshot.errorMessage != null)
            Text(
              contextSnapshot.errorMessage!,
              style: const TextStyle(color: AppTheme.rose),
            )
          else ...[
            if (detail != null) ...[
              Text(
                detail.title,
                style: const TextStyle(
                  color: AppTheme.textMain,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              _DetailRow(
                icon: PhosphorIcons.folderSimple(),
                text: detail.repository,
              ),
              const SizedBox(height: 16),
            ],
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Recent command:',
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textSubtle,
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    commandDescription,
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Recent file change:',
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textSubtle,
                      fontSize: 10,
                    ),
                  ),
                  Text(
                    fileChangeDescription,
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.white12),
                foregroundColor: AppTheme.textMain,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ThreadDetailPage(
                      bridgeApiBaseUrl: bridgeApiBaseUrl,
                      threadId: threadId,
                    ),
                  ),
                );
              },
              icon: PhosphorIcon(PhosphorIcons.chatTeardropText()),
              label: const Text('Open originating thread'),
            ),
          ),
        ],
      ),
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
        color: AppTheme.rose.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.rose.withValues(alpha: 0.3)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppTheme.rose, fontSize: 13),
      ),
    );
  }
}

class _InlineInfo extends StatelessWidget {
  const _InlineInfo({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.emerald.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.emerald.withValues(alpha: 0.3)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: AppTheme.emerald, fontSize: 13),
      ),
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
    if (event.kind == kind) return event;
  }
  return null;
}

String _describeCommand(ThreadTimelineEntryDto? event) {
  if (event == null) return 'No recent command output was captured.';
  final command = _optionalString(event.payload, 'command');
  final delta =
      _optionalString(event.payload, 'delta') ??
      _optionalString(event.payload, 'output') ??
      _optionalString(event.payload, 'text');
  if (command != null && delta != null) return '`$command` → $delta';
  return command ?? delta ?? event.summary;
}

String _describeFileChange(ThreadTimelineEntryDto? event) {
  if (event == null) return 'No recent file-change summary was captured.';
  final path =
      _optionalString(event.payload, 'path') ??
      _optionalString(event.payload, 'file') ??
      _optionalString(event.payload, 'file_path') ??
      _optionalString(event.payload, 'target');
  final summary =
      _optionalString(event.payload, 'summary') ??
      _optionalString(event.payload, 'change') ??
      _optionalString(event.payload, 'delta');
  if (path != null && summary != null) return '$path → $summary';
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
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}
