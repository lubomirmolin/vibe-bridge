import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

// Live bridge approval tests ask Claude Code to toggle this value.
const Color liveApprovalProbeIconColor = Color(0xFF2563EB);

class LiveApprovalProbeIcon extends StatelessWidget {
  const LiveApprovalProbeIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color(0xFF0F172A),
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: PhosphorIcon(
          PhosphorIcons.sparkle(PhosphorIconsStyle.fill),
          color: liveApprovalProbeIconColor,
          size: 20,
        ),
      ),
    );
  }
}
