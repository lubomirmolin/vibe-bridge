import 'package:codex_mobile_companion/features/home/presentation/home_screen.dart';
import 'package:codex_mobile_companion/features/pairing/application/pairing_controller.dart';
import 'package:codex_mobile_companion/foundation/storage/secure_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('home uses stacked cards on compact layouts', (tester) async {
    await _setDisplaySize(tester, const Size(430, 900));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(InMemorySecureStore()),
        ],
        child: const MaterialApp(
          home: HomeScreen(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            bridgeName: 'codex-mobile-companion',
            bridgeId: 'bridge-123',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-wide-grid')), findsNothing);
    expect(find.text('Active Threads'), findsOneWidget);
  });

  testWidgets('home switches to a wide grid on tablet layouts', (tester) async {
    await _setDisplaySize(tester, const Size(1400, 900));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          secureStoreProvider.overrideWithValue(InMemorySecureStore()),
        ],
        child: const MaterialApp(
          home: HomeScreen(
            bridgeApiBaseUrl: 'https://bridge.ts.net',
            bridgeName: 'codex-mobile-companion',
            bridgeId: 'bridge-123',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('home-wide-grid')), findsOneWidget);
    expect(
      find.textContaining('Large-screen workspace keeps session controls'),
      findsOneWidget,
    );
  });
}

Future<void> _setDisplaySize(WidgetTester tester, Size size) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
