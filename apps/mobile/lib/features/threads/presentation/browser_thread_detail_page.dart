import 'dart:async';
import 'dart:convert';

import 'package:codex_mobile_companion/features/threads/data/browser_thread_detail_api.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class BrowserThreadDetailPage extends ConsumerStatefulWidget {
  const BrowserThreadDetailPage({
    super.key,
    required this.bridgeApiBaseUrl,
    required this.threadId,
  });

  final String bridgeApiBaseUrl;
  final String threadId;

  @override
  ConsumerState<BrowserThreadDetailPage> createState() =>
      _BrowserThreadDetailPageState();
}

class _BrowserThreadDetailPageState
    extends ConsumerState<BrowserThreadDetailPage> {
  late final TextEditingController _composerController;

  ThreadSnapshotDto? _snapshot;
  AccessMode? _accessMode;
  String? _errorMessage;
  String? _mutationMessage;
  String? _accessModeErrorMessage;
  bool _isLoading = true;
  bool _isRefreshing = false;
  bool _isSubmittingTurn = false;
  bool _isInterruptingTurn = false;
  bool _isUpdatingAccessMode = false;
  Timer? _pollTimer;

  bool get _hasActiveTurn =>
      _snapshot?.thread.status == ThreadStatus.running ||
      _snapshot?.thread.status == ThreadStatus.idle;

  @override
  void initState() {
    super.initState();
    _composerController = TextEditingController();
    unawaited(_loadInitialState());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _composerController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialState() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    await _refresh(showLoading: true);
  }

  Future<void> _refresh({bool showLoading = false}) async {
    if (showLoading) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    } else {
      setState(() {
        _isRefreshing = true;
        _errorMessage = null;
      });
    }

    try {
      final api = ref.read(browserThreadDetailApiProvider);
      final values = await Future.wait<dynamic>([
        api.fetchThreadSnapshot(
          bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
          threadId: widget.threadId,
        ),
        api.fetchAccessMode(bridgeApiBaseUrl: widget.bridgeApiBaseUrl),
      ]);

      if (!mounted) {
        return;
      }

      final snapshot = values[0] as ThreadSnapshotDto;
      final accessMode = values[1] as AccessMode;
      _restartPollingIfNeeded(snapshot);
      setState(() {
        _snapshot = snapshot;
        _accessMode = accessMode;
        _isLoading = false;
        _isRefreshing = false;
      });
    } on BrowserThreadDetailException catch (error) {
      if (!mounted) {
        return;
      }
      _pollTimer?.cancel();
      setState(() {
        _errorMessage = error.message;
        _isLoading = false;
        _isRefreshing = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      _pollTimer?.cancel();
      setState(() {
        _errorMessage = 'Couldn’t load that thread right now.';
        _isLoading = false;
        _isRefreshing = false;
      });
    }
  }

  void _restartPollingIfNeeded(ThreadSnapshotDto snapshot) {
    _pollTimer?.cancel();
    if (snapshot.thread.status != ThreadStatus.running) {
      return;
    }

    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refresh());
    });
  }

  Future<void> _submitTurn() async {
    final prompt = _composerController.text.trim();
    if (prompt.isEmpty || _isSubmittingTurn || _isInterruptingTurn) {
      return;
    }

    setState(() {
      _isSubmittingTurn = true;
      _mutationMessage = null;
      _errorMessage = null;
    });

    try {
      final result = await ref
          .read(browserThreadDetailApiProvider)
          .startTurn(
            bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
            threadId: widget.threadId,
            prompt: prompt,
          );
      if (!mounted) {
        return;
      }
      _composerController.clear();
      setState(() {
        _mutationMessage = result.message;
        _isSubmittingTurn = false;
      });
      await _refresh();
    } on BrowserThreadDetailException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
        _isSubmittingTurn = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Couldn’t submit that prompt right now.';
        _isSubmittingTurn = false;
      });
    }
  }

  Future<void> _interruptTurn() async {
    if (_isSubmittingTurn || _isInterruptingTurn) {
      return;
    }

    setState(() {
      _isInterruptingTurn = true;
      _mutationMessage = null;
      _errorMessage = null;
    });

    try {
      final result = await ref
          .read(browserThreadDetailApiProvider)
          .interruptTurn(
            bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
            threadId: widget.threadId,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _mutationMessage = result.message;
        _isInterruptingTurn = false;
      });
      await _refresh();
    } on BrowserThreadDetailException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
        _isInterruptingTurn = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Couldn’t interrupt the active turn right now.';
        _isInterruptingTurn = false;
      });
    }
  }

  Future<void> _setAccessMode(AccessMode accessMode) async {
    if (_isUpdatingAccessMode) {
      return;
    }

    setState(() {
      _isUpdatingAccessMode = true;
      _accessModeErrorMessage = null;
    });

    try {
      final updatedMode = await ref
          .read(browserThreadDetailApiProvider)
          .setAccessMode(
            bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
            accessMode: accessMode,
          );
      if (!mounted) {
        return;
      }
      setState(() {
        _accessMode = updatedMode;
        _isUpdatingAccessMode = false;
      });
      await _refresh();
    } on BrowserThreadDetailException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _accessModeErrorMessage = error.message;
        _isUpdatingAccessMode = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _accessModeErrorMessage =
            'Couldn’t update access mode from the browser.';
        _isUpdatingAccessMode = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: _isLoading && snapshot == null
            ? const Center(
                child: CircularProgressIndicator(color: AppTheme.emerald),
              )
            : snapshot == null
            ? _BrowserDetailErrorState(
                message: _errorMessage ?? 'Couldn’t load that thread.',
                onRetry: _loadInitialState,
              )
            : Column(
                children: [
                  _BrowserThreadHeader(
                    snapshot: snapshot,
                    bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
                    isRefreshing: _isRefreshing,
                    onRefresh: _refresh,
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      children: [
                        _BrowserThreadMeta(snapshot: snapshot),
                        const SizedBox(height: 16),
                        _BrowserAccessModeCard(
                          accessMode: _accessMode ?? snapshot.thread.accessMode,
                          isUpdating: _isUpdatingAccessMode,
                          errorMessage: _accessModeErrorMessage,
                          onChangeMode: _setAccessMode,
                        ),
                        const SizedBox(height: 16),
                        _BrowserComposerCard(
                          controller: _composerController,
                          isSubmitting: _isSubmittingTurn,
                          isInterrupting: _isInterruptingTurn,
                          hasActiveTurn:
                              snapshot.thread.status == ThreadStatus.running,
                          mutationMessage: _mutationMessage,
                          errorMessage: _errorMessage,
                          onSubmit: _submitTurn,
                          onInterrupt: _interruptTurn,
                        ),
                        const SizedBox(height: 16),
                        if (snapshot.approvals.isNotEmpty) ...[
                          _BrowserApprovalsCard(approvals: snapshot.approvals),
                          const SizedBox(height: 16),
                        ],
                        _BrowserTimelineCard(entries: snapshot.entries),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _BrowserThreadHeader extends StatelessWidget {
  const _BrowserThreadHeader({
    required this.snapshot,
    required this.bridgeApiBaseUrl,
    required this.isRefreshing,
    required this.onRefresh,
  });

  final ThreadSnapshotDto snapshot;
  final String bridgeApiBaseUrl;
  final bool isRefreshing;
  final Future<void> Function({bool showLoading}) onRefresh;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: const BoxDecoration(
        color: AppTheme.background,
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).maybePop(),
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
                  snapshot.thread.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  bridgeApiBaseUrl,
                  style: GoogleFonts.jetBrainsMono(
                    color: AppTheme.textSubtle,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: isRefreshing
                ? null
                : () {
                    unawaited(onRefresh());
                  },
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
    );
  }
}

class _BrowserThreadMeta extends StatelessWidget {
  const _BrowserThreadMeta({required this.snapshot});

  final ThreadSnapshotDto snapshot;

  @override
  Widget build(BuildContext context) {
    final thread = snapshot.thread;
    return _BrowserCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                thread.repository,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              _StatusPill(
                label: thread.status.wireValue.toUpperCase(),
                color: thread.status == ThreadStatus.running
                    ? AppTheme.emerald
                    : AppTheme.textMuted,
              ),
            ],
          ),
          const SizedBox(height: 10),
          _MetaRow(label: 'Branch', value: thread.branch),
          _MetaRow(label: 'Workspace', value: thread.workspace),
          _MetaRow(label: 'Updated', value: thread.updatedAt),
          if (snapshot.gitStatus != null)
            _MetaRow(
              label: 'Git',
              value:
                  '${snapshot.gitStatus!.repository} · dirty=${snapshot.gitStatus!.dirty} · ahead=${snapshot.gitStatus!.aheadBy} · behind=${snapshot.gitStatus!.behindBy}',
            ),
        ],
      ),
    );
  }
}

class _BrowserAccessModeCard extends StatelessWidget {
  const _BrowserAccessModeCard({
    required this.accessMode,
    required this.isUpdating,
    required this.errorMessage,
    required this.onChangeMode,
  });

  final AccessMode accessMode;
  final bool isUpdating;
  final String? errorMessage;
  final ValueChanged<AccessMode> onChangeMode;

  @override
  Widget build(BuildContext context) {
    return _BrowserCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Browser Access Mode',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (isUpdating)
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppTheme.emerald,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'This browser session controls the bridge running on the current machine.',
            style: TextStyle(color: AppTheme.textMuted),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: AccessMode.values
                .map(
                  (mode) => ChoiceChip(
                    label: Text(_accessModeLabel(mode)),
                    selected: accessMode == mode,
                    onSelected: isUpdating
                        ? null
                        : (_) {
                            onChangeMode(mode);
                          },
                    selectedColor: AppTheme.emerald.withValues(alpha: 0.18),
                    labelStyle: TextStyle(
                      color: accessMode == mode
                          ? AppTheme.emerald
                          : AppTheme.textMuted,
                    ),
                    backgroundColor: AppTheme.surfaceZinc800,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                )
                .toList(growable: false),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(errorMessage!, style: const TextStyle(color: AppTheme.rose)),
          ],
        ],
      ),
    );
  }
}

class _BrowserComposerCard extends StatelessWidget {
  const _BrowserComposerCard({
    required this.controller,
    required this.isSubmitting,
    required this.isInterrupting,
    required this.hasActiveTurn,
    required this.mutationMessage,
    required this.errorMessage,
    required this.onSubmit,
    required this.onInterrupt,
  });

  final TextEditingController controller;
  final bool isSubmitting;
  final bool isInterrupting;
  final bool hasActiveTurn;
  final String? mutationMessage;
  final String? errorMessage;
  final Future<void> Function() onSubmit;
  final Future<void> Function() onInterrupt;

  @override
  Widget build(BuildContext context) {
    return _BrowserCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Prompt',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Speech input is not available in browser mode yet.',
            style: TextStyle(color: AppTheme.textMuted),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            minLines: 3,
            maxLines: 8,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Type a prompt for the current thread…',
              hintStyle: const TextStyle(color: AppTheme.textSubtle),
              filled: true,
              fillColor: AppTheme.surfaceZinc800,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide(
                  color: Colors.white.withValues(alpha: 0.06),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton(
                onPressed: isSubmitting || isInterrupting
                    ? null
                    : () {
                        unawaited(onSubmit());
                      },
                child: isSubmitting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Send Prompt'),
              ),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: hasActiveTurn && !isSubmitting && !isInterrupting
                    ? () {
                        unawaited(onInterrupt());
                      }
                    : null,
                child: isInterrupting
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Interrupt'),
              ),
            ],
          ),
          if (mutationMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              mutationMessage!,
              style: const TextStyle(color: AppTheme.emerald),
            ),
          ],
          if (errorMessage != null) ...[
            const SizedBox(height: 8),
            Text(errorMessage!, style: const TextStyle(color: AppTheme.rose)),
          ],
        ],
      ),
    );
  }
}

class _BrowserApprovalsCard extends StatelessWidget {
  const _BrowserApprovalsCard({required this.approvals});

  final List<ApprovalSummaryDto> approvals;

  @override
  Widget build(BuildContext context) {
    return _BrowserCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Approvals',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          ...approvals.map(
            (approval) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      approval.action,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      approval.reason,
                      style: const TextStyle(color: AppTheme.textMuted),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Status: ${approval.status.name}',
                      style: GoogleFonts.jetBrainsMono(
                        color: AppTheme.textSubtle,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BrowserTimelineCard extends StatelessWidget {
  const _BrowserTimelineCard({required this.entries});

  final List<ThreadTimelineEntryDto> entries;

  @override
  Widget build(BuildContext context) {
    return _BrowserCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Timeline',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          if (entries.isEmpty)
            const Text(
              'No timeline entries are available for this thread yet.',
              style: TextStyle(color: AppTheme.textMuted),
            )
          else
            ...entries.reversed.map(
              (entry) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black26,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.summary,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${entry.kind.wireValue} · ${entry.occurredAt}',
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textSubtle,
                          fontSize: 11,
                        ),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        _prettyPayload(entry.payload),
                        style: GoogleFonts.jetBrainsMono(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BrowserDetailErrorState extends StatelessWidget {
  const _BrowserDetailErrorState({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _BrowserCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Thread unavailable',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  message,
                  style: const TextStyle(color: AppTheme.textMuted),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    unawaited(onRetry());
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BrowserCard extends StatelessWidget {
  const _BrowserCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc800.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textSubtle),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: GoogleFonts.jetBrainsMono(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _accessModeLabel(AccessMode accessMode) {
  return switch (accessMode) {
    AccessMode.readOnly => 'Read-only',
    AccessMode.controlWithApprovals => '+ Approvals',
    AccessMode.fullControl => 'Full Control',
  };
}

String _prettyPayload(Map<String, dynamic> payload) {
  try {
    return const JsonEncoder.withIndent('  ').convert(payload);
  } catch (_) {
    return payload.toString();
  }
}
