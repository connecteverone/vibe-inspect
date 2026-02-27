import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';

Widget _buildMenuButton({
  VoidCallback? onKeyboard,
  bool showKeyboardAction = true,
  bool keyboardVisible = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: RustdeskMoreMenuButton(
          onKeyboard: onKeyboard,
          showKeyboardAction: showKeyboardAction,
          keyboardVisible: keyboardVisible,
          onExitFullscreen: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('RustDesk icon button triggers callback', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RustdeskIconButton(
              icon: Icons.keyboard,
              onPressed: () => tapped += 1,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.keyboard));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('RustDesk more menu shows keyboard label by visibility state', (
    tester,
  ) async {
    await tester.pumpWidget(
      _buildMenuButton(onKeyboard: () {}, keyboardVisible: false),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Keyboard input'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _buildMenuButton(onKeyboard: () {}, keyboardVisible: true),
    );
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    expect(find.text('Hide keyboard input'), findsOneWidget);
  });

  testWidgets('RustDesk more menu can hide keyboard action item', (
    tester,
  ) async {
    await tester.pumpWidget(_buildMenuButton(showKeyboardAction: false));
    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Keyboard input'), findsNothing);
    expect(find.text('Hide keyboard input'), findsNothing);
    expect(find.text('Exit fullscreen mode'), findsOneWidget);
  });

  testWidgets('RustDesk more menu actions trigger callbacks', (tester) async {
    var keyboardTapCount = 0;
    var exitTapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: RustdeskMoreMenuButton(
              onKeyboard: () => keyboardTapCount += 1,
              showKeyboardAction: true,
              keyboardVisible: false,
              onExitFullscreen: () => exitTapCount += 1,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keyboard input'));
    await tester.pumpAndSettle();
    expect(keyboardTapCount, 1);
    expect(exitTapCount, 0);

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Exit fullscreen mode'));
    await tester.pumpAndSettle();
    expect(keyboardTapCount, 1);
    expect(exitTapCount, 1);
  });

  testWidgets('RustDesk mouse button triggers down and up callbacks', (
    tester,
  ) async {
    var downTapCount = 0;
    var upTapCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: RustdeskMouseButton(
                label: 'Left click',
                onDown: () => downTapCount += 1,
                onUp: () => upTapCount += 1,
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Left click'));
    await tester.pumpAndSettle();

    expect(downTapCount, 1);
    expect(upTapCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RustDesk more menu has no layout overflow in narrow width', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: RustdeskMoreMenuButton(
                onKeyboard: () {},
                showKeyboardAction: true,
                keyboardVisible: true,
                onExitFullscreen: () {},
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byIcon(Icons.more_horiz));
    await tester.pumpAndSettle();

    expect(find.text('Hide keyboard input'), findsOneWidget);
    expect(find.text('Exit fullscreen mode'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
