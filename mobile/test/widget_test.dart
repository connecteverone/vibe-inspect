import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';
import 'package:mobile/storage/local_storage.dart';

void main() {
  testWidgets('Pairing connects with valid secret', (tester) async {
    await tester.pumpWidget(
      const VibeInspectApp(storageInitializer: MemoryStorageInitializer()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Pair your desktop agent'), findsOneWidget);

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'ABC123',
      'secret': 'SECRET77',
      'expires_at':
          DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
              1000,
      'tunnel_url': 'https://demo.trycloudflare.com',
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
    expect(find.text('https://demo.trycloudflare.com'), findsOneWidget);
    expect(find.text('Paired with desktop agent'), findsOneWidget);
  });

  testWidgets('Expired token shows retry prompt', (tester) async {
    await tester.pumpWidget(
      const VibeInspectApp(storageInitializer: MemoryStorageInitializer()),
    );
    await tester.pumpAndSettle();

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

  testWidgets('Tunnel error message is shown after scan', (tester) async {
    await tester.pumpWidget(
      const VibeInspectApp(storageInitializer: MemoryStorageInitializer()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'NEW456',
      'secret': 'SECRET',
      'expires_at':
          DateTime.now().add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/
              1000,
      'tunnel_error':
          'Cloudflared is not installed. Install it and retry pairing.',
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Cloudflared is not installed'), findsOneWidget);
  });

  testWidgets('Storage initialization failure blocks the UI', (tester) async {
    await tester.pumpWidget(
      const VibeInspectApp(storageInitializer: _FailingStorageInitializer()),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage unavailable'), findsOneWidget);
  });
}

class _FailingStorageInitializer extends StorageInitializer {
  const _FailingStorageInitializer();

  @override
  Future<StorageRepository> initialize() async {
    throw Exception('Database init failed');
  }
}
