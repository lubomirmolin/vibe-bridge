import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/features/home/presentation/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/magnetic_button.dart';
import 'package:codex_mobile_companion/shared/widgets/animated_bridge_background.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

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
      details: details == null || details.trim().isEmpty ? null : details.trim(),
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
    if (_scannerIssue == issue || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scannerIssue == issue) return;
      setState(() => _scannerIssue = issue);
    });
  }

  Future<void> _retryCamera() async {
    setState(() => _scannerIssue = null);
    try {
      await _cameraController.start();
    } on MobileScannerException catch (error) {
      if (!mounted) return;
      setState(() => _scannerIssue = PairingScannerIssue.fromScannerException(error));
    } catch (_) {
      if (!mounted) return;
      setState(() => _scannerIssue = const PairingScannerIssue.failure());
    }
  }

  void _focusManualFallback() {
    _manualPayloadFocusNode.requestFocus();
  }

  void _maybeAutoOpenThreadList(PairingState pairingState) {
    if (!widget.autoOpenThreadsOnPairing || pairingState.step != PairingStep.paired) return;

    final bridge = pairingState.trustedBridge;
    if (bridge == null || _isAutoOpeningThreadList) return;

    final sessionId = bridge.sessionId.trim();
    if (sessionId.isEmpty || _autoOpenedThreadSessionIds.contains(sessionId)) return;

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
            builder: (context) => HomeScreen(
              bridgeApiBaseUrl: bridge.bridgeApiBaseUrl,
              bridgeName: bridge.bridgeName,
              bridgeId: bridge.bridgeId,
            ),
          ),
        );
      } finally {
        _isAutoOpeningThreadList = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final pairingState = ref.watch(pairingControllerProvider);
    final pairingController = ref.read(pairingControllerProvider.notifier);
    _maybeAutoOpenThreadList(pairingState);

    Widget body = switch (pairingState.step) {
      PairingStep.unpaired => _buildUnpairedView(
        pairingController,
        errorMessage: pairingState.errorMessage,
        rePairRequiredForSecurity: pairingState.rePairRequiredForSecurity,
      ),
      PairingStep.scanning => _buildScannerView(pairingState, pairingController),
      PairingStep.review => _buildReviewView(pairingState, pairingController),
      PairingStep.paired => _buildPairedView(pairingState, pairingController),
    };

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AnimatedBridgeBackground(),
          
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 400),
                      switchInCurve: Curves.easeOutBack,
                      switchOutCurve: Curves.easeIn,
                      child: body,
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

  Widget _buildUnpairedView(
    PairingController pairingController, {
    String? errorMessage,
    required bool rePairRequiredForSecurity,
  }) {
    return Column(
      key: const ValueKey('unpaired'),
      mainAxisAlignment: MainAxisAlignment.end,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Codex\nBridge',
          style: Theme.of(context).textTheme.displayLarge?.copyWith(
            fontWeight: FontWeight.w500,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Secure operator console for remote monitoring and control.',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
        ),
        const SizedBox(height: 48),

        if (rePairRequiredForSecurity) ...[
          _SecurityRePairRequiredBanner(message: errorMessage),
          const SizedBox(height: 16),
        ] else if (errorMessage != null) ...[
          Text(errorMessage, style: const TextStyle(color: AppTheme.rose)),
          const SizedBox(height: 16),
        ],

        SizedBox(
          width: double.infinity,
          child: MagneticButton(
            variant: MagneticButtonVariant.primary,
            onClick: () => _openScanner(pairingController),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Initialize Pairing'),
                const SizedBox(width: 8),
                PhosphorIcon(PhosphorIcons.arrowRight(PhosphorIconsStyle.bold), size: 16),
              ],
            ),
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildScannerView(PairingState pairingState, PairingController pairingController) {
    return Column(
      key: const ValueKey('scanning'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 40),
        Text('Scan QR Code', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text('Display code on desktop bridge app', style: TextStyle(color: AppTheme.textMuted)),
        const SizedBox(height: 40),

        if (_scannerIssue != null)
          _ScannerIssueBanner(
            issue: _scannerIssue!,
            onRetryCamera: _retryCamera,
            onUseManualFallback: _focusManualFallback,
          )
        else
          Container(
            width: 250,
            height: 250,
            decoration: LiquidStyles.liquidGlass,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(32),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(color: const Color(0xFF09090B)), // Solid background while loading
                  if (widget.enableCameraPreview)
                    MobileScanner(
                      key: const Key('camera-scanner'),
                      controller: _cameraController,
                      onDetect: (capture) {
                        for (final barcode in capture.barcodes) {
                          if (barcode.rawValue?.trim().isNotEmpty == true) {
                            setState(() => _scannerIssue = null);
                            pairingController.submitScannedPayload(barcode.rawValue!);
                            break;
                          }
                        }
                      },
                      errorBuilder: (context, error) {
                        _setScannerIssue(PairingScannerIssue.fromScannerException(error));
                        return const Center(child: Icon(Icons.videocam_off, color: AppTheme.textMuted));
                      },
                    ),
                  
                  // Scanning animation overlay
                  Center(
                    child: PhosphorIcon(PhosphorIcons.qrCode(PhosphorIconsStyle.thin), size: 48, color: AppTheme.emerald),
                  ),
                ],
              ),
            ),
          ),

        const SizedBox(height: 40),
        
        MagneticButton(
          variant: MagneticButtonVariant.secondary,
          onClick: pairingController.cancelReview,
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildReviewView(PairingState pairingState, PairingController pairingController) {
    final payload = pairingState.pendingPayload;
    if (payload == null) return const SizedBox.shrink();

    return Column(
      key: const ValueKey('review'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Verify Identity', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text('Confirm desktop fingerprint before connecting.', style: TextStyle(color: AppTheme.textMuted)),
        const SizedBox(height: 32),

        Container(
          padding: const EdgeInsets.all(24),
          decoration: LiquidStyles.liquidGlass,
          child: Column(
            children: [
              _IdentityRow(label: 'Bridge', value: payload.bridgeName),
              const Divider(color: Colors.white10, height: 24),
              _IdentityRow(label: 'Host URL', value: payload.bridgeApiBaseUrl),
              const Divider(color: Colors.white10, height: 24),
              _IdentityRow(label: 'Identity', value: payload.bridgeId, valueColor: AppTheme.emerald),
            ],
          ),
        ),

        const SizedBox(height: 40),

        if (pairingState.errorMessage != null) ...[
          Text(pairingState.errorMessage!, style: const TextStyle(color: AppTheme.rose)),
          const SizedBox(height: 16),
        ],

        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            MagneticButton(
              variant: MagneticButtonVariant.primary,
              onClick: pairingState.isPersistingTrust ? () {} : () => pairingController.confirmTrust(),
              child: const Text('Trust & Connect'),
            ),
            const SizedBox(height: 12),
            MagneticButton(
              variant: MagneticButtonVariant.secondary,
              onClick: pairingController.cancelReview,
              child: const Text('Reject'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPairedView(PairingState pairingState, PairingController pairingController) {
    final bridge = pairingState.trustedBridge;
    if (bridge == null) {
      return _buildUnpairedView(
        pairingController,
        errorMessage: pairingState.errorMessage,
        rePairRequiredForSecurity: pairingState.rePairRequiredForSecurity,
      );
    }

    return Column(
      key: const ValueKey('paired'),
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Paired with ${bridge.bridgeName}', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text('A trusted connection is established.', style: TextStyle(color: AppTheme.textMuted)),
        const SizedBox(height: 32),

        if (pairingState.bridgeConnectionState == BridgeConnectionState.disconnected) ...[
          _ConnectionWarningBanner(
            message: pairingState.errorMessage ?? 'Bridge unreachable. Offline cache readable.',
            onRetry: pairingController.retryTrustedBridgeConnection,
          ),
          const SizedBox(height: 32),
        ],

        Column(
           crossAxisAlignment: CrossAxisAlignment.stretch,
           children: [
             MagneticButton(
               variant: MagneticButtonVariant.primary,
               onClick: () => Navigator.of(context).push(
                 MaterialPageRoute<void>(
                   builder: (context) => HomeScreen(
                     bridgeApiBaseUrl: bridge.bridgeApiBaseUrl,
                     bridgeName: bridge.bridgeName,
                     bridgeId: bridge.bridgeId,
                   ),
                 ),
               ),
               child: const Text('Open sessions'),
             ),
             const SizedBox(height: 12),
             MagneticButton(
               variant: MagneticButtonVariant.secondary,
               onClick: () => Navigator.of(context).push(
                 MaterialPageRoute<void>(
                   builder: (context) => SettingsPage(bridgeApiBaseUrl: bridge.bridgeApiBaseUrl),
                 ),
               ),
               child: const Text('Device Settings'),
             ),
           ],
        ),
      ],
    );
  }
}

class _IdentityRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _IdentityRow({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: const TextStyle(color: AppTheme.textSubtle, fontSize: 13, fontFamily: 'JetBrains Mono')),
        Flexible(
          child: Text(
            value,
            style: TextStyle(color: valueColor ?? AppTheme.textMain, fontSize: 13, fontFamily: 'JetBrains Mono'),
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

class _ConnectionWarningBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ConnectionWarningBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.amber.withOpacity(0.1),
        border: Border.all(color: AppTheme.amber.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(PhosphorIcons.warningCircle(PhosphorIconsStyle.duotone), color: AppTheme.amber),
              const SizedBox(width: 8),
              const Text('Disconnected', style: TextStyle(color: AppTheme.amber, fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 8),
          Text(message, style: const TextStyle(color: AppTheme.amber, fontSize: 13)),
          const SizedBox(height: 16),
          MagneticButton(
            variant: MagneticButtonVariant.secondary,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onClick: onRetry,
            child: const Text('Retry connection', style: TextStyle(color: AppTheme.amber)),
          ),
        ],
      ),
    );
  }
}

class _SecurityRePairRequiredBanner extends StatelessWidget {
  final String? message;
  const _SecurityRePairRequiredBanner({this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.rose.withOpacity(0.1),
        border: Border.all(color: AppTheme.rose.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Re-pair required', style: TextStyle(color: AppTheme.rose, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(message ?? 'Stored trust no longer matches.', style: const TextStyle(color: AppTheme.rose, fontSize: 13)),
        ],
      ),
    );
  }
}

class _ScannerIssueBanner extends StatelessWidget {
  final PairingScannerIssue issue;
  final VoidCallback onRetryCamera;
  final VoidCallback onUseManualFallback;

  const _ScannerIssueBanner({required this.issue, required this.onRetryCamera, required this.onUseManualFallback});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: AppTheme.rose.withOpacity(0.1),
        border: Border.all(color: AppTheme.rose.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
         crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
           Text('Scanner Issue', style: const TextStyle(color: AppTheme.rose, fontWeight: FontWeight.bold)),
           const SizedBox(height: 8),
           MagneticButton(
             variant: MagneticButtonVariant.danger,
             onClick: onRetryCamera,
             child: const Text('Retry Camera'),
           )
        ]
      ),
    );
  }
}
