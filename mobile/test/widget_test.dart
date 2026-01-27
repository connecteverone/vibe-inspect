import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';

void main() {
  testWidgets('Pairing connects with valid secret', (tester) async {
    await tester.pumpWidget(const VibeInspectApp());

    expect(find.text('Pair your desktop agent'), findsOneWidget);

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'ABC123',
      'secret': 'SECRET77',
      'expires_at':
          DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
              1000,
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await tester.pumpAndSettle();

    expect(find.text('ABC123'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('secretField')), 'SECRET77');
    final confirmButton = find.byKey(const Key('confirmSecretButton'));
    await tester.ensureVisible(confirmButton);
    await tester.tap(confirmButton);
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('Expired token shows retry prompt', (tester) async {
    await tester.pumpWidget(const VibeInspectApp());

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'OLD123',
      'secret': 'SECRET',
      'expires_at':
          DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch ~/
              1000,
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Token expired'), findsOneWidget);
    expect(find.byKey(const Key('retryButton')), findsOneWidget);
  });
}
