import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:archive/archive.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/storage/local_storage.dart';
import 'package:mobile/roi/roi_client.dart';
import 'package:mobile/roi/roi_models.dart';
import 'package:mobile/roi/roi_quic_client.dart';
import 'package:mobile/roi/roi_renderer.dart';
import 'package:mobile/app/terminal_input_policy.dart';
import 'package:mobile/app/terminal_output_sanitizer.dart';
import 'package:mobile/remote/media_protocol.dart';
import 'package:mobile/remote/cursor_motion_filter.dart';
import 'package:mobile/remote/remote_quic_client.dart';
import 'package:mobile/remote/rustdesk_bridge.dart';
import 'package:mobile/remote/trackpad_motion_engine.dart';
import 'package:mobile/remote/trackpad_scroll_behavior.dart';
import 'package:mobile/remote/remote_reconnect_policy.dart';
import 'package:mobile/vnc_client.dart';
import 'package:mobile/vnc/vnc_quic_transport.dart';
import 'package:uuid/uuid.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import 'package:mobile/utils/network_io_stub.dart'
    if (dart.library.io) 'package:mobile/utils/network_io.dart';

part 'vnc/vnc_session_screen.dart';
part 'vnc/vnc_session_input.dart';
part 'vnc/vnc_session_roi.dart';
part 'vnc/vnc_session_ui.dart';
part 'vnc/vnc_widgets.dart';
part 'app/agent_models.dart';
part 'app/api_explorer.dart';
part 'app/feature_flags.dart';
part 'app/pairing.dart';
part 'app/qr_scanner.dart';
part 'app/agent_workspace.dart';
part 'app/terminal_models.dart';
part 'app/terminal_workspace.dart';
part 'app/terminal_workspace_logic.dart';
part 'app/terminal_workspace_stream.dart';
part 'app/terminal_session.dart';
part 'remote/remote_session_screen.dart';
part 'remote/media_v2_view.dart';
part 'remote/rustdesk_controls.dart';
part 'remote/rustdesk_input.dart';
part 'remote/rustdesk_keyboard.dart';
part 'remote/rustdesk_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = !kIsWeb;
  if (kIsWeb) {
    RendererBinding.instance.ensureSemantics();
  }
  final storageInitializer = kIsWeb
      ? const MemoryStorageInitializer()
      : const LocalStorageInitializer();
  runApp(VibeInspectApp(storageInitializer: storageInitializer));
}

ThemeData _buildTheme() {
  const primary = Color(0xFF1E293B);
  const secondary = Color(0xFF22C55E);
  const surface = Color(0xFFFFFFFF);
  const background = Color(0xFFF8FAFC);
  const onSurface = Color(0xFF0F172A);
  const onPrimary = Color(0xFFF8FAFC);
  const onSecondary = Color(0xFF052E16);
  const error = Color(0xFFB91C1C);

  final baseTextTheme = GoogleFonts.ibmPlexSansTextTheme();
  final headingTextTheme = GoogleFonts.jetBrainsMonoTextTheme();
  final textTheme = baseTextTheme.copyWith(
    displayLarge: headingTextTheme.displayLarge,
    displayMedium: headingTextTheme.displayMedium,
    displaySmall: headingTextTheme.displaySmall,
    headlineLarge: headingTextTheme.headlineLarge,
    headlineMedium: headingTextTheme.headlineMedium,
    headlineSmall: headingTextTheme.headlineSmall,
    titleLarge: headingTextTheme.titleLarge,
    titleMedium: headingTextTheme.titleMedium,
    titleSmall: headingTextTheme.titleSmall,
  );

  final scheme = const ColorScheme(
    brightness: Brightness.light,
    primary: primary,
    onPrimary: onPrimary,
    secondary: secondary,
    onSecondary: onSecondary,
    tertiary: Color(0xFF38BDF8),
    onTertiary: onSurface,
    error: error,
    onError: onPrimary,
    surface: surface,
    onSurface: onSurface,
  );

  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    scaffoldBackgroundColor: background,
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      foregroundColor: onSurface,
      elevation: 0,
      centerTitle: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: secondary,
        foregroundColor: onPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        textStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: primary,
        side: const BorderSide(color: Color(0xFFE2E8F0)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFF1F5F9),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: primary, width: 1.5),
      ),
      hintStyle: textTheme.bodyMedium?.copyWith(color: const Color(0xFF64748B)),
    ),
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFFF1F5F9),
      selectedColor: const Color(0xFFBBF7D0),
      labelStyle: textTheme.labelMedium?.copyWith(
        color: onSurface,
        fontWeight: FontWeight.w600,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: Color(0xFF0F172A),
      contentTextStyle: TextStyle(color: Colors.white),
    ),
  );
}

class VibeInspectApp extends StatelessWidget {
  const VibeInspectApp({
    super.key,
    required this.storageInitializer,
    this.pairingHttpClient,
    this.forceManualQr = false,
    this.enableConnectivityRefresh = true,
    this.enableNetworkHints = true,
  });

  final StorageInitializer storageInitializer;
  final http.Client? pairingHttpClient;
  final bool forceManualQr;
  final bool enableConnectivityRefresh;
  final bool enableNetworkHints;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vibe Inspect',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(),
      home: StorageGate(
        storageInitializer: storageInitializer,
        pairingHttpClient: pairingHttpClient,
        forceManualQr: forceManualQr,
        enableConnectivityRefresh: enableConnectivityRefresh,
        enableNetworkHints: enableNetworkHints,
      ),
    );
  }
}

class StorageGate extends StatefulWidget {
  const StorageGate({
    super.key,
    required this.storageInitializer,
    this.pairingHttpClient,
    this.forceManualQr = false,
    this.enableConnectivityRefresh = true,
    this.enableNetworkHints = true,
  });

  final StorageInitializer storageInitializer;
  final http.Client? pairingHttpClient;
  final bool forceManualQr;
  final bool enableConnectivityRefresh;
  final bool enableNetworkHints;

  @override
  State<StorageGate> createState() => _StorageGateState();
}

class _StorageGateState extends State<StorageGate> {
  late Future<StorageRepository> _storageFuture;

  @override
  void initState() {
    super.initState();
    _storageFuture = widget.storageInitializer.initialize();
  }

  void _retryInitialization() {
    setState(() {
      _storageFuture = widget.storageInitializer.initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<StorageRepository>(
      future: _storageFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const StorageLoadingScreen();
        }
        if (snapshot.hasError) {
          return StorageErrorScreen(
            error: snapshot.error,
            onRetry: _retryInitialization,
          );
        }
        final storage = snapshot.data;
        if (storage == null) {
          return const StorageErrorScreen(error: 'Storage failed to load.');
        }
        return PairingScreen(
          storage: storage,
          pairingHttpClient: widget.pairingHttpClient,
          forceManualQr: widget.forceManualQr,
          enableConnectivityRefresh: widget.enableConnectivityRefresh,
          enableNetworkHints: widget.enableNetworkHints,
        );
      },
    );
  }
}

class StorageLoadingScreen extends StatelessWidget {
  const StorageLoadingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

class StorageErrorScreen extends StatelessWidget {
  const StorageErrorScreen({super.key, required this.error, this.onRetry});

  final Object? error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.storage_rounded,
              size: 56,
              color: Color(0xFFB91C1C),
            ),
            const SizedBox(height: 16),
            Text(
              'Storage unavailable',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Local history could not be initialized. Restart the app or retry '
              'after checking device storage permissions.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF475569)),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(
                error.toString(),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF991B1B),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: onRetry,
                child: const Text('Retry initialization'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
