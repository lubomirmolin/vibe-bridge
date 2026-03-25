import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@immutable
class AppPlatform {
  const AppPlatform({required this.isWeb, required this.isDesktop});

  final bool isWeb;
  final bool isDesktop;

  bool get supportsLocalLoopbackBridge => isDesktop || isWeb;
}

final appPlatformProvider = Provider<AppPlatform>((ref) {
  final isDesktop = switch (defaultTargetPlatform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    _ => false,
  };

  return AppPlatform(isWeb: kIsWeb, isDesktop: !kIsWeb && isDesktop);
});
