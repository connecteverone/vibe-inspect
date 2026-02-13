import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/main.dart';
import 'package:mobile/storage/local_storage.dart';
import 'package:xterm/xterm.dart';

Future<void> pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  throw TestFailure('Timed out waiting for widget: $finder');
}

void main() {
  testWidgets('Pairing connects with valid secret', (tester) async {
    final mockClient = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      if (request.url.path.endsWith('/pairing/confirm')) {
        expect(body['token'], 'ABC123');
        expect(body['secret'], 'SECRET77');
        return http.Response(
          jsonEncode({
            'status': 'connected',
            'connected_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            'auth_token': 'LONGTOKEN123',
            'device_id': 'device-1',
          }),
          200,
        );
      }
      return http.Response('Not found', 404);
    });

    await tester.pumpWidget(
      VibeInspectApp(
        storageInitializer: const MemoryStorageInitializer(),
        pairingHttpClient: mockClient,
        forceManualQr: true,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Agents & workspaces'), findsOneWidget);

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'ABC123',
      'secret': 'SECRET77',
      'expires_at':
          DateTime.now()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch ~/
          1000,
      'tunnel_url': 'https://demo.trycloudflare.com',
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await pumpUntilFound(tester, find.text('ABC123'));

    expect(find.text('ABC123'), findsOneWidget);

    await pumpUntilFound(tester, find.textContaining('Connected'));

    expect(find.textContaining('Connected'), findsOneWidget);
    expect(find.text('https://demo.trycloudflare.com'), findsOneWidget);
    expect(find.text('ABC123'), findsOneWidget);
  });

  testWidgets('Expired token shows retry prompt', (tester) async {
    await tester.pumpWidget(
      const VibeInspectApp(
        storageInitializer: MemoryStorageInitializer(),
        forceManualQr: true,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'OLD123',
      'secret': 'SECRET',
      'expires_at':
          DateTime.now()
              .subtract(const Duration(minutes: 1))
              .millisecondsSinceEpoch ~/
          1000,
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('Token expired'), findsOneWidget);
    expect(find.byKey(const Key('retryButton')), findsOneWidget);
  });

  testWidgets('Unsupported protocol token is blocked before pairing request', (
    tester,
  ) async {
    var requestCount = 0;
    final mockClient = MockClient((request) async {
      requestCount += 1;
      return http.Response('Unexpected request', 500);
    });

    await tester.pumpWidget(
      VibeInspectApp(
        storageInitializer: const MemoryStorageInitializer(),
        pairingHttpClient: mockClient,
        forceManualQr: true,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'UNSUPPORTED-1',
      'secret': 'SECRET',
      'protocol_version': '2.0',
      'expires_at':
          DateTime.now()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch ~/
          1000,
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Pairing protocol 2.0 is unsupported'),
      findsOneWidget,
    );
    expect(requestCount, 0);
  });

  testWidgets('Unsupported protocol blocks LAN use retry request', (
    tester,
  ) async {
    var requestCount = 0;
    final mockClient = MockClient((request) async {
      requestCount += 1;
      return http.Response('Unexpected request', 500);
    });

    await tester.pumpWidget(
      VibeInspectApp(
        storageInitializer: const MemoryStorageInitializer(),
        pairingHttpClient: mockClient,
        forceManualQr: true,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'UNSUPPORTED-2',
      'secret': 'SECRET',
      'protocol_version': '2.0',
      'local_urls': ['https://192.168.1.10:3030'],
      'expires_at':
          DateTime.now()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch ~/
          1000,
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await tester.pumpAndSettle();

    final useButton = find.widgetWithText(OutlinedButton, 'Use').first;
    await tester.tap(useButton);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Pairing protocol 2.0 is unsupported'),
      findsOneWidget,
    );
    expect(requestCount, 0);
  });

  testWidgets('Missing nonce shows regenerate QR hint and action', (
    tester,
  ) async {
    final mockClient = MockClient((request) async {
      if (request.url.path.endsWith('/pairing/confirm')) {
        return http.Response(
          jsonEncode({
            'error': {
              'code': 'missing_nonce',
              'message': 'Pairing nonce is required for this protocol version.',
            },
          }),
          400,
        );
      }
      return http.Response('Not found', 404);
    });

    await tester.pumpWidget(
      VibeInspectApp(
        storageInitializer: const MemoryStorageInitializer(),
        pairingHttpClient: mockClient,
        forceManualQr: true,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'NONCE-REQ-1',
      'secret': 'SECRET',
      'protocol_version': '1.1',
      'expires_at':
          DateTime.now()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch ~/
          1000,
      'local_urls': ['https://192.168.1.10:3030'],
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await pumpUntilFound(tester, find.textContaining('Pairing nonce missing'));

    expect(find.byKey(const Key('pairingRecoveryHint')), findsOneWidget);
    expect(find.byKey(const Key('regenerateQrButton')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('regenerateQrButton')));
    await tester.tap(find.byKey(const Key('regenerateQrButton')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('qrPayloadField')), findsOneWidget);
  });

  testWidgets('Tunnel error message is shown after scan', (tester) async {
    await tester.pumpWidget(
      const VibeInspectApp(
        storageInitializer: MemoryStorageInitializer(),
        forceManualQr: true,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('scanQrButton')));
    await tester.pumpAndSettle();

    final payload = jsonEncode({
      'token': 'NEW456',
      'secret': 'SECRET',
      'expires_at':
          DateTime.now()
              .add(const Duration(minutes: 2))
              .millisecondsSinceEpoch ~/
          1000,
      'tunnel_error':
          'Cloudflared is not installed. Install it and retry pairing.',
    });

    await tester.enterText(find.byKey(const Key('qrPayloadField')), payload);
    await tester.tap(find.byKey(const Key('applyQrButton')));
    await pumpUntilFound(
      tester,
      find.textContaining('Cloudflared is not installed'),
    );

    expect(find.textContaining('Cloudflared is not installed'), findsWidgets);
  });

  testWidgets('Storage initialization failure blocks the UI', (tester) async {
    await tester.pumpWidget(
      const VibeInspectApp(
        storageInitializer: _FailingStorageInitializer(),
        forceManualQr: true,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Storage unavailable'), findsOneWidget);
  });

  testWidgets('Workspace API session opens API explorer', (tester) async {
    final now = DateTime.now();
    const apiEventId = 'api-event-1';
    const apiSessionId = 'api-session-1';
    const agentId = 'agent-1';
    final initializer = _SeededStorageInitializer((storage) async {
      await storage.insertConnection(
        ConnectionRecord(
          id: agentId,
          token: 'TOKEN-1',
          status: 'connected',
          connectedAt: now,
          hostName: 'agent.local',
          agentUrl: 'https://agent.local',
          lastSeenAt: now,
        ),
      );
      await storage.insertToolSession(
        ToolSession(
          id: apiSessionId,
          type: 'api',
          label: 'Login API',
          status: 'complete',
          agentId: agentId,
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
      VibeInspectApp(
        storageInitializer: initializer,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    final agentFinder = find.text('agent.local');
    await tester.ensureVisible(agentFinder);
    await tester.tap(agentFinder);
    await tester.pumpAndSettle();

    final apiSessionFinder = find.text('Login API');
    await tester.ensureVisible(apiSessionFinder);
    await tester.tap(apiSessionFinder);
    await tester.pumpAndSettle();

    expect(find.text('API Explorer'), findsOneWidget);
    expect(find.text('POST'), findsWidgets);
    expect(find.text('https://api.example.com/login'), findsWidgets);
    expect(find.textContaining('Status 500'), findsOneWidget);
  });

  testWidgets('Workspace terminal session opens session', (tester) async {
    final now = DateTime.now();
    const terminalEventId = 'terminal-event-1';
    const terminalSessionId = 'terminal-session-1';
    const agentId = 'agent-2';
    final initializer = _SeededStorageInitializer((storage) async {
      await storage.insertConnection(
        ConnectionRecord(
          id: agentId,
          token: 'TOKEN-2',
          status: 'connected',
          connectedAt: now,
          hostName: 'terminal.agent',
          agentUrl: 'https://terminal.agent',
          lastSeenAt: now,
        ),
      );
      await storage.insertToolSession(
        ToolSession(
          id: terminalSessionId,
          type: 'terminal',
          label: 'Build logs',
          status: 'running',
          agentId: agentId,
          createdAt: now,
        ),
      );
      await storage.insertTimelineEvent(
        TimelineEvent(
          id: terminalEventId,
          sessionId: terminalSessionId,
          type: 'terminal',
          title: 'npm test',
          payload: {'command': 'npm test', 'output_preview': '1 failing test'},
          createdAt: now,
        ),
      );
    });

    await tester.pumpWidget(
      VibeInspectApp(
        storageInitializer: initializer,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    final agentFinder = find.text('terminal.agent');
    await tester.ensureVisible(agentFinder);
    await tester.tap(agentFinder);
    await tester.pumpAndSettle();

    final terminalSessionFinder = find.text('Build logs');
    await tester.ensureVisible(terminalSessionFinder);
    await tester.tap(terminalSessionFinder);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back'), findsOneWidget);
    expect(find.byTooltip('Show terminal controls'), findsOneWidget);
    expect(find.byType(TerminalView), findsOneWidget);
  });

  testWidgets('API Explorer blocks invalid JSON body', (tester) async {
    final now = DateTime.now();
    const agentId = 'agent-3';
    final initializer = _SeededStorageInitializer((storage) async {
      await storage.insertConnection(
        ConnectionRecord(
          id: agentId,
          token: 'TOKEN-3',
          status: 'connected',
          connectedAt: now,
          hostName: 'api.agent',
          agentUrl: 'https://api.agent',
          lastSeenAt: now,
        ),
      );
    });

    await tester.pumpWidget(
      VibeInspectApp(
        storageInitializer: initializer,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    final agentFinder = find.text('api.agent');
    await tester.ensureVisible(agentFinder);
    await tester.tap(agentFinder);
    await tester.pumpAndSettle();

    final newApiFinder = find.text('New API request');
    await tester.ensureVisible(newApiFinder);
    await tester.tap(newApiFinder);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('apiBodyField')),
      '{ invalid json',
    );
    final sendButton = find.byKey(const Key('apiSendButton'));
    await tester.ensureVisible(sendButton);
    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(find.text('Body must be valid JSON.'), findsOneWidget);
  });

  testWidgets('Workspace session with missing context shows error state', (
    tester,
  ) async {
    final now = DateTime.now();
    const brokenEventId = 'api-event-missing';
    const apiSessionId = 'api-session-missing';
    const agentId = 'agent-4';
    final initializer = _SeededStorageInitializer((storage) async {
      await storage.insertConnection(
        ConnectionRecord(
          id: agentId,
          token: 'TOKEN-4',
          status: 'connected',
          connectedAt: now,
          hostName: 'broken.agent',
          agentUrl: 'https://broken.agent',
          lastSeenAt: now,
        ),
      );
      await storage.insertToolSession(
        ToolSession(
          id: apiSessionId,
          type: 'api',
          label: 'Broken API',
          status: 'error',
          agentId: agentId,
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
      VibeInspectApp(
        storageInitializer: initializer,
        enableConnectivityRefresh: false,
        enableNetworkHints: false,
      ),
    );
    await tester.pumpAndSettle();

    final agentFinder = find.text('broken.agent');
    await tester.ensureVisible(agentFinder);
    await tester.tap(agentFinder);
    await tester.pumpAndSettle();

    final brokenSessionFinder = find.text('Broken API');
    await tester.ensureVisible(brokenSessionFinder);
    await tester.tap(brokenSessionFinder);
    await tester.pumpAndSettle();

    expect(find.textContaining('API context is missing'), findsOneWidget);
  });

  test('Agent terminal action prefers input_b64 for multibyte payload', () async {
    final requests = <Map<String, dynamic>>[];
    final mockClient = MockClient((request) async {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      requests.add(body);
      return http.Response(
        jsonEncode({
          'request_id': body['request_id'] ?? 'req-1',
          'status': 'ok',
          'payload': {
            'type': 'terminal',
            'action': 'input',
            'status': 'running',
          },
        }),
        200,
      );
    });

    final client = AgentCommandClient(
      baseUrl: 'https://terminal.agent',
      client: mockClient,
      authToken: 'TOKEN',
    );

    final bytes = utf8.encode('中文输入✓🚀');
    await client.sendTerminalAction(
      action: 'input',
      sessionId: 'session-1',
      input: 'ignored',
      inputBytes: bytes,
    );

    expect(requests, isNotEmpty);
    final payload = requests.single['payload'] as Map<String, dynamic>;
    expect(payload['action'], 'input');
    expect(payload['session_id'], 'session-1');
    expect(payload.containsKey('input'), isFalse);
    expect(payload['input_b64'], base64Encode(bytes));
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
