import 'dart:async';

import 'package:codex_mobile_companion/features/threads/data/browser_thread_list_api.dart';
import 'package:codex_mobile_companion/features/threads/data/browser_thread_list_api_stub.dart';
import 'package:codex_mobile_companion/features/threads/presentation/browser_thread_detail_page.dart';
import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class BrowserThreadListPage extends ConsumerStatefulWidget {
  const BrowserThreadListPage({super.key, required this.bridgeApiBaseUrl});

  final String bridgeApiBaseUrl;

  @override
  ConsumerState<BrowserThreadListPage> createState() =>
      _BrowserThreadListPageState();
}

class _BrowserThreadListPageState extends ConsumerState<BrowserThreadListPage> {
  bool _isLoading = true;
  String? _errorMessage;
  List<ThreadSummaryDto> _threads = const <ThreadSummaryDto>[];

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final threads = await ref
          .read(browserThreadListApiProvider)
          .fetchThreads(bridgeApiBaseUrl: widget.bridgeApiBaseUrl);
      if (!mounted) {
        return;
      }
      setState(() {
        _threads = threads;
        _isLoading = false;
      });
    } on BrowserThreadListException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = error.message;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Couldn’t load threads from the local bridge.';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Browser Local Threads',
                          key: Key('browser-thread-list-title'),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      FilledButton(
                        onPressed: _isLoading ? null : _refresh,
                        child: const Text('Refresh'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    widget.bridgeApiBaseUrl,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isLoading)
                    const Expanded(
                      child: Center(
                        child: CircularProgressIndicator(
                          color: AppTheme.emerald,
                        ),
                      ),
                    )
                  else if (_errorMessage != null)
                    Expanded(
                      child: Center(
                        child: Text(
                          _errorMessage!,
                          key: const Key('browser-thread-list-error'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppTheme.textMuted),
                        ),
                      ),
                    )
                  else if (_threads.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'No threads are available on the local bridge.',
                          style: TextStyle(color: AppTheme.textMuted),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.separated(
                        itemCount: _threads.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final thread = _threads[index];
                          return InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: () async {
                              await Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => BrowserThreadDetailPage(
                                    bridgeApiBaseUrl: widget.bridgeApiBaseUrl,
                                    threadId: thread.threadId,
                                  ),
                                ),
                              );
                            },
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: AppTheme.surfaceZinc800.withValues(
                                  alpha: 0.72,
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      thread.title,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 18,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Text(
                                      '${thread.repository} · ${thread.branch}',
                                      style: const TextStyle(
                                        color: AppTheme.textMuted,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      thread.workspace,
                                      style: const TextStyle(
                                        color: AppTheme.textSubtle,
                                        fontFamily: 'JetBrainsMono',
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Text(
                                      'Updated ${thread.updatedAt}',
                                      style: const TextStyle(
                                        color: AppTheme.textSubtle,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
