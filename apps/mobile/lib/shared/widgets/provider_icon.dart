import 'package:vibe_bridge/foundation/contracts/bridge_contracts.dart';
import 'package:codex_ui/codex_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

class ProviderIcon extends StatelessWidget {
  const ProviderIcon({super.key, required this.provider, this.size = 15});

  final ProviderKind provider;
  final double size;

  static const String _chatGptAsset = 'assets/provider_icons/openai_mark.svg';
  static const String _claudeAsset = 'assets/provider_icons/anthropic_mark.svg';

  @override
  Widget build(BuildContext context) {
    final assetName = switch (provider) {
      ProviderKind.codex => _chatGptAsset,
      ProviderKind.claudeCode => _claudeAsset,
    };
    final iconColor = switch (provider) {
      ProviderKind.codex => AppTheme.emerald,
      ProviderKind.claudeCode => const Color(0xFFC15F3C),
    };

    return SvgPicture.asset(
      assetName,
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
    );
  }
}
