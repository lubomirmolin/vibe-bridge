import 'package:codex_mobile_companion/main.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app starts in unpaired pairing state', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: CodexMobileApp()));

    expect(find.text('Pair your phone to this Mac'), findsOneWidget);
    expect(find.text('Scan pairing QR'), findsOneWidget);
  });
}
