import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:codex_ui/codex_ui.dart';

void main() {
  testWidgets('AnimatedBridgeBackground renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: AnimatedBridgeBackground()),
    );

    expect(find.byType(AnimatedBridgeBackground), findsOneWidget);
  });
}
