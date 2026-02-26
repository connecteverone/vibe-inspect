import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';
import 'package:mobile/remote/rustdesk_bridge.dart';

class _RecordedKeyCall {
  const _RecordedKeyCall({
    required this.sessionId,
    required this.name,
    required this.press,
    required this.alt,
    required this.ctrl,
    required this.shift,
    required this.command,
  });

  final String sessionId;
  final String name;
  final bool press;
  final bool alt;
  final bool ctrl;
  final bool shift;
  final bool command;
}

class _RecordingRustdeskBridge implements RustdeskBridge {
  final List<_RecordedKeyCall> keyCalls = <_RecordedKeyCall>[];

  @override
  void sessionInputKey(
    String sessionId, {
    required String name,
    bool down = false,
    bool press = true,
    bool alt = false,
    bool ctrl = false,
    bool shift = false,
    bool command = false,
  }) {
    keyCalls.add(
      _RecordedKeyCall(
        sessionId: sessionId,
        name: name,
        press: press,
        alt: alt,
        ctrl: ctrl,
        shift: shift,
        command: command,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'RustDesk keyboard header scrolls with special keys in compact height',
    (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      final input = RustdeskInputController(bridge: RustdeskBridge.instance);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                height: 220,
                child: RustdeskKeyboardPanel(
                  input: input,
                  controller: controller,
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Backspace'), findsOneWidget);
      expect(find.text('Enter'), findsOneWidget);
      expect(find.text('Tab'), findsOneWidget);
      expect(find.text('Command'), findsOneWidget);
      expect(find.text('Option'), findsOneWidget);

      final scrollable = find.byType(SingleChildScrollView);
      expect(scrollable, findsOneWidget);

      final keyboardTitle = find.text('Keyboard input');
      expect(keyboardTitle, findsOneWidget);
      final titleTopBefore = tester.getTopLeft(keyboardTitle).dy;

      await tester.drag(scrollable, const Offset(0, -120));
      await tester.pumpAndSettle();

      final titleTopAfter = tester.getTopLeft(keyboardTitle).dy;
      expect(titleTopAfter, lessThan(titleTopBefore - 20));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Command Option Ctrl buttons dispatch expected key names', (
    tester,
  ) async {
    final bridge = _RecordingRustdeskBridge();
    final input = RustdeskInputController(bridge: bridge)
      ..attachSession('session-1');
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 360,
              height: 260,
              child: RustdeskKeyboardPanel(
                input: input,
                controller: controller,
                onClose: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> tapSpecialKey(String label) async {
      final finder = find.text(label);
      expect(finder, findsOneWidget);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump();
    }

    await tapSpecialKey('Command');
    await tapSpecialKey('Option');
    await tapSpecialKey('Ctrl');
    await tapSpecialKey('Ctrl+Alt+Del');

    expect(bridge.keyCalls, hasLength(4));
    expect(
      bridge.keyCalls.map((call) => call.name).toList(),
      equals(<String>['Meta', 'RAlt', 'VK_CONTROL', 'VK_DELETE']),
    );

    final ctrlAltDelCall = bridge.keyCalls.last;
    expect(ctrlAltDelCall.sessionId, 'session-1');
    expect(ctrlAltDelCall.press, isTrue);
    expect(ctrlAltDelCall.alt, isTrue);
    expect(ctrlAltDelCall.ctrl, isTrue);
    expect(ctrlAltDelCall.shift, isFalse);
    expect(ctrlAltDelCall.command, isFalse);
  });
}
