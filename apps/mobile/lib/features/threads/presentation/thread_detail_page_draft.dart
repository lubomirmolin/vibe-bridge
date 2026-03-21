part of 'thread_detail_page.dart';

class _DraftThreadDetailHeader extends StatelessWidget {
  const _DraftThreadDetailHeader({
    required this.workspacePath,
    required this.workspaceLabel,
    required this.onBack,
  });

  final String workspacePath;
  final String workspaceLabel;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 0, right: 16, bottom: 8),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                key: const Key('thread-draft-back-button'),
                onPressed: onBack,
                icon: PhosphorIcon(
                  PhosphorIcons.caretLeft(PhosphorIconsStyle.bold),
                  size: 20,
                  color: AppTheme.textMuted,
                ),
              ),
              Expanded(
                child: Text(
                  'New Thread',
                  key: const Key('thread-draft-title'),
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.5,
                    fontSize: 18,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.folderSimple(),
                    size: 14,
                    color: AppTheme.textSubtle,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    workspaceLabel,
                    style: GoogleFonts.jetBrainsMono(
                      color: AppTheme.textSubtle,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text('•', style: TextStyle(color: AppTheme.textSubtle)),
                  const SizedBox(width: 8),
                  const StatusBadge(
                    text: 'DRAFT',
                    variant: BadgeVariant.defaultVariant,
                  ),
                ],
              ),
            ),
          ),
          ConnectionStatusBanner(
            state: ConnectionBannerState.connected,
            detail: 'Ready to start a new session in this workspace.',
            compact: true,
            margin: const EdgeInsets.fromLTRB(36, 12, 0, 0),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 12, 0, 0),
            child: Text(
              workspacePath,
              key: const Key('thread-draft-workspace-path'),
              style: GoogleFonts.jetBrainsMono(
                color: AppTheme.textSubtle,
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadDraftBody extends StatelessWidget {
  const _ThreadDraftBody({
    required this.workspacePath,
    required this.workspaceLabel,
    required this.isReadOnlyMode,
    required this.draftErrorMessage,
  });

  final String workspacePath;
  final String workspaceLabel;
  final bool isReadOnlyMode;
  final String? draftErrorMessage;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      padding: const EdgeInsets.only(
        left: 24,
        right: 24,
        top: 212,
        bottom: 140,
      ),
      children: [
        const SizedBox(height: 16),
        if (isReadOnlyMode) ...[
          const _MutatingActionsBlockedNotice(
            message: 'Read-only mode blocks creating and starting new turns.',
            onRetryReconnect: null,
          ),
          const SizedBox(height: 12),
        ],
        if (draftErrorMessage != null) ...[
          _InlineWarning(message: draftErrorMessage!),
          const SizedBox(height: 12),
        ],
        Container(
          padding: const EdgeInsets.all(20),
          decoration: LiquidStyles.liquidGlass.copyWith(
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Start a new session',
                style: TextStyle(
                  color: AppTheme.textMain,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'This opens a fresh Codex thread in the selected workspace. Your first message will create the thread and start the turn.',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
              ),
              const SizedBox(height: 20),
              _DraftDetailRow(
                icon: PhosphorIcons.folderSimple(),
                label: 'Workspace',
                value: workspaceLabel,
              ),
              const SizedBox(height: 10),
              _DraftDetailRow(
                icon: PhosphorIcons.terminalWindow(),
                label: 'Path',
                value: workspacePath,
              ),
              const SizedBox(height: 10),
              _DraftDetailRow(
                icon: PhosphorIcons.chatTeardropText(),
                label: 'Timeline',
                value: 'Empty until the first prompt is sent',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DraftDetailRow extends StatelessWidget {
  const _DraftDetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PhosphorIcon(icon, size: 14, color: AppTheme.textSubtle),
        const SizedBox(width: 8),
        Text(
          '$label:',
          style: GoogleFonts.jetBrainsMono(
            color: AppTheme.textSubtle,
            fontSize: 11,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: GoogleFonts.jetBrainsMono(
              color: AppTheme.textMain,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}
