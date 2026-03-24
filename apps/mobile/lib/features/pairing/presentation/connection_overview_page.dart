import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/features/pairing/presentation/pairing_constants.dart';
import 'package:codex_mobile_companion/features/settings/presentation/settings_page.dart';
import 'package:codex_mobile_companion/features/threads/presentation/thread_list_page.dart';
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
      setState(() => 
          _scannerIssue = PairingScannerIssue.fromScannerException(error));
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
    if (sessionId.isEmpty || 
        _autoOpenedThreadSessionIds.contains(sessionId)) {
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
            builder: (context) => ThreadListPage(
              bridgeApiBaseUrl: bridge.bridgeApiBaseUrl,
            ),
          ),
        );
      } finally {
        _isAutoOpeningThreadList = false;
      }
    });
  }

  // TODO: Extract these layout helper methods to a separate mixin or utility
  Offset? _resolveWipeCenter() {
    final foregroundBox = _foregroundFrameKey.currentContext?.findRenderObject()
        as RenderBox?;
    final centerSlotBox = _centerSlotKey.currentContext?.findRenderObject()
        as RenderBox?;
    
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
        ? const AnimatedBridgeBackground(sceneScale: 1.08)
        : const ColoredBox(color: AppTheme.background);
  }

  Widget _buildMainContent(
    PairingState pairingState,
    PairingController pairingController,
  ) {
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

  // TODO: Continue breaking down these massive methods into smaller widgets
  // For now, keeping the structure similar but will extract in next step
  Widget _buildForegroundLayout({
    required PairingState pairingState,
    required PairingController pairingController,
    required double titleSlotHeight,
    required double titleTravel,
    Key? centerSlotKey,
    PairingStep? displayStepOverride,
  }) {
    // This method is still too large - will extract into smaller widgets
    // in the next refactoring step
    return const Placeholder(); // TODO: Implement
  }

  Widget _buildForegroundWipeOverlay({
    required PairingState pairingState,
    required PairingController pairingController,
    required double titleSlotHeight,
    required double titleTravel,
  }) {
    return const Placeholder(); // TODO: Implement
  }

  Widget _buildTopRightAction(
    PairingState pairingState,
    PairingController pairingController,
  ) {
    return const Placeholder(); // TODO: Implement
  }
}
