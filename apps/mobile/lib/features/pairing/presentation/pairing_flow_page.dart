import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

enum PairingScannerIssueType { permissionDenied, scannerFailure }

@immutable
class PairingScannerIssue {
  const PairingScannerIssue._(this.type, {this.details});

  const PairingScannerIssue.permissionDenied()
    : this._(PairingScannerIssueType.permissionDenied);

  const PairingScannerIssue.failure({String? details})
    : this._(PairingScannerIssueType.scannerFailure, details: details);

  factory PairingScannerIssue.fromScannerException(
    MobileScannerException error,
  ) {
    if (error.errorCode == MobileScannerErrorCode.permissionDenied) {
      return const PairingScannerIssue.permissionDenied();
    }

    final details = error.errorDetails?.message;
    return PairingScannerIssue.failure(
      details: details == null || details.trim().isEmpty
          ? null
          : details.trim(),
    );
  }

  final PairingScannerIssueType type;
  final String? details;

  @override
  bool operator ==(Object other) {
    return other is PairingScannerIssue &&
        other.type == type &&
        other.details == details;
  }

  @override
  int get hashCode => Object.hash(type, details);
}

class PairingFlowPage extends ConsumerStatefulWidget {
  const PairingFlowPage({
    super.key,
    this.enableCameraPreview = true,
    this.initialScannerIssue,
    this.autoOpenThreadsOnPairing = false,
  });

  final bool enableCameraPreview;
  final PairingScannerIssue? initialScannerIssue;
  final bool autoOpenThreadsOnPairing;

  @override
  ConsumerState<PairingFlowPage> createState() => _PairingFlowPageState();
}

class _PairingFlowPageState extends ConsumerState<PairingFlowPage> {
  late final TextEditingController _manualPayloadController;
  late final FocusNode _manualPayloadFocusNode;
  late final MobileScannerController _cameraController;
  final Set<String> _autoOpenedThreadSessionIds = <String>{};
  PairingScannerIssue? _scannerIssue;
  bool _isAutoOpeningThreadList = false;

  @override
  void initState() {
    super.initState();
    _manualPayloadController = TextEditingController();
    _manualPayloadFocusNode = FocusNode();
    _cameraController = MobileScannerController();
    _scannerIssue = widget.initialScannerIssue;
  }

  @override
  void dispose() {
    _manualPayloadController.dispose();
    _manualPayloadFocusNode.dispose();
    _cameraController.dispose();
    super.dispose();
  }

  void _openScanner(PairingController pairingController) {
    setState(() {
      _scannerIssue = widget.initialScannerIssue;
    });
    pairingController.openScanner();
  }

  void _setScannerIssue(PairingScannerIssue issue) {
    if (_scannerIssue == issue || !mounted) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scannerIssue == issue) {
        return;
      }
      setState(() {
        _scannerIssue = issue;
      });
    });
  }

  Future<void> _retryCamera() async {
    setState(() {
      _scannerIssue = null;
    });

    try {
      await _cameraController.start();
    } on MobileScannerException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scannerIssue = PairingScannerIssue.fromScannerException(error);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scannerIssue = const PairingScannerIssue.failure();
      });
    }
  }

  void _focusManualFallback() {
    _manualPayloadFocusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final pairingState = ref.watch(pairingControllerProvider);
    final pairingController = ref.read(pairingControllerProvider.notifier);
    _maybeAutoOpenThreadList(pairingState);

    final body = switch (pairingState.step) {
      PairingStep.unpaired => _buildUnpairedView(
        pairingController,
        errorMessage: pairingState.errorMessage,
      ),
      PairingStep.scanning => _buildScannerView(
        pairingState,
        pairingController,
      ),
      PairingStep.review => _buildReviewView(pairingState, pairingController),
      PairingStep.paired => _buildPairedView(pairingState, pairingController),
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Codex Mobile Companion')),
      body: SafeArea(child: body),
    );
  }

  void _maybeAutoOpenThreadList(PairingState pairingState) {
    if (!widget.autoOpenThreadsOnPairing ||
        pairingState.step != PairingStep.paired) {
      return;
    }

    final bridge = pairingState.trustedBridge;
    if (bridge == null || _isAutoOpeningThreadList) {
      return;
    }

    final sessionId = bridge.sessionId.trim();
    if (sessionId.isEmpty || _autoOpenedThreadSessionIds.contains(sessionId)) {
      return;
    }

    _isAutoOpeningThreadList = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _isAutoOpeningThreadList = false;
        return;
      }

      _autoOpenedThreadSessionIds.add(sessionId);
      try {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) =>
                ThreadListPage(bridgeApiBaseUrl: bridge.bridgeApiBaseUrl),
          ),
        );
      } finally {
        _isAutoOpeningThreadList = false;
      }
    });
  }

  Widget _buildUnpairedView(
    PairingController pairingController, {
    String? errorMessage,
  }) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pair your phone to this Mac',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text(
            'Scan the QR code shown in the macOS shell to start pairing securely.',
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => _openScanner(pairingController),
            child: const Text('Scan pairing QR'),
          ),
          if (errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              errorMessage,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildScannerView(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Scan pairing QR',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text('Point your camera at the desktop pairing QR code.'),
          if (_scannerIssue != null) ...[
            const SizedBox(height: 16),
            _ScannerIssueBanner(
              issue: _scannerIssue!,
              onRetryCamera: () {
                _retryCamera();
              },
              onUseManualFallback: _focusManualFallback,
            ),
          ],
          const SizedBox(height: 16),
          if (widget.enableCameraPreview)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 260,
                child: MobileScanner(
                  key: const Key('camera-scanner'),
                  controller: _cameraController,
                  onDetect: (capture) {
                    for (final barcode in capture.barcodes) {
                      final rawValue = barcode.rawValue;
                      if (rawValue != null && rawValue.trim().isNotEmpty) {
                        setState(() {
                          _scannerIssue = null;
                        });
                        pairingController.submitScannedPayload(rawValue);
                        break;
                      }
                    }
                  },
                  errorBuilder: (context, error) {
                    _setScannerIssue(
                      PairingScannerIssue.fromScannerException(error),
                    );
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLow,
                      ),
                      child: const Center(
                        child: Icon(Icons.camera_alt_outlined, size: 48),
                      ),
                    );
                  },
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            'Manual fallback (use when camera scanning is unavailable):',
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('manual-payload-input'),
            controller: _manualPayloadController,
            focusNode: _manualPayloadFocusNode,
            maxLines: 6,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Paste scanned QR payload JSON',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: () => pairingController.submitScannedPayload(
                  _manualPayloadController.text,
                ),
                child: const Text('Submit scanned payload'),
              ),
              TextButton(
                onPressed: pairingController.cancelReview,
                child: const Text('Cancel scan'),
              ),
            ],
          ),
          if (pairingState.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              pairingState.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildReviewView(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    final payload = pairingState.pendingPayload;
    if (payload == null) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Confirm bridge trust',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          const Text('Review bridge identity details before saving trust.'),
          const SizedBox(height: 20),
          _IdentityRow(label: 'Bridge name', value: payload.bridgeName),
          _IdentityRow(label: 'Bridge id', value: payload.bridgeId),
          _IdentityRow(label: 'Bridge URL', value: payload.bridgeApiBaseUrl),
          _IdentityRow(label: 'Session id', value: payload.sessionId),
          _IdentityRow(
            label: 'Expires at (UTC)',
            value: payload.expiresAtUtc.toIso8601String(),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: pairingState.isPersistingTrust
                    ? null
                    : () {
                        pairingController.confirmTrust();
                      },
                child: const Text('Confirm trust'),
              ),
              TextButton(
                onPressed: pairingController.cancelReview,
                child: const Text('Cancel'),
              ),
            ],
          ),
          if (pairingState.errorMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              pairingState.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPairedView(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    final bridge = pairingState.trustedBridge;
    if (bridge == null) {
      return _buildUnpairedView(
        pairingController,
        errorMessage: pairingState.errorMessage,
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Paired with ${bridge.bridgeName}',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 12),
          _IdentityRow(label: 'Bridge id', value: bridge.bridgeId),
          _IdentityRow(label: 'Bridge URL', value: bridge.bridgeApiBaseUrl),
          _IdentityRow(label: 'Trusted session', value: bridge.sessionId),
          if (pairingState.bridgeConnectionState ==
              BridgeConnectionState.disconnected) ...[
            const SizedBox(height: 12),
            _ConnectionWarningBanner(
              message:
                  pairingState.errorMessage ??
                  'Bridge is currently unreachable. Cached data stays readable, but mutating actions are blocked until reconnect.',
              onRetry: pairingController.retryTrustedBridgeConnection,
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      ThreadListPage(bridgeApiBaseUrl: bridge.bridgeApiBaseUrl),
                ),
              );
            },
            icon: const Icon(Icons.forum_outlined),
            label: const Text('Open threads'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('open-device-settings'),
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      SettingsPage(bridgeApiBaseUrl: bridge.bridgeApiBaseUrl),
                ),
              );
            },
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Device settings'),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => _openScanner(pairingController),
            child: const Text('Scan another QR'),
          ),
          if (pairingState.errorMessage != null &&
              pairingState.bridgeConnectionState !=
                  BridgeConnectionState.disconnected) ...[
            const SizedBox(height: 12),
            Text(
              pairingState.errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnectionWarningBanner extends StatelessWidget {
  const _ConnectionWarningBanner({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: colorScheme.errorContainer.withValues(alpha: 0.28),
        border: Border.all(color: colorScheme.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Bridge disconnected',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(message),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: onRetry,
            child: const Text('Retry connection'),
          ),
        ],
      ),
    );
  }
}

class _ScannerIssueBanner extends StatelessWidget {
  const _ScannerIssueBanner({
    required this.issue,
    required this.onRetryCamera,
    required this.onUseManualFallback,
  });

  final PairingScannerIssue issue;
  final VoidCallback onRetryCamera;
  final VoidCallback onUseManualFallback;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    final (title, message) = switch (issue.type) {
      PairingScannerIssueType.permissionDenied => (
        'Camera permission is blocked',
        'Enable camera access in system Settings, then retry scanning. You can still pair by pasting the QR payload below.',
      ),
      PairingScannerIssueType.scannerFailure => (
        'Scanner is unavailable right now',
        'We could not read from the camera. Retry scanning or continue with the manual payload fallback.',
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: colorScheme.errorContainer.withValues(alpha: 0.3),
        border: Border.all(color: colorScheme.error),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: colorScheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(message),
          if (issue.details != null) ...[
            const SizedBox(height: 6),
            Text(issue.details!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: onRetryCamera,
                child: const Text('Retry camera'),
              ),
              TextButton(
                onPressed: onUseManualFallback,
                child: const Text('Use manual payload'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _IdentityRow extends StatelessWidget {
  const _IdentityRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
