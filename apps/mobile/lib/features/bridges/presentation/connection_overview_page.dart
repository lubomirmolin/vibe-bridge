import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:vibe_bridge/features/bridges/application/pairing_controller.dart';
import 'package:vibe_bridge/features/bridges/domain/pairing_qr_payload.dart';
import 'package:vibe_bridge/features/bridges/presentation/pairing_constants.dart';
import 'package:vibe_bridge/features/settings/presentation/settings_page.dart';
import 'package:vibe_bridge/features/threads/presentation/thread_list_page.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Main connection overview page that handles device pairing and management.
///
/// This page orchestrates the entire connection flow:
/// - Initial pairing via QR code scanning
/// - Trust confirmation and review
/// - Connected device management (sessions, settings, switching)
class ConnectionOverviewPage extends ConsumerStatefulWidget {
  const ConnectionOverviewPage({
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
  ConsumerState<ConnectionOverviewPage> createState() =>
      _ConnectionOverviewPageState();
}

class _ConnectionOverviewPageState extends ConsumerState<ConnectionOverviewPage>
    with TickerProviderStateMixin {
  // Controllers
  late final TextEditingController _manualPayloadController;
  late final FocusNode _manualPayloadFocusNode;
  late final MobileScannerController _cameraController;
  late final AnimationController _layoutTransitionController;
  late final AnimationController _flipRevealController;
  late final AnimationController _swipeHintController;

  // Animations
  late final Animation<double> _flipRotation;
  late final Animation<double> _flipScale;
  late final Animation<double> _swipeHintLift;
  late final Animation<double> _swipeHintOpacity;

  // State tracking
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
  bool _isSwiping = false;
  double _swipeOffset = 0.0;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    _setupAnimations();
    _scheduleCameraMount();
  }

  void _initializeControllers() {
    _manualPayloadController = TextEditingController();
    _manualPayloadFocusNode = FocusNode();
    _cameraController = MobileScannerController();
    _scannerIssue = widget.initialScannerIssue;

    _layoutTransitionController = AnimationController(
      vsync: this,
      duration: PairingConstants.layoutTransition,
    );
    _flipRevealController = AnimationController(
      vsync: this,
      duration: PairingConstants.flipReveal,
    );
    _swipeHintController = AnimationController(
      vsync: this,
      duration: PairingConstants.swipeHint,
    );
  }

  void _setupAnimations() {
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

    _swipeHintLift = Tween<double>(begin: 2.0, end: -4.0).animate(
      CurvedAnimation(
        parent: _swipeHintController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _swipeHintOpacity = Tween<double>(begin: 0.5, end: 1.0).animate(
      CurvedAnimation(
        parent: _swipeHintController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _setupAnimationListeners();
  }

  void _setupAnimationListeners() {
    // Swap application state once the wipe has expanded enough to hide the
    // foreground transition under the expanding card.
    _flipRevealController.addListener(() {
      if (_flipRevealController.value >= PairingConstants.flipRevealSwapPoint &&
          !_swappedDuringWipe) {
        _swappedDuringWipe = true;
        if (_scannedRawQr != null) {
          ref
              .read(pairingControllerProvider.notifier)
              .submitScannedPayload(_scannedRawQr!);
        }
      }
    });

    _swipeHintController.repeat(reverse: true);
  }

  @override
  void dispose() {
    _manualPayloadController.dispose();
    _manualPayloadFocusNode.dispose();
    _cameraController.dispose();
    _cameraMountTimer?.cancel();
    _layoutTransitionController.dispose();
    _flipRevealController.dispose();
    _swipeHintController.dispose();
    super.dispose();
  }

  void _scheduleCameraMount() {
    _cameraMountTimer?.cancel();
    if (!widget.enableCameraPreview) return;

    _cameraMountTimer = Timer(PairingConstants.cameraMountDelay, () {
      if (!mounted || _cameraMounted) return;
      setState(() => _cameraMounted = true);
    });
  }

  void _syncLayoutTransition(bool shouldUseCompactLayout) {
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

  void _openScanner(PairingController pairingController) {
    _resetScannerState(
      scannerIssue: widget.initialScannerIssue,
      resetCameraMounted: true,
    );
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
    _resetScannerState(scannerIssue: null);
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

  void _resetScannerState({
    required PairingScannerIssue? scannerIssue,
    bool resetCameraMounted = false,
  }) {
    setState(() {
      _scannerIssue = scannerIssue;
      _isLockedOn = false;
      _scannedRawQr = null;
      _swappedDuringWipe = false;
      if (resetCameraMounted) {
        _cameraMounted = false;
      }
    });
  }

  String? _extractDetectedRawQr(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final rawValue = barcode.rawValue;
      if (rawValue?.trim().isNotEmpty ?? false) {
        return rawValue;
      }
    }

    return null;
  }

  void _lockOnDetectedQr(String rawQr) {
    setState(() {
      _scannerIssue = null;
      _scannedRawQr = rawQr;
      _isLockedOn = true;
    });

    // Hang for visual lock-on confirmation, then explode the timeline unified
    // single-shot wipe.
    Future.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      _flipRevealController.forward(from: 0.0);
    });
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

  // TODO: Extract these layout helper methods to a separate mixin or utility
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
    final side = PairingConstants.scanCardSize * scale;
    return Rect.fromCenter(center: center, width: side, height: side);
  }

  void _activateNextSavedBridge(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    final savedBridges = pairingState.savedBridges;
    if (savedBridges.length < 2) return;

    final activeBridgeId = pairingState.activeBridgeId;
    final activeIndex = savedBridges.indexWhere(
      (bridge) => bridge.bridgeId == activeBridgeId,
    );
    final nextIndex = activeIndex < 0
        ? 0
        : (activeIndex + 1) % savedBridges.length;
    final nextBridge = savedBridges[nextIndex];
    unawaited(pairingController.activateSavedBridge(nextBridge.bridgeId));
  }

  void _handleSwipeStart(DragStartDetails details) {
    setState(() => _isSwiping = true);
  }

  void _handleSwipeUpdate(DragUpdateDetails details) {
    setState(() {
      _swipeOffset += details.primaryDelta ?? 0;
      if (_swipeOffset > 0) {
        _swipeOffset *= 0.5;
      }
    });
  }

  void _handleSwipeCancel() {
    _resetSwipeState();
  }

  void _handleSwipeEnd(
    DragEndDetails details,
    PairingState pairingState,
    PairingController pairingController,
  ) {
    final velocity = details.primaryVelocity ?? 0;
    final shouldSwitch = _swipeOffset < -40 || velocity < -150;

    setState(() {
      _isSwiping = false;
      _swipeOffset = shouldSwitch ? -80 : 0.0;
    });

    if (shouldSwitch) {
      _finishBridgeSwipeTransition(pairingState, pairingController);
    }
  }

  void _finishBridgeSwipeTransition(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSwiping = true;
        _swipeOffset = 80.0;
      });

      _activateNextSavedBridge(pairingState, pairingController);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }

        _resetSwipeState();
      });
    });
  }

  void _resetSwipeState() {
    setState(() {
      _isSwiping = false;
      _swipeOffset = 0.0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final pairingState = ref.watch(pairingControllerProvider);
    final pairingController = ref.read(pairingControllerProvider.notifier);
    _maybeAutoOpenThreadList(pairingState);

    final bool shouldUseCompactLayout =
        pairingState.step == PairingStep.scanning ||
        pairingState.step == PairingStep.review;
    _syncLayoutTransition(shouldUseCompactLayout);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildBackground(),
          _buildMainContent(pairingState, pairingController),
        ],
      ),
    );
  }

  Widget _buildBackground() {
    return (widget.enableAnimatedBackground ?? widget.enableCameraPreview)
        ? const AnimatedBridgeBackground(sceneScale: 0.9)
        : const ColoredBox(color: AppTheme.background);
  }

  Widget _buildMainContent(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    if (pairingState.isRestoringSavedBridges) {
      return _buildRestoringSplash();
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final titleSlotHeight = min(
              220.0,
              max(188.0, constraints.maxHeight * 0.24),
            );
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
                  Positioned(
                    top: 0,
                    right: 0,
                    child: _buildTopRightAction(
                      pairingState,
                      pairingController,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildRestoringSplash() {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              key: const ValueKey('restoring-splash'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Codex\nBridge',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Restoring saved bridges...',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppTheme.textMain,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Checking trusted devices before opening the pairing flow.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 14),
                ),
                const SizedBox(height: 24),
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2.2),
                ),
              ],
            ),
          ),
        ),
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
          PairingConstants.centerAnimationStart,
          1.0,
          curve: Curves.easeOutCubic,
        ).transform(_layoutTransitionController.value);
        final hasMultipleSavedBridges =
            displayStep == PairingStep.paired &&
            pairingState.savedBridgeCount > 1;

        Widget content = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTitleSection(
              pairingState,
              titleSlotHeight,
              titleTravel,
              layoutProgress,
              displayStep,
            ),
            _buildCenterSection(
              pairingState,
              pairingController,
              centerSlotKey,
              centerProgress,
              displayStep,
            ),
            _buildFooterSection(pairingState, pairingController, displayStep),
          ],
        );

        if (hasMultipleSavedBridges) {
          content = _buildSwipeGestureWrapper(
            content,
            pairingState,
            pairingController,
          );
        }

        return Transform.translate(
          offset: Offset(0, _swipeOffset),
          child: content,
        );
      },
    );
  }

  Widget _buildTitleSection(
    PairingState pairingState,
    double titleSlotHeight,
    double titleTravel,
    double layoutProgress,
    PairingStep displayStep,
  ) {
    return SizedBox(
      height: titleSlotHeight,
      child: Transform.translate(
        offset: Offset(0, titleTravel * (1.0 - layoutProgress)),
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: PairingConstants.titleSwitcher,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                alignment: Alignment.topCenter,
                children: currentChild == null
                    ? previousChildren
                    : [...previousChildren, currentChild],
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
    );
  }

  Widget _buildCenterSection(
    PairingState pairingState,
    PairingController pairingController,
    Key? centerSlotKey,
    double centerProgress,
    PairingStep displayStep,
  ) {
    return Expanded(
      child: Align(
        key: centerSlotKey,
        alignment: Alignment.center,
        child: IgnorePointer(
          ignoring: displayStep == PairingStep.unpaired,
          child: Opacity(
            opacity: displayStep == PairingStep.unpaired ? 0.0 : centerProgress,
            child: Transform.translate(
              offset: Offset(0, 32.0 * (1.0 - centerProgress)),
              child: AnimatedSwitcher(
                duration: PairingConstants.centerSwitcher,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                layoutBuilder: (currentChild, previousChildren) {
                  return Stack(
                    alignment: Alignment.center,
                    clipBehavior: Clip.none,
                    children: currentChild == null
                        ? previousChildren
                        : [...previousChildren, currentChild],
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
    );
  }

  Widget _buildFooterSection(
    PairingState pairingState,
    PairingController pairingController,
    PairingStep displayStep,
  ) {
    return SizedBox(
      width: double.infinity,
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          minHeight: PairingConstants.footerBaseHeight,
        ),
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
                    : [...previousChildren, currentChild],
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
    );
  }

  Widget _buildSwipeGestureWrapper(
    Widget content,
    PairingState pairingState,
    PairingController pairingController,
  ) {
    return GestureDetector(
      key: const Key('global-swipe-detector'),
      behavior: HitTestBehavior.translucent,
      onVerticalDragStart: _handleSwipeStart,
      onVerticalDragUpdate: _handleSwipeUpdate,
      onVerticalDragEnd: (details) =>
          _handleSwipeEnd(details, pairingState, pairingController),
      onVerticalDragCancel: _handleSwipeCancel,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0.0, end: _swipeOffset),
        duration: _isSwiping
            ? Duration.zero
            : const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        builder: (context, value, child) {
          final opacity = (1.0 - (value.abs() / 60)).clamp(0.0, 1.0);
          return Transform.translate(
            offset: Offset(0, value),
            child: Opacity(opacity: opacity, child: child),
          );
        },
        child: content,
      ),
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

        final wipeRadius =
            PairingConstants.scanCardRadius * max(1.0, _flipScale.value);
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
    switch (displayStep) {
      case PairingStep.unpaired:
        return _buildUnpairedTitle();
      case PairingStep.scanning:
        return _buildScanningTitle();
      case PairingStep.review:
        return _buildReviewTitle();
      case PairingStep.paired:
        return _buildPairedTitle(pairingState);
    }
  }

  Widget _buildUnpairedTitle() {
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
  }

  Widget _buildScanningTitle() {
    return Column(
      key: const ValueKey('title-scanning'),
      children: [
        Text('Scan QR Code', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text(
          'Display code on desktop bridge app',
          style: TextStyle(color: AppTheme.textMuted),
        ),
      ],
    );
  }

  Widget _buildReviewTitle() {
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
  }

  Widget _buildPairedTitle(PairingState pairingState) {
    final pairedTitleStyle = Theme.of(context).textTheme.displayLarge?.copyWith(
      fontWeight: FontWeight.w500,
      height: 1.0,
    );
    final pairedBridgeNameStyle = Theme.of(context).textTheme.headlineSmall
        ?.copyWith(fontWeight: FontWeight.w500, height: 1.05);
    final bridgeSummary = pairingState.savedBridgeCount > 1
        ? '${pairingState.savedBridgeCount} saved bridges available.'
        : 'A trusted bridge connection is established.';

    return SingleChildScrollView(
      key: const ValueKey('title-paired'),
      physics: const NeverScrollableScrollPhysics(),
      child: Transform.translate(
        offset: const Offset(0, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                text: 'Connected to\n',
                style: pairedTitleStyle,
                children: [
                  TextSpan(
                    text: pairingState.trustedBridge?.bridgeName ?? '',
                    style: pairedBridgeNameStyle,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  bridgeSummary,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 14,
                  ),
                ),
                _PairingConnectionIndicator(
                  state: pairingState.bridgeConnectionState,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopRightAction(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    final action = switch (pairingState.step) {
      PairingStep.paired => IconButton(
        key: const Key('top-right-add-bridge'),
        tooltip: 'Add another bridge',
        onPressed: () => _openScanner(pairingController),
        icon: PhosphorIcon(
          PhosphorIcons.plus(PhosphorIconsStyle.bold),
          size: 24,
        ),
      ),
      _ => const SizedBox.shrink(key: ValueKey('top-right-action-none')),
    };

    return AnimatedSwitcher(
      duration: PairingConstants.buttonSwitcher,
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.92, end: 1.0).animate(animation),
            child: child,
          ),
        );
      },
      child: action,
    );
  }

  Widget _buildCenterCard(
    PairingState pairingState,
    PairingController pairingController, {
    PairingStep? displayStepOverride,
  }) {
    final displayStep = displayStepOverride ?? pairingState.step;
    return switch (displayStep) {
      PairingStep.unpaired => const SizedBox.shrink(key: ValueKey('card-none')),
      PairingStep.scanning => _buildScanningCenterCard(),
      PairingStep.review => _buildReviewCenterCard(pairingState),
      PairingStep.paired => _buildPairedCenterCard(
        pairingState,
        pairingController,
      ),
    };
  }

  Widget _buildScanningCenterCard() {
    return AnimatedBuilder(
      key: const ValueKey('card-scanning'),
      animation: _flipRevealController,
      builder: (context, child) {
        final isFlipped = _flipRotation.value > (pi / 2);
        final card = isFlipped
            ? _buildRevealMaskCard()
            : Container(
                width: PairingConstants.scanCardSize,
                height: PairingConstants.scanCardSize,
                decoration: LiquidStyles.liquidGlass,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(
                    PairingConstants.scanCardRadius,
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 700),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeOutCubic,
                    child: _buildScanningCardContent(),
                  ),
                ),
              );

        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.002)
            ..scaleByDouble(_flipScale.value, _flipScale.value, 1.0, 1.0)
            ..rotateY(_flipRotation.value),
          child: card,
        );
      },
    );
  }

  Widget _buildScanningCardContent() {
    final hasLockedQr = _isLockedOn && _scannedRawQr != null;
    if (hasLockedQr) {
      return Container(
        key: const ValueKey('qr-reconstructed'),
        color: AppTheme.background,
        padding: const EdgeInsets.all(16),
        child: QrImageView(
          data: _scannedRawQr!,
          version: QrVersions.auto,
          padding: EdgeInsets.zero,
          errorCorrectionLevel: QrErrorCorrectLevel.M,
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Colors.white,
          ),
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Colors.white,
          ),
        ),
      );
    }

    return Stack(
      key: const ValueKey('camera'),
      fit: StackFit.expand,
      children: [
        Container(color: const Color(0xFF09090B)),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: widget.enableCameraPreview && _cameraMounted
              ? _buildCameraScanner()
              : const SizedBox.shrink(key: Key('camera-loading')),
        ),
      ],
    );
  }

  Widget _buildCameraScanner() {
    return MobileScanner(
      key: const Key('camera-scanner'),
      controller: _cameraController,
      onDetect: (capture) {
        final rawQr = _extractDetectedRawQr(capture);
        if (rawQr == null || _isLockedOn) {
          return;
        }

        _lockOnDetectedQr(rawQr);
      },
      errorBuilder: (context, error) {
        _setScannerIssue(PairingScannerIssue.fromScannerException(error));
        return const Center(
          child: Icon(Icons.videocam_off, color: AppTheme.textMuted),
        );
      },
    );
  }

  Widget _buildReviewCenterCard(PairingState pairingState) {
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

  Widget _buildPairedCenterCard(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    final activeBridge = pairingState.trustedBridge;
    if (activeBridge == null) {
      return const SizedBox.shrink(key: ValueKey('card-paired-empty'));
    }

    final titleStyle = Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);

    return Container(
      key: const ValueKey('card-paired'),
      padding: const EdgeInsets.all(24),
      decoration: LiquidStyles.liquidGlass,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Saved host bridges', style: titleStyle)),
                _PairingConnectionIndicator(
                  state: pairingState.bridgeConnectionState,
                  compact: true,
                ),
              ],
            ),
            const SizedBox(height: 12),
            _IdentityRow(label: 'Bridge', value: activeBridge.bridgeName),
            const Divider(color: Colors.white10, height: 24),
            _IdentityRow(
              label: 'Host URL',
              value: activeBridge.bridgeApiBaseUrl,
            ),
            const Divider(color: Colors.white10, height: 24),
            _IdentityRow(
              label: 'Identity',
              value: activeBridge.bridgeId,
              valueColor: AppTheme.emerald,
            ),
            if (pairingState.savedBridgeCount > 1) ...[
              const Divider(color: Colors.white10, height: 24),
              Text('Other saved bridges', style: titleStyle),
              const SizedBox(height: 12),
              ...pairingState.savedBridges.map(
                (bridge) => _buildSavedBridgeRow(
                  bridge,
                  pairingState,
                  pairingController,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSavedBridgeRow(
    TrustedBridgeIdentity bridge,
    PairingState pairingState,
    PairingController pairingController,
  ) {
    final isActive = bridge.bridgeId == pairingState.activeBridgeId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  bridge.bridgeName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMain,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  bridge.bridgeApiBaseUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (isActive)
            _PairingConnectionIndicator(
              state: pairingState.bridgeConnectionState,
              compact: true,
            )
          else
            TextButton(
              key: Key('activate-bridge-${bridge.bridgeId}'),
              onPressed: () =>
                  pairingController.activateSavedBridge(bridge.bridgeId),
              child: const Text('Activate'),
            ),
        ],
      ),
    );
  }

  Widget _buildRevealMaskCard() {
    return SizedBox(
      width: PairingConstants.scanCardSize,
      height: PairingConstants.scanCardSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PairingConstants.scanCardRadius),
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
              borderRadius: BorderRadius.circular(
                PairingConstants.scanCardRadius,
              ),
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

        if (anchoredAction != null) ...[
          MagneticButton(
            variant: anchoredAction.variant,
            onClick: anchoredAction.onClick,
            child: AnimatedSwitcher(
              duration: PairingConstants.buttonSwitcher,
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
                  builder: (context) => ThreadListPage(
                    bridgeApiBaseUrl: bridge.bridgeApiBaseUrl,
                    autoOpenPreviouslySelectedThread: false,
                  ),
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
          if (pairingState.savedBridgeCount > 1) ...[
            const SizedBox(height: 12),
            GestureDetector(
              key: const Key('swipe-switch-hint'),
              behavior: HitTestBehavior.opaque,
              onTap: () =>
                  _activateNextSavedBridge(pairingState, pairingController),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _swipeHintController,
                      builder: (context, child) {
                        return Opacity(
                          opacity: _swipeHintOpacity.value,
                          child: Transform.translate(
                            offset: Offset(0, _swipeHintLift.value),
                            child: child,
                          ),
                        );
                      },
                      child: PhosphorIcon(
                        PhosphorIcons.caretUp(PhosphorIconsStyle.bold),
                        size: 14,
                        color: AppTheme.textSubtle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Swipe up anywhere to switch device',
                      style: TextStyle(
                        color: AppTheme.textSubtle,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
    switch (displayStep) {
      case PairingStep.unpaired:
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
      case PairingStep.scanning:
        return _AnchoredFooterAction(
          variant: MagneticButtonVariant.secondary,
          onClick: pairingController.cancelReview,
          child: const Text(
            'Cancel',
            key: ValueKey('footer-action-cancel'),
            textAlign: TextAlign.center,
          ),
        );
      case PairingStep.review:
      case PairingStep.paired:
        return null;
    }
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

class _PairingConnectionIndicator extends StatelessWidget {
  const _PairingConnectionIndicator({
    required this.state,
    this.compact = false,
  });

  final BridgeConnectionState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = switch (state) {
      BridgeConnectionState.connected => (
        color: AppTheme.emerald,
        label: 'Online',
      ),
      BridgeConnectionState.reconnecting => (
        color: AppTheme.amber,
        label: 'Reconnecting',
      ),
      BridgeConnectionState.disconnected => (
        color: AppTheme.rose,
        label: 'Offline',
      ),
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 12,
        vertical: compact ? 6 : 8,
      ),
      decoration: BoxDecoration(
        color: palette.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: compact ? 8 : 10,
            height: compact ? 8 : 10,
            decoration: BoxDecoration(
              color: palette.color,
              shape: BoxShape.circle,
            ),
          ),
          SizedBox(width: compact ? 6 : 8),
          Text(
            palette.label,
            style: TextStyle(
              color: palette.color,
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
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
            issue.type.headline,
            style: TextStyle(color: AppTheme.rose, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(issue.type.body, style: const TextStyle(color: AppTheme.rose)),
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
