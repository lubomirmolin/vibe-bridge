import 'package:vibe_bridge/main.dart';
import 'package:vibe_bridge/features/bridges/application/pairing_controller.dart';
import 'package:vibe_bridge/foundation/storage/secure_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'app resolves to unpaired pairing state when no saved bridges exist',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            secureStoreProvider.overrideWithValue(InMemorySecureStore()),
          ],
          child: const VibeBridgeApp(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.text('Codex\nBridge'), findsOneWidget);
      expect(find.text('Initialize Pairing'), findsOneWidget);
    },
  );
}
