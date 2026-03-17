import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class PairingFlowPage extends ConsumerStatefulWidget {
  const PairingFlowPage({super.key, this.enableCameraPreview = true});

  final bool enableCameraPreview;

  @override
  ConsumerState<PairingFlowPage> createState() => _PairingFlowPageState();
}

class _PairingFlowPageState extends ConsumerState<PairingFlowPage> {
  late final TextEditingController _manualPayloadController;
  late final MobileScannerController _cameraController;

  @override
  void initState() {
    super.initState();
    _manualPayloadController = TextEditingController();
    _cameraController = MobileScannerController();
  }

  @override
  void dispose() {
    _manualPayloadController.dispose();
    _cameraController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pairingState = ref.watch(pairingControllerProvider);
    final pairingController = ref.read(pairingControllerProvider.notifier);

    final body = switch (pairingState.step) {
      PairingStep.unpaired => _buildUnpairedView(pairingController),
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

  Widget _buildUnpairedView(PairingController pairingController) {
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
            onPressed: pairingController.openScanner,
            child: const Text('Scan pairing QR'),
          ),
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
                        pairingController.submitScannedPayload(rawValue);
                        break;
                      }
                    }
                  },
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text('Manual fallback (for debug/testing):'),
          const SizedBox(height: 8),
          TextField(
            key: const Key('manual-payload-input'),
            controller: _manualPayloadController,
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
      return _buildUnpairedView(pairingController);
    }

    return Padding(
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
          const SizedBox(height: 24),
          FilledButton(
            onPressed: pairingController.openScanner,
            child: const Text('Scan another QR'),
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
