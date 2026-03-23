import 'package:codex_linux_shell/src/shell_controller.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';

class ShellView extends StatelessWidget {
  const ShellView({
    super.key,
    required this.state,
    required this.onRefreshQr,
    required this.onRestartRuntime,
    required this.onRevokeTrust,
  });

  final ShellPresentationState state;
  final Future<void> Function() onRefreshQr;
  final Future<void> Function() onRestartRuntime;
  final Future<void> Function() onRevokeTrust;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF09111A),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D1723), Color(0xFF09111A), Color(0xFF070E16)],
          ),
        ),
        child: Stack(
          children: [
            const Positioned.fill(child: _BackdropGrid()),
            SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1220),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 24,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _Header(state: state),
                        const SizedBox(height: 20),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final wide = constraints.maxWidth >= 980;
                              return wide
                                  ? Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: SingleChildScrollView(
                                            child: _PrimaryColumn(
                                              state: state,
                                              onRefreshQr: onRefreshQr,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 20),
                                        Expanded(
                                          child: SingleChildScrollView(
                                            child: _SecondaryColumn(
                                              state: state,
                                              onRestartRuntime:
                                                  onRestartRuntime,
                                              onRevokeTrust: onRevokeTrust,
                                            ),
                                          ),
                                        ),
                                      ],
                                    )
                                  : ListView(
                                      children: [
                                        _PrimaryColumn(
                                          state: state,
                                          onRefreshQr: onRefreshQr,
                                        ),
                                        const SizedBox(height: 20),
                                        _SecondaryColumn(
                                          state: state,
                                          onRestartRuntime: onRestartRuntime,
                                          onRevokeTrust: onRevokeTrust,
                                        ),
                                      ],
                                    );
                            },
                          ),
                        ),
                        if (state.errorMessage != null) ...[
                          const SizedBox(height: 16),
                          _ErrorBanner(message: state.errorMessage!),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PrimaryColumn extends StatelessWidget {
  const _PrimaryColumn({required this.state, required this.onRefreshQr});

  final ShellPresentationState state;
  final Future<void> Function() onRefreshQr;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionTitle(
                title: 'Runtime',
                subtitle:
                    'Host supervision, trust state, and active Codex workload.',
              ),
              const SizedBox(height: 18),
              _StatusRow(
                label: 'Shell State',
                value: _shellStateLabel(state.shellState),
              ),
              _StatusRow(
                label: 'Supervisor',
                value: state.supervisorStatusLabel,
              ),
              _StatusRow(label: 'Bridge', value: state.bridgeRuntimeLabel),
              _StatusRow(label: 'Paired Phone', value: state.pairedDeviceLabel),
              _StatusRow(
                label: 'Active Session',
                value: state.activeSessionLabel,
              ),
              _StatusRow(
                label: 'Active Threads',
                value: '${state.runningThreadCount}',
              ),
              const SizedBox(height: 14),
              _InlineNote(message: state.runtimeDetail),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                title: 'Pairing',
                subtitle:
                    'QR flow for establishing trust with the mobile companion.',
              ),
              const SizedBox(height: 18),
              _PairingPanel(state: state, onRefreshQr: onRefreshQr),
            ],
          ),
        ),
      ],
    );
  }
}

class _SecondaryColumn extends StatelessWidget {
  const _SecondaryColumn({
    required this.state,
    required this.onRestartRuntime,
    required this.onRevokeTrust,
  });

  final ShellPresentationState state;
  final Future<void> Function() onRestartRuntime;
  final Future<void> Function() onRevokeTrust;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                title: 'Linux Speech',
                subtitle: 'Visible for parity with macOS, but read-only in v1.',
              ),
              const SizedBox(height: 18),
              _StatusRow(label: 'Speech', value: state.speechPanel.stateLabel),
              const SizedBox(height: 14),
              _InlineNote(message: state.speechPanel.detail),
              const SizedBox(height: 14),
              const _ReadOnlyBadge(label: 'READ ONLY'),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionTitle(
                title: 'Actions',
                subtitle:
                    'Non-destructive shell controls for the local bridge runtime.',
              ),
              const SizedBox(height: 18),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton(
                    onPressed:
                        state.isRestartingRuntime || state.isRefreshingRuntime
                        ? null
                        : onRestartRuntime,
                    child: Text(
                      state.isRestartingRuntime
                          ? 'Restarting…'
                          : 'Restart Runtime',
                    ),
                  ),
                  OutlinedButton(
                    onPressed:
                        state.canRevokeTrust &&
                            !state.isRevokingTrust &&
                            !state.isRefreshingRuntime
                        ? onRevokeTrust
                        : null,
                    child: Text(
                      state.isRevokingTrust ? 'Revoking…' : 'Unpair Phone',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _InlineNote(message: state.trayStatusDetail),
            ],
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.state});

  final ShellPresentationState state;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: _cardDecoration(),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: const LinearGradient(
                colors: [Color(0xFF19C7B5), Color(0xFF0D8DA4)],
              ),
            ),
            child: const Icon(
              Icons.terminal_rounded,
              color: Colors.black87,
              size: 30,
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Codex Mobile Companion',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Linux host shell for the local bridge runtime.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF9FB2C8),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _StatusChip(
                label: _shellStateLabel(state.shellState),
                color: switch (state.shellState) {
                  ShellRuntimeState.starting => const Color(0xFFFFB020),
                  ShellRuntimeState.unpaired => const Color(0xFF4EA1FF),
                  ShellRuntimeState.pairedIdle => const Color(0xFF22C55E),
                  ShellRuntimeState.pairedActive => const Color(0xFF12B981),
                  ShellRuntimeState.degraded => const Color(0xFFFF5D73),
                },
              ),
              const SizedBox(height: 10),
              _StatusChip(
                label: state.trayAvailable ? 'Tray Ready' : 'Window Only',
                color: state.trayAvailable
                    ? const Color(0xFF19C7B5)
                    : const Color(0xFF6B7B8F),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PairingPanel extends StatelessWidget {
  const _PairingPanel({required this.state, required this.onRefreshQr});

  final ShellPresentationState state;
  final Future<void> Function() onRefreshQr;

  @override
  Widget build(BuildContext context) {
    switch (state.shellState) {
      case ShellRuntimeState.starting:
        return const _InfoBox(
          icon: Icons.hourglass_bottom_rounded,
          title: 'Starting Up',
          message:
              'Linux shell is starting the local bridge and Codex runtime. Pairing unlocks automatically once the stack is healthy.',
        );
      case ShellRuntimeState.pairedIdle:
      case ShellRuntimeState.pairedActive:
        return const _InfoBox(
          icon: Icons.verified_user_rounded,
          title: 'Host Paired',
          message:
              'The trusted phone can reconnect without scanning again. Use "Unpair Phone" to revoke trust and require a fresh pairing flow.',
          accent: Color(0xFF22C55E),
        );
      case ShellRuntimeState.degraded:
        return const _InfoBox(
          icon: Icons.warning_amber_rounded,
          title: 'Bridge Degraded',
          message:
              'Supervision is retrying automatically and the shell will recover when bridge health returns.',
          accent: Color(0xFFFF5D73),
        );
      case ShellRuntimeState.unpaired:
        final session = state.pairingSession;
        if (session == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _InfoBox(
                icon: Icons.qr_code_2_rounded,
                title: 'Ready to Generate QR',
                message:
                    'Bridge is reachable but there is no cached pairing session yet. Generate a fresh QR to begin.',
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: state.isLoadingPairing ? null : onRefreshQr,
                child: Text(
                  state.isLoadingPairing ? 'Generating…' : 'Refresh QR',
                ),
              ),
            ],
          );
        }

        final expiry = DateTime.fromMillisecondsSinceEpoch(
          session.pairingSession.expiresAtEpochSeconds * 1000,
        ).toLocal();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 26,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: QrImageView(
                  key: const Key('pairing-qr'),
                  data: session.qrPayload,
                  size: 280,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Color(0xFF061018),
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Color(0xFF061018),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Scan this QR from the mobile app to trust the Linux host.',
              style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _MetaPill(
                  label: 'Session',
                  value: session.pairingSession.sessionId,
                ),
                _MetaPill(
                  label: 'Bridge',
                  value: session.bridgeIdentity.bridgeId,
                ),
                _MetaPill(label: 'Expires', value: _formatDateTime(expiry)),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: state.isLoadingPairing ? null : onRefreshQr,
              child: Text(
                state.isLoadingPairing ? 'Generating…' : 'Refresh QR',
              ),
            ),
          ],
        );
    }
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: textTheme.titleLarge?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF8EA1B6),
            height: 1.45,
          ),
        ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label.toUpperCase(),
              style: GoogleFonts.ibmPlexMono(
                color: const Color(0xFF6F8298),
                fontSize: 12,
                letterSpacing: 0.8,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: GoogleFonts.ibmPlexMono(
                color: const Color(0xFFF2F6FA),
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  const _InlineNote({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1621),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF142534)),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF9AAEC2),
          height: 1.45,
        ),
      ),
    );
  }
}

class _ReadOnlyBadge extends StatelessWidget {
  const _ReadOnlyBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0x1419C7B5),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF1B5D65)),
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexMono(
          color: const Color(0xFF85E7DB),
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.36)),
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexMono(
          color: color,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0B161F),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF152736)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: GoogleFonts.ibmPlexMono(
              color: const Color(0xFF6F8298),
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          SelectableText(
            value,
            style: GoogleFonts.ibmPlexMono(color: Colors.white, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.icon,
    required this.title,
    required this.message,
    this.accent = const Color(0xFF19C7B5),
  });

  final IconData icon;
  final String title;
  final String message;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF0B161F),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF152736)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 28),
          const SizedBox(height: 12),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF97AABD),
              height: 1.45,
            ),
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0x26FF5D73),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0x66FF5D73)),
      ),
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: const Color(0xFFFFB8C1)),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: _cardDecoration(),
      child: child,
    );
  }
}

class _BackdropGrid extends StatelessWidget {
  const _BackdropGrid();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _BackdropGridPainter());
  }
}

class _BackdropGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x0F88A4C2)
      ..strokeWidth = 1;
    const spacing = 34.0;
    for (double x = 0; x <= size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

BoxDecoration _cardDecoration() {
  return BoxDecoration(
    color: const Color(0xCC0D1823),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: const Color(0xFF152736)),
    boxShadow: const [
      BoxShadow(
        color: Color(0x22000000),
        blurRadius: 30,
        offset: Offset(0, 18),
      ),
    ],
  );
}

String _shellStateLabel(ShellRuntimeState state) {
  return switch (state) {
    ShellRuntimeState.starting => 'Starting',
    ShellRuntimeState.unpaired => 'Unpaired',
    ShellRuntimeState.pairedIdle => 'Paired (Idle)',
    ShellRuntimeState.pairedActive => 'Paired (Active)',
    ShellRuntimeState.degraded => 'Degraded',
  };
}

String _formatDateTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}:${two(value.second)}';
}
