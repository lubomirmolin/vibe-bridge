import 'package:codex_mobile_companion/features/threads/application/thread_diff_controller.dart';
import 'package:codex_mobile_companion/features/threads/domain/parsed_command_output.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_diff_viewer.dart';
import 'package:codex_mobile_companion/foundation/connectivity/live_connection_state.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_mobile_companion/foundation/layout/adaptive_layout.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/shared/widgets/connection_status_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class ThreadGitDiffPage extends StatelessWidget {
  const ThreadGitDiffPage({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.threadId,
  });

  final String bridgeApiBaseUrl;
  final String threadId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: ThreadGitDiffPane(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
          showAppBarClose: true,
          onClose: () => Navigator.of(context).maybePop(),
        ),
      ),
    );
  }
}

class ThreadGitDiffPane extends ConsumerWidget {
  const ThreadGitDiffPane({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.threadId,
    this.showAppBarClose = false,
    this.onClose,
  });

  final String bridgeApiBaseUrl;
  final String threadId;
  final bool showAppBarClose;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(
      threadDiffControllerProvider(
        ThreadDiffControllerArgs(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
        ),
      ),
    );
    final controller = ref.read(
      threadDiffControllerProvider(
        ThreadDiffControllerArgs(
          bridgeApiBaseUrl: bridgeApiBaseUrl,
          threadId: threadId,
        ),
      ).notifier,
    );
    final layout = AdaptiveLayoutInfo.fromMediaQuery(MediaQuery.of(context));
    final diff = state.diff;
    final selectedFile = state.selectedFile;
    final files = state.parsedFiles;
    GitDiffFileSummaryDto? selectedSummary;
    if (diff != null) {
      for (final file in diff.files) {
        if (file.path == state.selectedFilePath) {
          selectedSummary = file;
          break;
        }
      }
    }
    final isWideInnerLayout =
        layout.windowSize.width >= 1100 && layout.isWideLayout;

    return DecoratedBox(
      decoration: const BoxDecoration(color: AppTheme.background),
      child: Column(
        children: [
          _DiffHeader(
            diff: diff,
            mode: state.mode,
            isRefreshing: state.isRefreshing,
            liveConnectionState: state.liveConnectionState,
            onModeChanged: controller.setMode,
            onRefresh: controller.refreshNow,
            showCloseButton: showAppBarClose || onClose != null,
            onClose: onClose,
          ),
          Expanded(
            child: state.isLoading && diff == null
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.emerald),
                  )
                : state.errorMessage != null && diff == null
                ? _DiffErrorState(
                    message: state.errorMessage!,
                    onRetry: controller.refreshNow,
                  )
                : files.isEmpty
                ? _DiffEmptyState(
                    mode: state.mode,
                    errorMessage: state.errorMessage,
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                    child: isWideInnerLayout
                        ? Row(
                            children: [
                              SizedBox(
                                width: 280,
                                child: _ChangedFilesList(
                                  selectedFilePath: state.selectedFilePath,
                                  files: diff?.files ?? const [],
                                  onSelect: controller.selectFile,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: _DiffPreviewCard(
                                  selectedFilePath: selectedFile?.path,
                                  document: state.document,
                                  selectedSummary: selectedSummary,
                                  errorMessage: state.errorMessage,
                                ),
                              ),
                            ],
                          )
                        : Column(
                            children: [
                              SizedBox(
                                height: 172,
                                child: _ChangedFilesList(
                                  selectedFilePath: state.selectedFilePath,
                                  files: diff?.files ?? const [],
                                  onSelect: controller.selectFile,
                                  horizontal: true,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Expanded(
                                child: _DiffPreviewCard(
                                  selectedFilePath: selectedFile?.path,
                                  document: state.document,
                                  selectedSummary: selectedSummary,
                                  errorMessage: state.errorMessage,
                                ),
                              ),
                            ],
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DiffHeader extends StatelessWidget {
  const _DiffHeader({
    required this.diff,
    required this.mode,
    required this.isRefreshing,
    required this.liveConnectionState,
    required this.onModeChanged,
    required this.onRefresh,
    required this.showCloseButton,
    required this.onClose,
  });

  final ThreadGitDiffDto? diff;
  final ThreadGitDiffMode mode;
  final bool isRefreshing;
  final LiveConnectionState liveConnectionState;
  final Future<void> Function(ThreadGitDiffMode mode) onModeChanged;
  final Future<void> Function() onRefresh;
  final bool showCloseButton;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final repositoryLabel = diff == null
        ? 'Git diff'
        : '${diff!.repository.repository} • ${diff!.repository.branch}';

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (showCloseButton)
                IconButton(
                  onPressed: onClose,
                  icon: PhosphorIcon(
                    PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                    color: AppTheme.textMuted,
                    size: 20,
                  ),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Git Diff',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      repositoryLabel,
                      style: GoogleFonts.jetBrainsMono(
                        color: AppTheme.textSubtle,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: isRefreshing ? null : onRefresh,
                icon: isRefreshing
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.textMain,
                        ),
                      )
                    : PhosphorIcon(
                        PhosphorIcons.arrowsClockwise(),
                        color: AppTheme.textMain,
                        size: 18,
                      ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ModeChip(
                label: 'Workspace',
                selected: mode == ThreadGitDiffMode.workspace,
                onTap: () => onModeChanged(ThreadGitDiffMode.workspace),
              ),
              _ModeChip(
                label: 'Latest thread change',
                selected: mode == ThreadGitDiffMode.latestThreadChange,
                onTap: () =>
                    onModeChanged(ThreadGitDiffMode.latestThreadChange),
              ),
            ],
          ),
          ConnectionStatusBanner(
            state: _connectionBannerState(liveConnectionState),
            detail: _connectionDetail(liveConnectionState),
            compact: true,
            margin: const EdgeInsets.only(top: 12),
          ),
        ],
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.emerald.withValues(alpha: 0.14)
              : AppTheme.surfaceZinc900,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? AppTheme.emerald.withValues(alpha: 0.34)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.jetBrainsMono(
            color: selected ? AppTheme.emerald : AppTheme.textSubtle,
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _ChangedFilesList extends StatelessWidget {
  const _ChangedFilesList({
    required this.selectedFilePath,
    required this.files,
    required this.onSelect,
    this.horizontal = false,
  });

  final String? selectedFilePath;
  final List<GitDiffFileSummaryDto> files;
  final ValueChanged<String> onSelect;
  final bool horizontal;

  @override
  Widget build(BuildContext context) {
    final child = horizontal
        ? ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: files.length,
            separatorBuilder: (context, index) => const SizedBox(width: 12),
            itemBuilder: (context, index) => SizedBox(
              width: 260,
              child: _ChangedFileTile(
                file: files[index],
                selected: files[index].path == selectedFilePath,
                onTap: () => onSelect(files[index].path),
              ),
            ),
          )
        : ListView.separated(
            itemCount: files.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) => _ChangedFileTile(
              file: files[index],
              selected: files[index].path == selectedFilePath,
              onTap: () => onSelect(files[index].path),
            ),
          );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: child,
    );
  }
}

class _ChangedFileTile extends StatelessWidget {
  const _ChangedFileTile({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final GitDiffFileSummaryDto file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.emerald.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected
                ? AppTheme.emerald.withValues(alpha: 0.28)
                : Colors.white.withValues(alpha: 0.05),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              file.path,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.jetBrainsMono(
                color: AppTheme.textMain,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                Text(
                  '+${file.additions}',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.emerald,
                    fontSize: 11,
                  ),
                ),
                Text(
                  '-${file.deletions}',
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.rose,
                    fontSize: 11,
                  ),
                ),
                Text(
                  _changeTypeLabel(file.changeType),
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 10.5,
                  ),
                ),
                if (file.isBinary)
                  Text(
                    'Binary',
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.amber,
                      fontSize: 10.5,
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

class _DiffPreviewCard extends StatelessWidget {
  const _DiffPreviewCard({
    required this.selectedFilePath,
    required this.document,
    required this.selectedSummary,
    required this.errorMessage,
  });

  final String? selectedFilePath;
  final ParsedDiffDocument? document;
  final GitDiffFileSummaryDto? selectedSummary;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final selectedFilePath = this.selectedFilePath;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: document == null || selectedFilePath == null
          ? Center(
              child: Text(
                selectedSummary?.isBinary == true
                    ? 'Binary diff preview is unavailable for this file.'
                    : 'No diff preview is available.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textMuted),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (errorMessage != null) ...[
                  _InlineDiffNotice(
                    color: AppTheme.amber,
                    message: errorMessage!,
                  ),
                  const SizedBox(height: 12),
                ],
                Expanded(
                  child: SingleChildScrollView(
                    child: ThreadDiffViewer(
                      document: document!,
                      fileFilter: selectedFilePath,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _DiffErrorState extends StatelessWidget {
  const _DiffErrorState({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhosphorIcon(
              PhosphorIcons.gitDiff(),
              size: 36,
              color: AppTheme.rose,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, height: 1.5),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _DiffEmptyState extends StatelessWidget {
  const _DiffEmptyState({required this.mode, required this.errorMessage});

  final ThreadGitDiffMode mode;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final message = switch (mode) {
      ThreadGitDiffMode.workspace =>
        'The workspace has no visible git changes right now.',
      ThreadGitDiffMode.latestThreadChange =>
        'This thread does not have a resolved diff yet.',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PhosphorIcon(
              PhosphorIcons.gitDiff(),
              size: 36,
              color: AppTheme.textSubtle,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, height: 1.5),
            ),
            if (errorMessage != null) ...[
              const SizedBox(height: 12),
              _InlineDiffNotice(color: AppTheme.amber, message: errorMessage!),
            ],
          ],
        ),
      ),
    );
  }
}

class _InlineDiffNotice extends StatelessWidget {
  const _InlineDiffNotice({required this.color, required this.message});

  final Color color;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Text(message, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}

ConnectionBannerState _connectionBannerState(LiveConnectionState state) {
  switch (state) {
    case LiveConnectionState.connected:
      return ConnectionBannerState.connected;
    case LiveConnectionState.reconnecting:
      return ConnectionBannerState.reconnecting;
    case LiveConnectionState.disconnected:
      return ConnectionBannerState.disconnected;
  }
}

String _connectionDetail(LiveConnectionState state) {
  switch (state) {
    case LiveConnectionState.connected:
      return 'Diff auto-refresh is live.';
    case LiveConnectionState.reconnecting:
      return 'Reconnecting diff updates.';
    case LiveConnectionState.disconnected:
      return 'Live diff updates are offline.';
  }
}

String _changeTypeLabel(GitDiffChangeType changeType) {
  switch (changeType) {
    case GitDiffChangeType.added:
      return 'Added';
    case GitDiffChangeType.modified:
      return 'Modified';
    case GitDiffChangeType.deleted:
      return 'Deleted';
    case GitDiffChangeType.renamed:
      return 'Renamed';
    case GitDiffChangeType.copied:
      return 'Copied';
    case GitDiffChangeType.typeChanged:
      return 'Type changed';
    case GitDiffChangeType.unmerged:
      return 'Unmerged';
    case GitDiffChangeType.unknown:
      return 'Unknown';
  }
}
