import 'package:codex_linux_shell/src/shell_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

class ShellView extends StatelessWidget {
  const ShellView({
    super.key,
    required this.state,
    required this.onCheckTailscale,
    required this.onCheckCodex,
    required this.onChooseCodexBinary,
    required this.onRefreshQr,
    required this.onRestartRuntime,
    required this.onRevokeTrust,
  });

  final ShellPresentationState state;
  final Future<void> Function() onCheckTailscale;
  final Future<void> Function() onCheckCodex;
  final Future<void> Function() onChooseCodexBinary;
  final Future<void> Function() onRefreshQr;
  final Future<void> Function() onRestartRuntime;
  final Future<void> Function() onRevokeTrust;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          const AnimatedBridgeBackground(),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1220),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 40,
                    vertical: 32,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _Header(state: state),
                      const SizedBox(height: 32),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final wide = constraints.maxWidth >= 800;
                            return wide
                                ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(
                                        flex: 5,
                                        child: SingleChildScrollView(
                                          child: state.requiresTailscaleSetup
                                              ? _TailscaleRequiredCard(
                                                  state: state,
                                                  onCheckTailscale:
                                                      onCheckTailscale,
                                                )
                                              : _PairDeviceCard(
                                                  state: state,
                                                  onRefreshQr: onRefreshQr,
                                                ),
                                        ),
                                      ),
                                      const SizedBox(width: 24),
                                      Expanded(
                                        flex: 7,
                                        child: SingleChildScrollView(
                                          child: Column(
                                            children: [
                                              if (state.requiresCodexSetup) ...[
                                                _CodexRequiredCard(
                                                  state: state,
                                                  onCheckCodex: onCheckCodex,
                                                  onChooseCodexBinary:
                                                      onChooseCodexBinary,
                                                ),
                                                const SizedBox(height: 24),
                                              ],
                                              _ConnectionDetailsCard(
                                                state: state,
                                              ),
                                              const SizedBox(height: 24),
                                              _SystemActionsCard(
                                                state: state,
                                                onCheckTailscale:
                                                    onCheckTailscale,
                                                onRestartRuntime:
                                                    onRestartRuntime,
                                                onRevokeTrust: onRevokeTrust,
                                              ),
                                              if (state.errorMessage !=
                                                  null) ...[
                                                const SizedBox(height: 16),
                                                _ErrorBanner(
                                                  message: state.errorMessage!,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : ListView(
                                    children: [
                                      state.requiresTailscaleSetup
                                          ? _TailscaleRequiredCard(
                                              state: state,
                                              onCheckTailscale:
                                                  onCheckTailscale,
                                            )
                                          : _PairDeviceCard(
                                              state: state,
                                              onRefreshQr: onRefreshQr,
                                            ),
                                      if (state.requiresCodexSetup) ...[
                                        const SizedBox(height: 24),
                                        _CodexRequiredCard(
                                          state: state,
                                          onCheckCodex: onCheckCodex,
                                          onChooseCodexBinary:
                                              onChooseCodexBinary,
                                        ),
                                      ],
                                      const SizedBox(height: 24),
                                      _ConnectionDetailsCard(state: state),
                                      const SizedBox(height: 24),
                                      _SystemActionsCard(
                                        state: state,
                                        onCheckTailscale: onCheckTailscale,
                                        onRestartRuntime: onRestartRuntime,
                                        onRevokeTrust: onRevokeTrust,
                                      ),
                                      if (state.errorMessage != null) ...[
                                        const SizedBox(height: 16),
                                        _ErrorBanner(
                                          message: state.errorMessage!,
                                        ),
                                      ],
                                    ],
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
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});

  final ShellPresentationState state;

  @override
  Widget build(BuildContext context) {
    Color badgeColor;
    String badgeText;

    switch (state.shellState) {
      case ShellRuntimeState.starting:
        badgeColor = AppTheme.amber;
        badgeText = 'Starting Bridge';
        break;
      case ShellRuntimeState.unpaired:
        badgeColor = AppTheme.amber;
        badgeText = 'Awaiting Pair';
        break;
      case ShellRuntimeState.pairedIdle:
      case ShellRuntimeState.pairedActive:
        badgeColor = AppTheme.emerald;
        badgeText = 'Connected';
        break;
      case ShellRuntimeState.needsTailscale:
        badgeColor = AppTheme.amber;
        badgeText = 'Tailscale Required';
        break;
      case ShellRuntimeState.degraded:
        badgeColor = AppTheme.rose;
        badgeText = 'Bridge Degraded';
        break;
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Codex Bridge',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: AppTheme.textMain,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Linux Host • Local Environment',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppTheme.textSubtle),
            ),
          ],
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: badgeColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                badgeText,
                style: const TextStyle(
                  color: AppTheme.textMain,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PairDeviceCard extends StatelessWidget {
  const _PairDeviceCard({required this.state, required this.onRefreshQr});

  final ShellPresentationState state;
  final Future<void> Function() onRefreshQr;

  @override
  Widget build(BuildContext context) {
    final isPaired =
        state.shellState == ShellRuntimeState.pairedIdle ||
        state.shellState == ShellRuntimeState.pairedActive;

    final session = state.pairingSession;

    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.emerald.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: PhosphorIcon(
              PhosphorIcons.qrCode(),
              color: AppTheme.emerald,
              size: 28,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            isPaired ? 'Device Paired' : 'Pair Device',
            style: const TextStyle(
              color: AppTheme.textMain,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isPaired
                ? 'Your companion device is connected securely.'
                : 'Open Codex Companion on your phone and scan this code to establish a secure local connection.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 32),
          if (!isPaired && session != null) ...[
            Container(
              key: const Key('pairing-qr'),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
              ),
              child: QrImageView(
                data: session.qrPayload,
                size: 220,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: Color(0xFF09090B),
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: Color(0xFF09090B),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Session ID',
                    style: TextStyle(color: AppTheme.textSubtle, fontSize: 14),
                  ),
                  Text(
                    session.pairingSession.sessionId.length > 8
                        ? session.pairingSession.sessionId.substring(0, 8)
                        : session.pairingSession.sessionId,
                    style: AppTheme.monoTextStyle.copyWith(
                      color: AppTheme.textMain,
                      fontSize: 15,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: state.isLoadingPairing ? null : onRefreshQr,
                style: TextButton.styleFrom(
                  foregroundColor: AppTheme.textMuted,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: Text(
                  state.isLoadingPairing ? 'Generating...' : 'Refresh Code',
                ),
              ),
            ),
          ] else if (isPaired) ...[
            Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Center(
                child: PhosphorIcon(
                  PhosphorIcons.shieldCheck(),
                  color: AppTheme.emerald,
                  size: 64,
                ),
              ),
            ),
          ] else ...[
            Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Center(
                child: state.isLoadingPairing
                    ? const CircularProgressIndicator(color: AppTheme.emerald)
                    : PhosphorIcon(
                        PhosphorIcons.qrCode(),
                        color: AppTheme.textSubtle,
                        size: 64,
                      ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: MagneticButton(
                variant: MagneticButtonVariant.primary,
                onClick: state.isLoadingPairing ? () {} : () => onRefreshQr(),
                child: Text(
                  state.isLoadingPairing ? 'Generating...' : 'Generate Code',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TailscaleRequiredCard extends StatelessWidget {
  const _TailscaleRequiredCard({
    required this.state,
    required this.onCheckTailscale,
  });

  final ShellPresentationState state;
  final Future<void> Function() onCheckTailscale;

  @override
  Widget build(BuildContext context) {
    final tailscale = state.tailscale;
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.amber.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: PhosphorIcon(
              PhosphorIcons.cloudSlash(),
              color: AppTheme.amber,
              size: 28,
            ),
          ),
          const SizedBox(height: 24),
          const Text(
            'Tailscale Required',
            style: TextStyle(
              color: AppTheme.textMain,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            tailscale.detail,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Status',
                  style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  tailscale.statusLabel,
                  style: const TextStyle(
                    color: AppTheme.textMain,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (tailscale.binaryPath != null) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Binary',
                    style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    tailscale.binaryPath!,
                    style: AppTheme.monoTextStyle.copyWith(
                      color: AppTheme.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (tailscale.installHint.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  const Text(
                    'Next Step',
                    style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            tailscale.installHint,
                            style: AppTheme.monoTextStyle.copyWith(
                              color: AppTheme.textMain,
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        TextButton.icon(
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: tailscale.installHint),
                            );
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: AppTheme.emerald,
                            backgroundColor: AppTheme.emerald.withValues(
                              alpha: 0.1,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          icon: PhosphorIcon(
                            PhosphorIcons.copy(),
                            size: 16,
                            color: AppTheme.emerald,
                          ),
                          label: const Text('Copy'),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: MagneticButton(
              variant: MagneticButtonVariant.primary,
              onClick: state.isCheckingTailscale
                  ? () {}
                  : () => onCheckTailscale(),
              child: Text(
                state.isCheckingTailscale ? 'Checking...' : 'Check Again',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodexRequiredCard extends StatelessWidget {
  const _CodexRequiredCard({
    required this.state,
    required this.onCheckCodex,
    required this.onChooseCodexBinary,
  });

  final ShellPresentationState state;
  final Future<void> Function() onCheckCodex;
  final Future<void> Function() onChooseCodexBinary;

  @override
  Widget build(BuildContext context) {
    final codex = state.codex;

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.amber.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.amber.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: PhosphorIcon(
                  PhosphorIcons.terminalWindow(),
                  color: AppTheme.amber,
                  size: 24,
                ),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Codex CLI Needed',
                      style: TextStyle(
                        color: AppTheme.textMain,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Pairing can continue, but threads, approvals, and live Codex status need a local Codex CLI on this Linux host.',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Status',
                  style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  codex.statusLabel,
                  style: const TextStyle(
                    color: AppTheme.textMain,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  codex.detail,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                if (codex.sourceLabel != null) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Source',
                    style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    codex.sourceLabel!,
                    style: const TextStyle(
                      color: AppTheme.textMain,
                      fontSize: 14,
                    ),
                  ),
                ],
                if (codex.binaryPath != null) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'Binary',
                    style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.05),
                      ),
                    ),
                    child: Text(
                      codex.binaryPath!,
                      style: AppTheme.monoTextStyle.copyWith(
                        color: AppTheme.textMain,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                const Text(
                  'Next Step',
                  style: TextStyle(color: AppTheme.textSubtle, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  codex.nextStep,
                  style: const TextStyle(
                    color: AppTheme.textMain,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: MagneticButton(
                  variant: MagneticButtonVariant.primary,
                  onClick: state.isSavingCodexPath
                      ? () {}
                      : () => onChooseCodexBinary(),
                  child: Text(
                    state.isSavingCodexPath ? 'Saving...' : 'Choose Binary',
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: TextButton(
                  onPressed: state.isCheckingCodex ? null : onCheckCodex,
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    state.isCheckingCodex ? 'Checking...' : 'Check Again',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ConnectionDetailsCard extends StatelessWidget {
  const _ConnectionDetailsCard({required this.state});

  final ShellPresentationState state;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Connection Details',
              style: TextStyle(
                color: AppTheme.textMain,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          _DetailRow(label: 'Supervisor', value: state.supervisorStatusLabel),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          _DetailRow(label: 'Bridge', value: state.bridgeRuntimeLabel),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          _DetailRow(label: 'Tailscale', value: state.tailscale.statusLabel),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          _DetailRow(label: 'Codex', value: state.codex.statusLabel),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          _DetailRow(
            label: 'Active Threads',
            value: '${state.runningThreadCount} sessions',
          ),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          _DetailRow(
            label: 'Encryption',
            valueWidget: Row(
              children: [
                PhosphorIcon(
                  PhosphorIcons.shieldCheck(PhosphorIconsStyle.fill),
                  color: AppTheme.emerald,
                  size: 16,
                ),
                const SizedBox(width: 6),
                const Text(
                  'End-to-End',
                  style: TextStyle(color: AppTheme.emerald, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, this.value, this.valueWidget});

  final String label;
  final String? value;
  final Widget? valueWidget;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: AppTheme.textSubtle, fontSize: 14),
          ),
          if (valueWidget != null)
            valueWidget!
          else if (value != null)
            Text(
              value!,
              style: const TextStyle(color: AppTheme.textMain, fontSize: 14),
            ),
        ],
      ),
    );
  }
}

class _SystemActionsCard extends StatelessWidget {
  const _SystemActionsCard({
    required this.state,
    required this.onCheckTailscale,
    required this.onRestartRuntime,
    required this.onRevokeTrust,
  });

  final ShellPresentationState state;
  final Future<void> Function() onCheckTailscale;
  final Future<void> Function() onRestartRuntime;
  final Future<void> Function() onRevokeTrust;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceZinc900.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'System Actions',
              style: TextStyle(
                color: AppTheme.textMain,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          if (state.requiresTailscaleSetup) ...[
            _ActionRow(
              icon: PhosphorIcons.cloudCheck(),
              iconColor: AppTheme.amber,
              iconBg: AppTheme.amber.withValues(alpha: 0.1),
              title: 'Check Tailscale',
              subtitle: 'Re-scan for the CLI and current tailnet status',
              buttonLabel: state.isCheckingTailscale ? 'Checking...' : 'Check',
              onTap: state.isCheckingTailscale ? null : onCheckTailscale,
            ),
            Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          ],
          _ActionRow(
            icon: PhosphorIcons.arrowsClockwise(),
            iconColor: AppTheme.textMain,
            iconBg: Colors.white.withValues(alpha: 0.05),
            title: 'Restart Runtime',
            subtitle: 'Restart the host daemon safely',
            buttonLabel: state.isRestartingRuntime
                ? 'Restarting...'
                : 'Restart',
            onTap: state.isRestartingRuntime || state.isRefreshingRuntime
                ? null
                : onRestartRuntime,
          ),
          Divider(color: Colors.white.withValues(alpha: 0.05), height: 1),
          _ActionRow(
            icon: PhosphorIcons.linkBreak(),
            iconColor: AppTheme.rose,
            iconBg: AppTheme.rose.withValues(alpha: 0.1),
            title: 'Unpair Phone',
            subtitle: 'Revoke trust from the current device',
            buttonLabel: state.isRevokingTrust ? 'Revoking...' : 'Unpair',
            isDestructive: true,
            onTap:
                state.canRevokeTrust &&
                    !state.isRevokingTrust &&
                    !state.isRefreshingRuntime
                ? onRevokeTrust
                : null,
          ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
    required this.onTap,
    this.isDestructive = false,
  });

  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String subtitle;
  final String buttonLabel;
  final Future<void> Function()? onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: iconBg, shape: BoxShape.circle),
            child: PhosphorIcon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textMain,
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppTheme.textSubtle,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: isDestructive ? AppTheme.rose : AppTheme.emerald,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              backgroundColor: isDestructive
                  ? AppTheme.rose.withValues(alpha: 0.1)
                  : AppTheme.emerald.withValues(alpha: 0.1),
            ),
            child: Text(buttonLabel),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.rose.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.rose.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          PhosphorIcon(PhosphorIcons.warningCircle(), color: AppTheme.rose),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.rose, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
