import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
import 'package:codex_mobile_companion/foundation/theme/app_theme.dart';
import 'package:codex_mobile_companion/foundation/theme/liquid_styles.dart';
import 'package:codex_mobile_companion/shared/widgets/animated_bridge_background.dart';
import 'package:codex_mobile_companion/shared/widgets/magnetic_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
    this.enableAnimatedBackground,
    this.initialScannerIssue,
    this.autoOpenThreadsOnPairing = false,
  });

  final bool enableCameraPreview;
  final bool? enableAnimatedBackground;
  final PairingScannerIssue? initialScannerIssue;
  final bool autoOpenThreadsOnPairing;

  @override
  ConsumerState<PairingFlowPage> createState() => _PairingFlowPageState();
}

class _PairingFlowPageState extends ConsumerState<PairingFlowPage>
    with TickerProviderStateMixin {
  static const Duration _cameraMountDelay = Duration(milliseconds: 100);
  static const double _scanCardSize = 250.0;
  static const double _scanCardRadius = 32.0;
  late final TextEditingController _manualPayloadController;
  late final FocusNode _manualPayloadFocusNode;
  late final MobileScannerController _cameraController;
  late final AnimationController _layoutTransitionController;
  late final AnimationController _flipRevealController;
  late final Animation<double> _flipRotation;
  late final Animation<double> _flipScale;

  final Set<String> _autoOpenedThreadSessionIds = <String>{};
  final GlobalKey _foregroundFrameKey = GlobalKey();
  final GlobalKey _centerSlotKey = GlobalKey();
  Timer? _cameraMountTimer;
  PairingScannerIssue? _scannerIssue;
  bool _isAutoOpeningThreadList = false;
  bool _isCompactLayout = false;
  bool _isLockedOn = false;
  bool _swappedDuringWipe = false;
  bool _cameraMounted = false;
  String? _scannedRawQr;

  @override
  void initState() {
    super.initState();
    _manualPayloadController = TextEditingController();
    _manualPayloadFocusNode = FocusNode();
    _cameraController = MobileScannerController();
    _scannerIssue = widget.initialScannerIssue;
    _layoutTransitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    );

    _flipRevealController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    // Smooth 3D flip during the first 35% of the timeline
    _flipRotation = Tween<double>(begin: 0.0, end: pi).animate(
      CurvedAnimation(
        parent: _flipRevealController,
        curve: const Interval(0.0, 0.35, curve: Curves.easeInCubic),
      ),
    );

    // Scale blast outwards during 30% -> 50%
    _flipScale = Tween<double>(begin: 1.0, end: 12.0).animate(
      CurvedAnimation(
        parent: _flipRevealController,
        curve: const Interval(0.30, 0.50, curve: Curves.easeInQuint),
      ),
    );

    // Swap application state once the wipe has expanded enough to hide the
    // foreground transition under the expanding card.
    _flipRevealController.addListener(() {
      if (_flipRevealController.value >= 0.50 && !_swappedDuringWipe) {
        _swappedDuringWipe = true;
        if (_scannedRawQr != null) {
          ref
              .read(pairingControllerProvider.notifier)
              .submitScannedPayload(_scannedRawQr!);
        }
      }
    });

    _scheduleCameraMount();
  }

  @override
  void dispose() {
    _manualPayloadController.dispose();
    _manualPayloadFocusNode.dispose();
    _cameraController.dispose();
    _cameraMountTimer?.cancel();
    _layoutTransitionController.dispose();
    _flipRevealController.dispose();
    super.dispose();
  }

  void _scheduleCameraMount() {
    _cameraMountTimer?.cancel();
    if (!widget.enableCameraPreview) return;

    _cameraMountTimer = Timer(_cameraMountDelay, () {
      if (!mounted || _cameraMounted) return;
      setState(() => _cameraMounted = true);
    });
  }

  void _syncLayoutTransition(bool isUnpaired) {
    final shouldUseCompactLayout = !isUnpaired;
    if (_isCompactLayout == shouldUseCompactLayout) return;

    _isCompactLayout = shouldUseCompactLayout;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _layoutTransitionController.animateTo(
        shouldUseCompactLayout ? 1.0 : 0.0,
        curve: Curves.easeOutCubic,
      );
    });
  }

  static const double _footerBaseHeight = 132.0;

  void _openScanner(PairingController pairingController) {
    setState(() {
      _scannerIssue = widget.initialScannerIssue;
      _isLockedOn = false;
      _scannedRawQr = null;
      _swappedDuringWipe = false;
      _cameraMounted = false;
    });
    pairingController.openScanner();
    _flipRevealController.reset();

    _scheduleCameraMount();
  }

  void _setScannerIssue(PairingScannerIssue issue) {
    if (_scannerIssue == issue || !mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _scannerIssue == issue) return;
      setState(() => _scannerIssue = issue);
    });
  }

  Future<void> _retryCamera() async {
    setState(() {
      _scannerIssue = null;
      _isLockedOn = false;
      _scannedRawQr = null;
      _swappedDuringWipe = false;
    });
    _flipRevealController.reset();
    try {
      await _cameraController.start();
    } on MobileScannerException catch (error) {
      if (!mounted) return;
      setState(
        () => _scannerIssue = PairingScannerIssue.fromScannerException(error),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _scannerIssue = const PairingScannerIssue.failure());
    }
  }

  void _maybeAutoOpenThreadList(PairingState pairingState) {
    if (!widget.autoOpenThreadsOnPairing ||
        pairingState.step != PairingStep.paired) {
      return;
    }

    final bridge = pairingState.trustedBridge;
    if (bridge == null || _isAutoOpeningThreadList) return;

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

  Offset? _resolveWipeCenter() {
    final foregroundBox =
        _foregroundFrameKey.currentContext?.findRenderObject() as RenderBox?;
    final centerSlotBox =
        _centerSlotKey.currentContext?.findRenderObject() as RenderBox?;
    if (foregroundBox == null || !foregroundBox.hasSize) return null;
    if (centerSlotBox == null || !centerSlotBox.hasSize) {
      return foregroundBox.size.center(Offset.zero);
    }

    final centerGlobal = centerSlotBox.localToGlobal(
      centerSlotBox.size.center(Offset.zero),
    );
    return foregroundBox.globalToLocal(centerGlobal);
  }

  Rect? _resolveWipeCardRect() {
    final center = _resolveWipeCenter();
    if (center == null) return null;

    final scale = max(1.0, _flipScale.value);
    final side = _scanCardSize * scale;
    return Rect.fromCenter(center: center, width: side, height: side);
  }

  @override
  Widget build(BuildContext context) {
    final pairingState = ref.watch(pairingControllerProvider);
    final pairingController = ref.read(pairingControllerProvider.notifier);
    _maybeAutoOpenThreadList(pairingState);

    final bool isUnpaired = pairingState.step == PairingStep.unpaired;
    _syncLayoutTransition(isUnpaired);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          (widget.enableAnimatedBackground ?? widget.enableCameraPreview)
              ? const AnimatedBridgeBackground()
              : const ColoredBox(color: AppTheme.background),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final titleSlotHeight = min(
                    220.0,
                    max(188.0, constraints.maxHeight * 0.24),
                  );
                  // Match the original unpaired composition more closely while
                  // still animating via transform instead of relayout.
                  final titleTravel = max(0.0, constraints.maxHeight * 0.55);

                  return SizedBox(
                    key: _foregroundFrameKey,
                    width: double.infinity,
                    height: double.infinity,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: _buildForegroundLayout(
                            pairingState: pairingState,
                            pairingController: pairingController,
                            titleSlotHeight: titleSlotHeight,
                            titleTravel: titleTravel,
                            centerSlotKey: _centerSlotKey,
                          ),
                        ),
                        Positioned.fill(
                          child: _buildForegroundWipeOverlay(
                            pairingState: pairingState,
                            pairingController: pairingController,
                            titleSlotHeight: titleSlotHeight,
                            titleTravel: titleTravel,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildForegroundLayout({
    required PairingState pairingState,
    required PairingController pairingController,
    required double titleSlotHeight,
    required double titleTravel,
    Key? centerSlotKey,
    PairingStep? displayStepOverride,
  }) {
    return AnimatedBuilder(
      animation: _layoutTransitionController,
      builder: (context, child) {
        final displayStep = displayStepOverride ?? pairingState.step;
        final layoutProgress = Curves.easeOutCubic.transform(
          _layoutTransitionController.value,
        );
        final centerProgress = Interval(
          0.18,
          1.0,
          curve: Curves.easeOutCubic,
        ).transform(_layoutTransitionController.value);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: titleSlotHeight,
              child: Transform.translate(
                offset: Offset(0, titleTravel * (1.0 - layoutProgress)),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: double.infinity,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 360),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: currentChild == null
                              ? previousChildren
                              : <Widget>[...previousChildren, currentChild],
                        );
                      },
                      transitionBuilder: (child, animation) {
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(
                            position: Tween<Offset>(
                              begin: const Offset(0, 0.08),
                              end: Offset.zero,
                            ).animate(animation),
                            child: child,
                          ),
                        );
                      },
                      child: _buildTitleArea(
                        pairingState,
                        displayStepOverride: displayStep,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Align(
                key: centerSlotKey,
                alignment: Alignment.center,
                child: IgnorePointer(
                  ignoring: displayStep == PairingStep.unpaired,
                  child: Opacity(
                    opacity: displayStep == PairingStep.unpaired
                        ? 0.0
                        : centerProgress,
                    child: Transform.translate(
                      offset: Offset(0, 32.0 * (1.0 - centerProgress)),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 420),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        layoutBuilder: (currentChild, previousChildren) {
                          return Stack(
                            alignment: Alignment.center,
                            clipBehavior: Clip.none,
                            children: currentChild == null
                                ? previousChildren
                                : <Widget>[...previousChildren, currentChild],
                          );
                        },
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: Tween<double>(
                                begin: 0.96,
                                end: 1.0,
                              ).animate(animation),
                              child: child,
                            ),
                          );
                        },
                        child: _buildCenterCard(
                          pairingState,
                          pairingController,
                          displayStepOverride: displayStep,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _footerBaseHeight),
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 320),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    layoutBuilder: (currentChild, previousChildren) {
                      return Stack(
                        alignment: Alignment.bottomCenter,
                        children: currentChild == null
                            ? previousChildren
                            : <Widget>[...previousChildren, currentChild],
                      );
                    },
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: Tween<Offset>(
                            begin: const Offset(0, 0.04),
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        ),
                      );
                    },
                    child: _buildFooterArea(
                      pairingState,
                      pairingController,
                      displayStepOverride: displayStep,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildForegroundWipeOverlay({
    required PairingState pairingState,
    required PairingController pairingController,
    required double titleSlotHeight,
    required double titleTravel,
  }) {
    return AnimatedBuilder(
      animation: _flipRevealController,
      builder: (context, child) {
        if (_flipRevealController.isDismissed) {
          return const SizedBox.shrink();
        }

        final wipeRect = _resolveWipeCardRect();
        if (wipeRect == null) {
          return const SizedBox.shrink();
        }

        final wipeRadius = _scanCardRadius * max(1.0, _flipScale.value);
        return IgnorePointer(
          child: ClipPath(
            clipper: _OutsideCardClipper(
              cutoutRect: wipeRect,
              cutoutRadius: wipeRadius,
            ),
            child: _buildForegroundLayout(
              pairingState: pairingState,
              pairingController: pairingController,
              titleSlotHeight: titleSlotHeight,
              titleTravel: titleTravel,
              displayStepOverride: PairingStep.scanning,
            ),
          ),
        );
      },
    );
  }

  Widget _buildTitleArea(
    PairingState pairingState, {
    PairingStep? displayStepOverride,
  }) {
    final displayStep = displayStepOverride ?? pairingState.step;
    if (displayStep == PairingStep.unpaired) {
      return Column(
        key: const ValueKey('title-unpaired'),
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
          const Text(
            'Secure operator console for remote monitoring and control.',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
          ),
        ],
      );
    } else if (displayStep == PairingStep.scanning) {
      return Column(
        key: const ValueKey('title-scanning'),
        children: [
          Text(
            'Scan QR Code',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Display code on desktop bridge app',
            style: TextStyle(color: AppTheme.textMuted),
          ),
        ],
      );
    } else if (displayStep == PairingStep.review) {
      return Column(
        key: const ValueKey('title-review'),
        children: [
          Text(
            'Verify Identity',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'Confirm desktop fingerprint before connecting.',
            style: TextStyle(color: AppTheme.textMuted),
          ),
        ],
      );
    } else if (displayStep == PairingStep.paired) {
      return Column(
        key: const ValueKey('title-paired'),
        children: [
          Text(
            'Paired with ${pairingState.trustedBridge?.bridgeName ?? ''}',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          const Text(
            'A trusted connection is established.',
            style: TextStyle(color: AppTheme.textMuted),
          ),
        ],
      );
    }
    return const SizedBox.shrink(key: ValueKey('title-none'));
  }

  Widget _buildCenterCard(
    PairingState pairingState,
    PairingController pairingController, {
    PairingStep? displayStepOverride,
  }) {
    final displayStep = displayStepOverride ?? pairingState.step;
    if (displayStep == PairingStep.scanning) {
      return AnimatedBuilder(
        key: const ValueKey('card-scanning'),
        animation: _flipRevealController,
        builder: (context, child) {
          final isFlipped = _flipRotation.value > (pi / 2);

          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.002) // Perspective flip
              ..scaleByDouble(_flipScale.value, _flipScale.value, 1.0, 1.0)
              ..rotateY(_flipRotation.value),
            child: isFlipped
                ? _buildRevealMaskCard()
                : Container(
                    width: _scanCardSize,
                    height: _scanCardSize,
                    decoration: LiquidStyles.liquidGlass,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(_scanCardRadius),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 700),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeOutCubic,
                        child: _isLockedOn && _scannedRawQr != null
                            ? Container(
                                key: const ValueKey('qr-reconstructed'),
                                color: AppTheme.background,
                                padding: const EdgeInsets.all(16),
                                child: QrImageView(
                                  data: _scannedRawQr!,
                                  version: QrVersions.auto,
                                  padding: EdgeInsets.zero,
                                  eyeStyle: const QrEyeStyle(
                                    eyeShape: QrEyeShape.square,
                                    color: Colors.white,
                                  ),
                                  dataModuleStyle: const QrDataModuleStyle(
                                    dataModuleShape: QrDataModuleShape.square,
                                    color: Colors.white,
                                  ),
                                ),
                              )
                            : Stack(
                                key: const ValueKey('camera'),
                                fit: StackFit.expand,
                                children: [
                                  Container(color: const Color(0xFF09090B)),
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 400),
                                    child:
                                        (widget.enableCameraPreview &&
                                            _cameraMounted)
                                        ? MobileScanner(
                                            key: const Key('camera-scanner'),
                                            controller: _cameraController,
                                            onDetect: (capture) {
                                              for (final barcode
                                                  in capture.barcodes) {
                                                if (barcode.rawValue
                                                        ?.trim()
                                                        .isNotEmpty ==
                                                    true) {
                                                  if (_isLockedOn) return;

                                                  setState(() {
                                                    _scannerIssue = null;
                                                    _scannedRawQr =
                                                        barcode.rawValue!;
                                                    _isLockedOn = true;
                                                  });

                                                  // Hang for visual lock-on confirmation, then explode the timeline unified single-shot wipe
                                                  Future.delayed(
                                                    const Duration(
                                                      milliseconds: 800,
                                                    ),
                                                    () {
                                                      if (mounted) {
                                                        _flipRevealController
                                                            .forward(from: 0.0);
                                                      }
                                                    },
                                                  );

                                                  break;
                                                }
                                              }
                                            },
                                            errorBuilder: (context, error) {
                                              _setScannerIssue(
                                                PairingScannerIssue.fromScannerException(
                                                  error,
                                                ),
                                              );
                                              return const Center(
                                                child: Icon(
                                                  Icons.videocam_off,
                                                  color: AppTheme.textMuted,
                                                ),
                                              );
                                            },
                                          )
                                        : const SizedBox.shrink(
                                            key: Key('camera-loading'),
                                          ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
          );
        },
      );
    }

    if (displayStep == PairingStep.review) {
      final payload = pairingState.pendingPayload;
      return Container(
        key: const ValueKey('card-review'),
        padding: const EdgeInsets.all(24),
        decoration: LiquidStyles.liquidGlass,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (payload != null) ...[
              _IdentityRow(label: 'Bridge', value: payload.bridgeName),
              const Divider(color: Colors.white10, height: 24),
              _IdentityRow(label: 'Host URL', value: payload.bridgeApiBaseUrl),
              const Divider(color: Colors.white10, height: 24),
              _IdentityRow(
                label: 'Identity',
                value: payload.bridgeId,
                valueColor: AppTheme.emerald,
              ),
            ],
          ],
        ),
      );
    }

    return const SizedBox.shrink(key: ValueKey('card-none'));
  }

  Widget _buildRevealMaskCard() {
    return SizedBox(
      width: _scanCardSize,
      height: _scanCardSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_scanCardRadius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white.withValues(alpha: 0.07),
                  Colors.white.withValues(alpha: 0.015),
                ],
              ),
              borderRadius: BorderRadius.circular(_scanCardRadius),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }

  Widget _buildFooterArea(
    PairingState pairingState,
    PairingController pairingController, {
    PairingStep? displayStepOverride,
  }) {
    final displayStep = displayStepOverride ?? pairingState.step;
    final anchoredAction = _buildAnchoredFooterAction(
      pairingState,
      pairingController,
      displayStepOverride: displayStep,
    );

    return Column(
      key: ValueKey('footer-$displayStep'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pairingState.rePairRequiredForSecurity) ...[
          _SecurityRePairRequiredBanner(message: pairingState.errorMessage),
          const SizedBox(height: 16),
        ] else if (pairingState.errorMessage != null &&
            displayStep != PairingStep.paired) ...[
          Text(
            pairingState.errorMessage!,
            style: const TextStyle(color: AppTheme.rose),
          ),
          const SizedBox(height: 16),
        ],

        if (displayStep == PairingStep.scanning && _scannerIssue != null)
          _ScannerIssueBanner(
            issue: _scannerIssue!,
            onRetryCamera: _retryCamera,
          ),

        if (displayStep == PairingStep.paired &&
            pairingState.bridgeConnectionState ==
                BridgeConnectionState.disconnected) ...[
          _ConnectionWarningBanner(
            message:
                pairingState.errorMessage ??
                'Bridge unreachable. Offline cache readable.',
            onRetry: pairingController.retryTrustedBridgeConnection,
          ),
          const SizedBox(height: 16),
        ],

        if (anchoredAction != null) ...[
          MagneticButton(
            variant: anchoredAction.variant,
            onClick: anchoredAction.onClick,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: anchoredAction.child,
            ),
          ),
        ] else if (displayStep == PairingStep.review) ...[
          MagneticButton(
            variant: MagneticButtonVariant.primary,
            onClick: pairingState.isPersistingTrust
                ? () {}
                : () => pairingController.confirmTrust(),
            child: const Text('Trust & Connect'),
          ),
          const SizedBox(height: 12),
          MagneticButton(
            variant: MagneticButtonVariant.secondary,
            onClick: pairingController.cancelReview,
            child: const Text('Reject'),
          ),
        ] else if (displayStep == PairingStep.paired) ...[
          MagneticButton(
            variant: MagneticButtonVariant.primary,
            onClick: () {
              final bridge = pairingState.trustedBridge;
              if (bridge == null) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      ThreadListPage(bridgeApiBaseUrl: bridge.bridgeApiBaseUrl),
                ),
              );
            },
            child: const Text('Open sessions'),
          ),
          const SizedBox(height: 12),
          MagneticButton(
            variant: MagneticButtonVariant.secondary,
            onClick: () {
              final bridge = pairingState.trustedBridge;
              if (bridge == null) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (context) =>
                      SettingsPage(bridgeApiBaseUrl: bridge.bridgeApiBaseUrl),
                ),
              );
            },
            child: const Text(
              'Device Settings',
              key: Key('open-device-settings'),
            ),
          ),
        ],
      ],
    );
  }

  _AnchoredFooterAction? _buildAnchoredFooterAction(
    PairingState pairingState,
    PairingController pairingController, {
    PairingStep? displayStepOverride,
  }) {
    final displayStep = displayStepOverride ?? pairingState.step;
    if (displayStep == PairingStep.unpaired) {
      return _AnchoredFooterAction(
        variant: MagneticButtonVariant.primary,
        onClick: () => _openScanner(pairingController),
        child: Row(
          key: const ValueKey('footer-action-init'),
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Initialize Pairing'),
            const SizedBox(width: 8),
            PhosphorIcon(
              PhosphorIcons.arrowRight(PhosphorIconsStyle.bold),
              size: 16,
            ),
          ],
        ),
      );
    }

    if (displayStep == PairingStep.scanning) {
      return _AnchoredFooterAction(
        variant: MagneticButtonVariant.secondary,
        onClick: pairingController.cancelReview,
        child: const Text(
          'Cancel',
          key: ValueKey('footer-action-cancel'),
          textAlign: TextAlign.center,
        ),
      );
    }

    return null;
  }
}

class _AnchoredFooterAction {
  const _AnchoredFooterAction({
    required this.variant,
    required this.onClick,
    required this.child,
  });

  final MagneticButtonVariant variant;
  final VoidCallback onClick;
  final Widget child;
}

class _OutsideCardClipper extends CustomClipper<Path> {
  const _OutsideCardClipper({
    required this.cutoutRect,
    required this.cutoutRadius,
  });

  final Rect cutoutRect;
  final double cutoutRadius;

  @override
  Path getClip(Size size) {
    final fullScreen = Path()..addRect(Offset.zero & size);
    final cutout = Path()
      ..addRRect(
        RRect.fromRectAndRadius(cutoutRect, Radius.circular(cutoutRadius)),
      );

    return Path.combine(PathOperation.difference, fullScreen, cutout);
  }

  @override
  bool shouldReclip(covariant _OutsideCardClipper oldClipper) {
    return oldClipper.cutoutRect != cutoutRect ||
        oldClipper.cutoutRadius != cutoutRadius;
  }
}

class _IdentityRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _IdentityRow({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSubtle,
            fontSize: 13,
            fontFamily: 'JetBrains Mono',
          ),
        ),
        Flexible(
          child: Text(
            value,
            style: TextStyle(
              color: valueColor ?? AppTheme.textMain,
              fontSize: 13,
              fontFamily: 'JetBrains Mono',
            ),
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

  const _ConnectionWarningBanner({
    required this.message,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.amber.withValues(alpha: 0.1),
        border: Border.all(color: AppTheme.amber.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(
                PhosphorIcons.warningCircle(PhosphorIconsStyle.duotone),
                color: AppTheme.amber,
              ),
              const SizedBox(width: 8),
              const Text(
                'Disconnected',
                style: TextStyle(
                  color: AppTheme.amber,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: const TextStyle(color: AppTheme.amber, fontSize: 13),
          ),
          const SizedBox(height: 16),
          MagneticButton(
            variant: MagneticButtonVariant.secondary,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            onClick: onRetry,
            child: const Text(
              'Retry connection',
              style: TextStyle(color: AppTheme.amber),
            ),
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
        color: AppTheme.rose.withValues(alpha: 0.1),
        border: Border.all(color: AppTheme.rose.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Re-pair required',
            style: TextStyle(color: AppTheme.rose, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            message ?? 'Stored trust no longer matches.',
            style: const TextStyle(color: AppTheme.rose, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _ScannerIssueBanner extends StatelessWidget {
  final PairingScannerIssue issue;
  final VoidCallback onRetryCamera;

  const _ScannerIssueBanner({required this.issue, required this.onRetryCamera});

  String get _headline {
    switch (issue.type) {
      case PairingScannerIssueType.permissionDenied:
        return 'Camera permission blocked';
      case PairingScannerIssueType.scannerFailure:
        return 'Scanner unavailable';
    }
  }

  String get _body {
    switch (issue.type) {
      case PairingScannerIssueType.permissionDenied:
        return 'Enable camera access in system settings, then retry scanning.';
      case PairingScannerIssueType.scannerFailure:
        return 'Camera feed could not be read. Retry scanning.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      margin: const EdgeInsets.only(bottom: 24),
      decoration: BoxDecoration(
        color: AppTheme.rose.withValues(alpha: 0.1),
        border: Border.all(color: AppTheme.rose.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _headline,
            style: TextStyle(color: AppTheme.rose, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(_body, style: const TextStyle(color: AppTheme.rose)),
          if (issue.details case final details?) ...[
            const SizedBox(height: 8),
            Text(details, style: const TextStyle(color: AppTheme.rose)),
          ],
          const SizedBox(height: 8),
          MagneticButton(
            variant: MagneticButtonVariant.danger,
            onClick: onRetryCamera,
            child: const Text('Retry camera'),
          ),
        ],
      ),
    );
  }
}
