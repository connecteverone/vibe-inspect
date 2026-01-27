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

  testWidgets('Timeline API event opens API explorer', (tester) async {
    final now = DateTime.now();
    const apiEventId = 'api-event-1';
    const apiSessionId = 'api-session-1';
    final initializer = _SeededStorageInitializer((storage) async {
      await storage.insertToolSession(
        ToolSession(
          id: apiSessionId,
          type: 'api',
          label: 'Login API',
          status: 'complete',
          createdAt: now,
        ),
      );
      await storage.insertTimelineEvent(
        TimelineEvent(
          id: apiEventId,
          sessionId: apiSessionId,
          type: 'api',
          title: 'POST /login',
          payload: {
            'request': {
              'method': 'POST',
              'url': 'https://api.example.com/login',
              'headers': {'Content-Type': 'application/json'},
              'body': {'email': 'user@example.com'},
            },
            'response': {
              'status': 500,
              'latency_ms': 120,
              'headers': {'x-request-id': 'req-1'},
              'body': {'error': 'Missing password'},
            },
          },
          createdAt: now,
        ),
      );
    });

    await tester.pumpWidget(
      VibeInspectApp(storageInitializer: initializer),
    );
    await tester.pumpAndSettle();

    final eventFinder = find.byKey(const Key('timelineEvent-$apiEventId'));
    await tester.ensureVisible(eventFinder);
    await tester.tap(eventFinder);
    await tester.pumpAndSettle();

    expect(find.text('API Explorer'), findsOneWidget);
    expect(find.text('POST'), findsWidgets);
    expect(find.text('https://api.example.com/login'), findsOneWidget);
    expect(find.textContaining('Status 500'), findsOneWidget);
  });

  testWidgets('Timeline terminal event opens session', (tester) async {
    final now = DateTime.now();
    const terminalEventId = 'terminal-event-1';
    const terminalSessionId = 'terminal-session-1';
    final initializer = _SeededStorageInitializer((storage) async {
      await storage.insertToolSession(
        ToolSession(
          id: terminalSessionId,
          type: 'terminal',
          label: 'Build logs',
          status: 'running',
          createdAt: now,
        ),
      );
      await storage.insertTimelineEvent(
        TimelineEvent(
          id: terminalEventId,
          sessionId: terminalSessionId,
          type: 'terminal',
          title: 'npm test',
          payload: {
            'command': 'npm test',
            'output_preview': '1 failing test',
          },
          createdAt: now,
        ),
      );
    });

    await tester.pumpWidget(
      VibeInspectApp(storageInitializer: initializer),
    );
    await tester.pumpAndSettle();

    final eventFinder = find.byKey(const Key('timelineEvent-$terminalEventId'));
    await tester.ensureVisible(eventFinder);
    await tester.tap(eventFinder);
    await tester.pumpAndSettle();

    expect(find.text('Terminal Session'), findsOneWidget);
    expect(find.text('Build logs'), findsOneWidget);
    expect(find.text('npm test'), findsWidgets);
  });

  testWidgets('Timeline event with missing context shows error state',
      (tester) async {
    final now = DateTime.now();
    const brokenEventId = 'api-event-missing';
    const apiSessionId = 'api-session-missing';
    final initializer = _SeededStorageInitializer((storage) async {
      await storage.insertToolSession(
        ToolSession(
          id: apiSessionId,
          type: 'api',
          label: 'Broken API',
          status: 'error',
          createdAt: now,
        ),
      );
      await storage.insertTimelineEvent(
        TimelineEvent(
          id: brokenEventId,
          sessionId: apiSessionId,
          type: 'api',
          title: 'GET /missing',
          payload: {
            'request': {
              'method': 'GET',
              'url': 'https://api.example.com/missing',
            },
          },
          createdAt: now,
        ),
      );
    });

    await tester.pumpWidget(
      VibeInspectApp(storageInitializer: initializer),
    );
    await tester.pumpAndSettle();

    final eventFinder = find.byKey(const Key('timelineEvent-$brokenEventId'));
    await tester.ensureVisible(eventFinder);
    await tester.tap(eventFinder);
    await tester.pumpAndSettle();

    expect(find.textContaining('missing request or response details'),
        findsOneWidget);
  });
}

class _FailingStorageInitializer extends StorageInitializer {
  const _FailingStorageInitializer();

  @override
  Future<StorageRepository> initialize() async {
    throw Exception('Database init failed');
  }
}

class _SeededStorageInitializer extends StorageInitializer {
  const _SeededStorageInitializer(this._seed);

  final Future<void> Function(StorageRepository storage) _seed;

  @override
  Future<StorageRepository> initialize() async {
    final storage = MemoryStorage();
    await _seed(storage);
    return storage;
  }
}
