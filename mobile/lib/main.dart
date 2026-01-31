import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:mobile/storage/local_storage.dart';
import 'package:mobile/roi/roi_client.dart';
import 'package:mobile/roi/roi_models.dart';
import 'package:mobile/roi/roi_quic_client.dart';
import 'package:mobile/roi/roi_renderer.dart';
import 'package:mobile/vnc_client.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';
import 'package:mobile/utils/network_io_stub.dart'
    if (dart.library.io) 'package:mobile/utils/network_io.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = !kIsWeb;
  if (kIsWeb) {
    RendererBinding.instance.ensureSemantics();
  }
  final storageInitializer =
      kIsWeb ? const MemoryStorageInitializer() : const LocalStorageInitializer();
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: primary,
        side: const BorderSide(color: Color(0xFFE2E8F0)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
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
      hintStyle: textTheme.bodyMedium?.copyWith(
        color: const Color(0xFF64748B),
      ),
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
          return const StorageErrorScreen(
            error: 'Storage failed to load.',
          );
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
    return const Scaffold(
      body: Center(
        child: CircularProgressIndicator(),
      ),
    );
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
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF475569),
                  ),
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

class PairingScreen extends StatefulWidget {
  const PairingScreen({
    super.key,
    required this.storage,
    this.pairingHttpClient,
    this.forceManualQr = false,
    this.enableConnectivityRefresh = true,
    this.enableNetworkHints = true,
  });

  final StorageRepository storage;
  final http.Client? pairingHttpClient;
  final bool forceManualQr;
  final bool enableConnectivityRefresh;
  final bool enableNetworkHints;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  PairingPayload? _payload;
  String? _scanError;
  String? _pairingStatus;
  bool _pairingStatusIsError = false;
  String? _pairingDetailStatus;
  bool _pairingDetailStatusIsError = false;
  String? _manualAgentUrl;
  String? _clientId;
  bool _isPairing = false;
  Timer? _pairingPoller;
  String? _pairingAgentUrl;
  bool? _pairingUsesTunnel;
  http.Client? _pairingClient;
  bool _ownsPairingClient = false;
  bool _forceTunnel = false;
  bool _isPendingPollActive = false;
  bool _isRefreshingAgents = false;
  List<ConnectionRecord> _connections = [];
  Map<String, String> _agentProbeErrors = {};
  String? _activeAgentId;
  String? _exportStatus;
  bool _exportStatusIsError = false;
  String? _importStatus;
  bool _importStatusIsError = false;
  static const String _clientIdStorageKey = 'mobile_client_id';

  @override
  void initState() {
    super.initState();
    _pairingClient = widget.pairingHttpClient ?? http.Client();
    _ownsPairingClient = widget.pairingHttpClient == null;
    _ensureClientId();
    _loadHistory();
  }

  @override
  void dispose() {
    _pairingPoller?.cancel();
    if (_ownsPairingClient) {
      _pairingClient?.close();
    }
    super.dispose();
  }

  Future<void> _scanQrPayload() async {
    if (widget.forceManualQr ||
        kIsWeb ||
        !(defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      final manual = await _promptQrPayloadInput();
      if (manual == null) {
        return;
      }
      await _applyQrPayload(manual);
      return;
    }

    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => const _QrScannerScreen(),
      ),
    );
    if (scanned == null) {
      return;
    }
    await _applyQrPayload(scanned);
  }

  void _selectManualAgentUrl(String url) {
    setState(() {
      _manualAgentUrl = _normalizeManualUrl(url);
    });
    unawaited(_retryPairing());
  }

  void _clearManualAgentUrl() {
    setState(() {
      _manualAgentUrl = null;
    });
  }

  Future<String?> _promptQrPayloadInput() async {
    final controller = TextEditingController();
    final payload = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Enter pairing token'),
          content: TextField(
            key: const Key('qrPayloadField'),
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Paste QR payload JSON or vibeinspect:// URL',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('applyQrButton'),
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Add token'),
            ),
          ],
        );
      },
    );
    return payload;
  }

  Future<_ManualLoginInput?> _promptFixedTokenInput() async {
    final urlController = TextEditingController(text: _manualAgentUrl ?? '');
    final tokenController = TextEditingController();
    final result = await showDialog<_ManualLoginInput>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Connect with fixed token'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: urlController,
                decoration: const InputDecoration(
                  labelText: 'Agent URL',
                  hintText: 'https://agent.local:8080',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(
                  labelText: 'Fixed token',
                  hintText: 'Paste the login token from desktop',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                _ManualLoginInput(
                  url: urlController.text,
                  token: tokenController.text,
                ),
              ),
              child: const Text('Connect'),
            ),
          ],
        );
      },
    );
    return result;
  }

  Future<void> _connectWithFixedToken() async {
    final input = await _promptFixedTokenInput();
    if (input == null) {
      return;
    }
    final url = _normalizeManualUrl(input.url);
    final token = input.token.trim();
    if (url.isEmpty || token.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Agent URL and token are required.')),
      );
      return;
    }
    setState(() {
      _pairingStatus = 'Connecting with fixed token...';
      _pairingStatusIsError = false;
      _pairingDetailStatus = null;
      _pairingDetailStatusIsError = false;
    });
    final httpClient = http.Client();
    try {
      final client = AgentCommandClient(
        baseUrl: url,
        client: httpClient,
        authToken: token,
        clientId: _clientId,
        clientName: _resolveDeviceName(),
      );
      final identity = await client.fetchIdentity();
      final deviceId = identity['device_id']?.toString();
      final hostName =
          identity['host_name']?.toString() ?? identity['hostName']?.toString();
      await _recordManualConnection(
        agentUrl: url,
        authToken: token,
        deviceId: deviceId,
        hostName: hostName,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _pairingStatus = 'Connected using fixed token.';
        _pairingStatusIsError = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _pairingStatus = 'Failed to connect with fixed token.';
        _pairingStatusIsError = true;
        _pairingDetailStatus = error.toString();
        _pairingDetailStatusIsError = true;
      });
    } finally {
      httpClient.close();
    }
  }

  Future<void> _applyQrPayload(String raw) async {
    final parsed = PairingPayload.tryParse(raw);
    _pairingPoller?.cancel();
    setState(() {
      _payload = parsed;
      _scanError = parsed == null ? 'Invalid QR payload.' : null;
      _pairingStatus = null;
      _pairingStatusIsError = false;
      _pairingDetailStatus = null;
      _pairingDetailStatusIsError = false;
      _manualAgentUrl = null;
      _isPairing = false;
      _pairingAgentUrl = null;
      _pairingUsesTunnel = null;
      if (parsed != null && parsed.isExpired) {
        _scanError = 'Token expired. Request a new token and retry.';
      }
    });
    if (parsed != null && !parsed.isExpired) {
      await _attemptAutoPairing(parsed);
    }
  }

  Future<void> _attemptAutoPairing(PairingPayload payload) async {
    if (_isPairing) {
      return;
    }
    setState(() {
      _isPairing = true;
      _pairingStatus = 'Contacting the desktop agent...';
      _pairingStatusIsError = false;
      _pairingDetailStatus = null;
      _pairingDetailStatusIsError = false;
    });
    final result = await _confirmPairingWithUrls(payload);
    if (!mounted) {
      return;
    }
    switch (result.status) {
      case _PairingAttemptStatus.connected:
        await _completePairing(
          payload,
          result.agentUrl!,
          authToken: result.authToken,
          deviceId: result.deviceId,
        );
        break;
      case _PairingAttemptStatus.pending:
        _pairingPoller?.cancel();
        setState(() {
          _isPairing = false;
          _pairingAgentUrl = result.agentUrl;
          _pairingUsesTunnel =
              result.agentUrl == null ? null : _isTunnelUrl(payload, result.agentUrl!);
          _pairingStatus = 'Waiting for desktop approval.';
          _pairingStatusIsError = false;
          _pairingDetailStatus = null;
          _pairingDetailStatusIsError = false;
        });
        _startPendingPolling(payload, result.agentUrl!);
        break;
      case _PairingAttemptStatus.failed:
        setState(() {
          _isPairing = false;
          _pairingStatus =
              result.message ?? 'Unable to reach the desktop agent.';
          _pairingStatusIsError = true;
          _pairingUsesTunnel = null;
          _pairingDetailStatus = result.detail;
          _pairingDetailStatusIsError =
              result.detail != null && result.detail!.trim().isNotEmpty;
        });
        break;
    }
  }

  Future<void> _retryPairing() async {
    final payload = _payload;
    if (payload == null) {
      if (widget.enableConnectivityRefresh) {
        await _refreshAgentConnectivity();
      }
      return;
    }
    if (payload.isExpired) {
      setState(() {
        _scanError = 'Token expired. Request a new token and retry.';
      });
      if (widget.enableConnectivityRefresh) {
        await _refreshAgentConnectivity();
      }
      return;
    }
    await _attemptAutoPairing(payload);
    if (widget.enableConnectivityRefresh) {
      await _refreshAgentConnectivity();
    }
  }

  void _startPendingPolling(PairingPayload payload, String agentUrl) {
    _pairingPoller?.cancel();
    _pairingPoller =
        Timer.periodic(const Duration(seconds: 2), (_) async {
      await _pollPendingPairing(payload, agentUrl);
    });
  }

  Future<void> _pollPendingPairing(
    PairingPayload payload,
    String agentUrl,
  ) async {
    if (_isPairing) {
      return;
    }
    if (payload.isExpired) {
      _pairingPoller?.cancel();
      if (mounted) {
        setState(() {
          _pairingStatus = 'Token expired. Request a new token and retry.';
          _pairingStatusIsError = true;
        });
      }
      return;
    }
    if (_isPendingPollActive) {
      return;
    }
    _isPendingPollActive = true;
    try {
      final result = await _confirmPairingAtUrl(payload, agentUrl);
      if (!mounted) {
        return;
      }
      if (result.status == _PairingAttemptStatus.connected) {
        await _completePairing(
          payload,
          agentUrl,
          authToken: result.authToken,
          deviceId: result.deviceId,
        );
        return;
      }
      if (result.status == _PairingAttemptStatus.failed) {
        _pairingPoller?.cancel();
        setState(() {
          _pairingStatus =
              result.message ?? 'Desktop approval check failed.';
          _pairingStatusIsError = true;
          _pairingDetailStatus = result.detail;
          _pairingDetailStatusIsError =
              result.detail != null && result.detail!.trim().isNotEmpty;
        });
      }
    } finally {
      _isPendingPollActive = false;
    }
  }

  Future<void> _completePairing(
    PairingPayload payload,
    String agentUrl,
    {String? authToken, String? deviceId}
  ) async {
    _pairingPoller?.cancel();
    final resolvedToken = authToken?.trim();
    if (resolvedToken == null || resolvedToken.isEmpty) {
      if (mounted) {
        setState(() {
          _pairingStatus =
              'Desktop approval required. Ask the desktop to approve and re-scan.';
          _pairingStatusIsError = true;
          _isPairing = false;
        });
      }
      return;
    }
    final resolvedDeviceId = deviceId ??
        (payload.deviceId?.trim().isNotEmpty == true ? payload.deviceId : null);
    setState(() {
      _pairingAgentUrl = agentUrl;
      _pairingUsesTunnel = _isTunnelUrl(payload, agentUrl);
      _pairingStatus = 'Connected.';
      _pairingStatusIsError = false;
      _isPairing = false;
      _pairingDetailStatus = null;
      _pairingDetailStatusIsError = false;
    });
    await _recordPairingEvent(
      payload,
      agentUrl,
      authToken: resolvedToken,
      deviceId: resolvedDeviceId,
    );
  }

  Future<_PairingAttemptResult> _confirmPairingWithUrls(
    PairingPayload payload,
  ) async {
    final selection = await _selectPairingCandidates(payload);
    final candidates = selection.candidates;
    if (candidates.isEmpty) {
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: selection.message ??
            payload.tunnelError ??
            'No desktop URL found in the pairing payload.',
        detail: selection.detail,
      );
    }
    final errors = <String>[];
    final attemptDetails = <String>[];
    for (final url in candidates) {
      final result = await _confirmPairingAtUrl(payload, url);
      if (result.status != _PairingAttemptStatus.failed) {
        return result;
      }
      if (result.message != null) {
        errors.add(result.message!);
      }
      attemptDetails.add(_formatAttemptDetail(url, result.message));
    }
    final detail = _mergePairingDetails(selection.detail, attemptDetails);
    return _PairingAttemptResult(
      status: _PairingAttemptStatus.failed,
      message: errors.isNotEmpty
          ? errors.first
          : 'Unable to reach the desktop agent.',
      detail: detail,
    );
  }

  Future<_PairingCandidateSelection> _selectPairingCandidates(
    PairingPayload payload,
  ) async {
    final tunnelUrl = payload.tunnelUrl?.trim() ?? '';
    final frpUrl = payload.frpUrl?.trim() ?? '';
    final remoteUrls = <String>[
      if (tunnelUrl.isNotEmpty) tunnelUrl,
      if (frpUrl.isNotEmpty && frpUrl != tunnelUrl) frpUrl,
    ];
    final localUrls = payload.localUrls;
    final manualUrl = _manualAgentUrl?.trim();
    final currentSsid = await _currentWifiSsid();
    final currentIps = await _currentLocalIps();
    final sameLan = _isSameLan(
      agentSsid: payload.wifiSsid,
      agentIps: payload.localIps,
      currentSsid: currentSsid,
      currentIps: currentIps,
      allowUnknown: true,
    );
    if (manualUrl != null && manualUrl.isNotEmpty && !_forceTunnel) {
      final normalizedManual = _normalizeManualUrl(manualUrl);
      final rest = localUrls
          .where((url) => _normalizeManualUrl(url) != normalizedManual)
          .toList();
      final candidates = <String>[
        normalizedManual,
        ...rest,
        ...remoteUrls,
      ];
      return _PairingCandidateSelection(
        candidates: candidates,
        message: 'Using manually selected endpoint.',
      );
    }
    if (_forceTunnel) {
      if (remoteUrls.isNotEmpty) {
        return _PairingCandidateSelection(candidates: remoteUrls);
      }
      final message = payload.tunnelError != null &&
              payload.tunnelError!.trim().isNotEmpty
          ? payload.tunnelError!
          : 'Remote URL unavailable. Disable "Force tunnel" or add an FRP URL.';
      return _PairingCandidateSelection(candidates: const [], message: message);
    }

    if (localUrls.isNotEmpty) {
      if (!sameLan) {
        return _PairingCandidateSelection(
          candidates: remoteUrls,
          message: remoteUrls.isNotEmpty
              ? 'SSID/subnet mismatch. Trying public endpoint.'
              : 'SSID/subnet mismatch. No public endpoint available.',
        );
      }
      final diagnostics = await _probeLocalUrls(
        localUrls,
        timeout: const Duration(seconds: 2),
      );
      final reachable = diagnostics
          .where((result) => result.reachable)
          .map((result) => result.url)
          .toList();
      final localDetail = _formatLocalDiagnostics(diagnostics);
      final candidates = <String>[
        if (reachable.isNotEmpty) ...reachable else ...localUrls,
        ...remoteUrls,
      ];
      if (reachable.isNotEmpty) {
        return _PairingCandidateSelection(
          candidates: candidates,
          detail: localDetail,
        );
      }
      return _PairingCandidateSelection(
        candidates: candidates,
        message: remoteUrls.isNotEmpty
            ? 'Local health check failed. Trying LAN first, then tunnel.'
            : 'Local health check failed. Trying LAN endpoints directly.',
        detail: localDetail,
      );
    }

    if (remoteUrls.isNotEmpty) {
      return _PairingCandidateSelection(candidates: remoteUrls);
    }

    final fallbackMessage = payload.tunnelError != null &&
            payload.tunnelError!.trim().isNotEmpty
        ? payload.tunnelError!
        : 'No desktop URL found in the pairing payload.';
    return _PairingCandidateSelection(
      candidates: const [],
      message: fallbackMessage,
    );
  }

  Future<List<_ReachabilityResult>> _probeLocalUrls(
    List<String> localUrls, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    final results = await Future.wait(
      localUrls.map((url) => _probeLocalUrl(url, timeout: timeout)),
    );
    return results;
  }

  Future<_ReachabilityResult> _probeLocalUrl(
    String baseUrl, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    return _probeUrl(baseUrl, timeout);
  }

  String _formatAttemptDetail(String url, String? message) {
    final label = _shortUrlLabel(url);
    final requestLabel = _appendPath(url, '/pairing/confirm');
    final reason = message == null || message.trim().isEmpty ? 'Failed.' : message;
    return '- $label ($requestLabel): $reason';
  }

  String? _mergePairingDetails(String? base, List<String> attempts) {
    final parts = <String>[];
    if (base != null && base.trim().isNotEmpty) {
      parts.add(base.trim());
    }
    if (attempts.isNotEmpty) {
      parts.add('Tried endpoints:\n${attempts.join('\n')}');
    }
    if (parts.isEmpty) {
      return null;
    }
    return parts.join('\n\n');
  }

  String _formatLocalDiagnostics(List<_ReachabilityResult> diagnostics) {
    final lines = diagnostics.map((result) {
      final label = _shortUrlLabel(result.url);
      final requestLabel = _appendPath(result.url, '/health');
      final reason = result.reason ?? 'Unreachable.';
      return '- $label ($requestLabel): $reason';
    }).join('\n');
    return [
      'Local checks:',
      lines,
      'Tips: ensure same Wi-Fi, allow local network permission, disable AP isolation, and allow the desktop firewall port.',
    ].join('\n');
  }

  String _shortUrlLabel(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) {
      return url;
    }
    if (uri.hasPort) {
      return '${uri.host}:${uri.port}';
    }
    return uri.host;
  }

  String _normalizeManualUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    final parsed = Uri.tryParse(trimmed);
    if (parsed != null && parsed.hasScheme) {
      return trimmed;
    }
    return 'http://$trimmed';
  }

  String _appendPath(String baseUrl, String path) {
    final normalized = _normalizeManualUrl(baseUrl);
    final base = Uri.tryParse(normalized);
    if (base == null) {
      return normalized + path;
    }
    final basePath =
        base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final nextPath = basePath.isEmpty ? path : '$basePath$path';
    return base.replace(path: nextPath).toString();
  }

  String _describeReachFailure(String url, Object error) {
    final detail = _describeNetworkError(error);
    if (detail.isEmpty) {
      return 'Failed to reach $url.';
    }
    return 'Failed to reach $url: $detail';
  }

  String _describeNetworkError(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('no route to host') || lower.contains('errno = 65')) {
      return 'No route to host (errno 65). iOS may be blocking local network access for this app. Check Settings > Local Network and disable VPN/Private Relay.';
    }
    if (lower.contains('connection refused') || lower.contains('errno = 61')) {
      return 'Connection refused (errno 61). The host is reachable but the port was rejected by the OS/firewall.';
    }
    if (lower.contains('network is unreachable') || lower.contains('errno = 51')) {
      return 'Network is unreachable (errno 51). The app has no route to the LAN. Check Wi-Fi and local network permission.';
    }
    final socketPrefix = 'SocketException: ';
    final clientPrefix = 'ClientException: ';
    if (raw.startsWith(socketPrefix)) {
      return raw.substring(socketPrefix.length).trim();
    }
    if (raw.startsWith(clientPrefix)) {
      return raw.substring(clientPrefix.length).trim();
    }
    return raw.trim();
  }

  Future<_PairingAttemptResult> _confirmPairingAtUrl(
    PairingPayload payload,
    String baseUrl,
  ) async {
    final client = _pairingClient;
    if (client == null) {
      return const _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: 'Pairing client unavailable.',
      );
    }
    Uri uri;
    try {
      uri = _pairingUri(baseUrl);
    } catch (_) {
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: 'Invalid agent URL: $baseUrl',
        agentUrl: baseUrl,
      );
    }
    http.Response response;
    try {
      response = await client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token': payload.token,
              'secret': payload.secret,
              'client_id': _clientId,
              'client_name': _resolveDeviceName(),
            }),
          )
          .timeout(const Duration(seconds: 4));
    } catch (error) {
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: _describeReachFailure(baseUrl, error),
        agentUrl: baseUrl,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: 'Desktop agent returned HTTP ${response.statusCode}.',
        agentUrl: baseUrl,
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: 'Desktop agent response was not JSON.',
        agentUrl: baseUrl,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: 'Desktop agent response was malformed.',
        agentUrl: baseUrl,
      );
    }

    final status = decoded['status']?.toString();
    if (status == 'connected') {
      final authTokenRaw =
          decoded['auth_token']?.toString().trim() ??
          decoded['authToken']?.toString().trim();
      final resolvedAuthToken =
          authTokenRaw != null && authTokenRaw.isNotEmpty ? authTokenRaw : null;
      if (resolvedAuthToken == null) {
        return _PairingAttemptResult(
          status: _PairingAttemptStatus.failed,
          message:
              'Desktop approval required. Ask the desktop to approve and re-scan.',
          agentUrl: baseUrl,
        );
      }
      final deviceIdRaw =
          decoded['device_id']?.toString().trim() ??
          decoded['deviceId']?.toString().trim();
      final resolvedDeviceId =
          deviceIdRaw != null && deviceIdRaw.isNotEmpty ? deviceIdRaw : null;
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.connected,
        agentUrl: baseUrl,
        authToken: resolvedAuthToken,
        deviceId: resolvedDeviceId,
      );
    }
    if (status == 'pending') {
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.pending,
        agentUrl: baseUrl,
      );
    }
    final error = decoded['error'];
    if (error is Map) {
      final message = error['message']?.toString();
      if (message != null && message.isNotEmpty) {
        return _PairingAttemptResult(
          status: _PairingAttemptStatus.failed,
          message: message,
          agentUrl: baseUrl,
        );
      }
    }

    return _PairingAttemptResult(
      status: _PairingAttemptStatus.failed,
      message: 'Desktop agent returned an unexpected response.',
      agentUrl: baseUrl,
    );
  }

  Uri _pairingUri(String baseUrl) {
    final base = Uri.parse(baseUrl);
    if (base.scheme.isEmpty) {
      throw const FormatException(
        'Agent URL must include a scheme (https://).',
      );
    }
    final basePath =
        base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final confirmPath =
        basePath.isEmpty ? '/pairing/confirm' : '$basePath/pairing/confirm';
    return base.replace(path: confirmPath);
  }

  Uri _healthUri(String baseUrl) {
    final base = Uri.parse(baseUrl);
    if (base.scheme.isEmpty) {
      throw const FormatException(
        'Agent URL must include a scheme (https://).',
      );
    }
    final basePath =
        base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final healthPath = basePath.isEmpty ? '/health' : '$basePath/health';
    return base.replace(path: healthPath);
  }

  bool _isTunnelUrl(PairingPayload payload, String agentUrl) {
    final tunnelUrl = payload.tunnelUrl?.trim();
    final frpUrl = payload.frpUrl?.trim();
    if (tunnelUrl != null && tunnelUrl.isNotEmpty) {
      if (_normalizeUrl(tunnelUrl) == _normalizeUrl(agentUrl)) {
        return true;
      }
    }
    if (frpUrl != null && frpUrl.isNotEmpty) {
      return _normalizeUrl(frpUrl) == _normalizeUrl(agentUrl);
    }
    return false;
  }

  String _normalizeUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.endsWith('/')) {
      return trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  void _resetPairing() {
    _pairingPoller?.cancel();
    setState(() {
      _payload = null;
      _scanError = null;
      _pairingStatus = null;
      _pairingStatusIsError = false;
      _pairingDetailStatus = null;
      _pairingDetailStatusIsError = false;
      _isPairing = false;
      _pairingAgentUrl = null;
      _pairingUsesTunnel = null;
    });
  }

  Future<void> _recordPairingEvent(
    PairingPayload payload,
    String agentUrl, {
    required String authToken,
    String? deviceId,
  }) async {
    try {
      final now = DateTime.now();
      final resolvedToken = authToken.trim();
      ConnectionRecord? existing;
      if (deviceId != null) {
        for (final connection in _connections) {
          if (connection.deviceId == deviceId) {
            existing = connection;
            break;
          }
        }
      }
      if (existing == null) {
        for (final connection in _connections) {
          if ((connection.agentUrl ?? '').trim() == agentUrl.trim()) {
            existing = connection;
            break;
          }
        }
      }
      final connectionId = existing?.id ?? createStorageId();
      final connection = ConnectionRecord(
        id: connectionId,
        token: resolvedToken,
        status: 'connected',
        connectedAt: now,
        deviceId: deviceId ?? existing?.deviceId,
        hostName: payload.hostName ?? existing?.hostName,
        agentUrl: agentUrl,
        tunnelUrl: payload.tunnelUrl,
        tunnelError: payload.tunnelError,
        frpUrl: payload.frpUrl ?? existing?.frpUrl,
        roiQuicPort: payload.roiQuicPort ?? existing?.roiQuicPort,
        wifiSsid: payload.wifiSsid ?? existing?.wifiSsid,
        localIps: payload.localIps.isNotEmpty
            ? payload.localIps
            : existing?.localIps ?? const [],
        localUrls: payload.localUrls.isNotEmpty
            ? payload.localUrls
            : existing?.localUrls ?? const [],
        lastSeenAt: now,
      );
      final session = ToolSession(
        id: createStorageId(),
        type: 'pairing',
        label: 'Pairing ${_truncate(resolvedToken, 6)}',
        status: 'connected',
        agentId: connectionId,
        createdAt: now,
      );
      final event = TimelineEvent(
        id: createStorageId(),
        sessionId: session.id,
        type: 'pairing',
        title: 'Paired with desktop agent',
        payload: {
          'token': resolvedToken,
          'device_id': deviceId ?? '',
          'agent_url': agentUrl,
          'tunnel_url': payload.tunnelUrl ?? '',
          'connected_at': now.toIso8601String(),
        },
        createdAt: now,
      );
      await widget.storage.insertConnection(connection);
      await widget.storage.insertToolSession(session);
      await widget.storage.insertTimelineEvent(event);
      await _loadHistory();
      if (mounted) {
        setState(() {
          _activeAgentId = connectionId;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save local history: ${error.toString()}',
          ),
        ),
      );
    }
  }

  Future<void> _recordManualConnection({
    required String agentUrl,
    required String authToken,
    String? deviceId,
    String? hostName,
  }) async {
    try {
      final now = DateTime.now();
      ConnectionRecord? existing;
      if (deviceId != null && deviceId.trim().isNotEmpty) {
        for (final connection in _connections) {
          if (connection.deviceId == deviceId) {
            existing = connection;
            break;
          }
        }
      }
      if (existing == null) {
        for (final connection in _connections) {
          if ((connection.agentUrl ?? '').trim() == agentUrl.trim()) {
            existing = connection;
            break;
          }
        }
      }
      final connectionId = existing?.id ?? createStorageId();
      final connection = ConnectionRecord(
        id: connectionId,
        token: authToken,
        status: 'connected',
        connectedAt: now,
        deviceId: deviceId ?? existing?.deviceId,
        hostName: hostName ?? existing?.hostName,
        agentUrl: agentUrl,
        tunnelUrl: existing?.tunnelUrl,
        tunnelError: existing?.tunnelError,
        frpUrl: existing?.frpUrl,
        roiQuicPort: existing?.roiQuicPort,
        wifiSsid: existing?.wifiSsid,
        localIps: existing?.localIps ?? const [],
        localUrls: existing?.localUrls ?? const [],
        lastSeenAt: now,
      );
      final session = ToolSession(
        id: createStorageId(),
        type: 'pairing',
        label: 'Login ${_truncate(authToken, 6)}',
        status: 'connected',
        agentId: connectionId,
        createdAt: now,
      );
      final event = TimelineEvent(
        id: createStorageId(),
        sessionId: session.id,
        type: 'pairing',
        title: 'Connected with fixed token',
        payload: {
          'token': authToken,
          'device_id': deviceId ?? '',
          'agent_url': agentUrl,
          'connected_at': now.toIso8601String(),
        },
        createdAt: now,
      );
      await widget.storage.insertConnection(connection);
      await widget.storage.insertToolSession(session);
      await widget.storage.insertTimelineEvent(event);
      await _loadHistory();
      if (mounted) {
        setState(() {
          _activeAgentId = connectionId;
        });
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to save connection: ${error.toString()}'),
        ),
      );
    }
  }

  Future<void> _exportBundle() async {
    setState(() {
      _exportStatus = null;
      _exportStatusIsError = false;
    });
    try {
      final connections = await widget.storage.fetchConnections();
      final sessions = await widget.storage.fetchToolSessions();
      final events = await widget.storage.fetchTimelineEvents();
      final bundle = ExportBundle(
        version: ExportBundle.currentVersion,
        deviceName: _resolveDeviceName(),
        exportedAt: DateTime.now().toUtc(),
        connections: connections,
        toolSessions: sessions,
        timelineEvents: events,
      );
      final exportJson =
          const JsonEncoder.withIndent('  ').convert(bundle.toJson());
      if (!mounted) {
        return;
      }
      await _showExportDialog(exportJson);
      if (!mounted) {
        return;
      }
      setState(() {
        _exportStatus =
            'Exported ${connections.length} connections, ${events.length} events, '
            '${sessions.length} sessions.';
        _exportStatusIsError = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _exportStatus = 'Export failed: ${error.toString()}';
        _exportStatusIsError = true;
      });
    }
  }

  Future<void> _showExportDialog(String exportJson) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Export bundle'),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: SelectableText(exportJson),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: exportJson));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Export JSON copied.')),
                );
              },
              child: const Text('Copy JSON'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _openImportDialog() async {
    final controller = TextEditingController();
    final payload = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Import bundle'),
          content: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: 'Paste export bundle JSON',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Import'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (payload == null || payload.trim().isEmpty) {
      return;
    }
    await _importBundle(payload);
  }

  Future<void> _importBundle(String raw) async {
    setState(() {
      _importStatus = null;
      _importStatusIsError = false;
    });
    ExportBundle bundle;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('Bundle must be a JSON object.');
      }
      bundle = ExportBundle.fromJson(Map<String, dynamic>.from(decoded));
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importStatus = 'Import failed: ${error.message}';
        _importStatusIsError = true;
      });
      return;
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importStatus = 'Import failed: ${error.toString()}';
        _importStatusIsError = true;
      });
      return;
    }

    try {
      for (final connection in bundle.connections) {
        await widget.storage.insertConnection(connection);
      }
      for (final session in bundle.toolSessions) {
        await widget.storage.insertToolSession(session);
      }
      for (final event in bundle.timelineEvents) {
        await widget.storage.insertTimelineEvent(event);
      }
      await _loadHistory();
      if (!mounted) {
        return;
      }
      setState(() {
        _importStatus =
            'Imported ${bundle.connections.length} connections, '
            '${bundle.timelineEvents.length} events, '
            '${bundle.toolSessions.length} sessions.';
        _importStatusIsError = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _importStatus = 'Import failed: ${error.toString()}';
        _importStatusIsError = true;
      });
    }
  }

  String _resolveDeviceName() {
    if (kIsWeb) {
      return 'Web';
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      case TargetPlatform.fuchsia:
        return 'Fuchsia';
    }
  }

  Future<void> _loadHistory() async {
    try {
      final connections = await widget.storage.fetchConnections();
      if (!mounted) {
        return;
      }
      setState(() {
        _connections = connections;
        _activeAgentId ??= connections.isNotEmpty ? connections.first.id : null;
      });
      if (widget.enableConnectivityRefresh) {
        unawaited(_refreshAgentConnectivity());
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
    }
  }

  Future<void> _refreshAgentConnectivity() async {
    if (_isRefreshingAgents) {
      return;
    }
    if (_connections.isEmpty) {
      return;
    }
    _isRefreshingAgents = true;
    try {
      final currentSsid = await _currentWifiSsid();
      final currentIps = await _currentLocalIps();
      final updated = <ConnectionRecord>[];
      final probeErrors = <String, String>{};
      for (final agent in _connections) {
        final resolution = await _resolveAgentRoute(
          agent,
          currentSsid: currentSsid,
          currentIps: currentIps,
        );
        updated.add(resolution.record);
        final detail = resolution.errorDetail;
        if (detail != null && detail.trim().isNotEmpty) {
          probeErrors[agent.id] = detail.trim();
        }
      }
      for (final agent in updated) {
        await widget.storage.insertConnection(agent);
      }
      if (mounted) {
        setState(() {
          _connections = updated;
          _agentProbeErrors = probeErrors;
        });
      }
    } finally {
      _isRefreshingAgents = false;
    }
  }

  Future<String?> _currentWifiSsid() async {
    if (kIsWeb || !widget.enableNetworkHints) {
      return null;
    }
    try {
      final info = NetworkInfo();
      final ssid =
          await info.getWifiName().timeout(const Duration(seconds: 1));
      if (ssid == null) {
        return null;
      }
      final cleaned = ssid.replaceAll('"', '').trim();
      if (cleaned.isEmpty) {
        return null;
      }
      final lower = cleaned.toLowerCase();
      if (lower == '<unknown ssid>' || lower == 'unknown ssid') {
        return null;
      }
      return cleaned;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _currentLocalIps() async {
    if (kIsWeb || !widget.enableNetworkHints) {
      return const [];
    }
    try {
      return await listLocalIps().timeout(const Duration(seconds: 1));
    } catch (_) {
      return const [];
    }
  }

  bool _isSameLan({
    required String? agentSsid,
    required List<String> agentIps,
    required String? currentSsid,
    required List<String> currentIps,
    bool allowUnknown = false,
  }) {
    if (agentSsid == null ||
        currentSsid == null ||
        agentSsid.trim().isEmpty ||
        currentSsid.trim().isEmpty) {
      return allowUnknown;
    }
    if (agentSsid.trim() != currentSsid.trim()) {
      return false;
    }
    if (agentIps.isEmpty || currentIps.isEmpty) {
      return allowUnknown;
    }
    for (final agentIp in agentIps) {
      for (final deviceIp in currentIps) {
        if (_sameSubnet(agentIp, deviceIp)) {
          return true;
        }
      }
    }
    return false;
  }

  bool _sameSubnet(String a, String b) {
    final partsA = a.split('.');
    final partsB = b.split('.');
    if (partsA.length != 4 || partsB.length != 4) {
      return false;
    }
    for (var i = 0; i < 3; i++) {
      final ai = int.tryParse(partsA[i]);
      final bi = int.tryParse(partsB[i]);
      if (ai == null || bi == null || ai != bi) {
        return false;
      }
    }
    return true;
  }

  bool _isPrivateIpv4(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) {
      return false;
    }
    final a = int.tryParse(parts[0]) ?? -1;
    final b = int.tryParse(parts[1]) ?? -1;
    if (a == 10) {
      return true;
    }
    if (a == 192 && b == 168) {
      return true;
    }
    if (a == 172 && b >= 16 && b <= 31) {
      return true;
    }
    return false;
  }

  List<String> _fallbackLocalUrls(ConnectionRecord agent) {
    if (agent.localUrls.isNotEmpty) {
      return agent.localUrls;
    }
    final url = agent.agentUrl;
    if (url == null || url.trim().isEmpty) {
      return const [];
    }
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      if (_isPrivateIpv4(host)) {
        return [url.trim()];
      }
    } catch (_) {
      return const [];
    }
    return const [];
  }

  Future<List<_ReachabilityResult>> _probeReachability(
    List<String> urls,
    Duration timeout,
  ) async {
    if (urls.isEmpty) {
      return const [];
    }
    final results = await Future.wait(
      urls.map((url) => _probeUrl(url, timeout)),
    );
    return results;
  }

  _ReachabilityResult? _firstReachable(List<_ReachabilityResult> results) {
    for (final result in results) {
      if (result.reachable) {
        return result;
      }
    }
    return null;
  }

  String? _summarizeProbeFailures(
    List<_ReachabilityResult> localResults,
    List<_ReachabilityResult> remoteResults, {
    String? fallbackMessage,
  }) {
    final summaries = <String>[];
    final localSummary = _summarizeProbeGroup('LAN', localResults);
    if (localSummary != null) {
      summaries.add(localSummary);
    }
    final remoteSummary = _summarizeProbeGroup('FRP', remoteResults);
    if (remoteSummary != null) {
      summaries.add(remoteSummary);
    }
    if (summaries.isNotEmpty) {
      return summaries.join(' | ');
    }
    return fallbackMessage;
  }

  String? _summarizeProbeGroup(
    String label,
    List<_ReachabilityResult> results,
  ) {
    if (results.isEmpty) {
      return null;
    }
    if (results.any((result) => result.reachable)) {
      return null;
    }
    final first = results.first;
    final reason = first.reason ?? 'Unreachable.';
    final count = results.length;
    final countLabel = count > 1 ? ' ($count endpoints)' : '';
    return '$label probe failed: $reason$countLabel';
  }

  Future<_ReachabilityResult> _probeUrl(
    String baseUrl,
    Duration timeout,
  ) async {
    final client = _pairingClient;
    if (client == null) {
      return _ReachabilityResult(
        url: baseUrl,
        reachable: false,
        reason: 'HTTP client unavailable.',
      );
    }
    Uri uri;
    try {
      uri = _healthUri(baseUrl);
    } catch (_) {
      return _ReachabilityResult(
        url: baseUrl,
        reachable: false,
        reason: 'Invalid URL.',
      );
    }
    try {
      final response = await client.get(uri).timeout(timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _ReachabilityResult(
          url: baseUrl,
          reachable: true,
          reason: 'OK',
        );
      }
      return _ReachabilityResult(
        url: baseUrl,
        reachable: false,
        reason: 'HTTP ${response.statusCode}.',
      );
    } on TimeoutException {
      return _ReachabilityResult(
        url: baseUrl,
        reachable: false,
        reason: 'Timeout after ${timeout.inSeconds}s.',
      );
    } catch (error) {
      return _ReachabilityResult(
        url: baseUrl,
        reachable: false,
        reason: _describeNetworkError(error),
      );
    }
  }

  Future<_AgentRouteResolution> _resolveAgentRoute(
    ConnectionRecord agent, {
    required String? currentSsid,
    required List<String> currentIps,
  }) async {
    final sameLan = _isSameLan(
      agentSsid: agent.wifiSsid,
      agentIps: agent.localIps,
      currentSsid: currentSsid,
      currentIps: currentIps,
      allowUnknown: true,
    );
    final localUrls = _fallbackLocalUrls(agent);
    final remoteUrls = <String>[
      if (agent.frpUrl != null && agent.frpUrl!.trim().isNotEmpty)
        agent.frpUrl!.trim(),
      if (agent.tunnelUrl != null && agent.tunnelUrl!.trim().isNotEmpty)
        agent.tunnelUrl!.trim(),
    ].toSet().toList();

    final localFuture = sameLan && localUrls.isNotEmpty
        ? _probeReachability(localUrls, const Duration(seconds: 2))
        : Future<List<_ReachabilityResult>>.value(const []);
    final remoteFuture = remoteUrls.isNotEmpty
        ? _probeReachability(remoteUrls, const Duration(seconds: 3))
        : Future<List<_ReachabilityResult>>.value(const []);

    final results = await Future.wait([localFuture, remoteFuture]);
    final localResults = results[0];
    final remoteResults = results[1];
    final localHit = _firstReachable(localResults);
    final remoteHit = _firstReachable(remoteResults);
    final now = DateTime.now();

    if (localHit != null) {
      final connected = agent.copyWith(
        status: 'connected',
        agentUrl: localHit.url,
        lastSeenAt: now,
      );
      return _AgentRouteResolution(
        record: await _refreshAgentIdentity(connected),
      );
    }
    if (remoteHit != null) {
      final connected = agent.copyWith(
        status: 'connected',
        agentUrl: remoteHit.url,
        lastSeenAt: now,
      );
      return _AgentRouteResolution(
        record: await _refreshAgentIdentity(connected),
      );
    }
    final errorDetail = _summarizeProbeFailures(
      localResults,
      remoteResults,
      fallbackMessage:
          (localUrls.isEmpty && remoteUrls.isEmpty)
              ? 'No LAN/FRP endpoints available.'
              : null,
    );
    return _AgentRouteResolution(
      record: agent.copyWith(
        status: 'offline',
      ),
      errorDetail: errorDetail,
    );
  }

  Future<ConnectionRecord> _refreshAgentIdentity(ConnectionRecord agent) async {
    final url = agent.agentUrl?.trim();
    if (url == null || url.isEmpty) {
      return agent;
    }
    final client = _pairingClient ?? http.Client();
    try {
      final commandClient = AgentCommandClient(
        baseUrl: url,
        client: client,
        authToken: agent.token,
        clientId: _clientId,
        clientName: _resolveDeviceName(),
      );
      final identity = await commandClient.fetchIdentity();
      final deviceId = identity['device_id']?.toString();
      final hostName =
          identity['host_name']?.toString() ?? identity['hostName']?.toString();
      final wifiSsid =
          identity['wifi_ssid']?.toString() ?? identity['wifiSsid']?.toString();
      final localIps =
          _parseLocalIps(identity['local_ips'] ?? identity['localIps']);
      final localUrls = _parseLocalUrls(
        identity['local_urls'] ??
            identity['localUrls'] ??
            identity['local_url'],
      );
      final frpUrl =
          identity['frp_url']?.toString() ?? identity['frpUrl']?.toString();
      final tunnelUrl =
          identity['tunnel_url']?.toString() ?? identity['tunnelUrl']?.toString();
      final roiQuicPort = _parsePort(
        identity['roi_quic_port'] ?? identity['roiQuicPort'],
      );
      return agent.copyWith(
        deviceId: deviceId ?? agent.deviceId,
        hostName: hostName ?? agent.hostName,
        wifiSsid: wifiSsid ?? agent.wifiSsid,
        localIps: localIps.isNotEmpty ? localIps : agent.localIps,
        localUrls: localUrls.isNotEmpty ? localUrls : agent.localUrls,
        frpUrl: frpUrl ?? agent.frpUrl,
        roiQuicPort: roiQuicPort ?? agent.roiQuicPort,
        tunnelUrl: tunnelUrl ?? agent.tunnelUrl,
        status: 'connected',
        lastSeenAt: DateTime.now(),
      );
    } catch (_) {
      return agent.copyWith(status: 'error');
    } finally {
      if (_pairingClient == null) {
        client.close();
      }
    }
  }

  Future<void> _ensureClientId() async {
    final existing = await widget.storage.readKeyValue(_clientIdStorageKey);
    if (existing != null && existing.trim().isNotEmpty) {
      if (mounted) {
        setState(() {
          _clientId = existing.trim();
        });
      }
      return;
    }
    final generated = createStorageId();
    await widget.storage.writeKeyValue(_clientIdStorageKey, generated);
    if (mounted) {
      setState(() {
        _clientId = generated;
      });
    }
  }

  void _openAgentWorkspace(ConnectionRecord agent) {
    setState(() {
      _activeAgentId = agent.id;
    });
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => AgentWorkspaceScreen(
              storage: widget.storage,
              agent: agent,
              agents: _connections,
              clientId: _clientId,
              clientName: _resolveDeviceName(),
            ),
          ),
        )
        .then((_) {
      if (mounted) {
        _loadHistory();
      }
    });
  }

  Future<void> _deleteAgent(ConnectionRecord agent) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove agent?'),
          content: Text(
            'This will delete all sessions and history for ${_agentLabel(agent)}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.storage.deleteToolSessionsByAgent(agent.id);
      await widget.storage.deleteConnection(agent.id);
      await _loadHistory();
      if (!mounted) {
        return;
      }
      setState(() {
        if (_activeAgentId == agent.id) {
          _activeAgentId =
              _connections.isNotEmpty ? _connections.first.id : null;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to remove agent: ${error.toString()}'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAgents = _connections.isNotEmpty;
    return Scaffold(
      body: Stack(
        children: [
          const _PairingBackground(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _PairingHeader(),
                  const SizedBox(height: 24),
                  PairingStepCard(
                    title: 'Add agent',
                    description:
                        'Scan a pairing token to add a desktop agent.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FilledButton.icon(
                          key: const Key('scanQrButton'),
                          onPressed: _scanQrPayload,
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text('Scan QR token'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _connectWithFixedToken,
                          icon: const Icon(Icons.vpn_key),
                          label: const Text('Use fixed token'),
                        ),
                        const SizedBox(height: 16),
                        if (_payload == null)
                          const Text(
                            'No pairing token scanned yet.',
                          )
                        else
                          _PairingTokenDetails(payload: _payload!),
                        if (_payload != null &&
                            _payload!.localUrls.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'LAN endpoints',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF64748B),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Column(
                            children: [
                              for (final url in _payload!.localUrls)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          url,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: const Color(0xFF0F172A),
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton(
                                        onPressed: () =>
                                            _selectManualAgentUrl(url),
                                        child: const Text('Use'),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ],
                        if (_payload?.frpUrl != null &&
                            _payload!.frpUrl!.trim().isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Public endpoint (FRP)',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF64748B),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _payload!.frpUrl!,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF0F172A),
                                ),
                          ),
                        ],
                        if (_scanError != null) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(
                            message: _scanError!,
                            isError: true,
                          ),
                        ],
                        if (_payload?.tunnelError != null &&
                            _pairingStatus != _payload!.tunnelError) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(
                            message: _payload!.tunnelError!,
                            isError: true,
                          ),
                        ],
                        if (_payload != null && _payload!.isExpired) ...[
                          const SizedBox(height: 12),
                          OutlinedButton(
                            key: const Key('retryButton'),
                            onPressed: _resetPairing,
                            child: const Text('Retry pairing'),
                          ),
                        ],
                        const SizedBox(height: 12),
                        if (_isPairing) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE0F2FE),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: const Color(0xFFBAE6FD),
                              ),
                            ),
                            child: Row(
                              children: [
                                const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.4,
                                    valueColor: AlwaysStoppedAnimation(
                                      Color(0xFF0284C7),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  'Pairing in progress...',
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyMedium
                                      ?.copyWith(
                                        fontWeight: FontWeight.w600,
                                        color: const Color(0xFF0C4A6E),
                                      ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        if (_pairingStatus != null)
                          _InlineStatus(
                            key: const Key('pairingStatus'),
                            message: _pairingStatus!,
                            isError: _pairingStatusIsError,
                          )
                        else
                          const Text(
                            'Scan a token to begin pairing. Approve on desktop if required.',
                          ),
                        if (_manualAgentUrl != null) ...[
                          const SizedBox(height: 8),
                          _InlineStatus(
                            message:
                                'Manual endpoint: ${_shortUrlLabel(_manualAgentUrl!)}',
                            isError: false,
                          ),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton(
                              onPressed: _clearManualAgentUrl,
                              child: const Text('Clear manual endpoint'),
                            ),
                          ),
                        ],
                        if (_pairingDetailStatus != null &&
                            _pairingDetailStatus!.trim().isNotEmpty) ...[
                          const SizedBox(height: 8),
                          _InlineStatus(
                            message: _pairingDetailStatus!,
                            isError: _pairingDetailStatusIsError,
                          ),
                        ],
                        if (_pairingAgentUrl != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Agent: $_pairingAgentUrl',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: const Color(0xFF64748B),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          if (_pairingUsesTunnel != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Mode: ${_pairingUsesTunnel! ? 'Tunnel' : 'Local network'}',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF94A3B8),
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ],
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          key: const Key('retryPairingButton'),
                          onPressed: _payload == null ? null : _retryPairing,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry pairing'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  PairingStepCard(
                    title: 'Advanced',
                    description:
                        'Control how the mobile app connects to the desktop agent.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Force tunnel connection',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Use the cloud tunnel even when the agent is on the same LAN.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                          color: const Color(0xFF64748B),
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            Switch.adaptive(
                              value: _forceTunnel,
                              onChanged: (value) {
                                setState(() {
                                  _forceTunnel = value;
                                });
                              },
                            ),
                          ],
                        ),
                        if (_forceTunnel &&
                            (_payload?.tunnelUrl == null ||
                                _payload!.tunnelUrl!.trim().isEmpty)) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(
                            message: _payload?.tunnelError ??
                                'Tunnel URL unavailable. Install Cloudflared and generate a new token.',
                            isError: true,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  PairingStepCard(
                    title: 'Agents',
                    description:
                        'Each agent has its own workspace and sessions.',
                    child: hasAgents
                        ? Column(
                            children: [
                              for (final agent in _connections) ...[
                                _AgentCard(
                                  agent: agent,
                                  isActive: agent.id == _activeAgentId,
                                  probeDetail: _agentProbeErrors[agent.id],
                                  onOpenWorkspace: () =>
                                      _openAgentWorkspace(agent),
                                  onDelete: () => _deleteAgent(agent),
                                ),
                                if (agent != _connections.last)
                                  const SizedBox(height: 12),
                              ],
                            ],
                          )
                        : Text(
                            'No agents paired yet.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: const Color(0xFF64748B),
                                ),
                          ),
                  ),
                  const SizedBox(height: 20),
                  PairingStepCard(
                    title: 'Export and import',
                    description:
                        'Move connections and timeline history between devices.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            FilledButton.icon(
                              key: const Key('exportBundleButton'),
                              onPressed: _exportBundle,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Export bundle'),
                            ),
                            OutlinedButton.icon(
                              key: const Key('importBundleButton'),
                              onPressed: _openImportDialog,
                              icon: const Icon(Icons.download),
                              label: const Text('Import bundle'),
                            ),
                          ],
                        ),
                        if (_exportStatus != null) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(
                            message: _exportStatus!,
                            isError: _exportStatusIsError,
                          ),
                        ],
                        if (_importStatus != null) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(
                            message: _importStatus!,
                            isError: _importStatusIsError,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _QrScannerScreen extends StatefulWidget {
  const _QrScannerScreen();

  @override
  State<_QrScannerScreen> createState() => _QrScannerScreenState();
}

class _QrScannerScreenState extends State<_QrScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
  );
  bool _isHandling = false;
  String? _errorMessage;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleDetect(BarcodeCapture capture) {
    if (_isHandling) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.trim().isEmpty) {
        continue;
      }
      if (PairingPayload.tryParse(raw) == null) {
        setState(() {
          _errorMessage = 'Unrecognized QR code. Try again or paste the token.';
        });
        return;
      }
      _isHandling = true;
      _controller.stop();
      Navigator.of(context).pop(raw);
      return;
    }
  }

  Future<void> _openManualEntry() async {
    final controller = TextEditingController();
    final payload = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Enter pairing token'),
          content: TextField(
            key: const Key('qrPayloadField'),
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Paste QR payload JSON or vibeinspect:// URL',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('applyQrButton'),
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Use token'),
            ),
          ],
        );
      },
    );
    if (!mounted || payload == null) {
      return;
    }
    final trimmed = payload.trim();
    if (trimmed.isEmpty) {
      return;
    }
    Navigator.of(context).pop(trimmed);
  }

  String _describeScannerError(MobileScannerException error) {
    switch (error.errorCode) {
      case MobileScannerErrorCode.permissionDenied:
        return 'Camera permission denied. Enable it or paste the token.';
      case MobileScannerErrorCode.unsupported:
        return 'Camera not available on this device.';
      case MobileScannerErrorCode.controllerUninitialized:
        return 'Camera not ready yet.';
      case MobileScannerErrorCode.genericError:
      default:
        return 'Unable to start the camera.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan pairing QR'),
        actions: [
          IconButton(
            tooltip: 'Paste token',
            onPressed: _openManualEntry,
            icon: const Icon(Icons.edit),
          ),
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              final torchState = state.torchState;
              final hasTorch = torchState != TorchState.unavailable;
              return IconButton(
                tooltip: 'Toggle torch',
                onPressed: hasTorch ? _controller.toggleTorch : null,
                icon: Icon(
                  torchState == TorchState.on
                      ? Icons.flash_on
                      : Icons.flash_off,
                ),
              );
            },
          ),
          IconButton(
            tooltip: 'Switch camera',
            onPressed: _controller.switchCamera,
            icon: const Icon(Icons.cameraswitch),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final scanSize = size.shortestSide * 0.7;
          final scanWindow = Rect.fromCenter(
            center: size.center(Offset.zero),
            width: scanSize,
            height: scanSize,
          );
          return Stack(
            children: [
              MobileScanner(
                controller: _controller,
                onDetect: _handleDetect,
                scanWindow: scanWindow,
                tapToFocus: true,
                errorBuilder: (context, error) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.camera_alt_outlined,
                            size: 48,
                            color: Color(0xFF64748B),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _describeScannerError(error),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF475569),
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _openManualEntry,
                            child: const Text('Paste token'),
                          ),
                        ],
                      ),
                    ),
                  );
                },
                overlayBuilder: (context, constraints) {
                  return CustomPaint(
                    painter: _ScannerOverlayPainter(scanWindow),
                    child: const SizedBox.expand(),
                  );
                },
              ),
              if (_errorMessage != null)
                Positioned(
                  left: 24,
                  right: 24,
                  bottom: 32,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color.fromARGB(217, 15, 23, 42),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: Color(0xFFFCA5A5),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ScannerOverlayPainter extends CustomPainter {
  _ScannerOverlayPainter(this.scanWindow);

  final Rect scanWindow;

  @override
  void paint(Canvas canvas, Size size) {
    final overlay = Paint()
      ..color = const Color(0x99000000)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectXY(scanWindow, 16, 16));
    canvas.drawPath(path, overlay);
    canvas.drawRRect(RRect.fromRectXY(scanWindow, 16, 16), border);
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) {
    return oldDelegate.scanWindow != scanWindow;
  }
}

class _RoiTilePainter extends CustomPainter {
  _RoiTilePainter({
    required this.tiles,
    required this.renderer,
    required this.translation,
    required this.scale,
    required this.revision,
  });

  final Map<RoiTileKey, ui.Image> tiles;
  final RoiRenderer renderer;
  final Offset translation;
  final double scale;
  final int revision;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in tiles.entries) {
      renderer.paintTile(
        canvas: canvas,
        tile: entry.key,
        image: entry.value,
        scale: scale,
        translation: translation,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RoiTilePainter oldDelegate) {
    return oldDelegate.revision != revision ||
        oldDelegate.scale != scale ||
        oldDelegate.translation != translation ||
        !mapEquals(oldDelegate.tiles, tiles);
  }
}

class AgentWorkspaceScreen extends StatefulWidget {
  const AgentWorkspaceScreen({
    super.key,
    required this.storage,
    required this.agent,
    required this.agents,
    required this.clientId,
    required this.clientName,
  });

  final StorageRepository storage;
  final ConnectionRecord agent;
  final List<ConnectionRecord> agents;
  final String? clientId;
  final String? clientName;

  @override
  State<AgentWorkspaceScreen> createState() => _AgentWorkspaceScreenState();
}

class _AgentWorkspaceScreenState extends State<AgentWorkspaceScreen> {
  List<ToolSession> _sessions = [];
  List<TimelineEvent> _events = [];
  bool _isLoading = true;
  String? _errorMessage;
  late ConnectionRecord _activeAgent;

  @override
  void initState() {
    super.initState();
    _activeAgent = widget.agent;
    _loadWorkspace();
  }

  Future<void> _loadWorkspace() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final sessions = await widget.storage.fetchToolSessions();
      final events = await widget.storage.fetchTimelineEvents();
      final agentSessions = sessions
          .where((session) => session.agentId == _activeAgent.id)
          .toList();
      final sessionIds = agentSessions.map((session) => session.id).toSet();
      final agentEvents =
          events.where((event) => sessionIds.contains(event.sessionId)).toList();
      if (!mounted) {
        return;
      }
      setState(() {
        _sessions = agentSessions;
        _events = agentEvents;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to load workspace.';
      });
    }
  }

  String? get _agentBaseUrl {
    final url = _activeAgent.agentUrl?.trim();
    return url == null || url.isEmpty ? null : url;
  }

  Future<void> _openTerminalSession() async {
    final now = DateTime.now();
    final terminalCount =
        _sessions.where((session) => session.type == 'terminal').length;
    final session = ToolSession(
      id: createStorageId(),
      type: 'terminal',
      label: 'Terminal Session ${terminalCount + 1}',
      status: 'idle',
      agentId: _activeAgent.id,
      createdAt: now,
    );
    try {
      await widget.storage.insertToolSession(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to create terminal session: ${error.toString()}',
          ),
        ),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    await Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => TerminalWorkspaceScreen(
              storage: widget.storage,
              agentBaseUrl: _agentBaseUrl,
              authToken: _activeAgent.token,
              clientId: widget.clientId,
              clientName: widget.clientName,
              agentId: widget.agent.id,
              initialSession: session,
            ),
          ),
        )
        .then((_) => _loadWorkspace());
  }

  Future<void> _openApiSession() async {
    final now = DateTime.now();
    final intent = _buildApiIntent('GET /');
    final session = ToolSession(
      id: createStorageId(),
      type: intent.tool.storageKey,
      label: intent.sessionLabel,
      status: 'queued',
      agentId: _activeAgent.id,
      createdAt: now,
    );
    final event = TimelineEvent(
      id: createStorageId(),
      sessionId: session.id,
      type: intent.tool.storageKey,
      title: intent.title,
      payload: intent.payload,
      createdAt: now,
    );
    try {
      await widget.storage.insertToolSession(session);
      await widget.storage.insertTimelineEvent(event);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to create API session: ${error.toString()}',
          ),
        ),
      );
      return;
    }
    final apiContext = ApiEventContext.fromPayload(event.payload);
    if (!mounted || apiContext == null) {
      return;
    }
    await Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => ApiExplorerScreen(
              event: event,
              context: apiContext,
              storage: widget.storage,
              agentBaseUrl: _agentBaseUrl,
              authToken: _activeAgent.token,
              clientId: widget.clientId,
              clientName: widget.clientName,
            ),
          ),
        )
        .then((_) => _loadWorkspace());
  }

  Future<void> _openVncView() async {
    final baseUrl = _agentBaseUrl;
    if (baseUrl == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Agent URL missing. Re-pair to enable VNC.'),
        ),
      );
      return;
    }
    final existingSession = _sessions.firstWhere(
      (session) => session.type == 'vnc',
      orElse: () => ToolSession(
        id: '',
        type: 'vnc',
        label: '',
        status: 'queued',
        createdAt: DateTime.now(),
      ),
    );
    final now = DateTime.now();
    final session = existingSession.id.isEmpty
        ? ToolSession(
            id: createStorageId(),
            type: 'vnc',
            label: 'VNC Workspace',
            status: 'queued',
            agentId: _activeAgent.id,
            createdAt: now,
          )
        : existingSession;
    if (existingSession.id.isEmpty) {
      try {
        await widget.storage.insertToolSession(session);
      } catch (error) {
        if (!mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to create VNC session: ${error.toString()}',
            ),
          ),
        );
        return;
      }
    }
    final event = TimelineEvent(
      id: createStorageId(),
      sessionId: session.id,
      type: 'vnc',
      title: 'VNC: ${_agentLabel(_activeAgent)}',
      payload: {
        'target': _agentLabel(_activeAgent),
        'status': 'queued',
      },
      createdAt: now,
    );
    try {
      await widget.storage.insertTimelineEvent(event);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start VNC: ${error.toString()}'),
        ),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    await Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => VncSessionScreen(
              event: event,
              session: session,
              storage: widget.storage,
              agentBaseUrl: baseUrl,
              authToken: _activeAgent.token,
              clientId: widget.clientId,
              clientName: widget.clientName,
            ),
          ),
        )
        .then((_) => _loadWorkspace());
  }

  Future<void> _removeActiveAgent() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove agent?'),
          content: Text(
            'This will delete all sessions and history for ${_agentLabel(_activeAgent)}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
    if (confirmed != true) {
      return;
    }
    try {
      await widget.storage.deleteToolSessionsByAgent(_activeAgent.id);
      await widget.storage.deleteConnection(_activeAgent.id);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to remove agent: ${error.toString()}'),
        ),
      );
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openSession(ToolSession session) async {
    final baseUrl = _agentBaseUrl;
    final latestEvent = _latestEventForSession(session.id);
    if (session.type == 'terminal') {
      await Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => TerminalWorkspaceScreen(
                storage: widget.storage,
                agentBaseUrl: baseUrl,
                authToken: _activeAgent.token,
                clientId: widget.clientId,
                clientName: widget.clientName,
                agentId: _activeAgent.id,
                initialSession: session,
                initialEvent: latestEvent,
              ),
            ),
          )
          .then((_) => _loadWorkspace());
      return;
    }
    if (session.type == 'api') {
      if (latestEvent == null) {
        _showMissingContext('No API activity found for this session.');
        return;
      }
      final apiContext = ApiEventContext.fromPayload(latestEvent.payload);
      if (apiContext == null) {
        _showMissingContext('API context is missing for this session.');
        return;
      }
      await Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => ApiExplorerScreen(
                event: latestEvent,
                context: apiContext,
                storage: widget.storage,
                agentBaseUrl: baseUrl,
                authToken: _activeAgent.token,
                clientId: widget.clientId,
                clientName: widget.clientName,
              ),
            ),
          )
          .then((_) => _loadWorkspace());
      return;
    }
    if (session.type == 'ai') {
      if (latestEvent == null) {
        _showMissingContext('No AI insight found for this session.');
        return;
      }
      await Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => AiInsightScreen(
                event: latestEvent,
                session: session,
              ),
            ),
          )
          .then((_) => _loadWorkspace());
      return;
    }
    _showMissingContext('This session type is not supported yet.');
  }

  void _showMissingContext(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  TimelineEvent? _latestEventForSession(String sessionId) {
    for (final event in _events) {
      if (event.sessionId == sessionId) {
        return event;
      }
    }
    return null;
  }

  List<ToolSession> _visibleSessions() {
    return _sessions
        .where((session) =>
            session.type != 'pairing' && session.type != 'vnc')
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_isLoading) {
      return const _TimelineDetailScaffold(
        title: 'Workspace',
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (_errorMessage != null) {
      return _TimelineDetailScaffold(
        title: 'Workspace',
        body: Center(
          child: _InlineStatus(message: _errorMessage!, isError: true),
        ),
      );
    }
    final sessions = _visibleSessions();
    final baseUrl = _agentBaseUrl;
    final hasAgentUrl = baseUrl != null && baseUrl.isNotEmpty;
    return _TimelineDetailScaffold(
      title: _agentLabel(_activeAgent),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Workspace',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Manage sessions and open tools for this agent.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 16),
            _ContextSectionCard(
              title: 'Agent',
              subtitle: hasAgentUrl
                  ? 'Connected to ${_agentLabel(_activeAgent)}.'
                  : 'Agent URL missing. Re-pair to enable commands.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _AgentSwitcher(
                    agents: widget.agents,
                    activeAgentId: _activeAgent.id,
                    onChanged: (next) {
                      setState(() {
                        _activeAgent = next;
                      });
                      _loadWorkspace();
                    },
                  ),
                  const SizedBox(height: 12),
                  _KeyValueRow(
                    label: 'Status',
                    value: _activeAgent.status.toUpperCase(),
                  ),
                  if (_activeAgent.agentUrl != null)
                    _KeyValueRow(
                      label: 'Base URL',
                      value: _activeAgent.agentUrl!,
                    ),
                  if (_activeAgent.lastSeenAt != null)
                    _KeyValueRow(
                      label: 'Last seen',
                      value: _formatTimestamp(_activeAgent.lastSeenAt!),
                    ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _removeActiveAgent,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Remove agent'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFB91C1C),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _ContextSectionCard(
              title: 'Actions',
              subtitle: 'Create sessions or launch the VNC view.',
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _openTerminalSession,
                    icon: const Icon(Icons.terminal),
                    label: const Text('New terminal'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _openApiSession,
                    icon: const Icon(Icons.http),
                    label: const Text('New API request'),
                  ),
                  OutlinedButton.icon(
                    onPressed: hasAgentUrl ? _openVncView : null,
                    icon: const Icon(Icons.desktop_windows_outlined),
                    label: const Text('Open VNC view'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _ContextSectionCard(
              title: 'Sessions',
              subtitle: 'Tap a session to open its tool view.',
              child: sessions.isEmpty
                  ? const _EmptyHint(text: 'No sessions yet.')
                  : Column(
                      children: [
                        for (final session in sessions) ...[
                          _AgentSessionRow(
                            session: session,
                            event: _latestEventForSession(session.id),
                            onTap: () => _openSession(session),
                          ),
                          if (session != sessions.last)
                            const SizedBox(height: 10),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AgentCard extends StatelessWidget {
  const _AgentCard({
    required this.agent,
    required this.isActive,
    this.probeDetail,
    required this.onOpenWorkspace,
    required this.onDelete,
  });

  final ConnectionRecord agent;
  final bool isActive;
  final String? probeDetail;
  final VoidCallback onOpenWorkspace;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusStyle = _agentStatusStyle(agent.status);
    final borderColor =
        isActive ? const Color(0xFF38BDF8) : const Color(0xFFE2E8F0);
    final background =
        isActive ? const Color(0xFFF0F9FF) : const Color(0xFFF8FAFC);
    final agentUrl = agent.agentUrl;
    final subtitle = agentUrl == null || agentUrl.trim().isEmpty
        ? 'Agent URL missing'
        : agentUrl;
    final detail = probeDetail?.trim();
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onOpenWorkspace,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: statusStyle.background,
                child: Icon(
                  Icons.memory,
                  size: 18,
                  color: statusStyle.foreground,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _agentLabel(agent),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                    ),
                    if (detail != null && detail.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFB91C1C),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: statusStyle.background,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      agent.status.toUpperCase(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: statusStyle.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  IconButton(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Remove agent',
                    splashRadius: 18,
                    color: const Color(0xFFDC2626),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AgentSessionRow extends StatelessWidget {
  const _AgentSessionRow({
    required this.session,
    required this.event,
    required this.onTap,
  });

  final ToolSession session;
  final TimelineEvent? event;
  final VoidCallback onTap;

  String _previewText() {
    if (event == null) {
      return 'No activity yet';
    }
    switch (session.type.toLowerCase()) {
      case 'terminal':
        final command = event!.payload['command']?.toString();
        return command?.trim().isNotEmpty == true
            ? command!.trim()
            : event!.title;
      case 'api':
        final context = ApiEventContext.fromPayload(event!.payload);
        if (context != null) {
          return '${context.request.method} ${context.request.url}';
        }
        return event!.title;
      case 'ai':
        return event!.title;
      default:
        return event!.title;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visuals = _eventVisuals(session.type);
    final statusStyle = _sessionStatusStyle(session.status);
    final timeLabel =
        event == null ? 'Never run' : _formatTimestamp(event!.createdAt);
    return Material(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: visuals.backgroundColor,
                child: Icon(
                  visuals.icon,
                  size: 18,
                  color: visuals.foregroundColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _previewText(),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      timeLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF94A3B8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: statusStyle.background,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  session.status.toUpperCase(),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: statusStyle.foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionStatusStyle {
  const _SessionStatusStyle(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

_SessionStatusStyle _sessionStatusStyle(String status) {
  switch (status.toLowerCase()) {
    case 'running':
    case 'complete':
    case 'success':
      return const _SessionStatusStyle(
        Color(0xFFDCFCE7),
        Color(0xFF166534),
      );
    case 'queued':
    case 'idle':
      return const _SessionStatusStyle(
        Color(0xFFFEF3C7),
        Color(0xFF92400E),
      );
    case 'disconnected':
    case 'error':
    case 'failed':
      return const _SessionStatusStyle(
        Color(0xFFFEE2E2),
        Color(0xFFB91C1C),
      );
    case 'exited':
    case 'killed':
    case 'closed':
      return const _SessionStatusStyle(
        Color(0xFFE2E8F0),
        Color(0xFF475569),
      );
    default:
      return const _SessionStatusStyle(
        Color(0xFFE2E8F0),
        Color(0xFF475569),
      );
  }
}

class _AgentStatusStyle {
  const _AgentStatusStyle(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

_AgentStatusStyle _agentStatusStyle(String status) {
  switch (status.toLowerCase()) {
    case 'connected':
      return const _AgentStatusStyle(
        Color(0xFFDCFCE7),
        Color(0xFF166534),
      );
    case 'pending':
    case 'connecting':
      return const _AgentStatusStyle(
        Color(0xFFFEF3C7),
        Color(0xFF92400E),
      );
    case 'disconnected':
    case 'offline':
    case 'error':
      return const _AgentStatusStyle(
        Color(0xFFFEE2E2),
        Color(0xFFB91C1C),
      );
    default:
      return const _AgentStatusStyle(
        Color(0xFFE2E8F0),
        Color(0xFF475569),
      );
  }
}

class _AgentSwitcher extends StatelessWidget {
  const _AgentSwitcher({
    required this.agents,
    required this.activeAgentId,
    required this.onChanged,
  });

  final List<ConnectionRecord> agents;
  final String activeAgentId;
  final ValueChanged<ConnectionRecord> onChanged;

  @override
  Widget build(BuildContext context) {
    if (agents.isEmpty) {
      return const _EmptyHint(text: 'No agents connected.');
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: activeAgentId,
          icon: const Icon(Icons.swap_horiz),
          onChanged: (value) {
            if (value == null) {
              return;
            }
            final selected = agents.firstWhere((agent) => agent.id == value);
            onChanged(selected);
          },
          items: [
            for (final agent in agents)
              DropdownMenuItem<String>(
                value: agent.id,
                child: Row(
                  children: [
                    _AgentStatusDot(status: agent.status),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_agentLabel(agent))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AgentStatusDot extends StatelessWidget {
  const _AgentStatusDot({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final style = _agentStatusStyle(status);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: style.foreground,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _PairingBackground extends StatelessWidget {
  const _PairingBackground();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Color(0xFFF8FAFC),
                Color(0xFFE2E8F0),
                Color(0xFFE0F2FE),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        const Positioned(
          top: -80,
          left: -40,
          child: _GlowCircle(
            size: 180,
            color: Color(0xFFDCFCE7),
          ),
        ),
        const Positioned(
          bottom: -60,
          right: -30,
          child: _GlowCircle(
            size: 200,
            color: Color(0xFFE0F2FE),
          ),
        ),
        const Positioned(
          top: 120,
          right: -40,
          child: _BackdropShard(
            width: 180,
            height: 120,
            angle: 0.2,
            color: Color(0xFFE2E8F0),
          ),
        ),
        const Positioned(
          bottom: 180,
          left: -60,
          child: _BackdropShard(
            width: 220,
            height: 140,
            angle: -0.24,
            color: Color(0xFFDBEAFE),
          ),
        ),
      ],
    );
  }
}

class _GlowCircle extends StatelessWidget {
  const _GlowCircle({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withAlpha(153),
        boxShadow: [
          BoxShadow(
            color: color.withAlpha(128),
            blurRadius: 40,
            spreadRadius: 12,
          ),
        ],
      ),
    );
  }
}

class _BackdropShard extends StatelessWidget {
  const _BackdropShard({
    required this.width,
    required this.height,
    required this.angle,
    required this.color,
  });

  final double width;
  final double height;
  final double angle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Transform.rotate(
      angle: angle,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: color.withAlpha(180),
          borderRadius: BorderRadius.circular(36),
          boxShadow: [
            BoxShadow(
              color: color.withAlpha(120),
              blurRadius: 30,
              spreadRadius: 4,
            ),
          ],
        ),
      ),
    );
  }
}

class _PairingHeader extends StatelessWidget {
  const _PairingHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Agents & workspaces',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'Connect multiple agents and manage their sessions in dedicated workspaces.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF475569),
              ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: const [
            _FeatureChip(label: 'Multi-agent'),
            _FeatureChip(label: 'Session workspaces'),
            _FeatureChip(label: 'VNC ready'),
          ],
        ),
      ],
    );
  }
}

class _FeatureChip extends StatelessWidget {
  const _FeatureChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF3),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: const Color(0xFF166534),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class PairingStepCard extends StatelessWidget {
  const PairingStepCard({
    super.key,
    required this.title,
    required this.description,
    required this.child,
  });

  final String title;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          colors: [Color(0xFFE0F2FE), Color(0xFFDCFCE7)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(27),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withAlpha(14),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 4,
              width: 48,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: const LinearGradient(
                  colors: [Color(0xFF22C55E), Color(0xFF38BDF8)],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF64748B),
                  ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _PairingTokenDetails extends StatelessWidget {
  const _PairingTokenDetails({required this.payload});

  final PairingPayload payload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TokenRow(label: 'Token', value: payload.token),
          const SizedBox(height: 8),
          _TokenRow(label: 'Expires in', value: payload.expiryLabel),
          if (payload.localUrls.isNotEmpty) ...[
            const SizedBox(height: 8),
            _TokenRow(
              label: 'LAN endpoints',
              value: '${payload.localUrls.length} available',
            ),
          ],
          if (payload.requiresApproval) ...[
            const SizedBox(height: 8),
            const _TokenRow(
              label: 'Desktop approval',
              value: 'Required',
            ),
          ],
        ],
      ),
    );
  }
}

class _TokenRow extends StatelessWidget {
  const _TokenRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

class _InlineStatus extends StatelessWidget {
  const _InlineStatus({super.key, required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final background = isError ? const Color(0xFFFEE2E2) : const Color(0xFFDCFCE7);
    final textColor = isError ? const Color(0xFF991B1B) : const Color(0xFF166534);
    final icon =
        isError ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(10),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: textColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: textColor,
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EventVisuals {
  const _EventVisuals({
    required this.icon,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final IconData icon;
  final Color backgroundColor;
  final Color foregroundColor;
}

_EventVisuals _eventVisuals(String type) {
  switch (type.toLowerCase()) {
    case 'api':
      return const _EventVisuals(
        icon: Icons.http,
        backgroundColor: Color(0xFFDBEAFE),
        foregroundColor: Color(0xFF1D4ED8),
      );
    case 'terminal':
      return const _EventVisuals(
        icon: Icons.terminal,
        backgroundColor: Color(0xFFDCFCE7),
        foregroundColor: Color(0xFF166534),
      );
    case 'ai':
      return const _EventVisuals(
        icon: Icons.auto_awesome,
        backgroundColor: Color(0xFFEDE9FE),
        foregroundColor: Color(0xFF6D28D9),
      );
    case 'vnc':
      return const _EventVisuals(
        icon: Icons.desktop_windows,
        backgroundColor: Color(0xFFE0F2FE),
        foregroundColor: Color(0xFF0E7490),
      );
    case 'pairing':
      return const _EventVisuals(
        icon: Icons.link,
        backgroundColor: Color(0xFFFFEDD5),
        foregroundColor: Color(0xFF9A3412),
      );
    default:
      return const _EventVisuals(
        icon: Icons.timeline,
        backgroundColor: Color(0xFFE2E8F0),
        foregroundColor: Color(0xFF475569),
      );
  }
}

class _TimelineDetailScaffold extends StatelessWidget {
  const _TimelineDetailScaffold({
    required this.title,
    required this.body,
  });

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Stack(
        children: [
          const _PairingBackground(),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContextSectionCard extends StatelessWidget {
  const _ContextSectionCard({
    required this.title,
    required this.child,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(12),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF0F172A),
                ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF64748B),
                  ),
            ),
          ],
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF0F172A),
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: SelectableText(
        content,
        style: GoogleFonts.spaceMono(
          fontSize: 12,
          color: const Color(0xFF0F172A),
        ),
      ),
    );
  }
}

class _JsonTreeView extends StatelessWidget {
  const _JsonTreeView({
    required this.data,
    required this.changedPaths,
  });

  final dynamic data;
  final Set<String> changedPaths;

  @override
  Widget build(BuildContext context) {
    return _JsonTreeNode(
      label: 'JSON',
      value: data,
      path: '',
      depth: 0,
      changedPaths: changedPaths,
      initiallyExpanded: true,
    );
  }
}

class _JsonTreeNode extends StatelessWidget {
  const _JsonTreeNode({
    required this.label,
    required this.value,
    required this.path,
    required this.depth,
    required this.changedPaths,
    this.initiallyExpanded = false,
  });

  final String label;
  final dynamic value;
  final String path;
  final int depth;
  final Set<String> changedPaths;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasChildren = value is Map || value is List;
    final hasChanges = _hasChanges(path, changedPaths);
    if (hasChildren) {
      final entries = <_JsonTreeEntry>[];
      if (value is Map) {
        final map = Map<String, dynamic>.from(value as Map);
        final keys = map.keys.toList()..sort();
        for (final key in keys) {
          entries.add(
            _JsonTreeEntry(
              label: key,
              pathKey: key,
              value: map[key],
            ),
          );
        }
      } else if (value is List) {
        final list = value as List;
        for (var index = 0; index < list.length; index += 1) {
          entries.add(
            _JsonTreeEntry(
              label: '[$index]',
              pathKey: index.toString(),
              value: list[index],
            ),
          );
        }
      }
      final countLabel =
          value is List ? '${entries.length} items' : '${entries.length} fields';
      return Padding(
        padding: EdgeInsets.only(left: depth * 12),
        child: Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(left: 12),
            initiallyExpanded: initiallyExpanded,
            title: Row(
              children: [
                Text(
                  label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  countLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF94A3B8),
                  ),
                ),
                if (hasChanges) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFEDD5),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'changed',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF9A3412),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            children: [
              for (final entry in entries)
                _JsonTreeNode(
                  label: entry.label,
                  value: entry.value,
                  path: _childJsonPath(path, entry.pathKey),
                  depth: depth + 1,
                  changedPaths: changedPaths,
                ),
            ],
          ),
        ),
      );
    }

    final isChanged = _isChangedPath(path, changedPaths);
    return Padding(
      padding: EdgeInsets.only(left: depth * 12, bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: isChanged ? const Color(0xFFFFF7ED) : const Color(0xFFF8FAFC),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isChanged ? const Color(0xFFF59E0B) : const Color(0xFFE2E8F0),
          ),
        ),
        child: RichText(
          text: TextSpan(
            text: '$label: ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF1E293B),
              fontWeight: FontWeight.w600,
            ),
            children: [
              TextSpan(
                text: _formatJsonValue(value),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF0F172A),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JsonTreeEntry {
  const _JsonTreeEntry({
    required this.label,
    required this.pathKey,
    required this.value,
  });

  final String label;
  final String pathKey;
  final dynamic value;
}

bool _hasChanges(String path, Set<String> changes) {
  if (changes.isEmpty) {
    return false;
  }
  if (path.isEmpty) {
    return true;
  }
  return changes.any(
    (entry) => entry == path || entry.startsWith('$path/'),
  );
}

bool _isChangedPath(String path, Set<String> changes) {
  if (path.isEmpty) {
    return false;
  }
  return changes.contains(path);
}

String _formatJsonValue(dynamic value) {
  if (value == null) {
    return 'null';
  }
  if (value is String) {
    return '"$value"';
  }
  if (value is num || value is bool) {
    return value.toString();
  }
  return value.toString();
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.label,
    required this.backgroundColor,
    required this.textColor,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _AiInsightSummaryCard extends StatelessWidget {
  const _AiInsightSummaryCard({required this.insight});

  final AiInsightSummary insight;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = insight.summary.trim();
    final hasMissing = insight.missingFields.isNotEmpty;
    final isUnavailable = insight.isUnavailable;
    return _ContextSectionCard(
      title: 'AI Insight',
      subtitle: isUnavailable ? 'AI analysis unavailable' : 'Error analysis',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isUnavailable)
            _InlineStatus(
              message: summary,
              isError: true,
            )
          else
            Text(
              summary,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF1E293B),
                fontWeight: FontWeight.w600,
              ),
            ),
          if (!isUnavailable && hasMissing) ...[
            const SizedBox(height: 12),
            Text(
              'Missing fields',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFFB91C1C),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: insight.missingFields
                  .map((field) => _MissingFieldChip(label: field))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _MissingFieldChip extends StatelessWidget {
  const _MissingFieldChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFEE2E2),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFFB91C1C),
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class AiInsightSummary {
  const AiInsightSummary({
    required this.status,
    required this.summary,
    this.missingFields = const [],
  });

  final String status;
  final String summary;
  final List<String> missingFields;

  bool get isUnavailable => status == 'unavailable';

  Map<String, dynamic> toPayload() {
    return {
      'status': status,
      'summary': summary,
      if (missingFields.isNotEmpty) 'missing_fields': missingFields,
    };
  }

  static AiInsightSummary? fromPayload(Map<String, dynamic> payload) {
    final raw = payload['ai_insight'];
    if (raw is! Map) {
      return null;
    }
    final summary = raw['summary']?.toString() ?? '';
    if (summary.trim().isEmpty) {
      return null;
    }
    final status = raw['status']?.toString() ?? 'complete';
    final missingFields = _coerceStringList(raw['missing_fields']);
    return AiInsightSummary(
      status: status,
      summary: summary,
      missingFields: missingFields,
    );
  }

  static AiInsightSummary unavailable(String message) {
    return AiInsightSummary(
      status: 'unavailable',
      summary: message,
    );
  }
}

Map<String, dynamic> _applyAiInsight(
  Map<String, dynamic> payload,
  AiInsightSummary? insight,
) {
  final updated = Map<String, dynamic>.from(payload);
  if (insight == null) {
    updated.remove('ai_insight');
  } else {
    updated['ai_insight'] = insight.toPayload();
  }
  return updated;
}

AiInsightSummary? _buildApiInsight({
  required ApiResponseDetails? response,
  String? errorMessage,
  required String? agentBaseUrl,
}) {
  final status = response?.status;
  final hasError = errorMessage != null || (status != null && status >= 400);
  if (!hasError) {
    return null;
  }
  if (agentBaseUrl == null || agentBaseUrl.trim().isEmpty) {
    return AiInsightSummary.unavailable(
      'AI insights unavailable while disconnected from the desktop agent.',
    );
  }
  final errorText = _resolveErrorText(errorMessage, response?.body);
  final missingFields = _extractMissingFields(errorText, response?.body);
  if (missingFields.isNotEmpty) {
    final label = missingFields.length == 1 ? 'field' : 'fields';
    return AiInsightSummary(
      status: 'complete',
      summary:
          'Missing required $label: ${missingFields.join(', ')}. Update the request payload.',
      missingFields: missingFields,
    );
  }
  if (errorText != null && errorText.trim().isNotEmpty) {
    return AiInsightSummary(
      status: 'complete',
      summary: 'API error: ${_truncate(errorText, 160)}',
    );
  }
  if (status != null) {
    return AiInsightSummary(
      status: 'complete',
      summary:
          'API request failed with status $status. Review the response body for details.',
    );
  }
  return const AiInsightSummary(
    status: 'complete',
    summary: 'API request failed. Review the request and response details.',
  );
}

AiInsightSummary? _buildTerminalInsight({
  required List<TerminalOutputEntry> entries,
  required String status,
  String? errorMessage,
  int? exitCode,
  required String? agentBaseUrl,
}) {
  final loweredStatus = status.toLowerCase();
  final stderrLines = entries
      .where((entry) => entry.stream == TerminalStream.stderr)
      .map((entry) => entry.text.trim())
      .where((line) => line.isNotEmpty)
      .toList();
  final hasError = stderrLines.isNotEmpty ||
      errorMessage != null ||
      (exitCode != null && exitCode != 0) ||
      loweredStatus == 'disconnected' ||
      loweredStatus == 'failed' ||
      loweredStatus == 'error';
  if (!hasError) {
    return null;
  }
  if (agentBaseUrl == null || agentBaseUrl.trim().isEmpty) {
    return AiInsightSummary.unavailable(
      'AI insights unavailable while disconnected from the desktop agent.',
    );
  }
  final resolvedMessage = errorMessage?.trim();
  if (resolvedMessage != null && resolvedMessage.isNotEmpty) {
    return AiInsightSummary(
      status: 'complete',
      summary: 'Terminal error: ${_truncate(resolvedMessage, 160)}',
    );
  }
  if (stderrLines.isNotEmpty) {
    return AiInsightSummary(
      status: 'complete',
      summary: 'Terminal error: ${_truncate(stderrLines.first, 160)}',
    );
  }
  if (exitCode != null && exitCode != 0) {
    return AiInsightSummary(
      status: 'complete',
      summary: 'Terminal exited with code $exitCode.',
    );
  }
  if (loweredStatus == 'disconnected') {
    return const AiInsightSummary(
      status: 'complete',
      summary:
          'Terminal session disconnected before completion. Reconnect and rerun the command.',
    );
  }
  return const AiInsightSummary(
    status: 'complete',
    summary: 'Terminal error detected. Review stderr for details.',
  );
}

String? _resolveErrorText(String? errorMessage, dynamic body) {
  if (errorMessage != null && errorMessage.trim().isNotEmpty) {
    return errorMessage.trim();
  }
  if (body is Map) {
    final candidates = [
      body['error'],
      body['message'],
      body['detail'],
      body['title'],
    ];
    for (final candidate in candidates) {
      if (candidate != null) {
        final text = candidate.toString().trim();
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
    final errors = body['errors'];
    if (errors is List && errors.isNotEmpty) {
      final first = errors.first;
      if (first != null) {
        final text = first.toString().trim();
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
  }
  if (body is String && body.trim().isNotEmpty) {
    return body.trim();
  }
  return null;
}

List<String> _extractMissingFields(String? errorText, dynamic body) {
  final fields = <String>{};

  void addField(String? field) {
    final cleaned = field?.trim();
    if (cleaned == null || cleaned.isEmpty) {
      return;
    }
    fields.add(cleaned);
  }

  void addFields(Iterable<String> values) {
    for (final value in values) {
      addField(value);
    }
  }

  if (body is Map) {
    final missingValues = body['missing'] ??
        body['missing_fields'] ??
        body['missingFields'] ??
        body['required_fields'] ??
        body['requiredFields'] ??
        body['required'] ??
        body['fields'];
    addFields(_coerceStringList(missingValues));
    final errors = body['errors'];
    if (errors is Map) {
      for (final entry in errors.entries) {
        final key = entry.key?.toString();
        final value = entry.value?.toString().toLowerCase() ?? '';
        if (key != null &&
            (value.contains('required') || value.contains('missing'))) {
          addField(key);
        }
      }
    }
  }

  if (errorText != null && errorText.trim().isNotEmpty) {
    addFields(_extractMissingFieldsFromText(errorText));
  }

  return fields.toList();
}

List<String> _extractMissingFieldsFromText(String text) {
  final normalized = text.trim();
  if (normalized.isEmpty) {
    return [];
  }
  final patterns = [
    RegExp(
      r'''missing (?:required )?field[s]?:?\s*['"]?([A-Za-z0-9_.-]+)''',
      caseSensitive: false,
    ),
    RegExp(
      r'''required field[s]?:?\s*['"]?([A-Za-z0-9_.-]+)''',
      caseSensitive: false,
    ),
    RegExp(
      r'field[s]? ([A-Za-z0-9_.-]+) (?:is|are) required',
      caseSensitive: false,
    ),
  ];
  final results = <String>{};
  for (final pattern in patterns) {
    for (final match in pattern.allMatches(normalized)) {
      final raw = match.group(1);
      if (raw == null) {
        continue;
      }
      final trimmed =
          raw.replaceAll(RegExp(r'''^['"]|['"]$'''), '').trim();
      if (trimmed.contains(',')) {
        results.addAll(
          trimmed
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty),
        );
      } else if (trimmed.contains(' and ')) {
        results.addAll(
          trimmed
              .split(' and ')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty),
        );
      } else if (trimmed.isNotEmpty) {
        results.add(trimmed);
      }
    }
  }
  return results.toList();
}

List<String> _coerceStringList(dynamic raw) {
  if (raw == null) {
    return [];
  }
  if (raw is List) {
    return raw
        .map((entry) => entry?.toString() ?? '')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
  }
  if (raw is String) {
    return raw
        .split(',')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
  }
  if (raw is Map) {
    return raw.keys.map((key) => key.toString()).toList();
  }
  return [raw.toString()];
}

class ApiRequestDetails {
  const ApiRequestDetails({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
  });

  final String method;
  final String url;
  final Map<String, String> headers;
  final dynamic body;

  factory ApiRequestDetails.fromPayload(Map<String, dynamic> payload) {
    final methodValue =
        payload['method'] ?? payload['http_method'] ?? payload['httpMethod'];
    final urlValue = payload['url'] ?? payload['endpoint'] ?? payload['path'];
    return ApiRequestDetails(
      method: methodValue?.toString().toUpperCase() ?? 'UNKNOWN',
      url: urlValue?.toString() ?? 'Unknown URL',
      headers: _parseHeaders(payload['headers']),
      body: payload['body'] ?? payload['data'],
    );
  }
}

class ApiResponseDetails {
  const ApiResponseDetails({
    required this.status,
    required this.headers,
    this.body,
    this.latencyMs,
  });

  final int? status;
  final int? latencyMs;
  final Map<String, String> headers;
  final dynamic body;

  factory ApiResponseDetails.fromPayload(Map<String, dynamic> payload) {
    final statusValue =
        payload['status'] ?? payload['status_code'] ?? payload['statusCode'];
    final latencyValue =
        payload['latency_ms'] ?? payload['latencyMs'] ?? payload['latency'];
    return ApiResponseDetails(
      status: statusValue is num ? statusValue.toInt() : int.tryParse(
        statusValue?.toString() ?? '',
      ),
      latencyMs: latencyValue is num ? latencyValue.toInt() : int.tryParse(
        latencyValue?.toString() ?? '',
      ),
      headers: _parseHeaders(payload['headers']),
      body: payload['body'] ?? payload['data'],
    );
  }
}

class ApiEventContext {
  const ApiEventContext({
    required this.request,
    required this.response,
    this.previousResponse,
  });

  final ApiRequestDetails request;
  final ApiResponseDetails response;
  final ApiResponseDetails? previousResponse;

  static ApiEventContext? fromPayload(Map<String, dynamic> payload) {
    final rawRequest = payload['request'] ?? payload['api_request'];
    final rawResponse = payload['response'] ?? payload['api_response'];
    final rawPrevious = payload['previous_response'] ?? payload['previousResponse'];
    if (rawRequest is! Map || rawResponse is! Map) {
      return null;
    }
    return ApiEventContext(
      request: ApiRequestDetails.fromPayload(
        Map<String, dynamic>.from(rawRequest),
      ),
      response: ApiResponseDetails.fromPayload(
        Map<String, dynamic>.from(rawResponse),
      ),
      previousResponse: rawPrevious is Map
          ? ApiResponseDetails.fromPayload(
              Map<String, dynamic>.from(rawPrevious),
            )
          : null,
    );
  }
}

class ApiExplorerScreen extends StatefulWidget {
  const ApiExplorerScreen({
    super.key,
    required this.event,
    required this.context,
    required this.storage,
    required this.agentBaseUrl,
    required this.authToken,
    required this.clientId,
    required this.clientName,
  });

  final TimelineEvent event;
  final ApiEventContext context;
  final StorageRepository storage;
  final String? agentBaseUrl;
  final String? authToken;
  final String? clientId;
  final String? clientName;

  @override
  State<ApiExplorerScreen> createState() => _ApiExplorerScreenState();
}

class _ApiExplorerScreenState extends State<ApiExplorerScreen> {
  static const List<String> _httpMethods = [
    'GET',
    'POST',
    'PUT',
    'PATCH',
    'DELETE',
    'HEAD',
    'OPTIONS',
  ];

  late String _method;
  late TextEditingController _urlController;
  late TextEditingController _bodyController;
  late List<_HeaderEditor> _headerEditors;
  ApiResponseDetails? _response;
  ApiResponseDetails? _previousResponse;
  AiInsightSummary? _aiInsight;
  Set<String> _changedPaths = {};
  String? _bodyError;
  String? _requestError;
  bool _isSending = false;
  http.Client? _httpClient;
  AgentCommandClient? _agentClient;

  @override
  void initState() {
    super.initState();
    final request = widget.context.request;
    final method = request.method.toUpperCase();
    _method = _httpMethods.contains(method) ? method : _httpMethods.first;
    _urlController = TextEditingController(text: request.url);
    _bodyController = TextEditingController(
      text: _stringifyBody(request.body) ?? '',
    );
    _headerEditors = _buildHeaderEditors(request.headers);
    _response = widget.context.response;
    _previousResponse = widget.context.previousResponse;
    _changedPaths = _collectChangedPaths(
      _response?.body,
      _previousResponse?.body,
    );
    _aiInsight = AiInsightSummary.fromPayload(widget.event.payload) ??
        _buildApiInsight(
          response: _response,
          errorMessage: widget.event.payload['error_message']?.toString(),
          agentBaseUrl: widget.agentBaseUrl,
        );
    _configureAgentClient();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _bodyController.dispose();
    for (final header in _headerEditors) {
      header.dispose();
    }
    _httpClient?.close();
    super.dispose();
  }

  void _configureAgentClient() {
    final baseUrl = widget.agentBaseUrl?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      _agentClient = null;
      return;
    }
    _httpClient = http.Client();
    _agentClient = AgentCommandClient(
      baseUrl: baseUrl,
      client: _httpClient!,
      authToken: widget.authToken,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
  }

  List<_HeaderEditor> _buildHeaderEditors(Map<String, String> headers) {
    if (headers.isEmpty) {
      return [];
    }
    return headers.entries
        .map(
          (entry) => _HeaderEditor(
            keyText: entry.key,
            valueText: entry.value,
          ),
        )
        .toList();
  }

  void _addHeader() {
    setState(() {
      _headerEditors.add(_HeaderEditor());
    });
  }

  void _removeHeader(int index) {
    setState(() {
      final header = _headerEditors.removeAt(index);
      header.dispose();
    });
  }

  Map<String, String> _collectHeaders() {
    final headers = <String, String>{};
    for (final entry in _headerEditors) {
      final key = entry.keyController.text.trim();
      if (key.isEmpty) {
        continue;
      }
      headers[key] = entry.valueController.text.trim();
    }
    return headers;
  }

  bool _hasResponse(ApiResponseDetails? response) {
    if (response == null) {
      return false;
    }
    final bodyText = _stringifyBody(response.body);
    return response.status != null ||
        response.latencyMs != null ||
        response.headers.isNotEmpty ||
        (bodyText != null && bodyText.trim().isNotEmpty);
  }

  Future<void> _sendRequest() async {
    if (_isSending) {
      return;
    }

    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _requestError = 'Enter a request URL.';
      });
      return;
    }

    dynamic parsedBody;
    final rawBody = _bodyController.text.trim();
    if (rawBody.isNotEmpty) {
      try {
        parsedBody = jsonDecode(rawBody);
      } catch (_) {
        setState(() {
          _bodyError = 'Body must be valid JSON.';
          _requestError = null;
        });
        return;
      }
    }

    final headers = _collectHeaders();
    final requestDetails = ApiRequestDetails(
      method: _method,
      url: url,
      headers: headers,
      body: parsedBody,
    );

    final agentClient = _agentClient;
    if (agentClient == null) {
      const errorMessage = 'Connect to the desktop agent to send API requests.';
      final insight = AiInsightSummary.unavailable(
        'AI insights unavailable while disconnected from the desktop agent.',
      );
      setState(() {
        _requestError = errorMessage;
        _aiInsight = insight;
      });
      await _persistApiFailure(
        request: requestDetails,
        errorMessage: errorMessage,
        insight: insight,
      );
      return;
    }

    setState(() {
      _isSending = true;
      _bodyError = null;
      _requestError = null;
    });

    try {
      final result = await agentClient.sendApiCommand(
        method: _method,
        url: url,
        headers: headers,
        body: parsedBody,
      );
      if (!mounted) {
        return;
      }
      final previousResponse = _response;
      final response = result.response;
      final changedPaths = _collectChangedPaths(
        response.body,
        previousResponse?.body,
      );
      final insight = _buildApiInsight(
        response: response,
        errorMessage: null,
        agentBaseUrl: widget.agentBaseUrl,
      );
      setState(() {
        _previousResponse = previousResponse;
        _response = response;
        _changedPaths = changedPaths;
        _aiInsight = insight;
      });
      await _persistApiEvent(
        request: result.request,
        response: response,
        previousResponse: previousResponse,
        insight: insight,
      );
    } on AgentCommandFailure catch (error) {
      if (!mounted) {
        return;
      }
      final insight = _buildApiInsight(
        response: null,
        errorMessage: error.message,
        agentBaseUrl: widget.agentBaseUrl,
      );
      setState(() {
        _requestError = error.message;
        _aiInsight = insight;
      });
      await _persistApiFailure(
        request: requestDetails,
        errorMessage: error.message,
        insight: insight,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      final message = 'Request failed: ${error.toString()}';
      final insight = _buildApiInsight(
        response: null,
        errorMessage: message,
        agentBaseUrl: widget.agentBaseUrl,
      );
      setState(() {
        _requestError = message;
        _aiInsight = insight;
      });
      await _persistApiFailure(
        request: requestDetails,
        errorMessage: message,
        insight: insight,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<void> _persistApiEvent({
    required ApiRequestDetails request,
    required ApiResponseDetails response,
    required ApiResponseDetails? previousResponse,
    required AiInsightSummary? insight,
  }) async {
    final payload = Map<String, dynamic>.from(widget.event.payload);
    payload['request'] = {
      'method': request.method,
      'url': request.url,
      'headers': request.headers,
      'body': request.body,
    };
    payload['response'] = {
      'status': response.status,
      'latency_ms': response.latencyMs,
      'headers': response.headers,
      'body': response.body,
    };
    if (previousResponse != null && _hasResponse(previousResponse)) {
      payload['previous_response'] = {
        'status': previousResponse.status,
        'latency_ms': previousResponse.latencyMs,
        'headers': previousResponse.headers,
        'body': previousResponse.body,
      };
    }
    payload.remove('error_message');
    final updatedPayload = _applyAiInsight(payload, insight);

    final updatedEvent = TimelineEvent(
      id: widget.event.id,
      sessionId: widget.event.sessionId,
      type: widget.event.type,
      title: widget.event.title,
      payload: updatedPayload,
      createdAt: widget.event.createdAt,
    );
    try {
      await widget.storage.insertTimelineEvent(updatedEvent);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save API response: ${error.toString()}',
          ),
        ),
      );
    }
  }

  Future<void> _persistApiFailure({
    required ApiRequestDetails request,
    required String errorMessage,
    required AiInsightSummary? insight,
  }) async {
    final payload = Map<String, dynamic>.from(widget.event.payload);
    payload['request'] = {
      'method': request.method,
      'url': request.url,
      'headers': request.headers,
      'body': request.body,
    };
    payload['error_message'] = errorMessage;
    final updatedPayload = _applyAiInsight(payload, insight);

    final updatedEvent = TimelineEvent(
      id: widget.event.id,
      sessionId: widget.event.sessionId,
      type: widget.event.type,
      title: widget.event.title,
      payload: updatedPayload,
      createdAt: widget.event.createdAt,
    );
    try {
      await widget.storage.insertTimelineEvent(updatedEvent);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save API failure: ${error.toString()}',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final response = _response;
    final responseStatus = response?.status;
    final statusLabel =
        responseStatus == null ? 'Unknown' : responseStatus.toString();
    final statusColor = _statusPillColor(responseStatus);
    final responseBody = response?.body;
    final responseBodyText = _stringifyBody(responseBody);
    final hasResponse = _hasResponse(response);
    final hasDiff = _changedPaths.isNotEmpty;
    final aiInsight = _aiInsight;

    return _TimelineDetailScaffold(
      title: 'API Explorer',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.event.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Recorded ${_formatTimestamp(widget.event.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 20),
            _ContextSectionCard(
              title: 'Request',
              subtitle: 'Method, URL, headers, and JSON body',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Method',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  InputDecorator(
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _method,
                        isExpanded: true,
                        items: _httpMethods
                            .map(
                              (method) => DropdownMenuItem<String>(
                                value: method,
                                child: Text(method),
                              ),
                            )
                            .toList(),
                        onChanged: _isSending
                            ? null
                            : (value) {
                                if (value == null) {
                                  return;
                                }
                                setState(() {
                                  _method = value;
                                });
                              },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'URL',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    key: const Key('apiUrlField'),
                    controller: _urlController,
                    decoration: const InputDecoration(
                      hintText: 'https://api.example.com/login',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.done,
                    onChanged: (_) {
                      if (_requestError != null) {
                        setState(() {
                          _requestError = null;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Headers',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_headerEditors.isEmpty)
                    const _EmptyHint(text: 'No headers set.')
                  else
                    Column(
                      children: [
                        for (final entry in _headerEditors)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: entry.keyController,
                                    decoration: const InputDecoration(
                                      hintText: 'Header',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: entry.valueController,
                                    decoration: const InputDecoration(
                                      hintText: 'Value',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                IconButton(
                                  onPressed: _isSending
                                      ? null
                                      : () => _removeHeader(
                                            _headerEditors.indexOf(entry),
                                          ),
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _isSending ? null : _addHeader,
                      icon: const Icon(Icons.add),
                      label: const Text('Add header'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Body',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    key: const Key('apiBodyField'),
                    controller: _bodyController,
                    maxLines: 6,
                    decoration: InputDecoration(
                      hintText: '{"email":"user@example.com"}',
                      border: const OutlineInputBorder(),
                      errorText: _bodyError,
                    ),
                    onChanged: (_) {
                      if (_bodyError != null) {
                        setState(() {
                          _bodyError = null;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  if (_requestError != null) ...[
                    _InlineStatus(
                      message: _requestError!,
                      isError: true,
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton.icon(
                    key: const Key('apiSendButton'),
                    onPressed: _isSending ? null : _sendRequest,
                    icon: _isSending
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send),
                    label: Text(_isSending ? 'Sending' : 'Send request'),
                  ),
                ],
              ),
            ),
            _ContextSectionCard(
              title: 'Response',
              subtitle: hasResponse
                  ? 'Status, latency, headers, and body'
                  : 'Awaiting response from desktop agent',
              child: hasResponse
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _InfoPill(
                              label: 'Status $statusLabel',
                              backgroundColor: statusColor.background,
                              textColor: statusColor.foreground,
                            ),
                            if (response?.latencyMs != null) ...[
                              const SizedBox(width: 12),
                              _InfoPill(
                                label: '${response!.latencyMs} ms',
                                backgroundColor: const Color(0xFFEDE9FE),
                                textColor: const Color(0xFF6D28D9),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 16),
                        _HeadersBlock(headers: response!.headers),
                        const SizedBox(height: 16),
                        Text(
                          'Body',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF64748B),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (hasDiff) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Changed fields highlighted from previous run.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: const Color(0xFFB45309),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                        const SizedBox(height: 8),
                        if (responseBody is Map || responseBody is List)
                          _JsonTreeView(
                            data: responseBody,
                            changedPaths: _changedPaths,
                          )
                        else if (responseBodyText != null)
                          _CodeBlock(content: responseBodyText)
                        else
                          const _EmptyHint(text: 'No response body recorded.'),
                      ],
                    )
                  : const _EmptyHint(text: 'No response recorded yet.'),
            ),
            if (aiInsight != null) ...[
              const SizedBox(height: 16),
              _AiInsightSummaryCard(insight: aiInsight),
            ],
          ],
        ),
      ),
    );
  }
}

class _HeaderEditor {
  _HeaderEditor({String? keyText, String? valueText})
      : keyController = TextEditingController(text: keyText ?? ''),
        valueController = TextEditingController(text: valueText ?? '');

  final TextEditingController keyController;
  final TextEditingController valueController;

  void dispose() {
    keyController.dispose();
    valueController.dispose();
  }
}

enum TerminalStream { stdout, stderr }

class TerminalOutputEntry {
  const TerminalOutputEntry({
    required this.stream,
    required this.text,
    required this.timestamp,
  });

  final TerminalStream stream;
  final String text;
  final DateTime timestamp;
}

class TerminalSessionView {
  const TerminalSessionView({
    required this.session,
    required this.output,
    this.nextSeq = 0,
    this.exitCode,
    this.lastCommand,
    this.lastEvent,
  });

  final ToolSession session;
  final List<TerminalOutputEntry> output;
  final int nextSeq;
  final int? exitCode;
  final String? lastCommand;
  final TimelineEvent? lastEvent;

  TerminalSessionView copyWith({
    ToolSession? session,
    List<TerminalOutputEntry>? output,
    int? nextSeq,
    int? exitCode,
    String? lastCommand,
    TimelineEvent? lastEvent,
  }) {
    return TerminalSessionView(
      session: session ?? this.session,
      output: output ?? this.output,
      nextSeq: nextSeq ?? this.nextSeq,
      exitCode: exitCode ?? this.exitCode,
      lastCommand: lastCommand ?? this.lastCommand,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}

class _TerminalGrid {
  const _TerminalGrid({required this.cols, required this.rows});

  final int cols;
  final int rows;

  @override
  bool operator ==(Object other) {
    return other is _TerminalGrid &&
        other.cols == cols &&
        other.rows == rows;
  }

  @override
  int get hashCode => Object.hash(cols, rows);
}

class _TerminalKeySpec {
  const _TerminalKeySpec({
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.isActive = false,
    this.isLocked = false,
    this.isEmphasis = false,
    this.isRepeatable = false,
    this.minWidth,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isActive;
  final bool isLocked;
  final bool isEmphasis;
  final bool isRepeatable;
  final double? minWidth;
}

class _TerminalSearchMatch {
  const _TerminalSearchMatch({
    required this.line,
    required this.start,
    required this.end,
  });

  final int line;
  final int start;
  final int end;
}

class _TerminalThemeSpec {
  const _TerminalThemeSpec({
    required this.label,
    required this.theme,
  });

  final String label;
  final TerminalTheme theme;
}

class _TerminalToolAction {
  const _TerminalToolAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isActive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;
}

class _TerminalKeyButton extends StatefulWidget {
  const _TerminalKeyButton({required this.spec});

  final _TerminalKeySpec spec;

  @override
  State<_TerminalKeyButton> createState() => _TerminalKeyButtonState();
}

class _TerminalKeyButtonState extends State<_TerminalKeyButton> {
  Timer? _repeatTimer;
  Timer? _repeatStartTimer;

  @override
  void dispose() {
    _cancelRepeat();
    super.dispose();
  }

  void _cancelRepeat() {
    _repeatStartTimer?.cancel();
    _repeatStartTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  void _startRepeat() {
    if (!widget.spec.isRepeatable) {
      return;
    }
    widget.spec.onTap();
    _repeatStartTimer = Timer(const Duration(milliseconds: 300), () {
      _repeatTimer = Timer.periodic(
        const Duration(milliseconds: 70),
        (_) => widget.spec.onTap(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final isLocked = spec.isLocked;
    final isActive = spec.isActive;
    final baseColor = isLocked
        ? const Color(0xFF7DD3FC)
        : (isActive
            ? const Color(0xFF34D399)
            : (spec.isEmphasis
                ? const Color(0xFFF8FAFC)
                : const Color(0xFFCBD5F5)));
    final background = isLocked
        ? const Color(0xFF0B1F33)
        : (isActive ? const Color(0xFF0B3B2E) : const Color(0xFF111827));
    final borderColor = isLocked
        ? const Color(0xFF38BDF8)
        : (isActive
            ? const Color(0xFF34D399)
            : (spec.isEmphasis
                ? const Color(0xFF475569)
                : const Color(0xFF1F2937)));
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        spec.onTap();
      },
      onLongPressStart: (_) {
        if (spec.onLongPress != null) {
          HapticFeedback.selectionClick();
          spec.onLongPress!();
          return;
        }
        _startRepeat();
      },
      onLongPressEnd: (_) => _cancelRepeat(),
      onLongPressCancel: _cancelRepeat,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(minWidth: spec.minWidth ?? 0),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 6,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          spec.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: baseColor,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
        ),
      ),
    );
  }
}

class _TerminalToolButton extends StatelessWidget {
  const _TerminalToolButton({required this.action});

  final _TerminalToolAction action;

  @override
  Widget build(BuildContext context) {
    final foreground = action.isActive
        ? const Color(0xFFE2E8F0)
        : const Color(0xFFCBD5F5);
    final background = action.isActive
        ? const Color(0xFF1E293B)
        : const Color(0xFF0F172A);
    final borderColor = action.isActive
        ? const Color(0xFF38BDF8)
        : const Color(0xFF1F2937);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          action.onTap();
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Icon(action.icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                action.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteTerminalFetchResult {
  const _RemoteTerminalFetchResult({
    required this.sessions,
    required this.isSuccess,
    this.errorMessage,
  });

  final List<RemoteTerminalSession> sessions;
  final bool isSuccess;
  final String? errorMessage;

  factory _RemoteTerminalFetchResult.success(
    List<RemoteTerminalSession> sessions,
  ) {
    return _RemoteTerminalFetchResult(
      sessions: sessions,
      isSuccess: true,
    );
  }

  factory _RemoteTerminalFetchResult.failure(String message) {
    return _RemoteTerminalFetchResult(
      sessions: const [],
      isSuccess: false,
      errorMessage: message,
    );
  }
}

class TerminalWorkspaceScreen extends StatefulWidget {
  const TerminalWorkspaceScreen({
    super.key,
    required this.storage,
    required this.agentBaseUrl,
    required this.authToken,
    required this.clientId,
    required this.clientName,
    this.initialSession,
    this.initialEvent,
    this.agentId,
  });

  final StorageRepository storage;
  final String? agentBaseUrl;
  final String? authToken;
  final String? clientId;
  final String? clientName;
  final ToolSession? initialSession;
  final TimelineEvent? initialEvent;
  final String? agentId;

  @override
  State<TerminalWorkspaceScreen> createState() =>
      _TerminalWorkspaceScreenState();
}

class _TerminalWorkspaceScreenState extends State<TerminalWorkspaceScreen> {
  static const int _defaultCols = 120;
  static const int _defaultRows = 32;
  static const int _maxOutputEntries = 800;
  static const int _terminalLabelMax = 80;
  static const int _terminalMaxLines = 8000;
  static const Duration _pollInterval = Duration(milliseconds: 900);
  static const Duration _terminalPersistInterval = Duration(milliseconds: 900);
  static const String _missingRemoteSessionReason =
      'Session closed because the desktop agent restarted.';

  final FocusNode _terminalFocusNode = FocusNode();
  final TerminalController _terminalController = TerminalController();
  final ScrollController _terminalScrollController = ScrollController();
  Map<String, Terminal> _terminals = {};
  final Map<String, List<int>> _commandBuffers = {};
  String? _statusMessage;
  bool _statusIsError = false;
  bool _isLoading = true;
  String? _loadError;
  String? _remoteFetchError;
  bool _autoRunTriggered = false;
  List<TerminalSessionView> _sessions = [];
  String? _activeSessionId;
  http.Client? _httpClient;
  AgentCommandClient? _agentClient;
  Timer? _pollTimer;
  bool _isPolling = false;
  WebSocketChannel? _terminalChannel;
  StreamSubscription<dynamic>? _terminalChannelSub;
  String? _terminalChannelSessionId;
  bool _terminalChannelReady = false;
  final Map<String, _TerminalGrid> _terminalSizes = {};
  final Map<String, DateTime> _terminalPersistedAt = {};
  Timer? _terminalReconnectTimer;
  Timer? _terminalKeepaliveTimer;
  int _terminalReconnectAttempts = 0;
  bool _ctrlModifier = false;
  bool _ctrlLocked = false;
  bool _altModifier = false;
  bool _altLocked = false;
  bool _shiftModifier = false;
  bool _shiftLocked = false;
  bool _showFnRow = false;
  int _secondaryKeyPage = 0;
  bool _showKeyBar = true;
  bool _showNavOnly = false;
  bool _mouseInputEnabled = false;
  bool _hardwareKeyboardOnly = false;
  bool _isTerminalAtBottom = true;
  final Set<String> _terminalGapWarned = {};
  final Set<String> _terminalTruncateWarned = {};
  SelectionMode _selectionMode = SelectionMode.line;
  double _terminalFontSize = 13;
  int _terminalThemeIndex = 0;
  String _terminalSearchQuery = '';
  bool _terminalSearchCaseSensitive = false;
  int _terminalSearchIndex = -1;
  final List<_TerminalSearchMatch> _terminalSearchMatches = [];
  final List<TerminalHighlight> _terminalSearchHighlights = [];
  Timer? _terminalSearchRefreshTimer;

  bool get _hasActiveModifiers =>
      _ctrlModifier || _altModifier || _shiftModifier;

  @override
  void initState() {
    super.initState();
    _configureAgentClient();
    _terminalController.setSelectionMode(_selectionMode);
    _applyPointerInputMode();
    _terminalScrollController.addListener(_handleTerminalScroll);
    _loadSessions();
  }

  @override
  void dispose() {
    _terminalFocusNode.dispose();
    _terminalScrollController
      ..removeListener(_handleTerminalScroll)
      ..dispose();
    _pollTimer?.cancel();
    _disconnectTerminalStream();
    _terminalReconnectTimer?.cancel();
    _terminalKeepaliveTimer?.cancel();
    _terminalSearchRefreshTimer?.cancel();
    _httpClient?.close();
    super.dispose();
  }

  void _configureAgentClient() {
    final baseUrl = widget.agentBaseUrl?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      _agentClient = null;
      _httpClient?.close();
      _httpClient = null;
      return;
    }
    _httpClient?.close();
    _httpClient = http.Client();
    _agentClient = AgentCommandClient(
      baseUrl: baseUrl,
      client: _httpClient!,
      authToken: widget.authToken,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
  }

  Future<_RemoteTerminalFetchResult> _fetchRemoteTerminalSessions() async {
    final client = _agentClient;
    if (client == null) {
      return _RemoteTerminalFetchResult.failure(
        'Connect to the desktop agent to load sessions.',
      );
    }
    try {
      final sessions = await client.fetchTerminalSessions();
      return _RemoteTerminalFetchResult.success(sessions);
    } on AgentCommandFailure catch (error) {
      return _RemoteTerminalFetchResult.failure(error.message);
    } catch (_) {
      return _RemoteTerminalFetchResult.failure(
        'Unable to load terminal sessions.',
      );
    }
  }

  Uri? _terminalWsUri(String baseUrl, String sessionId) {
    Uri base;
    try {
      base = Uri.parse(baseUrl);
    } catch (_) {
      return null;
    }
    final scheme = switch (base.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      'wss' => 'wss',
      'ws' => 'ws',
      _ => '',
    };
    if (scheme.isEmpty) {
      return null;
    }
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final path =
        basePath.isEmpty ? '/terminal/$sessionId' : '$basePath/terminal/$sessionId';
    final queryParameters = Map<String, String>.from(base.queryParameters);
    final token = widget.authToken?.trim();
    if (token != null && token.isNotEmpty) {
      queryParameters['auth_token'] = token;
    }
    final clientId = widget.clientId?.trim();
    if (clientId != null && clientId.isNotEmpty) {
      queryParameters['client_id'] = clientId;
    }
    final clientName = widget.clientName?.trim();
    if (clientName != null && clientName.isNotEmpty) {
      queryParameters['client_name'] = clientName;
    }
    return base.replace(
      scheme: scheme,
      path: path,
      queryParameters: queryParameters,
    );
  }

  TerminalTargetPlatform _resolveTerminalPlatform() {
    if (kIsWeb) {
      return TerminalTargetPlatform.web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return TerminalTargetPlatform.android;
      case TargetPlatform.iOS:
        return TerminalTargetPlatform.ios;
      case TargetPlatform.fuchsia:
        return TerminalTargetPlatform.fuchsia;
      case TargetPlatform.linux:
        return TerminalTargetPlatform.linux;
      case TargetPlatform.macOS:
        return TerminalTargetPlatform.macos;
      case TargetPlatform.windows:
        return TerminalTargetPlatform.windows;
    }
  }

  Terminal _buildTerminalForSession(String sessionId) {
    final terminal = Terminal(
      maxLines: _terminalMaxLines,
      platform: _resolveTerminalPlatform(),
      onOutput: (data) => _handleTerminalInput(sessionId, data),
    );
    terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
      // Keep pixel values unused for now; grid size drives PTY resize.
      unawaited(_sendTerminalResize(sessionId, cols, rows));
    };
    return terminal;
  }

  void _hydrateTerminal(
    String sessionId,
    Terminal terminal,
    List<TerminalOutputEntry> entries,
  ) {
    if (entries.isEmpty) {
      return;
    }
    final buffer = StringBuffer();
    for (final entry in entries) {
      buffer.write(entry.text);
    }
    terminal.write(buffer.toString());
    if (sessionId == _activeSessionId) {
      if (_isTerminalAtBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _jumpToTerminalBottom();
          }
        });
      }
      _scheduleTerminalSearchRefresh();
    }
  }

  void _focusTerminal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      FocusScope.of(context).requestFocus(_terminalFocusNode);
    });
  }

  Terminal? _activeTerminal() {
    final active = _activeSession;
    if (active == null) {
      return null;
    }
    return _terminals[active.session.id];
  }

  String? _sessionStatusReason(TerminalSessionView? session) {
    if (session == null) {
      return null;
    }
    final status = session.session.status.toLowerCase();
    if (!_isTerminalClosed(status) &&
        status != 'disconnected' &&
        status != 'error') {
      return null;
    }
    final reason = session.lastEvent?.payload['error_message']?.toString();
    if (reason == null) {
      return null;
    }
    final trimmed = reason.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _setTerminalStatusMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _statusMessage = message;
      _statusIsError = isError;
    });
  }

  Terminal? _requireActiveTerminal() {
    final active = _activeSession;
    if (active == null) {
      _setTerminalStatusMessage('Create a session to start.');
      return null;
    }
    final status = active.session.status.toLowerCase();
    if (_isTerminalClosed(status)) {
      _setTerminalStatusMessage(
        'This session is no longer active.',
        isError: true,
      );
      return null;
    }
    if (status == 'disconnected' || status == 'error') {
      _setTerminalStatusMessage(
        'Session disconnected. Reconnect to type.',
        isError: true,
      );
      return null;
    }
    return _terminals[active.session.id];
  }

  void _toggleCtrlModifier() {
    setState(() {
      if (_ctrlLocked) {
        _ctrlLocked = false;
        _ctrlModifier = false;
      } else {
        _ctrlModifier = !_ctrlModifier;
        _ctrlLocked = false;
      }
    });
    _focusTerminal();
  }

  void _toggleCtrlLock() {
    setState(() {
      _ctrlLocked = !_ctrlLocked;
      _ctrlModifier = _ctrlLocked;
    });
    _focusTerminal();
  }

  void _toggleAltModifier() {
    setState(() {
      if (_altLocked) {
        _altLocked = false;
        _altModifier = false;
      } else {
        _altModifier = !_altModifier;
        _altLocked = false;
      }
    });
    _focusTerminal();
  }

  void _toggleAltLock() {
    setState(() {
      _altLocked = !_altLocked;
      _altModifier = _altLocked;
    });
    _focusTerminal();
  }

  void _toggleShiftModifier() {
    setState(() {
      if (_shiftLocked) {
        _shiftLocked = false;
        _shiftModifier = false;
      } else {
        _shiftModifier = !_shiftModifier;
        _shiftLocked = false;
      }
    });
    _focusTerminal();
  }

  void _toggleShiftLock() {
    setState(() {
      _shiftLocked = !_shiftLocked;
      _shiftModifier = _shiftLocked;
    });
    _focusTerminal();
  }

  void _toggleFnRow() {
    setState(() {
      _showFnRow = !_showFnRow;
    });
    _focusTerminal();
  }

  void _showBaseKeys() {
    setState(() {
      _secondaryKeyPage = 0;
    });
    _focusTerminal();
  }

  void _showAdvancedKeys() {
    setState(() {
      _secondaryKeyPage = 1;
    });
    _focusTerminal();
  }

  void _showSymbolKeys() {
    setState(() {
      _secondaryKeyPage = 2;
    });
    _focusTerminal();
  }

  void _toggleNavOnly() {
    setState(() {
      _showNavOnly = !_showNavOnly;
    });
    _focusTerminal();
  }

  void _clearModifiers() {
    setState(() {
      _ctrlModifier = false;
      _ctrlLocked = false;
      _altModifier = false;
      _altLocked = false;
      _shiftModifier = false;
      _shiftLocked = false;
    });
    _focusTerminal();
  }

  void _consumeOneShotModifiers() {
    if ((!_ctrlModifier || _ctrlLocked) &&
        (!_altModifier || _altLocked) &&
        (!_shiftModifier || _shiftLocked)) {
      return;
    }
    setState(() {
      if (_ctrlModifier && !_ctrlLocked) {
        _ctrlModifier = false;
      }
      if (_altModifier && !_altLocked) {
        _altModifier = false;
      }
      if (_shiftModifier && !_shiftLocked) {
        _shiftModifier = false;
      }
    });
  }

  void _applyPointerInputMode() {
    _terminalController.setPointerInputs(
      _mouseInputEnabled
          ? const PointerInputs.all()
          : const PointerInputs.none(),
    );
  }

  void _handleTerminalScroll() {
    if (!_terminalScrollController.hasClients) {
      return;
    }
    final position = _terminalScrollController.position;
    final isAtBottom = position.pixels >= position.maxScrollExtent - 4;
    if (isAtBottom == _isTerminalAtBottom) {
      return;
    }
    setState(() {
      _isTerminalAtBottom = isAtBottom;
    });
  }

  void _jumpToTerminalBottom() {
    if (!_terminalScrollController.hasClients) {
      return;
    }
    _terminalScrollController.animateTo(
      _terminalScrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _toggleMouseInput() {
    setState(() {
      _mouseInputEnabled = !_mouseInputEnabled;
    });
    _applyPointerInputMode();
    _focusTerminal();
  }

  void _toggleHardwareKeyboardOnly() {
    setState(() {
      _hardwareKeyboardOnly = !_hardwareKeyboardOnly;
    });
    _focusTerminal();
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = _selectionMode == SelectionMode.line
          ? SelectionMode.block
          : SelectionMode.line;
    });
    _terminalController.setSelectionMode(_selectionMode);
    _focusTerminal();
  }

  void _adjustTerminalFontSize(double nextSize) {
    setState(() {
      _terminalFontSize = nextSize;
    });
    _focusTerminal();
  }

  void _setTerminalTheme(int index) {
    setState(() {
      _terminalThemeIndex = index;
    });
    _focusTerminal();
  }

  void _sendTerminalKey(TerminalKey key, {bool shift = false}) {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.keyInput(
      key,
      ctrl: _ctrlModifier,
      alt: _altModifier,
      shift: shift || _shiftModifier,
    );
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendTerminalKeyCombo(
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.keyInput(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
    );
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendTerminalChar(String value) {
    final terminal = _requireActiveTerminal();
    if (terminal == null || value.isEmpty) {
      return;
    }
    if (_ctrlModifier && value == ' ') {
      terminal.textInput('\x00');
      _focusTerminal();
      return;
    }
    if (_altModifier && value == ' ') {
      terminal.textInput('\x1b ');
      _focusTerminal();
      return;
    }
    final normalized = _shiftModifier ? value.toUpperCase() : value;
    final charCode = normalized.runes.first;
    if (_ctrlModifier || _altModifier) {
      final handled = terminal.charInput(
        charCode,
        ctrl: _ctrlModifier,
        alt: _altModifier,
      );
      if (!handled) {
        terminal.textInput(normalized);
      }
    } else {
      terminal.textInput(normalized);
    }
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendCtrlCombo(String value) {
    final terminal = _requireActiveTerminal();
    if (terminal == null || value.isEmpty) {
      return;
    }
    terminal.charInput(value.runes.first, ctrl: true);
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendCtrlNull() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.textInput('\x00');
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendAltCombo(String value) {
    final terminal = _requireActiveTerminal();
    if (terminal == null || value.isEmpty) {
      return;
    }
    terminal.charInput(value.runes.first, alt: true);
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendPairedChars(String open, String close) {
    if (_hasActiveModifiers) {
      _sendTerminalChar(open);
      return;
    }
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.textInput('$open$close');
    terminal.keyInput(TerminalKey.arrowLeft);
    _focusTerminal();
  }

  String _applyTerminalModifiers(String data) {
    if (!_hasActiveModifiers || data.isEmpty) {
      return data;
    }
    final runes = data.runes.toList(growable: false);
    if (runes.length != 1) {
      return data;
    }
    final rune = runes.first;
    if (rune < 32 || rune == 127) {
      return data;
    }
    if (_ctrlModifier && rune == 32) {
      return '\x00';
    }
    if (_altModifier && rune == 32) {
      return '\x1b ';
    }
    var normalized = data;
    if (_shiftModifier) {
      final upper = data.toUpperCase();
      if (upper.runes.length == 1) {
        normalized = upper;
      }
    }
    final normalizedRune = normalized.runes.first;
    if (_ctrlModifier) {
      final mapped = _mapCtrlRune(normalizedRune);
      if (mapped != null) {
        return String.fromCharCode(mapped);
      }
    }
    if (_altModifier &&
        _resolveTerminalPlatform() != TerminalTargetPlatform.macos) {
      final mapped = _mapAltRune(normalizedRune);
      if (mapped != null) {
        return String.fromCharCodes([0x1b, mapped]);
      }
    }
    return normalized;
  }

  int? _mapCtrlRune(int rune) {
    if (rune >= 97 && rune <= 122) {
      return rune - 96;
    }
    if (rune >= 91 && rune <= 95) {
      return rune - 91 + 27;
    }
    return null;
  }

  int? _mapAltRune(int rune) {
    if (rune >= 97 && rune <= 122) {
      return rune - 97 + 65;
    }
    return null;
  }

  Future<void> _copySelection() async {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    final selection = _terminalController.selection;
    if (selection == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No selection to copy.')),
      );
      return;
    }
    final text = terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard.')),
    );
  }

  Future<void> _pasteClipboard() async {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    terminal.paste(text);
    _focusTerminal();
  }

  void _selectAllInTerminal() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    _terminalController.setSelection(
      terminal.buffer.createAnchor(
        0,
        terminal.buffer.height - terminal.viewHeight,
      ),
      terminal.buffer.createAnchor(
        terminal.viewWidth,
        terminal.buffer.height - 1,
      ),
      mode: SelectionMode.line,
    );
    _focusTerminal();
  }

  void _clearSelection() {
    _terminalController.clearSelection();
    _focusTerminal();
  }

  void _clearTerminal() {
    _sendCtrlCombo('l');
  }

  void _resetTerminal() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.textInput('\x1bc');
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendAltBackspace() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.keyInput(TerminalKey.backspace, alt: true);
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _clearTerminalSearchHighlights({bool clearQuery = false}) {
    for (final highlight in _terminalSearchHighlights) {
      highlight.dispose();
    }
    _terminalSearchHighlights.clear();
    _terminalSearchMatches.clear();
    _terminalSearchIndex = -1;
    if (clearQuery) {
      _terminalSearchQuery = '';
    }
  }

  void _runTerminalSearch(
    String query, {
    bool? caseSensitive,
    bool preserveSelection = false,
  }) {
    final terminal = _activeTerminal();
    if (terminal == null) {
      return;
    }
    final useCase = caseSensitive ?? _terminalSearchCaseSensitive;
    _clearTerminalSearchHighlights(clearQuery: false);
    if (query.trim().isEmpty) {
      setState(() {
        _terminalSearchQuery = '';
        _terminalSearchCaseSensitive = useCase;
      });
      return;
    }
    final matches = <_TerminalSearchMatch>[];
    final needle = useCase ? query : query.toLowerCase();
    final buffer = terminal.buffer;
    const maxMatches = 240;
    for (var lineIndex = 0; lineIndex < buffer.height; lineIndex++) {
      final lineText = buffer.lines[lineIndex].getText();
      if (lineText.isEmpty) {
        continue;
      }
      final haystack = useCase ? lineText : lineText.toLowerCase();
      var searchIndex = 0;
      while (true) {
        final found = haystack.indexOf(needle, searchIndex);
        if (found == -1) {
          break;
        }
        matches.add(
          _TerminalSearchMatch(
            line: lineIndex,
            start: found,
            end: found + needle.length,
          ),
        );
        if (matches.length >= maxMatches) {
          break;
        }
        searchIndex = found + needle.length;
      }
      if (matches.length >= maxMatches) {
        break;
      }
    }

    final highlights = <TerminalHighlight>[];
    for (final match in matches) {
      final start = match.start.clamp(0, buffer.viewWidth);
      final end = match.end.clamp(start, buffer.viewWidth);
      if (end == start) {
        continue;
      }
      highlights.add(
        _terminalController.highlight(
          p1: buffer.createAnchor(start, match.line),
          p2: buffer.createAnchor(end, match.line),
          color: const Color(0x5538BDF8),
        ),
      );
    }

    setState(() {
      _terminalSearchQuery = query;
      _terminalSearchCaseSensitive = useCase;
      _terminalSearchMatches.addAll(matches);
      _terminalSearchHighlights.addAll(highlights);
      if (matches.isEmpty) {
        _terminalSearchIndex = -1;
      } else if (preserveSelection && _terminalSearchIndex >= 0) {
        _terminalSearchIndex =
            _terminalSearchIndex.clamp(0, matches.length - 1);
      } else {
        _terminalSearchIndex = 0;
      }
    });

    if (_terminalSearchIndex >= 0) {
      _selectTerminalSearchMatch(_terminalSearchIndex);
    }
  }

  void _scheduleTerminalSearchRefresh() {
    if (_terminalSearchQuery.isEmpty) {
      return;
    }
    _terminalSearchRefreshTimer?.cancel();
    _terminalSearchRefreshTimer =
        Timer(const Duration(milliseconds: 260), () {
      if (!mounted) {
        return;
      }
      _runTerminalSearch(
        _terminalSearchQuery,
        caseSensitive: _terminalSearchCaseSensitive,
        preserveSelection: true,
      );
    });
  }

  void _navigateTerminalSearch(int delta) {
    if (_terminalSearchMatches.isEmpty) {
      return;
    }
    if (_terminalSearchIndex < 0) {
      _selectTerminalSearchMatch(0);
      return;
    }
    final nextIndex = (_terminalSearchIndex + delta) %
        _terminalSearchMatches.length;
    _selectTerminalSearchMatch(nextIndex < 0
        ? _terminalSearchMatches.length - 1
        : nextIndex);
  }

  void _selectTerminalSearchMatch(int index) {
    if (index < 0 || index >= _terminalSearchMatches.length) {
      return;
    }
    final terminal = _activeTerminal();
    if (terminal == null) {
      return;
    }
    final match = _terminalSearchMatches[index];
    final buffer = terminal.buffer;
    final start = match.start.clamp(0, buffer.viewWidth);
    final end = match.end.clamp(start, buffer.viewWidth);
    if (start == end) {
      return;
    }
    _terminalController.setSelection(
      buffer.createAnchor(start, match.line),
      buffer.createAnchor(end, match.line),
      mode: SelectionMode.line,
    );
    setState(() {
      _terminalSearchIndex = index;
    });
    _scrollToTerminalLine(match.line);
  }

  void _scrollToTerminalLine(int lineIndex) {
    if (!_terminalScrollController.hasClients) {
      return;
    }
    final terminal = _activeTerminal();
    if (terminal == null) {
      return;
    }
    final extraLines = terminal.buffer.height - terminal.viewHeight;
    if (extraLines <= 0) {
      return;
    }
    final maxExtent = _terminalScrollController.position.maxScrollExtent;
    final lineHeight = maxExtent / extraLines;
    final target = (lineIndex * lineHeight).clamp(0.0, maxExtent);
    _terminalScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  List<_TerminalThemeSpec> _terminalThemeOptions() {
    const midnight = TerminalTheme(
      cursor: Color(0xFFE2E8F0),
      selection: Color(0x33475569),
      foreground: Color(0xFFE2E8F0),
      background: Color(0xFF0B1120),
      black: Color(0xFF020617),
      red: Color(0xFFF87171),
      green: Color(0xFF4ADE80),
      yellow: Color(0xFFFACC15),
      blue: Color(0xFF60A5FA),
      magenta: Color(0xFFD946EF),
      cyan: Color(0xFF22D3EE),
      white: Color(0xFFF8FAFC),
      brightBlack: Color(0xFF334155),
      brightRed: Color(0xFFFCA5A5),
      brightGreen: Color(0xFF86EFAC),
      brightYellow: Color(0xFFFDE047),
      brightBlue: Color(0xFF93C5FD),
      brightMagenta: Color(0xFFF0ABFC),
      brightCyan: Color(0xFF67E8F9),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFF1F2937),
      searchHitBackgroundCurrent: Color(0xFF334155),
      searchHitForeground: Color(0xFFE2E8F0),
    );
    const slate = TerminalTheme(
      cursor: Color(0xFFE2E8F0),
      selection: Color(0x332E3A59),
      foreground: Color(0xFFE2E8F0),
      background: Color(0xFF111827),
      black: Color(0xFF020617),
      red: Color(0xFFFB7185),
      green: Color(0xFF22C55E),
      yellow: Color(0xFFFBBF24),
      blue: Color(0xFF38BDF8),
      magenta: Color(0xFFC084FC),
      cyan: Color(0xFF2DD4BF),
      white: Color(0xFFF8FAFC),
      brightBlack: Color(0xFF334155),
      brightRed: Color(0xFFFDA4AF),
      brightGreen: Color(0xFF86EFAC),
      brightYellow: Color(0xFFFCD34D),
      brightBlue: Color(0xFF7DD3FC),
      brightMagenta: Color(0xFFE9D5FF),
      brightCyan: Color(0xFF5EEAD4),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFF1F2937),
      searchHitBackgroundCurrent: Color(0xFF475569),
      searchHitForeground: Color(0xFFE2E8F0),
    );
    const paper = TerminalTheme(
      cursor: Color(0xFF0F172A),
      selection: Color(0x33475569),
      foreground: Color(0xFF0F172A),
      background: Color(0xFFF8FAFC),
      black: Color(0xFF0F172A),
      red: Color(0xFFDC2626),
      green: Color(0xFF16A34A),
      yellow: Color(0xFFD97706),
      blue: Color(0xFF2563EB),
      magenta: Color(0xFF7C3AED),
      cyan: Color(0xFF0891B2),
      white: Color(0xFFE2E8F0),
      brightBlack: Color(0xFF64748B),
      brightRed: Color(0xFFF87171),
      brightGreen: Color(0xFF4ADE80),
      brightYellow: Color(0xFFFACC15),
      brightBlue: Color(0xFF60A5FA),
      brightMagenta: Color(0xFFC4B5FD),
      brightCyan: Color(0xFF22D3EE),
      brightWhite: Color(0xFF0F172A),
      searchHitBackground: Color(0xFFE2E8F0),
      searchHitBackgroundCurrent: Color(0xFFCBD5F5),
      searchHitForeground: Color(0xFF0F172A),
    );
    return const [
      _TerminalThemeSpec(label: 'Midnight', theme: midnight),
      _TerminalThemeSpec(label: 'Slate', theme: slate),
      _TerminalThemeSpec(label: 'Paper', theme: paper),
    ];
  }

  Future<void> _showTerminalSearchSheet() async {
    final controller = TextEditingController(text: _terminalSearchQuery);
    bool caseSensitive = _terminalSearchCaseSensitive;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final matches = _terminalSearchMatches.length;
            final index =
                _terminalSearchIndex >= 0 ? _terminalSearchIndex + 1 : 0;
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 12,
                bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Search in terminal',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Find text...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      _runTerminalSearch(
                        value,
                        caseSensitive: caseSensitive,
                      );
                      setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilterChip(
                        label: const Text('Case sensitive'),
                        selected: caseSensitive,
                        onSelected: (selected) {
                          caseSensitive = selected;
                          _runTerminalSearch(
                            controller.text,
                            caseSensitive: caseSensitive,
                          );
                          setSheetState(() {});
                        },
                      ),
                      if (_terminalSearchQuery.isNotEmpty)
                        ActionChip(
                          label: const Text('Clear'),
                          onPressed: () {
                            controller.clear();
                            _clearTerminalSearchHighlights(clearQuery: true);
                            setState(() {});
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        matches == 0
                            ? 'No matches'
                            : '$index / $matches',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFF475569),
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Previous match',
                        onPressed:
                            matches == 0 ? null : () => _navigateTerminalSearch(-1),
                        icon: const Icon(Icons.keyboard_arrow_up),
                      ),
                      IconButton(
                        tooltip: 'Next match',
                        onPressed:
                            matches == 0 ? null : () => _navigateTerminalSearch(1),
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showTerminalFontSheet() async {
    var current = _terminalFontSize;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Font size',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    value: current,
                    min: 11,
                    max: 18,
                    divisions: 14,
                    label: current.toStringAsFixed(1),
                    onChanged: (value) {
                      setSheetState(() {
                        current = value;
                      });
                      _adjustTerminalFontSize(value);
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Tap outside to close.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                        ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showTerminalThemeSheet() async {
    final options = _terminalThemeOptions();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Terminal theme',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 12),
              ...List.generate(options.length, (index) {
                final theme = options[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.theme.background,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: index == _terminalThemeIndex
                          ? const Color(0xFF38BDF8)
                          : const Color(0xFFE2E8F0),
                      width: index == _terminalThemeIndex ? 2 : 1,
                    ),
                  ),
                  child: RadioListTile<int>(
                    value: index,
                    groupValue: _terminalThemeIndex,
                    activeColor: theme.theme.foreground,
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      _setTerminalTheme(value);
                    },
                    title: Text(
                      theme.label,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            color: theme.theme.foreground,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    subtitle: Text(
                      theme.theme.background == const Color(0xFFF8FAFC)
                          ? 'Light surface'
                          : 'Dark surface',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: theme.theme.foreground.withAlpha(180),
                          ),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKeyRow(List<_TerminalKeySpec> keys) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: keys
            .map(
              (key) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _TerminalKeyButton(spec: key),
              ),
            )
            .toList(),
      ),
    );
  }

  Future<void> _connectTerminalStream() async {
    final active = _activeSession;
    final baseUrl = widget.agentBaseUrl?.trim();
    if (active == null || baseUrl == null || baseUrl.isEmpty) {
      _disconnectTerminalStream();
      return;
    }
    if (_isTerminalClosed(active.session.status.toLowerCase())) {
      _disconnectTerminalStream();
      return;
    }
    if (_terminalChannelReady &&
        _terminalChannelSessionId == active.session.id) {
      return;
    }
    _terminalReconnectTimer?.cancel();
    _terminalReconnectTimer = null;
    _disconnectTerminalStream();
    final ready = await _ensureRemoteSession(active, forceAttach: true);
    if (!ready) {
      _startPolling();
      return;
    }
    final uri = _terminalWsUri(baseUrl, active.session.id);
    if (uri == null) {
      _startPolling();
      return;
    }
    WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(uri);
    } catch (_) {
      _scheduleTerminalReconnect();
      _startPolling();
      return;
    }
    _terminalChannel = channel;
    _terminalChannelSessionId = active.session.id;
    _terminalChannelReady = true;
    _terminalReconnectAttempts = 0;
    _pollTimer?.cancel();
    _startTerminalKeepalive();
    _terminalChannelSub = channel.stream.listen(
      _handleTerminalStreamMessage,
      onError: (_) {
        _disconnectTerminalStream();
        _scheduleTerminalReconnect();
        _startPolling();
      },
      onDone: () {
        _disconnectTerminalStream();
        _scheduleTerminalReconnect();
        _startPolling();
      },
    );

    try {
      channel.sink.add(jsonEncode({'action': 'status'}));
    } catch (_) {
      // Ignore send errors; stream listener will handle disconnects.
    }
  }

  void _disconnectTerminalStream() {
    _terminalChannelSub?.cancel();
    _terminalChannelSub = null;
    _terminalChannel?.sink.close();
    _terminalChannel = null;
    _terminalChannelReady = false;
    _terminalChannelSessionId = null;
    _terminalKeepaliveTimer?.cancel();
    _terminalKeepaliveTimer = null;
  }

  void _startTerminalKeepalive() {
    _terminalKeepaliveTimer?.cancel();
    _terminalKeepaliveTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) {
        if (!_terminalChannelReady) {
          return;
        }
        try {
          _terminalChannel?.sink.add(jsonEncode({'action': 'keepalive'}));
        } catch (_) {
          _disconnectTerminalStream();
          _scheduleTerminalReconnect();
          _startPolling();
        }
      },
    );
  }

  void _scheduleTerminalReconnect() {
    if (!mounted || _terminalReconnectTimer != null) {
      return;
    }
    final active = _activeSession;
    final baseUrl = widget.agentBaseUrl?.trim();
    if (active == null || baseUrl == null || baseUrl.isEmpty) {
      return;
    }
    _terminalReconnectAttempts =
        (_terminalReconnectAttempts + 1).clamp(1, 6);
    final seconds = 1 << (_terminalReconnectAttempts - 1);
    final delay =
        Duration(seconds: seconds > 12 ? 12 : seconds);
    _terminalReconnectTimer = Timer(delay, () {
      _terminalReconnectTimer = null;
      _connectTerminalStream();
    });
  }

  void _handleTerminalStreamMessage(dynamic event) {
    final active = _activeSession;
    final sessionId = _terminalChannelSessionId;
    if (active == null || sessionId == null) {
      return;
    }
    String? text;
    if (event is String) {
      text = event;
    } else if (event is List<int>) {
      text = utf8.decode(event);
    } else if (event is Uint8List) {
      text = utf8.decode(event);
    }
    if (text == null || text.trim().isEmpty) {
      return;
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) {
      return;
    }
    if (decoded['type'] != 'terminal' && decoded['status'] == null) {
      return;
    }
    _terminalReconnectAttempts = 0;
    unawaited(
      _applyTerminalPayload(
        sessionId: sessionId,
        payload: decoded,
        event: active.lastEvent,
        command: active.lastCommand,
      ),
    );
  }

  Future<void> _loadSessions() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
      _remoteFetchError = null;
    });
    try {
      final sessions = await widget.storage.fetchToolSessions();
      final events = await widget.storage.fetchTimelineEvents();
      final agentId = widget.agentId;
      var terminalSessions = sessions
          .where((session) => session.type.toLowerCase() == 'terminal')
          .where((session) => agentId == null || session.agentId == agentId)
          .toList();
      final remoteResult = await _fetchRemoteTerminalSessions();
      final closedReasons = <String, String>{};
      String? remoteError;
      if (remoteResult.isSuccess) {
        remoteError = null;
        final remoteSessions = remoteResult.sessions;
        final remoteById = <String, RemoteTerminalSession>{
          for (final remote in remoteSessions) remote.id: remote,
        };
        final merged = <ToolSession>[];
        for (final session in terminalSessions) {
          final remote = remoteById.remove(session.id);
          if (remote == null) {
            if (_isTerminalClosed(session.status.toLowerCase())) {
              merged.add(session);
            } else {
              final closedSession = _sessionWithStatus(session, 'closed');
              await widget.storage.insertToolSession(closedSession);
              merged.add(closedSession);
              closedReasons[session.id] = _missingRemoteSessionReason;
            }
            continue;
          }
          final remoteStatus =
              remote.status.trim().isNotEmpty ? remote.status : session.status;
          final remoteLabel =
              remote.label.trim().isNotEmpty ? remote.label : session.label;
          final statusChanged = remoteStatus != session.status;
          final labelChanged = remoteLabel != session.label;
          final updated = statusChanged || labelChanged
              ? ToolSession(
                  id: session.id,
                  type: session.type,
                  label: remoteLabel,
                  status: remoteStatus,
                  agentId: session.agentId,
                  createdAt: session.createdAt,
                )
              : session;
          if (statusChanged || labelChanged) {
            await widget.storage.insertToolSession(updated);
          }
          merged.add(updated);
          final reason = remote.closedReason?.trim();
          if (reason != null && reason.isNotEmpty) {
            closedReasons[session.id] = reason;
          }
        }
        for (final remote in remoteById.values) {
          final createdAt = remote.createdAt;
          final label = remote.label.trim().isNotEmpty
              ? remote.label
              : 'Terminal ${_truncate(remote.id, 6)}';
          final newSession = ToolSession(
            id: remote.id,
            type: 'terminal',
            label: label,
            status: remote.status,
            agentId: agentId,
            createdAt: createdAt,
          );
          await widget.storage.insertToolSession(newSession);
          merged.add(newSession);
          final reason = remote.closedReason?.trim();
          if (reason != null && reason.isNotEmpty) {
            closedReasons[newSession.id] = reason;
          }
        }
        terminalSessions = merged;
      } else {
        remoteError = remoteResult.errorMessage ??
            'Unable to load terminal sessions.';
      }
      final terminalEvents = events
          .where((event) => event.type.toLowerCase() == 'terminal')
          .toList();
      final latestEvents = <String, TimelineEvent>{};
      for (final event in terminalEvents) {
        latestEvents.putIfAbsent(event.sessionId, () => event);
      }
      if (closedReasons.isNotEmpty) {
        await _applyClosedReasons(
          closedReasons,
          latestEvents,
          terminalSessions,
        );
      }
      final initialSession = widget.initialSession;
      if (initialSession != null &&
          !terminalSessions.any((session) => session.id == initialSession.id)) {
        terminalSessions.insert(0, initialSession);
      }
      final views = terminalSessions.map((session) {
        TimelineEvent? event = latestEvents[session.id];
        if (widget.initialEvent?.sessionId == session.id) {
          event = widget.initialEvent;
        }
        final output = event == null
            ? <TerminalOutputEntry>[]
            : _parseOutputEntries(event.payload, event.createdAt);
        final lastCommand = event?.payload['command']?.toString();
        final nextSeq = event == null ? 0 : _parseNextSeq(event.payload);
        final exitCode = event == null ? null : _parseExitCode(event.payload);
        return TerminalSessionView(
          session: session,
          output: output,
          nextSeq: nextSeq,
          exitCode: exitCode,
          lastCommand: lastCommand,
          lastEvent: event,
        );
      }).toList();
      final terminals = <String, Terminal>{};
      for (final view in views) {
        final terminal = _buildTerminalForSession(view.session.id);
        _hydrateTerminal(view.session.id, terminal, view.output);
        terminals[view.session.id] = terminal;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _sessions = views;
        _activeSessionId = initialSession?.id ??
            (views.isNotEmpty ? views.first.session.id : null);
        _terminals = terminals;
        _statusMessage = null;
        _statusIsError = false;
        _isLoading = false;
        _remoteFetchError = remoteError;
      });
      _startPolling();
      unawaited(_pollActiveSession());
      _autoRunInitialCommand();
      _focusTerminal();
      _connectTerminalStream();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadError = 'Unable to load terminal sessions.';
        _remoteFetchError = null;
      });
    }
  }

  Future<void> _applyClosedReasons(
    Map<String, String> closedReasons,
    Map<String, TimelineEvent> latestEvents,
    List<ToolSession> terminalSessions,
  ) async {
    for (final entry in closedReasons.entries) {
      final sessionId = entry.key;
      final reason = entry.value.trim();
      if (reason.isEmpty) {
        continue;
      }
      final existing = latestEvents[sessionId];
      if (existing != null) {
        final existingReason =
            existing.payload['error_message']?.toString() ?? '';
        final existingStatus =
            existing.payload['status']?.toString().toLowerCase() ?? '';
        if (existingReason == reason && existingStatus == 'closed') {
          continue;
        }
        final entries = _parseOutputEntries(
          existing.payload,
          existing.createdAt,
        );
        final command = existing.payload['command']?.toString() ?? '';
        final updated = await _persistTerminalEvent(
          event: existing,
          command: command,
          entries: entries,
          status: 'closed',
          nextSeq: _parseNextSeq(existing.payload),
          exitCode: null,
          errorMessage: reason,
        );
        if (updated != null) {
          latestEvents[sessionId] = updated;
        }
        continue;
      }
      final session = terminalSessions.firstWhere(
        (session) => session.id == sessionId,
        orElse: () => ToolSession(
          id: sessionId,
          type: 'terminal',
          label: 'Terminal ${_truncate(sessionId, 6)}',
          status: 'closed',
          agentId: widget.agentId,
          createdAt: DateTime.now(),
        ),
      );
      final event = TimelineEvent(
        id: createStorageId(),
        sessionId: sessionId,
        type: 'terminal',
        title: 'Terminal: ${session.label}',
        payload: {
          'command': '',
          'status': 'closed',
          'next_seq': 0,
          'error_message': reason,
        },
        createdAt: DateTime.now(),
      );
      try {
        await widget.storage.insertTimelineEvent(event);
        latestEvents[sessionId] = event;
      } catch (_) {
        // Ignore storage errors for recovery hint.
      }
    }
  }

  void _startPolling() {
    if (_terminalChannelReady &&
        _terminalChannelSessionId == _activeSessionId) {
      return;
    }
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) {
      unawaited(_pollActiveSession());
    });
  }

  Future<bool> _attachRemoteSession(TerminalSessionView view) async {
    final agentClient = _agentClient;
    if (agentClient == null) {
      await _markSessionDisconnected(
        view.session.id,
        'Connect to the desktop agent to stream output.',
        event: view.lastEvent,
        command: view.lastCommand,
      );
      return false;
    }
    try {
      final payload = await agentClient.sendTerminalAction(
        action: 'status',
        sessionId: view.session.id,
      );
      await _applyTerminalPayload(
        sessionId: view.session.id,
        payload: payload,
        event: view.lastEvent,
        command: view.lastCommand,
      );
      return true;
    } on AgentCommandFailure catch (error) {
      await _markSessionDisconnected(
        view.session.id,
        error.message,
        event: view.lastEvent,
        command: view.lastCommand,
      );
      return false;
    }
  }

  Future<bool> _startRemoteSession(ToolSession session) async {
    final agentClient = _agentClient;
    if (agentClient == null) {
      await _markSessionDisconnected(
        session.id,
        'Connect to the desktop agent to start a session.',
      );
      return false;
    }
    try {
      final payload = await agentClient.sendTerminalAction(
        action: 'start',
        sessionId: session.id,
        label: session.label,
        cols: _defaultCols,
        rows: _defaultRows,
      );
      await _applyTerminalPayload(
        sessionId: session.id,
        payload: payload,
      );
      return true;
    } on AgentCommandFailure catch (error) {
      if (error.code == 'session_exists') {
        final view = _sessionById(session.id);
        if (view != null) {
          return _attachRemoteSession(view);
        }
      }
      await _markSessionDisconnected(session.id, error.message);
      return false;
    }
  }

  Future<bool> _ensureRemoteSession(
    TerminalSessionView view, {
    bool forceAttach = false,
  }) async {
    final status = view.session.status.toLowerCase();
    if (status == 'idle') {
      return _startRemoteSession(view.session);
    }
    if ((status == 'disconnected' || status == 'error') && forceAttach) {
      return _attachRemoteSession(view);
    }
    return true;
  }

  Future<void> _pollActiveSession({bool force = false}) async {
    if (_isPolling) {
      return;
    }
    final active = _activeSession;
    if (active == null) {
      return;
    }
    if (!force &&
        _terminalChannelReady &&
        _terminalChannelSessionId == active.session.id) {
      return;
    }
    final status = active.session.status.toLowerCase();
    if (!force &&
        (status == 'closed' ||
            status == 'killed' ||
            status == 'disconnected' ||
            status == 'error')) {
      return;
    }
    final agentClient = _agentClient;
    if (agentClient == null) {
      if (status != 'disconnected') {
        await _markSessionDisconnected(
          active.session.id,
          'Connect to the desktop agent to stream output.',
          event: active.lastEvent,
          command: active.lastCommand,
        );
      }
      return;
    }
    _isPolling = true;
    try {
      final ready = await _ensureRemoteSession(active, forceAttach: force);
      if (!ready) {
        return;
      }
      final payload = await agentClient.sendTerminalAction(
        action: 'poll',
        sessionId: active.session.id,
        since: active.nextSeq,
        limit: _maxOutputEntries,
      );
      await _applyTerminalPayload(
        sessionId: active.session.id,
        payload: payload,
        event: active.lastEvent,
        command: active.lastCommand,
      );
    } on AgentCommandFailure catch (error) {
      await _markSessionDisconnected(
        active.session.id,
        error.message,
        event: active.lastEvent,
        command: active.lastCommand,
      );
    } finally {
      _isPolling = false;
    }
  }

  TerminalSessionView? get _activeSession {
    final activeId = _activeSessionId;
    if (activeId == null) {
      return null;
    }
    for (final session in _sessions) {
      if (session.session.id == activeId) {
        return session;
      }
    }
    return null;
  }

  void _autoRunInitialCommand() {
    if (_autoRunTriggered) {
      return;
    }
    final event = widget.initialEvent;
    if (event == null) {
      return;
    }
    final hasOutput = _payloadHasOutput(event.payload);
    if (hasOutput) {
      return;
    }
    final status = event.payload['status']?.toString().toLowerCase() ?? '';
    if (status.isNotEmpty && status != 'queued') {
      return;
    }
    final command = event.payload['command']?.toString().trim();
    if (command == null || command.isEmpty) {
      return;
    }
    _autoRunTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_sendCommandLine(command));
      }
    });
  }

  bool _payloadHasOutput(Map<String, dynamic> payload) {
    final stdout = _coerceOutputList(payload['stdout']);
    final stderr = _coerceOutputList(payload['stderr']);
    final output = payload['output'];
    final outputPreview = payload['output_preview'];
    final preview = outputPreview;
    final previewText = preview?.toString() ?? '';
    final hasOutput = output is List ? output.isNotEmpty : false;
    return stdout.isNotEmpty ||
        stderr.isNotEmpty ||
        hasOutput ||
        previewText.isNotEmpty;
  }

  void _setActiveSession(String sessionId) {
    setState(() {
      _activeSessionId = sessionId;
      _statusMessage = null;
      _statusIsError = false;
      _clearTerminalSearchHighlights(clearQuery: true);
    });
    _terminalReconnectAttempts = 0;
    _startPolling();
    unawaited(_pollActiveSession(force: true));
    _focusTerminal();
    _connectTerminalStream();
    _jumpToTerminalBottom();
  }

  Future<void> _openSessionPicker() async {
    if (_sessions.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.7;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Sessions',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () {
                          Navigator.of(sheetContext).pop();
                          unawaited(_createSession());
                        },
                        icon: const Icon(Icons.add),
                        label: const Text('New'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: ListView.separated(
                      itemCount: _sessions.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final session = _sessions[index];
                        final status = session.session.status.toLowerCase();
                        final canClose = status != 'closed' &&
                            status != 'killed' &&
                            status != 'exited';
                        return _TerminalSessionRow(
                          session: session,
                          isActive: session.session.id == _activeSessionId,
                          onSelect: () {
                            Navigator.of(sheetContext).pop();
                            _setActiveSession(session.session.id);
                          },
                          onClose: canClose
                              ? () => _closeSession(session.session.id)
                              : null,
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _createSession() async {
    final controller = TextEditingController();
    final label = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('New terminal session'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'Session name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    if (label == null) {
      return;
    }
    final trimmed = label.trim();
    if (trimmed.isNotEmpty && trimmed.runes.length > _terminalLabelMax) {
      _showSessionLabelError(
        'Session name must be $_terminalLabelMax characters or fewer.',
      );
      return;
    }
    final sessionLabel = trimmed.isEmpty
        ? 'Terminal Session ${_sessions.length + 1}'
        : trimmed;
    final now = DateTime.now();
    final session = ToolSession(
      id: createStorageId(),
      type: 'terminal',
      label: sessionLabel,
      status: 'idle',
      agentId: widget.agentId,
      createdAt: now,
    );
    await _persistSession(session);
    if (!mounted) {
      return;
    }
    final terminal = _buildTerminalForSession(session.id);
    setState(() {
      _sessions = [
        TerminalSessionView(
          session: session,
          output: const <TerminalOutputEntry>[],
        ),
        ..._sessions,
      ];
      _activeSessionId = session.id;
      _terminals = {
        ..._terminals,
        session.id: terminal,
      };
      _statusMessage = null;
      _statusIsError = false;
    });
    unawaited(_startRemoteSession(session));
    _startPolling();
    unawaited(_pollActiveSession());
    _focusTerminal();
  }

  void _showSessionLabelError(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _renameActiveSession() async {
    final active = _activeSession;
    if (active == null) {
      _setTerminalStatusMessage(
        'Select a session to rename.',
        isError: true,
      );
      return;
    }
    await _renameSession(active);
  }

  Future<void> _renameSession(TerminalSessionView view) async {
    final controller = TextEditingController(text: view.session.label);
    final label = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename terminal session'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'Session name',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );
    if (label == null) {
      return;
    }
    final trimmed = label.trim();
    if (trimmed.isEmpty) {
      _showSessionLabelError('Session name cannot be empty.');
      return;
    }
    if (trimmed.runes.length > _terminalLabelMax) {
      _showSessionLabelError(
        'Session name must be $_terminalLabelMax characters or fewer.',
      );
      return;
    }
    if (trimmed == view.session.label) {
      return;
    }

    final previousSession = view.session;
    Future<void> revert() async {
      final currentView = _sessionById(previousSession.id) ?? view;
      _replaceSession(
        previousSession.id,
        currentView.copyWith(session: previousSession),
      );
      await _persistSession(previousSession);
    }
    final updatedSession = ToolSession(
      id: previousSession.id,
      type: previousSession.type,
      label: trimmed,
      status: previousSession.status,
      agentId: previousSession.agentId,
      createdAt: previousSession.createdAt,
    );
    _replaceSession(
      previousSession.id,
      view.copyWith(session: updatedSession),
    );
    await _persistSession(updatedSession);

    final agentClient = _agentClient;
    if (agentClient == null) {
      await revert();
      _showSessionLabelError(
        'Connect to the desktop agent to rename sessions.',
      );
      return;
    }
    try {
      await agentClient.sendTerminalAction(
        action: 'rename',
        sessionId: previousSession.id,
        label: trimmed,
      );
      _setTerminalStatusMessage('Session renamed.');
    } on AgentCommandFailure catch (error) {
      await revert();
      _showSessionLabelError(error.message);
    } catch (error) {
      await revert();
      _showSessionLabelError('Failed to rename session.');
    }
  }

  Future<void> _closeSession(String sessionId) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final agentClient = _agentClient;
    if (agentClient != null) {
      try {
        await agentClient.sendTerminalAction(
          action: 'stop',
          sessionId: sessionId,
        );
      } catch (_) {
        // Best-effort kill; update local state regardless.
      }
    }
    final updated = _sessionWithStatus(view.session, 'killed');
    await _persistSession(updated);
    if (!mounted) {
      return;
    }
    _replaceSession(
      sessionId,
      view.copyWith(session: updated),
    );
    if (sessionId == _terminalChannelSessionId) {
      _disconnectTerminalStream();
    }
  }

  TerminalSessionView? _sessionById(String sessionId) {
    for (final session in _sessions) {
      if (session.session.id == sessionId) {
        return session;
      }
    }
    return null;
  }

  void _replaceSession(String sessionId, TerminalSessionView updated) {
    setState(() {
      _sessions = _sessions
          .map(
            (session) =>
                session.session.id == sessionId ? updated : session,
          )
          .toList();
    });
  }

  bool _isTerminalClosed(String status) {
    return status == 'closed' ||
        status == 'killed' ||
        status == 'exited';
  }

  void _handleTerminalInput(String sessionId, String data) {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final status = view.session.status.toLowerCase();
    if (_isTerminalClosed(status)) {
      _setTerminalStatusMessage(
        'This session is no longer active.',
        isError: true,
      );
      _consumeOneShotModifiers();
      return;
    }
    if (status == 'disconnected' || status == 'error') {
      _setTerminalStatusMessage(
        'Session disconnected. Reconnect to type.',
        isError: true,
      );
      _consumeOneShotModifiers();
      return;
    }
    final resolved = _applyTerminalModifiers(data);
    _updateCommandBuffer(sessionId, resolved);
    unawaited(_sendTerminalInput(sessionId, resolved, view: view));
    _consumeOneShotModifiers();
  }

  void _updateCommandBuffer(String sessionId, String data) {
    final buffer = _commandBuffers.putIfAbsent(sessionId, () => <int>[]);
    var skippingEscape = false;
    for (final rune in data.runes) {
      if (skippingEscape) {
        if (rune >= 64 && rune <= 126) {
          skippingEscape = false;
        }
        continue;
      }
      if (rune == 27) {
        skippingEscape = true;
        continue;
      }
      if (rune == 10 || rune == 13) {
        final command = String.fromCharCodes(buffer).trim();
        buffer.clear();
        if (command.isNotEmpty) {
          unawaited(_recordCommand(sessionId, command));
        }
        continue;
      }
      if (rune == 8 || rune == 127) {
        if (buffer.isNotEmpty) {
          buffer.removeLast();
        }
        continue;
      }
      if (rune < 32) {
        continue;
      }
      buffer.add(rune);
    }
  }

  Future<void> _recordCommand(String sessionId, String command) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final event = await _ensureTerminalEvent(view, command);
    if (!mounted) {
      return;
    }
    _replaceSession(
      sessionId,
      view.copyWith(lastCommand: command, lastEvent: event),
    );
    if (sessionId == _activeSessionId) {
      unawaited(_pollActiveSession());
    }
  }

  Future<void> _sendCommandLine(String command) async {
    final active = _activeSession;
    if (active == null) {
      setState(() {
        _statusMessage = 'Create a session to run commands.';
        _statusIsError = true;
      });
      return;
    }
    final status = active.session.status.toLowerCase();
    if (_isTerminalClosed(status)) {
      setState(() {
        _statusMessage = 'This session is no longer active.';
        _statusIsError = true;
      });
      return;
    }
    final event = await _ensureTerminalEvent(active, command);
    if (!mounted) {
      return;
    }
    final updatedView = active.copyWith(
      lastCommand: command,
      lastEvent: event,
    );
    _replaceSession(active.session.id, updatedView);
    await _sendTerminalInput(
      active.session.id,
      command.endsWith('\n') ? command : '$command\n',
      view: updatedView,
      triggerPoll: true,
    );
  }

  Future<void> _sendTerminalInput(
    String sessionId,
    String data, {
    TerminalSessionView? view,
    bool triggerPoll = false,
  }) async {
    final activeView = view ?? _sessionById(sessionId);
    if (activeView == null) {
      return;
    }
    if (_terminalChannelReady && _terminalChannelSessionId == sessionId) {
      try {
        _terminalChannel?.sink.add(jsonEncode({
          'action': 'input',
          'data': data,
        }));
      } catch (_) {
        _disconnectTerminalStream();
        _startPolling();
      }
      return;
    }
    final agentClient = _agentClient;
    if (agentClient == null) {
      await _markSessionDisconnected(
        sessionId,
        'Connect to the desktop agent to run terminal commands.',
        event: activeView.lastEvent,
        command: activeView.lastCommand,
      );
      return;
    }
    try {
      final ready = await _ensureRemoteSession(activeView);
      if (!ready) {
        return;
      }
      await agentClient.sendTerminalAction(
        action: 'input',
        sessionId: sessionId,
        input: data,
      );
      if (triggerPoll) {
        _startPolling();
        unawaited(_pollActiveSession());
      }
    } on AgentCommandFailure catch (error) {
      await _markSessionDisconnected(
        sessionId,
        error.message,
        event: activeView.lastEvent,
        command: activeView.lastCommand,
      );
    } catch (error) {
      await _markSessionDisconnected(
        sessionId,
        'Terminal command failed: ${error.toString()}',
        event: activeView.lastEvent,
        command: activeView.lastCommand,
      );
    }
  }

  Future<void> _sendTerminalResize(
    String sessionId,
    int cols,
    int rows,
  ) async {
    if (cols <= 0 || rows <= 0) {
      return;
    }
    final nextGrid = _TerminalGrid(cols: cols, rows: rows);
    final lastGrid = _terminalSizes[sessionId];
    if (lastGrid != null && lastGrid == nextGrid) {
      return;
    }
    _terminalSizes[sessionId] = nextGrid;
    if (_terminalChannelReady && _terminalChannelSessionId == sessionId) {
      try {
        _terminalChannel?.sink.add(jsonEncode({
          'action': 'resize',
          'cols': cols,
          'rows': rows,
        }));
      } catch (_) {
        _disconnectTerminalStream();
        _startPolling();
      }
      return;
    }
    final agentClient = _agentClient;
    if (agentClient == null) {
      return;
    }
    try {
      await agentClient.sendTerminalAction(
        action: 'resize',
        sessionId: sessionId,
        cols: cols,
        rows: rows,
      );
    } catch (_) {
      // Best-effort resize.
    }
  }

  Future<void> _markSessionDisconnected(
    String sessionId,
    String message, {
    TimelineEvent? event,
    String? command,
  }) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final updated = _sessionWithStatus(view.session, 'disconnected');
    await _persistSession(updated);
    if (!mounted) {
      return;
    }
    final updatedView = view.copyWith(session: updated);
    _replaceSession(sessionId, updatedView);
    if (event != null && command != null) {
      final updatedEvent = await _persistTerminalEvent(
        event: event,
        command: command,
        entries: updatedView.output,
        status: 'disconnected',
        nextSeq: updatedView.nextSeq,
        exitCode: updatedView.exitCode,
        errorMessage: message,
      );
      if (updatedEvent != null) {
        _replaceSession(
          sessionId,
          updatedView.copyWith(lastEvent: updatedEvent),
        );
      }
    }
    setState(() {
      _statusMessage = message;
      _statusIsError = true;
    });
  }

  Future<void> _attemptReconnect() async {
    final active = _activeSession;
    if (active == null) {
      return;
    }
    final baseUrl = widget.agentBaseUrl?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Pair with the desktop agent to reconnect.'),
        ),
      );
      return;
    }
    _configureAgentClient();
    setState(() {
      _statusMessage = 'Reconnecting...';
      _statusIsError = false;
    });
    await _pollActiveSession(force: true);
    unawaited(_connectTerminalStream());
  }

  ToolSession _sessionWithStatus(
    ToolSession session,
    String status, {
    String? label,
  }) {
    return ToolSession(
      id: session.id,
      type: session.type,
      label: label ?? session.label,
      status: status,
      agentId: session.agentId,
      createdAt: session.createdAt,
    );
  }

  Future<void> _persistSession(ToolSession session) async {
    try {
      await widget.storage.insertToolSession(session);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save terminal session: ${error.toString()}',
          ),
        ),
      );
    }
  }

  Future<TimelineEvent> _ensureTerminalEvent(
    TerminalSessionView session,
    String command,
  ) async {
    final existing = session.lastEvent;
    final status = existing?.payload['status']?.toString().toLowerCase();
    if (existing != null && (status == null || status == 'queued')) {
      return existing;
    }
    final now = DateTime.now();
    final title = 'Terminal: ${_truncate(command, 28)}';
    final event = TimelineEvent(
      id: createStorageId(),
      sessionId: session.session.id,
      type: 'terminal',
      title: title,
      payload: {
        'command': command,
        'status': 'queued',
        'next_seq': session.nextSeq,
      },
      createdAt: now,
    );
    try {
      await widget.storage.insertTimelineEvent(event);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to save terminal event: ${error.toString()}',
            ),
          ),
        );
      }
    }
    return event;
  }

  Future<TimelineEvent?> _persistTerminalEvent({
    required TimelineEvent event,
    required String command,
    required List<TerminalOutputEntry> entries,
    required String status,
    int? nextSeq,
    int? exitCode,
    String? errorMessage,
  }) async {
    final payload = Map<String, dynamic>.from(event.payload);
    payload['command'] = command;
    payload['status'] = status;
    payload['output'] = entries.map((entry) => entry.text).toList();
    payload['stdout'] = entries
        .where((entry) => entry.stream == TerminalStream.stdout)
        .map((entry) => entry.text)
        .toList();
    payload['stderr'] = entries
        .where((entry) => entry.stream == TerminalStream.stderr)
        .map((entry) => entry.text)
        .toList();
    payload['output_preview'] = _buildOutputPreview(entries);
    if (nextSeq != null) {
      payload['next_seq'] = nextSeq;
    }
    if (exitCode != null) {
      payload['exit_code'] = exitCode;
    } else {
      payload.remove('exit_code');
    }
    payload['updated_at'] = DateTime.now().toIso8601String();
    if (errorMessage != null && errorMessage.trim().isNotEmpty) {
      payload['error_message'] = errorMessage;
    } else {
      payload.remove('error_message');
    }
    final insight = _buildTerminalInsight(
      entries: entries,
      status: status,
      errorMessage: errorMessage,
      exitCode: exitCode,
      agentBaseUrl: widget.agentBaseUrl,
    );
    final updatedPayload = _applyAiInsight(payload, insight);
    final updatedEvent = TimelineEvent(
      id: event.id,
      sessionId: event.sessionId,
      type: event.type,
      title: event.title,
      payload: updatedPayload,
      createdAt: event.createdAt,
    );
    try {
      await widget.storage.insertTimelineEvent(updatedEvent);
      return updatedEvent;
    } catch (error) {
      if (!mounted) {
        return null;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save terminal output: ${error.toString()}',
          ),
        ),
      );
    }
    return null;
  }

  Future<void> _applyTerminalPayload({
    required String sessionId,
    required Map<String, dynamic> payload,
    TimelineEvent? event,
    String? command,
  }) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final status = payload['status']?.toString() ?? view.session.status;
    final labelRaw = payload['label']?.toString() ?? '';
    final resolvedLabel =
        labelRaw.trim().isNotEmpty ? labelRaw.trim() : view.session.label;
    final action = payload['action']?.toString() ?? '';
    final nextSeq = _parseNextSeq(payload, fallback: view.nextSeq);
    final firstSeq =
        _parseChunkSeq(payload['first_seq']) ?? _extractFirstSeq(payload['output']);
    final expectedNext = view.nextSeq + 1;
    final truncated = payload['truncated'] == true;
    final hasGap = truncated ||
        (view.nextSeq > 0 && firstSeq != null && firstSeq > expectedNext);
    final missingHistory = (truncated && view.nextSeq == 0) ||
        (view.nextSeq == 0 && firstSeq != null && firstSeq > 1);
    final shouldReset =
        action == 'start' || nextSeq < view.nextSeq || hasGap;
    final parsedExitCode = _parseExitCode(payload);
    final exitCode = parsedExitCode ??
        (status.toLowerCase() == 'running' ? null : view.exitCode);
    final snapshotRaw = payload['snapshot']?.toString();
    final snapshot = snapshotRaw != null && snapshotRaw.isNotEmpty
        ? snapshotRaw
        : null;
    final outputEntries = _parseTerminalChunks(
      payload['output'],
      DateTime.now(),
      minSeq: shouldReset ? 0 : view.nextSeq,
    );
    final mergedOutput = shouldReset
        ? outputEntries
        : _mergeOutputEntries(view.output, outputEntries);
    final updatedSession =
        _sessionWithStatus(view.session, status, label: resolvedLabel);
    final updatedView = view.copyWith(
      session: updatedSession,
      output: mergedOutput,
      nextSeq: nextSeq,
      exitCode: exitCode,
    );
    _replaceSession(sessionId, updatedView);
    if (action == 'start' || nextSeq < view.nextSeq) {
      _terminalGapWarned.remove(sessionId);
      _terminalTruncateWarned.remove(sessionId);
    }
    if (sessionId == _activeSessionId) {
      if (hasGap && !_terminalGapWarned.contains(sessionId)) {
        _terminalGapWarned.add(sessionId);
        _setTerminalStatusMessage(
          'Terminal output dropped; screen re-synced.',
        );
      } else if (missingHistory &&
          !_terminalTruncateWarned.contains(sessionId)) {
        _terminalTruncateWarned.add(sessionId);
        _setTerminalStatusMessage(
          'Terminal history truncated; screen may be incomplete.',
        );
      }
    }
    await _persistSession(updatedSession);
    final shouldApplySnapshot =
        snapshot != null && (shouldReset || action == 'status');
    if (shouldApplySnapshot) {
      _resetTerminalSession(sessionId);
      _writeTerminalSnapshot(sessionId, snapshot);
    } else {
      if (shouldReset) {
        _resetTerminalSession(sessionId);
      }
      _appendTerminalOutput(sessionId, outputEntries);
    }

    final resolvedCommand =
        command ?? event?.payload['command']?.toString() ?? '';
    if (event != null && resolvedCommand.trim().isNotEmpty) {
      final errorMessage = exitCode != null && exitCode != 0
          ? 'Command exited with code $exitCode.'
          : null;
      if (_shouldPersistTerminalEvent(sessionId, status)) {
        final updatedEvent = await _persistTerminalEvent(
          event: event,
          command: resolvedCommand,
          entries: mergedOutput,
          status: status,
          nextSeq: nextSeq,
          exitCode: exitCode,
          errorMessage: errorMessage,
        );
        if (updatedEvent != null) {
          _replaceSession(
            sessionId,
            updatedView.copyWith(lastEvent: updatedEvent),
          );
        }
      }
    }

    if (!mounted || sessionId != _activeSessionId) {
      return;
    }
    if (status.toLowerCase() == 'exited') {
      setState(() {
        _statusMessage = exitCode == null
            ? 'Session exited.'
            : 'Session exited with code $exitCode.';
        _statusIsError = exitCode != null && exitCode != 0;
      });
    }
  }

  List<TerminalOutputEntry> _mergeOutputEntries(
    List<TerminalOutputEntry> existing,
    List<TerminalOutputEntry> incoming,
  ) {
    if (incoming.isEmpty) {
      return existing;
    }
    final merged = List<TerminalOutputEntry>.from(existing)..addAll(incoming);
    if (merged.length > _maxOutputEntries) {
      merged.removeRange(0, merged.length - _maxOutputEntries);
    }
    return merged;
  }

  void _appendTerminalOutput(
    String sessionId,
    List<TerminalOutputEntry> entries,
  ) {
    if (entries.isEmpty) {
      return;
    }
    final terminal = _terminals[sessionId];
    if (terminal == null) {
      return;
    }
    final buffer = StringBuffer();
    for (final entry in entries) {
      buffer.write(entry.text);
    }
    terminal.write(buffer.toString());
  }

  void _writeTerminalSnapshot(String sessionId, String? snapshot) {
    if (snapshot == null || snapshot.isEmpty) {
      return;
    }
    final terminal = _terminals[sessionId];
    if (terminal == null) {
      return;
    }
    terminal.write(snapshot);
  }

  bool _shouldPersistTerminalEvent(String sessionId, String status) {
    final lowered = status.toLowerCase();
    if (lowered == 'exited' ||
        lowered == 'killed' ||
        lowered == 'closed' ||
        lowered == 'error' ||
        lowered == 'disconnected') {
      _terminalPersistedAt[sessionId] = DateTime.now();
      return true;
    }
    final last = _terminalPersistedAt[sessionId];
    final now = DateTime.now();
    if (last == null ||
        now.difference(last) > _terminalPersistInterval) {
      _terminalPersistedAt[sessionId] = now;
      return true;
    }
    return false;
  }

  List<TerminalOutputEntry> _parseTerminalChunks(
    dynamic raw,
    DateTime fallbackTimestamp, {
    int minSeq = 0,
  }) {
    if (raw == null) {
      return [];
    }
    final entries = <TerminalOutputEntry>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final seq = _parseChunkSeq(item['seq']);
          if (seq != null && seq <= minSeq) {
            continue;
          }
          final text = item['data']?.toString() ?? '';
          if (text.isEmpty) {
            continue;
          }
          final ts = item['ts'];
          final timestamp = _parseEpochSeconds(ts) ?? fallbackTimestamp;
          entries.add(
            TerminalOutputEntry(
              stream: TerminalStream.stdout,
              text: text,
              timestamp: timestamp,
            ),
          );
        } else if (item != null) {
          final text = item.toString();
          if (text.isEmpty) {
            continue;
          }
          entries.add(
            TerminalOutputEntry(
              stream: TerminalStream.stdout,
              text: text,
              timestamp: fallbackTimestamp,
            ),
          );
        }
      }
      return entries;
    }
    final text = raw.toString();
    if (text.isEmpty) {
      return entries;
    }
    entries.add(
      TerminalOutputEntry(
        stream: TerminalStream.stdout,
        text: text,
        timestamp: fallbackTimestamp,
      ),
    );
    return entries;
  }

  int? _parseChunkSeq(dynamic raw) {
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
  }

  int? _extractFirstSeq(dynamic raw) {
    if (raw is! List) {
      return null;
    }
    for (final item in raw) {
      if (item is Map) {
        final seq = _parseChunkSeq(item['seq']);
        if (seq != null) {
          return seq;
        }
      }
    }
    return null;
  }

  void _resetTerminalSession(String sessionId) {
    final terminal = _terminals[sessionId];
    if (terminal == null) {
      return;
    }
    terminal.write('\x1bc');
  }

  DateTime? _parseEpochSeconds(dynamic raw) {
    if (raw is int) {
      return DateTime.fromMillisecondsSinceEpoch(raw * 1000);
    }
    if (raw is num) {
      return DateTime.fromMillisecondsSinceEpoch(raw.toInt() * 1000);
    }
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) {
        return DateTime.fromMillisecondsSinceEpoch(parsed * 1000);
      }
    }
    return null;
  }

  int _parseNextSeq(Map<String, dynamic> payload, {int fallback = 0}) {
    final raw = payload['next_seq'];
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      final parsed = int.tryParse(raw);
      if (parsed != null) {
        return parsed;
      }
    }
    return fallback;
  }

  int? _parseExitCode(Map<String, dynamic> payload) {
    final raw = payload['exit_code'];
    if (raw is int) {
      return raw;
    }
    if (raw is num) {
      return raw.toInt();
    }
    if (raw is String) {
      return int.tryParse(raw);
    }
    return null;
  }

  List<TerminalOutputEntry> _parseOutputEntries(
    Map<String, dynamic> payload,
    DateTime createdAt,
  ) {
    final streamed = _parseTerminalChunks(payload['output'], createdAt);
    if (streamed.isNotEmpty) {
      return streamed;
    }
    final stdoutLines = _coerceOutputList(payload['stdout']);
    final stderrLines = _coerceOutputList(payload['stderr']);
    final entries = <TerminalOutputEntry>[];
    for (final line in stdoutLines) {
      entries.add(
        TerminalOutputEntry(
          stream: TerminalStream.stdout,
          text: line,
          timestamp: createdAt,
        ),
      );
    }
    for (final line in stderrLines) {
      entries.add(
        TerminalOutputEntry(
          stream: TerminalStream.stderr,
          text: line,
          timestamp: createdAt,
        ),
      );
    }
    if (entries.isEmpty) {
      final preview = payload['output_preview'];
      final previewText = preview?.toString() ?? '';
      if (previewText.isNotEmpty) {
        entries.add(
          TerminalOutputEntry(
            stream: TerminalStream.stdout,
            text: previewText,
            timestamp: createdAt,
          ),
        );
      }
    }
    return entries;
  }

  List<String> _coerceOutputList(dynamic raw) {
    if (raw == null) {
      return [];
    }
    if (raw is List) {
      return raw
          .map((entry) => entry?.toString() ?? '')
          .where((line) => line.isNotEmpty)
          .toList();
    }
    if (raw is String) {
      return raw
          .split('\n')
          .where((line) => line.isNotEmpty)
          .toList();
    }
    return [raw.toString()];
  }

  String _buildOutputPreview(List<TerminalOutputEntry> entries) {
    if (entries.isEmpty) {
      return '';
    }
    final preview = entries.take(3).map((entry) => entry.text).toList();
    return preview.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_isLoading) {
      return const _TimelineDetailScaffold(
        title: 'Terminal',
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_loadError != null) {
      return _TimelineDetailScaffold(
        title: 'Terminal',
        body: Center(
          child: _InlineStatus(
            message: _loadError!,
            isError: true,
          ),
        ),
      );
    }

    final active = _activeSession;
    final status = active?.session.status.toLowerCase() ?? 'idle';
    final isDisconnected = status == 'disconnected' || status == 'error';
    final isEnded = _isTerminalClosed(status);
    final statusStyle = _terminalStatusStyle(status);
    final terminal = active == null ? null : _terminals[active.session.id];
    final terminalThemes = _terminalThemeOptions();
    final resolvedThemeIndex = _terminalThemeIndex
        .clamp(0, terminalThemes.length - 1)
        .toInt();
    final terminalTheme = terminalThemes[resolvedThemeIndex].theme;
    final terminalBackground = terminalTheme.background;
    final terminalForeground = terminalTheme.foreground;
    final isLightTerminal =
        ThemeData.estimateBrightnessForColor(terminalBackground) ==
            Brightness.light;
    final terminalBorderColor =
        isLightTerminal ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B);
    final terminalOverlayBackground =
        isLightTerminal ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
    final terminalOverlayForeground =
        isLightTerminal ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0);
    final terminalStyle = TerminalStyle.fromTextStyle(
      GoogleFonts.jetBrainsMono(
        fontSize: _terminalFontSize,
        height: 1.4,
      ),
    );
    final sessionLabel = active?.session.label ?? 'No session selected';
    final sessionStatus =
        active == null ? 'IDLE' : active.session.status.toUpperCase();
    final connectionLabel = active == null
        ? 'Create a session to start.'
        : _terminalChannelReady
            ? 'Live stream'
            : 'Polling updates';
    final resolvedStatusMessage =
        _statusMessage ?? _sessionStatusReason(active);
    final resolvedStatusIsError =
        _statusMessage != null ? _statusIsError : resolvedStatusMessage != null;
    final showEmptyHint = _sessions.isEmpty && _remoteFetchError == null;
    final headerStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: const Color(0xFF0F172A),
    );
    const dockBackground = Color(0xFF0B1220);
    final keyRowPrimary = [
      _TerminalKeySpec(
        label: 'Esc',
        onTap: () => _sendTerminalKey(TerminalKey.escape),
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'Tab',
        onTap: () => _sendTerminalKey(TerminalKey.tab),
      ),
      _TerminalKeySpec(
        label: 'S-Tab',
        onTap: () => _sendTerminalKey(TerminalKey.backtab),
      ),
      _TerminalKeySpec(
        label: 'Ctrl',
        onTap: _toggleCtrlModifier,
        onLongPress: _toggleCtrlLock,
        isActive: _ctrlModifier,
        isLocked: _ctrlLocked,
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'Alt',
        onTap: _toggleAltModifier,
        onLongPress: _toggleAltLock,
        isActive: _altModifier,
        isLocked: _altLocked,
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'Shift',
        onTap: _toggleShiftModifier,
        onLongPress: _toggleShiftLock,
        isActive: _shiftModifier,
        isLocked: _shiftLocked,
      ),
      _TerminalKeySpec(
        label: _showFnRow ? 'Fn On' : 'Fn',
        onTap: _toggleFnRow,
        isActive: _showFnRow,
      ),
      _TerminalKeySpec(
        label: '←',
        onTap: () => _sendTerminalKey(TerminalKey.arrowLeft),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: '↓',
        onTap: () => _sendTerminalKey(TerminalKey.arrowDown),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: '↑',
        onTap: () => _sendTerminalKey(TerminalKey.arrowUp),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: '→',
        onTap: () => _sendTerminalKey(TerminalKey.arrowRight),
        isRepeatable: true,
      ),
    ];
    final keyRowSecondaryBase = [
      _TerminalKeySpec(
        label: 'Bksp',
        onTap: () => _sendTerminalKey(TerminalKey.backspace),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: 'Enter',
        onTap: () => _sendTerminalKey(TerminalKey.enter),
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'PgUp',
        onTap: () => _sendTerminalKey(TerminalKey.pageUp),
      ),
      _TerminalKeySpec(
        label: 'PgDn',
        onTap: () => _sendTerminalKey(TerminalKey.pageDown),
      ),
      _TerminalKeySpec(
        label: 'Home',
        onTap: () => _sendTerminalKey(TerminalKey.home),
      ),
      _TerminalKeySpec(
        label: 'End',
        onTap: () => _sendTerminalKey(TerminalKey.end),
      ),
      _TerminalKeySpec(
        label: 'Del',
        onTap: () => _sendTerminalKey(TerminalKey.delete),
      ),
      _TerminalKeySpec(
        label: 'Ins',
        onTap: () => _sendTerminalKey(TerminalKey.insert),
      ),
      _TerminalKeySpec(
        label: '/',
        onTap: () => _sendTerminalChar('/'),
      ),
      _TerminalKeySpec(
        label: ':',
        onTap: () => _sendTerminalChar(':'),
      ),
      _TerminalKeySpec(
        label: '-',
        onTap: () => _sendTerminalChar('-'),
      ),
      _TerminalKeySpec(
        label: '|',
        onTap: () => _sendTerminalChar('|'),
      ),
      _TerminalKeySpec(
        label: '~',
        onTap: () => _sendTerminalChar('~'),
      ),
      _TerminalKeySpec(
        label: '_',
        onTap: () => _sendTerminalChar('_'),
      ),
      _TerminalKeySpec(
        label: '=',
        onTap: () => _sendTerminalChar('='),
      ),
      _TerminalKeySpec(
        label: '.',
        onTap: () => _sendTerminalChar('.'),
      ),
      _TerminalKeySpec(
        label: 'Space',
        onTap: () => _sendTerminalChar(' '),
        minWidth: 72,
      ),
    ];

    final keyRowSecondarySymbols = [
      _TerminalKeySpec(
        label: '[]',
        onTap: () => _sendPairedChars('[', ']'),
        onLongPress: () => _sendTerminalChar('['),
      ),
      _TerminalKeySpec(
        label: '()',
        onTap: () => _sendPairedChars('(', ')'),
        onLongPress: () => _sendTerminalChar('('),
      ),
      _TerminalKeySpec(
        label: '{}',
        onTap: () => _sendPairedChars('{', '}'),
        onLongPress: () => _sendTerminalChar('{'),
      ),
      _TerminalKeySpec(
        label: "''",
        onTap: () => _sendPairedChars("'", "'"),
        onLongPress: () => _sendTerminalChar("'"),
      ),
      _TerminalKeySpec(
        label: '""',
        onTap: () => _sendPairedChars('"', '"'),
        onLongPress: () => _sendTerminalChar('"'),
      ),
      _TerminalKeySpec(
        label: '<>',
        onTap: () => _sendPairedChars('<', '>'),
        onLongPress: () => _sendTerminalChar('<'),
      ),
      _TerminalKeySpec(
        label: '`',
        onTap: () => _sendTerminalChar('`'),
      ),
      _TerminalKeySpec(
        label: '?',
        onTap: () => _sendTerminalChar('?'),
      ),
      _TerminalKeySpec(
        label: '!',
        onTap: () => _sendTerminalChar('!'),
      ),
      _TerminalKeySpec(
        label: '&',
        onTap: () => _sendTerminalChar('&'),
      ),
      _TerminalKeySpec(
        label: '#',
        onTap: () => _sendTerminalChar('#'),
      ),
      _TerminalKeySpec(
        label: '@',
        onTap: () => _sendTerminalChar('@'),
      ),
      _TerminalKeySpec(
        label: r'$',
        onTap: () => _sendTerminalChar(r'$'),
      ),
      _TerminalKeySpec(
        label: '%',
        onTap: () => _sendTerminalChar('%'),
      ),
      _TerminalKeySpec(
        label: '^',
        onTap: () => _sendTerminalChar('^'),
      ),
    ];

    final keyRowSecondaryAdvanced = [
      _TerminalKeySpec(
        label: 'Ctrl+A',
        onTap: () => _sendCtrlCombo('a'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+C',
        onTap: () => _sendCtrlCombo('c'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+R',
        onTap: () => _sendCtrlCombo('r'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+L',
        onTap: () => _sendCtrlCombo('l'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+D',
        onTap: () => _sendCtrlCombo('d'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+Z',
        onTap: () => _sendCtrlCombo('z'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+K',
        onTap: () => _sendCtrlCombo('k'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+U',
        onTap: () => _sendCtrlCombo('u'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+W',
        onTap: () => _sendCtrlCombo('w'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+Space',
        onTap: _sendCtrlNull,
      ),
      _TerminalKeySpec(
        label: 'Ctrl+Bksp',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.backspace,
          ctrl: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Alt+B',
        onTap: () => _sendAltCombo('b'),
      ),
      _TerminalKeySpec(
        label: 'Alt+F',
        onTap: () => _sendAltCombo('f'),
      ),
      _TerminalKeySpec(
        label: 'Alt+Bksp',
        onTap: _sendAltBackspace,
      ),
      _TerminalKeySpec(
        label: 'Ctrl+←',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowLeft,
          ctrl: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+→',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowRight,
          ctrl: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Alt+←',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowLeft,
          alt: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Alt+→',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowRight,
          alt: true,
        ),
      ),
    ];

    final keyRowFn = [
      _TerminalKeySpec(
        label: 'F1',
        onTap: () => _sendTerminalKey(TerminalKey.f1),
      ),
      _TerminalKeySpec(
        label: 'F2',
        onTap: () => _sendTerminalKey(TerminalKey.f2),
      ),
      _TerminalKeySpec(
        label: 'F3',
        onTap: () => _sendTerminalKey(TerminalKey.f3),
      ),
      _TerminalKeySpec(
        label: 'F4',
        onTap: () => _sendTerminalKey(TerminalKey.f4),
      ),
      _TerminalKeySpec(
        label: 'F5',
        onTap: () => _sendTerminalKey(TerminalKey.f5),
      ),
      _TerminalKeySpec(
        label: 'F6',
        onTap: () => _sendTerminalKey(TerminalKey.f6),
      ),
      _TerminalKeySpec(
        label: 'F7',
        onTap: () => _sendTerminalKey(TerminalKey.f7),
      ),
      _TerminalKeySpec(
        label: 'F8',
        onTap: () => _sendTerminalKey(TerminalKey.f8),
      ),
      _TerminalKeySpec(
        label: 'F9',
        onTap: () => _sendTerminalKey(TerminalKey.f9),
      ),
      _TerminalKeySpec(
        label: 'F10',
        onTap: () => _sendTerminalKey(TerminalKey.f10),
      ),
      _TerminalKeySpec(
        label: 'F11',
        onTap: () => _sendTerminalKey(TerminalKey.f11),
      ),
      _TerminalKeySpec(
        label: 'F12',
        onTap: () => _sendTerminalKey(TerminalKey.f12),
      ),
    ];

    final isWideLayout = MediaQuery.of(context).size.width >= 900;
    final allowPaging = !_showFnRow && !isWideLayout;
    final baseKeys = List<_TerminalKeySpec>.from(keyRowSecondaryBase);
    final advancedKeys = List<_TerminalKeySpec>.from(keyRowSecondaryAdvanced);
    final symbolKeys = List<_TerminalKeySpec>.from(keyRowSecondarySymbols);
    if (allowPaging) {
      baseKeys.insert(
        baseKeys.length - 1,
        _TerminalKeySpec(
          label: 'More',
          onTap: _showAdvancedKeys,
          isEmphasis: true,
        ),
      );
      baseKeys.insert(
        baseKeys.length - 1,
        _TerminalKeySpec(
          label: 'Sym',
          onTap: _showSymbolKeys,
          isEmphasis: true,
        ),
      );
      advancedKeys.insert(
        0,
        _TerminalKeySpec(
          label: 'Back',
          onTap: _showBaseKeys,
          isEmphasis: true,
        ),
      );
      advancedKeys.insert(
        1,
        _TerminalKeySpec(
          label: 'Sym',
          onTap: _showSymbolKeys,
          isEmphasis: true,
        ),
      );
      symbolKeys.insert(
        0,
        _TerminalKeySpec(
          label: 'Back',
          onTap: _showBaseKeys,
          isEmphasis: true,
        ),
      );
      symbolKeys.insert(
        1,
        _TerminalKeySpec(
          label: 'More',
          onTap: _showAdvancedKeys,
          isEmphasis: true,
        ),
      );
    } else if (!_showFnRow) {
      baseKeys.insert(
        baseKeys.length - 1,
        _TerminalKeySpec(
          label: 'Sym',
          onTap: _showSymbolKeys,
          isEmphasis: true,
        ),
      );
      symbolKeys.insert(
        0,
        _TerminalKeySpec(
          label: 'Back',
          onTap: _showBaseKeys,
          isEmphasis: true,
        ),
      );
    }
    final keyRowSecondary = _showFnRow
        ? keyRowFn
        : (isWideLayout
            ? baseKeys
            : (_secondaryKeyPage == 2
                ? symbolKeys
                : (_secondaryKeyPage == 1 && allowPaging
                    ? advancedKeys
                    : baseKeys)));
    final toolActions = [
      _TerminalToolAction(
        label: 'Paste',
        icon: Icons.content_paste,
        onTap: () => unawaited(_pasteClipboard()),
      ),
      _TerminalToolAction(
        label: 'Copy',
        icon: Icons.content_copy,
        onTap: () => unawaited(_copySelection()),
      ),
      _TerminalToolAction(
        label: 'Search',
        icon: Icons.search,
        onTap: () => unawaited(_showTerminalSearchSheet()),
      ),
      _TerminalToolAction(
        label: _showNavOnly ? 'Nav On' : 'Nav',
        icon: Icons.navigation,
        onTap: _toggleNavOnly,
        isActive: _showNavOnly,
      ),
      _TerminalToolAction(
        label: 'Select',
        icon: Icons.select_all,
        onTap: _selectAllInTerminal,
      ),
      _TerminalToolAction(
        label: 'Unselect',
        icon: Icons.highlight_off_outlined,
        onTap: _clearSelection,
      ),
      _TerminalToolAction(
        label: 'Clear',
        icon: Icons.cleaning_services_outlined,
        onTap: _clearTerminal,
      ),
      _TerminalToolAction(
        label: 'Reset',
        icon: Icons.restart_alt,
        onTap: _resetTerminal,
      ),
      if (!_isTerminalAtBottom)
        _TerminalToolAction(
          label: 'Bottom',
          icon: Icons.vertical_align_bottom,
          onTap: _jumpToTerminalBottom,
        ),
      if (_hasActiveModifiers)
        _TerminalToolAction(
          label: 'Mods Off',
          icon: Icons.backspace_outlined,
          onTap: _clearModifiers,
          isActive: true,
        ),
      _TerminalToolAction(
        label: _selectionMode == SelectionMode.block ? 'Block' : 'Line',
        icon: Icons.text_fields,
        onTap: _toggleSelectionMode,
        isActive: _selectionMode == SelectionMode.block,
      ),
      _TerminalToolAction(
        label: _mouseInputEnabled ? 'Mouse On' : 'Mouse',
        icon: _mouseInputEnabled ? Icons.mouse : Icons.mouse_outlined,
        onTap: _toggleMouseInput,
        isActive: _mouseInputEnabled,
      ),
      _TerminalToolAction(
        label: _hardwareKeyboardOnly ? 'HW KB' : 'Soft KB',
        icon:
            _hardwareKeyboardOnly ? Icons.keyboard_alt_outlined : Icons.keyboard,
        onTap: _toggleHardwareKeyboardOnly,
        isActive: _hardwareKeyboardOnly,
      ),
      _TerminalToolAction(
        label: 'Font',
        icon: Icons.format_size,
        onTap: () => unawaited(_showTerminalFontSheet()),
      ),
      _TerminalToolAction(
        label: 'Theme',
        icon: Icons.palette_outlined,
        onTap: () => unawaited(_showTerminalThemeSheet()),
      ),
    ];
    return _TimelineDetailScaffold(
      title: 'Terminal',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        sessionLabel,
                        style: headerStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Rename session',
                      onPressed: active == null ? null : _renameActiveSession,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: 'Switch session',
                      onPressed: _sessions.isEmpty
                          ? null
                          : () => _openSessionPicker(),
                      icon: const Icon(Icons.layers_outlined),
                    ),
                    IconButton(
                      tooltip: 'New session',
                      onPressed: _createSession,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusStyle.background,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          sessionStatus,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: statusStyle.foreground,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        connectionLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_terminalSearchQuery.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE2E8F0),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Search: "${_terminalSearchQuery}"',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: const Color(0xFF334155),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_remoteFetchError != null) ...[
                  const SizedBox(height: 8),
                  _InlineStatus(
                    message: _remoteFetchError!,
                    isError: true,
                  ),
                ] else if (showEmptyHint) ...[
                  const SizedBox(height: 8),
                  const _InlineStatus(
                    message: 'No terminal sessions yet.',
                  ),
                ],
                if (resolvedStatusMessage != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    resolvedStatusMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: resolvedStatusIsError
                          ? const Color(0xFFB91C1C)
                          : const Color(0xFF16A34A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (isDisconnected) ...[
                  const SizedBox(height: 6),
                  _TerminalReconnectCard(onReconnect: _attemptReconnect),
                ],
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: terminalBackground,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: terminalBorderColor),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: terminal == null
                          ? Center(
                              child: Text(
                                'Create a session to start.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: terminalForeground.withAlpha(180),
                                ),
                              ),
                            )
                          : TerminalView(
                              terminal,
                              controller: _terminalController,
                              focusNode: _terminalFocusNode,
                              scrollController: _terminalScrollController,
                              autofocus: true,
                              theme: terminalTheme,
                              textStyle: terminalStyle,
                              padding:
                                  const EdgeInsets.fromLTRB(10, 8, 10, 12),
                              backgroundOpacity: 0,
                              cursorType: TerminalCursorType.block,
                              keyboardType: TextInputType.text,
                              keyboardAppearance: isLightTerminal
                                  ? Brightness.light
                                  : Brightness.dark,
                              deleteDetection: true,
                              hardwareKeyboardOnly: _hardwareKeyboardOnly,
                              readOnly:
                                  active == null || isEnded || isDisconnected,
                            ),
                    ),
                    if (terminal != null && !_isTerminalAtBottom)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: InkWell(
                          onTap: _jumpToTerminalBottom,
                          borderRadius: BorderRadius.circular(999),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: terminalOverlayBackground,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: terminalOverlayForeground
                                    .withAlpha(isLightTerminal ? 40 : 70),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.vertical_align_bottom,
                                  size: 14,
                                  color: terminalOverlayForeground,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Bottom',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: terminalOverlayForeground,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
              10,
              6,
              10,
              _showKeyBar ? 10 : 6,
            ),
            decoration: const BoxDecoration(
              color: dockBackground,
              border: Border(
                top: BorderSide(color: Color(0xFF1E293B)),
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Spacer(),
                    IconButton(
                      tooltip: _showKeyBar ? 'Hide keys' : 'Show keys',
                      onPressed: () {
                        setState(() {
                          _showKeyBar = !_showKeyBar;
                        });
                      },
                      icon: Icon(
                        _showKeyBar
                            ? Icons.keyboard_hide_outlined
                            : Icons.keyboard_outlined,
                        color: const Color(0xFFE2E8F0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: toolActions
                        .map(
                          (action) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _TerminalToolButton(action: action),
                          ),
                        )
                        .toList(),
                  ),
                ),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 200),
                  crossFadeState: _showKeyBar
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: const SizedBox.shrink(),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      children: [
                        _buildKeyRow(keyRowPrimary),
                        if (!_showNavOnly) ...[
                          const SizedBox(height: 6),
                          _buildKeyRow(keyRowSecondary),
                          if (isWideLayout && !_showFnRow) ...[
                            const SizedBox(height: 6),
                            _buildKeyRow(keyRowSecondaryAdvanced),
                            if (_secondaryKeyPage == 2) ...[
                              const SizedBox(height: 6),
                              _buildKeyRow(keyRowSecondarySymbols),
                            ],
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class TerminalSessionScreen extends StatelessWidget {
  const TerminalSessionScreen({
    super.key,
    required this.event,
    required this.session,
    required this.storage,
    required this.agentBaseUrl,
    required this.authToken,
    required this.clientId,
    required this.clientName,
  });

  final TimelineEvent event;
  final ToolSession session;
  final StorageRepository storage;
  final String? agentBaseUrl;
  final String? authToken;
  final String? clientId;
  final String? clientName;

  @override
  Widget build(BuildContext context) {
    return TerminalWorkspaceScreen(
      storage: storage,
      agentBaseUrl: agentBaseUrl,
      authToken: authToken,
      clientId: clientId,
      clientName: clientName,
      initialSession: session,
      initialEvent: event,
      agentId: session.agentId,
    );
  }
}

class _TerminalSessionRow extends StatelessWidget {
  const _TerminalSessionRow({
    required this.session,
    required this.isActive,
    required this.onSelect,
    this.onClose,
  });

  final TerminalSessionView session;
  final bool isActive;
  final VoidCallback onSelect;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusStyle = _terminalStatusStyle(session.session.status);
    final background = isActive ? const Color(0xFFE0F2FE) : const Color(0xFFF8FAFC);
    final borderColor =
        isActive ? const Color(0xFF93C5FD) : const Color(0xFFE2E8F0);
    final statusLabel = session.session.status.toUpperCase();
    final rawReason = session.lastEvent?.payload['error_message']?.toString();
    final reason = rawReason?.trim();
    final status = session.session.status.toLowerCase();
    final showReason = reason != null &&
        reason.isNotEmpty &&
        (status == 'closed' ||
            status == 'killed' ||
            status == 'exited' ||
            status == 'disconnected' ||
            status == 'error');

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onSelect,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              const CircleAvatar(
                radius: 16,
                backgroundColor: Color(0xFFDBEAFE),
                child: Icon(
                  Icons.terminal,
                  size: 18,
                  color: Color(0xFF1D4ED8),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.session.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    if (session.lastCommand != null &&
                        session.lastCommand!.trim().isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        _truncate(session.lastCommand!, 40),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                        ),
                      ),
                    ],
                    if (showReason) ...[
                      const SizedBox(height: 4),
                      Text(
                        _truncate(reason!, 60),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFB91C1C),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: statusStyle.background,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  statusLabel,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: statusStyle.foreground,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (onClose != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onClose,
                  icon: const Icon(Icons.stop_circle_outlined),
                  tooltip: 'Disconnect',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TerminalReconnectCard extends StatelessWidget {
  const _TerminalReconnectCard({required this.onReconnect});

  final VoidCallback onReconnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFE4E6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDA4AF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.wifi_off,
            color: Color(0xFFBE123C),
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Session disconnected',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF9F1239),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Reconnect to the desktop agent to resume streaming.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF9F1239),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onReconnect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalStatusStyle {
  const _TerminalStatusStyle(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

_TerminalStatusStyle _terminalStatusStyle(String status) {
  switch (status.toLowerCase()) {
    case 'running':
      return const _TerminalStatusStyle(
        Color(0xFFDBEAFE),
        Color(0xFF1D4ED8),
      );
    case 'exited':
    case 'complete':
      return const _TerminalStatusStyle(
        Color(0xFFDCFCE7),
        Color(0xFF166534),
      );
    case 'error':
    case 'disconnected':
      return const _TerminalStatusStyle(
        Color(0xFFFEE2E2),
        Color(0xFFB91C1C),
      );
    case 'killed':
    case 'closed':
      return const _TerminalStatusStyle(
        Color(0xFFE2E8F0),
        Color(0xFF475569),
      );
    default:
      return const _TerminalStatusStyle(
        Color(0xFFFEF3C7),
        Color(0xFF92400E),
      );
  }
}

class AiInsightScreen extends StatelessWidget {
  const AiInsightScreen({
    super.key,
    required this.event,
    required this.session,
  });

  final TimelineEvent event;
  final ToolSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prompt = event.payload['prompt']?.toString();
    final summary = event.payload['summary']?.toString();
    final status = event.payload['status']?.toString() ?? session.status;
    final promptText = prompt ?? '';
    final summaryText = summary ?? '';
    final hasSummary = summaryText.trim().isNotEmpty;
    final hasPrompt = promptText.trim().isNotEmpty;

    return _TimelineDetailScaffold(
      title: 'AI Insight',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.label,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Requested ${_formatTimestamp(event.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 20),
            _ContextSectionCard(
              title: 'Session status',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _KeyValueRow(
                    label: 'Status',
                    value: status.toUpperCase(),
                  ),
                  _KeyValueRow(
                    label: 'Created',
                    value: _formatTimestamp(session.createdAt),
                  ),
                ],
              ),
            ),
            _ContextSectionCard(
              title: 'Prompt',
              child: hasPrompt
                  ? _CodeBlock(content: promptText)
                  : const _EmptyHint(text: 'No prompt recorded.'),
            ),
            _ContextSectionCard(
              title: 'AI output',
              subtitle: hasSummary
                  ? 'Summary and structured output'
                  : 'Awaiting AI response',
              child: hasSummary
                  ? _CodeBlock(content: summaryText)
                  : const _EmptyHint(text: 'No AI output recorded yet.'),
            ),
          ],
        ),
      ),
    );
  }
}

class VncSessionScreen extends StatefulWidget {
  const VncSessionScreen({
    super.key,
    required this.event,
    required this.session,
    required this.storage,
    required this.agentBaseUrl,
    required this.authToken,
    required this.clientId,
    required this.clientName,
  });

  final TimelineEvent event;
  final ToolSession session;
  final StorageRepository storage;
  final String? agentBaseUrl;
  final String? authToken;
  final String? clientId;
  final String? clientName;

  @override
  State<VncSessionScreen> createState() => _VncSessionScreenState();
}

enum VncEncodingPreference {
  zrle,
  tight,
  zlib,
  raw,
}

enum VncViewMode {
  fit,
  fill,
  original,
}

enum VncColorDepth {
  full,
  depth16,
}

class _VncSessionScreenState extends State<VncSessionScreen> {
  static const double _zoomMin = 0.5;
  static const double _zoomMax = 3.0;
  static const double _zoomDefault = 1.0;
  static const double _swipeThreshold = 120;
  static const double _tapSlop = 8;
  static const double _dragSlop = 6;
  static const double _scrollStep = 18;
  static const Duration _tapTimeout = Duration(milliseconds: 240);
  static const Duration _doubleTapTimeout = Duration(milliseconds: 220);
  static const int _encodingRaw = 0;
  static const int _encodingCopyRect = 1;
  static const int _encodingZlib = 6;
  static const int _encodingTight = 7;
  static const int _encodingZrle = 16;
  static const int _encodingCursor = -239;
  static const int _encodingCompressLevelBase = -256;
  static const int _encodingQualityLevelBase = -32;
  static const int _encodingDataSaver = -312;
  static const int _encodingHighPerf = -313;
  static const Duration _noFrameTimeout = Duration(seconds: 8);
  static const Duration _fpsWindow = Duration(milliseconds: 1000);
  static const double _trackpadMoreButtonSize = 40;
  static const double _trackpadMoreButtonMargin = 10;
  static const Offset _trackpadMoreAnchorDefault = Offset(0.88, 0.1);
  static const int _calibrationVersion = 2;
  static const double _calibrationAspectTolerance = 0.02;

  late Offset _pointerPosition;
  late Offset _cameraCenter;
  double _zoomValue = _zoomDefault;
  VncEncodingPreference _encodingPreference = VncEncodingPreference.zrle;
  int _tightCompressionLevel = 6;
  int _tightQualityLevel = 6;
  bool _tightJpegEnabled = false;
  bool _lowLatencyEnabled = true;
  VncColorDepth _colorDepth = VncColorDepth.full;
  bool _dataSaverEnabled = false;
  bool _highPerfEnabled = false;
  int _highPerfIntervalMs = 100;
  VncViewMode _viewMode = VncViewMode.fit;
  bool _isConnecting = false;
  bool _isResizing = false;
  String? _connectionError;
  Timer? _clickTimer;
  Timer? _dragHoldTimer;
  Timer? _focusTimer;
  bool _showFocusPulse = false;
  bool _showClickPulse = false;
  double _swipeDistance = 0;
  late DateTime _lastUpdatedAt;
  http.Client? _httpClient;
  AgentCommandClient? _agentClient;
  VncRfbClient? _vncClient;
  VncSessionInfo? _lastVncSessionInfo;
  RoiClient _roiClient = RoiNoopClient();
  RoiSessionInfo? _roiSession;
  StreamSubscription<RoiTilePayload>? _roiSubscription;
  final Map<RoiTileKey, ui.Image> _roiImages = {};
  RoiRenderer? _roiRenderer;
  Timer? _roiRequestTimer;
  Timer? _roiReconnectTimer;
  Timer? _roiResyncTimer;
  Size? _roiPendingResyncSize;
  double _devicePixelRatio = 1.0;
  DateTime? _roiLastTileAt;
  bool _roiConnecting = false;
  bool _roiConnected = false;
  DateTime? _roiConnectedAt;
  DateTime? _roiLastRequestAt;
  int _roiTileCount = 0;
  int _roiTileBytes = 0;
  String? _roiLastError;
  String? _roiHost;
  String? _roiDisabledReason;
  int _roiReconnectAttempts = 0;
  int _roiRevision = 0;
  bool _debugPanelOpen = false;
  ui.Image? _frameImage;
  ui.Image? _cursorImage;
  Size _cursorSize = Size.zero;
  Offset _cursorHotspot = Offset.zero;
  Size _frameSize = const Size(720, 1280);
  bool _isDecoding = false;
  VncFrame? _pendingFrame;
  DateTime? _streamStartedAt;
  DateTime? _lastFrameAt;
  Timer? _noFrameTimer;
  final List<int> _frameTimestamps = [];
  double _streamFps = 0;
  int? _streamLatencyMs;
  DateTime? _lastInputAt;
  bool _controlsSheetOpen = false;
  int _buttonMask = 0;
  bool _isDragging = false;
  Size _lastViewSize = Size.zero;
  Size _lastTrackpadSize = Size.zero;
  bool _directDragActive = false;
  final Map<int, Offset> _activePointers = {};
  Offset? _primaryDownPosition;
  DateTime? _primaryDownTime;
  Offset? _lastPrimaryPosition;
  DateTime? _lastTapTime;
  Offset? _lastTapPosition;
  bool _isFullscreen = false;
  double _inputScaleX = 1;
  double _inputScaleY = 1;
  double _inputOffsetX = 0;
  double _inputOffsetY = 0;
  bool _directInputEnabled = false;
  bool _showLocalCursor = false;
  bool _cursorDebugEnabled = false;
  final List<String> _cursorDebugLog = [];
  DateTime? _lastCursorDebugLoggedAt;
  Offset? _lastCursorDebugPointer;
  DateTime? _lastGestureDoubleTapAt;
  bool? _directInputBackup;
  int? _selectedDisplayIndex;
  List<VncDisplayInfo> _availableDisplays = const [];
  bool _isAutoCalibrating = false;
  int _calibrationStep = 0;
  List<Offset> _calibrationTargets = const [];
  final List<Offset> _calibrationSamples = [];
  Timer? _calibrationSaveTimer;
  Timer? _autoResizeTimer;
  bool _autoSizedOnce = false;
  bool _pendingFullFrameRequest = false;
  double? _calibrationBackupScaleX;
  double? _calibrationBackupScaleY;
  double? _calibrationBackupOffsetX;
  double? _calibrationBackupOffsetY;
  double? _calibrationAspectRatio;
  bool _calibrationNormalized = true;
  bool _hasStreamInfo = false;
  bool _isDisposed = false;
  Offset _trackpadMoreAnchor = _trackpadMoreAnchorDefault;
  bool _trackpadMoreRepositioning = false;
  Timer? _layoutRecalibrationTimer;
  bool _pendingLayoutRecalibration = false;
  DateTime? _lastRecalibrationAt;
  Size _lastLayoutSize = Size.zero;
  bool? _lastLayoutLandscape;
  bool _lastLayoutFullscreen = false;
  bool _pendingPointerReset = false;

  @override
  void initState() {
    super.initState();
    _pointerPosition = Offset(
      _frameSize.width / 2,
      _frameSize.height / 2,
    );
    _cameraCenter = _applyInputCalibration(_pointerPosition);
    _autoSizedOnce = false;
    _lastUpdatedAt = widget.event.createdAt;
    _configureAgentClient();
    _configureRoiClient();
    _hydrateFromPayload();
    unawaited(_loadDisplaySelection());
    unawaited(_loadLocalCursorPreference());
    unawaited(_loadCalibration());
    unawaited(_fetchDisplays());
    unawaited(_startStream());
  }

  @override
  void dispose() {
    _isDisposed = true;
    _clickTimer?.cancel();
    _dragHoldTimer?.cancel();
    _focusTimer?.cancel();
    _calibrationSaveTimer?.cancel();
    _autoResizeTimer?.cancel();
    _noFrameTimer?.cancel();
    _layoutRecalibrationTimer?.cancel();
    unawaited(_stopRoiSession());
    _vncClient?.close();
    _frameImage?.dispose();
    _cursorImage?.dispose();
    _httpClient?.close();
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _configureAgentClient() {
    final baseUrl = widget.agentBaseUrl?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      _agentClient = null;
      return;
    }
    _httpClient = http.Client();
    _agentClient = AgentCommandClient(
      baseUrl: baseUrl,
      client: _httpClient!,
      authToken: widget.authToken,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
  }

  void _configureRoiClient() {
    _roiDisabledReason = null;
    _roiHost = null;
    if (kIsWeb) {
      _roiClient = RoiNoopClient();
      _roiDisabledReason = 'web';
      return;
    }
    final baseUrl = widget.agentBaseUrl?.trim();
    if (baseUrl == null || baseUrl.isEmpty) {
      _roiClient = RoiNoopClient();
      _roiDisabledReason = 'no-agent';
      return;
    }
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host.isEmpty) {
      _roiClient = RoiNoopClient();
      _roiDisabledReason = 'invalid-url';
      return;
    }
    _roiHost = uri.host;
    _roiClient = RoiQuicClient(host: uri.host);
  }

  void _resetCursorState() {
    _cursorImage?.dispose();
    _cursorImage = null;
    _cursorSize = Size.zero;
    _cursorHotspot = Offset.zero;
  }

  void _resetStreamStats() {
    _frameTimestamps.clear();
    _streamFps = 0;
    _streamLatencyMs = null;
    _lastInputAt = null;
  }

  void _resetRoiState() {
    _roiRequestTimer?.cancel();
    _roiRequestTimer = null;
    _roiReconnectTimer?.cancel();
    _roiReconnectTimer = null;
    _roiResyncTimer?.cancel();
    _roiResyncTimer = null;
    _roiPendingResyncSize = null;
    _roiSession = null;
    _roiLastTileAt = null;
    _roiConnected = false;
    _roiConnectedAt = null;
    _roiLastRequestAt = null;
    _roiTileCount = 0;
    _roiTileBytes = 0;
    _roiLastError = null;
    _roiConnecting = false;
    _roiReconnectAttempts = 0;
    _roiSubscription?.cancel();
    _roiSubscription = null;
    for (final image in _roiImages.values) {
      image.dispose();
    }
    _roiImages.clear();
    _roiRenderer = null;
    _roiRevision = 0;
  }

  Future<void> _startRoiSession(VncSessionInfo sessionInfo) async {
    final agentClient = _agentClient;
    if (agentClient == null || _roiClient is RoiNoopClient) {
      return;
    }
    if (_roiConnecting) {
      return;
    }
    final screenWidth = sessionInfo.screenWidth ?? sessionInfo.width;
    final screenHeight = sessionInfo.screenHeight ?? sessionInfo.height;
    if (screenWidth <= 0 || screenHeight <= 0) {
      return;
    }
    _roiConnecting = true;
    _roiConnected = false;
    _roiLastError = null;
    if (mounted && !_isDisposed) {
      setState(() {});
    }
    try {
      final roiInfo = await agentClient.sendRoiCommand(
        action: 'start',
        sessionId: '${sessionInfo.sessionId}-roi',
        vncSessionId: sessionInfo.sessionId,
        framebufferWidth: sessionInfo.width,
        framebufferHeight: sessionInfo.height,
        screenWidth: screenWidth,
        screenHeight: screenHeight,
        displayIndex: sessionInfo.displayIndex,
      );
      if (!mounted || _isDisposed) {
        return;
      }
      _roiSession = roiInfo;
      await _roiClient.connect(roiInfo);
      _roiSubscription?.cancel();
      _roiSubscription = _roiClient.tiles.listen(_handleRoiTile);
      _scheduleRoiRequest();
      _roiReconnectAttempts = 0;
      _roiConnecting = false;
      _roiConnected = true;
      _roiConnectedAt = DateTime.now();
      if (mounted && !_isDisposed) {
        setState(() {});
      }
      _sendRoiRequest();
    } catch (error) {
      _roiConnecting = false;
      _roiConnected = false;
      _roiLastError = error.toString();
      if (mounted && !_isDisposed) {
        setState(() {});
      }
      _scheduleRoiReconnect(sessionInfo);
    }
  }

  Future<void> _stopRoiSession() async {
    if (_roiClient is RoiNoopClient) {
      _resetRoiState();
      return;
    }
    try {
      await _roiClient.disconnect();
    } catch (_) {}
    _resetRoiState();
  }

  void _scheduleRoiReconnect(VncSessionInfo sessionInfo) {
    if (_roiClient is RoiNoopClient) {
      return;
    }
    if (_roiReconnectTimer != null) {
      return;
    }
    if (_vncClient == null || _connectionError != null) {
      return;
    }
    _roiReconnectAttempts = (_roiReconnectAttempts + 1).clamp(0, 5);
    final delay = Duration(milliseconds: 1200 + _roiReconnectAttempts * 800);
    _roiReconnectTimer = Timer(delay, () {
      _roiReconnectTimer = null;
      if (!mounted || _isDisposed) {
        return;
      }
      if (_vncClient == null || _connectionError != null) {
        return;
      }
      unawaited(_startRoiSession(sessionInfo));
    });
  }

  void _scheduleRoiRequest() {
    if (_roiSession == null) {
      return;
    }
    if (_roiRequestTimer != null) {
      return;
    }
    _roiRequestTimer = Timer(const Duration(milliseconds: 60), () {
      _roiRequestTimer = null;
      _sendRoiRequest();
    });
  }

  void _sendRoiRequest() {
    final roiSession = _roiSession;
    if (roiSession == null) {
      return;
    }
    final now = DateTime.now();
    _roiLastRequestAt = now;
    var viewSize = _lastViewSize;
    if (viewSize.width <= 0 || viewSize.height <= 0) {
      final fallback = _frameSize;
      if (fallback.width <= 0 || fallback.height <= 0) {
        return;
      }
      viewSize = fallback;
    }
    final center = _clampedCameraCenter(viewSize);
    final scale = _baseScale(viewSize) * _zoom;
    if (scale <= 0) {
      return;
    }
    final viewportWidth = viewSize.width / scale;
    final viewportHeight = viewSize.height / scale;
    final prefetchRadius = (viewportWidth < viewportHeight
            ? viewportWidth
            : viewportHeight) *
        0.6;
    unawaited(_roiClient.requestRoi(
      centerX: center.dx,
      centerY: center.dy,
      zoom: _zoom,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      prefetchRadius: prefetchRadius,
    ));
    final lastTileAt = _roiLastTileAt;
    if (lastTileAt == null) {
      final connectedAt = _roiConnectedAt;
      if (connectedAt != null &&
          now.difference(connectedAt) > const Duration(seconds: 4)) {
        final info = _lastVncSessionInfo;
        if (info != null && !_roiConnecting) {
          _scheduleRoiReconnect(info);
        }
      }
      return;
    }
    if (now.difference(lastTileAt) > const Duration(seconds: 4)) {
      final info = _lastVncSessionInfo;
      if (info != null && !_roiConnecting) {
        _scheduleRoiReconnect(info);
      }
    }
  }

  void _handleRoiTile(RoiTilePayload payload) {
    if (!mounted || _isDisposed) {
      return;
    }
    final receivedAt = DateTime.now();
    _roiLastTileAt = receivedAt;
    final reconnectTimer = _roiReconnectTimer;
    if (reconnectTimer != null) {
      reconnectTimer.cancel();
      _roiReconnectTimer = null;
      _roiReconnectAttempts = 0;
    }
    if (payload.pixelWidth <= 0 || payload.pixelHeight <= 0) {
      return;
    }
    final expected = payload.pixelWidth * payload.pixelHeight * 4;
    if (payload.pixels.length < expected) {
      return;
    }
    final pixels = payload.pixels.length == expected
        ? payload.pixels
        : Uint8List.sublistView(payload.pixels, 0, expected);
    ui.decodeImageFromPixels(
      pixels,
      payload.pixelWidth,
      payload.pixelHeight,
      ui.PixelFormat.bgra8888,
      (image) {
      if (!mounted || _isDisposed) {
        image.dispose();
        return;
      }
      setState(() {
        _roiLastTileAt = receivedAt;
        _roiTileCount += 1;
        _roiTileBytes += payload.pixels.length;
        if (_roiTileCount > 1000000) {
          _roiTileCount = 0;
          _roiTileBytes = 0;
        }
        _roiImages.remove(payload.key)?.dispose();
        _roiImages[payload.key] = image;
        _roiRevision += 1;
          if (_roiImages.length > 256) {
            final firstKey = _roiImages.keys.first;
            _roiImages.remove(firstKey)?.dispose();
          }
        });
      },
      rowBytes: payload.pixelWidth * 4,
    );
  }

  void _maybeResyncRoiForFrame(Size newSize) {
    final roiSession = _roiSession;
    if (roiSession == null || _roiConnecting) {
      return;
    }
    final nextWidth = newSize.width.round();
    final nextHeight = newSize.height.round();
    if (roiSession.framebufferWidth == nextWidth &&
        roiSession.framebufferHeight == nextHeight) {
      _roiPendingResyncSize = null;
      return;
    }
    _roiPendingResyncSize = Size(
      nextWidth.toDouble(),
      nextHeight.toDouble(),
    );
    if (_roiResyncTimer != null) {
      return;
    }
    _roiResyncTimer = Timer(const Duration(milliseconds: 320), () {
      _roiResyncTimer = null;
      if (!mounted || _isDisposed) {
        return;
      }
      final sessionInfo = _lastVncSessionInfo;
      final pendingSize = _roiPendingResyncSize;
      _roiPendingResyncSize = null;
      if (sessionInfo == null || pendingSize == null) {
        return;
      }
      final pendingWidth = pendingSize.width.round();
      final pendingHeight = pendingSize.height.round();
      final activeSession = _roiSession;
      if (activeSession == null ||
          activeSession.framebufferWidth == pendingWidth &&
              activeSession.framebufferHeight == pendingHeight) {
        return;
      }
      unawaited(_resyncRoiSession(sessionInfo, pendingWidth, pendingHeight));
    });
  }

  Future<void> _resyncRoiSession(
    VncSessionInfo sessionInfo,
    int framebufferWidth,
    int framebufferHeight,
  ) async {
    if (_roiConnecting || _roiClient is RoiNoopClient) {
      return;
    }
    final updated = VncSessionInfo(
      sessionId: sessionInfo.sessionId,
      token: sessionInfo.token,
      wsPath: sessionInfo.wsPath,
      width: framebufferWidth,
      height: framebufferHeight,
      displayIndex: sessionInfo.displayIndex,
      inputWidth: sessionInfo.inputWidth,
      inputHeight: sessionInfo.inputHeight,
      inputOriginX: sessionInfo.inputOriginX,
      inputOriginY: sessionInfo.inputOriginY,
      inputScaleX: sessionInfo.inputScaleX,
      inputScaleY: sessionInfo.inputScaleY,
      screenWidth: sessionInfo.screenWidth,
      screenHeight: sessionInfo.screenHeight,
    );
    await _stopRoiSession();
    await _startRoiSession(updated);
  }

  void _markInputActivity() {
    _lastInputAt = DateTime.now();
  }

  String _formatSince(DateTime? value) {
    if (value == null) {
      return 'never';
    }
    final delta = DateTime.now().difference(value);
    if (delta.inMilliseconds < 1000) {
      return '${delta.inMilliseconds}ms';
    }
    if (delta.inSeconds < 60) {
      return '${delta.inSeconds}s';
    }
    if (delta.inMinutes < 60) {
      return '${delta.inMinutes}m';
    }
    return '${delta.inHours}h';
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '${bytes}B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)}KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)}GB';
  }

  String _roiStatusLabel() {
    if (_roiClient is RoiNoopClient) {
      switch (_roiDisabledReason) {
        case 'web':
          return '禁用(Web)';
        case 'no-agent':
          return '禁用(无Agent)';
        case 'invalid-url':
          return '禁用(URL异常)';
      }
      return '禁用';
    }
    if (_roiConnecting) {
      return '连接中';
    }
    if (_roiConnected) {
      return '已连接';
    }
    return '待机';
  }

  double _recordFrameFps(int nowMs) {
    _frameTimestamps.add(nowMs);
    final cutoff = nowMs - _fpsWindow.inMilliseconds;
    while (_frameTimestamps.length > 1 && _frameTimestamps.first < cutoff) {
      _frameTimestamps.removeAt(0);
    }
    final spanMs = _frameTimestamps.length > 1
        ? nowMs - _frameTimestamps.first
        : _fpsWindow.inMilliseconds;
    if (spanMs <= 0) {
      return _frameTimestamps.length.toDouble();
    }
    final fps = _frameTimestamps.length * 1000 / spanMs;
    return fps.clamp(0, 120).toDouble();
  }

  int? _resolveLatencyMs(VncFrame frame, int nowMs) {
    final lastInputAt = _lastInputAt;
    if (lastInputAt == null) {
      final requestLatency = frame.latencyMs;
      if (requestLatency == null || requestLatency > 1000) {
        return null;
      }
      return requestLatency;
    }
    final delta = nowMs - lastInputAt.millisecondsSinceEpoch;
    if (delta < 0 || delta > 5000) {
      final requestLatency = frame.latencyMs;
      if (requestLatency == null || requestLatency > 1000) {
        return null;
      }
      return requestLatency;
    }
    return delta;
  }

  void _hydrateFromPayload() {
    final status = widget.event.payload['status']?.toString().toLowerCase();
    if (status == 'failed' || status == 'error') {
      _connectionError =
          widget.event.payload['error']?.toString() ??
              'VNC stream failed. Retry to reconnect.';
    }
    final updatedAt = widget.event.payload['updated_at']?.toString();
    if (updatedAt != null) {
      final parsed = DateTime.tryParse(updatedAt);
      if (parsed != null) {
        _lastUpdatedAt = parsed;
      }
    }
    final zoomValue = widget.event.payload['zoom'];
    if (zoomValue is num) {
      _zoomValue = _clampZoom(zoomValue.toDouble());
    }
  }

  double? _currentAspectRatio() {
    if (_frameSize.width <= 0 || _frameSize.height <= 0) {
      return null;
    }
    return _frameSize.width / _frameSize.height;
  }

  bool _isAspectRatioCompatible(double? stored, Size size) {
    if (stored == null || size.width <= 0 || size.height <= 0) {
      return true;
    }
    final ratio = size.width / size.height;
    return (ratio - stored).abs() <= _calibrationAspectTolerance;
  }

  bool _isDefaultCalibration() {
    return (_inputScaleX - 1).abs() < 0.0001 &&
        (_inputScaleY - 1).abs() < 0.0001 &&
        _inputOffsetX.abs() < 0.0001 &&
        _inputOffsetY.abs() < 0.0001;
  }

  void _applyCalibrationDefaults({bool sendPointer = true}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _inputScaleX = 1;
      _inputScaleY = 1;
      _inputOffsetX = 0;
      _inputOffsetY = 0;
      _calibrationAspectRatio = null;
      _calibrationNormalized = true;
      _cameraCenter = _applyInputCalibration(_pointerPosition);
    });
    if (sendPointer) {
      _sendPointerEvent();
    }
  }

  void _maybeInvalidateCalibrationForFrameSize() {
    if (!_hasStreamInfo || !_calibrationNormalized) {
      return;
    }
    if (_isDefaultCalibration()) {
      return;
    }
    if (!_isAspectRatioCompatible(_calibrationAspectRatio, _frameSize)) {
      unawaited(_resetCalibration());
    }
  }

  String _calibrationStorageKey() {
    final agentId = widget.session.agentId ?? widget.session.id;
    final displayIndex = _selectedDisplayIndex ?? 0;
    return 'vnc_calibration:$agentId:$displayIndex';
  }

  Future<void> _loadCalibration() async {
    final raw = await widget.storage.readKeyValue(_calibrationStorageKey());
    if (!mounted) {
      return;
    }
    if (raw == null || raw.trim().isEmpty) {
      _applyCalibrationDefaults();
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await widget.storage.deleteKeyValue(_calibrationStorageKey());
        _applyCalibrationDefaults();
        return;
      }
      final version = (decoded['version'] as num?)?.toInt() ?? 1;
      final normalized = decoded['normalized'] == true;
      final scaleX = (decoded['scaleX'] as num?)?.toDouble();
      final scaleY = (decoded['scaleY'] as num?)?.toDouble();
      final offsetX = (decoded['offsetX'] as num?)?.toDouble();
      final offsetY = (decoded['offsetY'] as num?)?.toDouble();
      final aspectRatio = (decoded['aspectRatio'] as num?)?.toDouble();
      if (!normalized ||
          version != _calibrationVersion ||
          scaleX == null ||
          scaleY == null ||
          offsetX == null ||
          offsetY == null) {
        await widget.storage.deleteKeyValue(_calibrationStorageKey());
        _applyCalibrationDefaults();
        return;
      }
      setState(() {
        _inputScaleX = scaleX;
        _inputScaleY = scaleY;
        _inputOffsetX = offsetX;
        _inputOffsetY = offsetY;
        _calibrationAspectRatio = aspectRatio;
        _calibrationNormalized = true;
        _cameraCenter = _applyInputCalibration(_pointerPosition);
      });
      _sendPointerEvent();
      _maybeInvalidateCalibrationForFrameSize();
    } catch (_) {
      await widget.storage.deleteKeyValue(_calibrationStorageKey());
      _applyCalibrationDefaults();
      return;
    }
  }

  void _scheduleCalibrationSave() {
    _calibrationSaveTimer?.cancel();
    _calibrationSaveTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_persistCalibration());
    });
  }

  Future<void> _persistCalibration() async {
    final aspectRatio = _currentAspectRatio();
    final payload = jsonEncode({
      'version': _calibrationVersion,
      'normalized': true,
      'scaleX': _inputScaleX,
      'scaleY': _inputScaleY,
      'offsetX': _inputOffsetX,
      'offsetY': _inputOffsetY,
      'aspectRatio': aspectRatio,
    });
    await widget.storage.writeKeyValue(_calibrationStorageKey(), payload);
  }

  Future<void> _resetCalibration() async {
    _applyCalibrationDefaults();
    await widget.storage.deleteKeyValue(_calibrationStorageKey());
  }

  String _displayStorageKey() {
    final agentId = widget.session.agentId ?? widget.session.id;
    return 'vnc_display:$agentId';
  }

  String _localCursorStorageKey() {
    final agentId = widget.session.agentId ?? widget.session.id;
    return 'vnc_local_cursor:$agentId';
  }

  Future<void> _loadDisplaySelection() async {
    final raw = await widget.storage.readKeyValue(_displayStorageKey());
    if (!mounted || raw == null || raw.trim().isEmpty) {
      return;
    }
    final parsed = int.tryParse(raw);
    if (parsed == null) {
      return;
    }
    setState(() {
      _selectedDisplayIndex = parsed;
    });
  }

  Future<void> _persistDisplaySelection(int? index) async {
    if (index == null) {
      await widget.storage.deleteKeyValue(_displayStorageKey());
      return;
    }
    await widget.storage.writeKeyValue(_displayStorageKey(), index.toString());
  }

  Future<void> _loadLocalCursorPreference() async {
    final raw = await widget.storage.readKeyValue(_localCursorStorageKey());
    if (!mounted || raw == null || raw.trim().isEmpty) {
      return;
    }
    final normalized = raw.trim().toLowerCase();
    final nextValue = normalized == '1' || normalized == 'true';
    setState(() {
      _showLocalCursor = nextValue;
    });
  }

  Future<void> _persistLocalCursorPreference(bool value) async {
    await widget.storage.writeKeyValue(
      _localCursorStorageKey(),
      value ? '1' : '0',
    );
  }

  void _logCursorDebug(String type, Map<String, Object?> payload,
      {bool force = false}) {
    if (!_cursorDebugEnabled) {
      return;
    }
    final now = DateTime.now();
    if (!force && _lastCursorDebugLoggedAt != null) {
      final delta = now.difference(_lastCursorDebugLoggedAt!);
      if (delta < const Duration(milliseconds: 40)) {
        return;
      }
    }
    _lastCursorDebugLoggedAt = now;
    final entry = <String, Object?>{
      't': now.toIso8601String(),
      'type': type,
      ...payload,
    };
    _cursorDebugLog.add(jsonEncode(entry));
    if (_cursorDebugLog.length > 1200) {
      _cursorDebugLog.removeRange(0, _cursorDebugLog.length - 1000);
    }
  }

  void _copyCursorDebugLog() {
    if (_cursorDebugLog.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可复制的光标调试日志')),
      );
      return;
    }
    final header = jsonEncode({
      't': DateTime.now().toIso8601String(),
      'type': 'header',
      'sessionId': widget.session.id,
      'frameSize': {'w': _frameSize.width, 'h': _frameSize.height},
      'trackpadSize': {
        'w': _lastTrackpadSize.width,
        'h': _lastTrackpadSize.height,
      },
      'viewMode': _viewMode.name,
      'zoom': _zoom,
      'localCursor': _showLocalCursor,
    });
    final text = ([header, ..._cursorDebugLog]).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_cursorDebugLog.length} 条光标日志')),
    );
  }

  void _clearCursorDebugLog() {
    _cursorDebugLog.clear();
    _lastCursorDebugPointer = null;
    _lastCursorDebugLoggedAt = null;
  }

  void _logPointerSample(String source, Offset pointer) {
    if (_lastViewSize.width <= 0 || _lastViewSize.height <= 0) {
      return;
    }
    final effective = _applyInputCalibration(pointer);
    final scale = _baseScale(_lastViewSize) * _zoom;
    final translation = _calculateTranslation(_lastViewSize);
    final screen = translation + effective * scale;
    _logCursorDebug('pointer', {
      'source': source,
      'frame': {'x': pointer.dx, 'y': pointer.dy},
      'effective': {'x': effective.dx, 'y': effective.dy},
      'screen': {'x': screen.dx, 'y': screen.dy},
      'view': {'w': _lastViewSize.width, 'h': _lastViewSize.height},
      'frameSize': {'w': _frameSize.width, 'h': _frameSize.height},
      'viewMode': _viewMode.name,
      'zoom': _zoom,
      'calibration': {
        'scaleX': _inputScaleX,
        'scaleY': _inputScaleY,
        'offsetX': _inputOffsetX,
        'offsetY': _inputOffsetY,
        'normalized': _calibrationNormalized,
      },
    });
  }

  Future<void> _fetchDisplays() async {
    final agentClient = _agentClient;
    if (agentClient == null) {
      return;
    }
    try {
      final displays = await agentClient.fetchVncDisplays();
      if (!mounted) {
        return;
      }
      final previousIndex = _selectedDisplayIndex;
      int? nextIndex = previousIndex;
      if (displays.isNotEmpty) {
        if (previousIndex == null ||
            !displays.any((display) => display.index == previousIndex)) {
          nextIndex = displays.first.index;
        }
      }
      setState(() {
        _availableDisplays = displays;
        _selectedDisplayIndex = nextIndex;
      });
    if (nextIndex != previousIndex) {
      unawaited(_persistDisplaySelection(nextIndex));
      unawaited(_loadCalibration());
      _autoSizedOnce = false;
    }
    } catch (_) {
      return;
    }
  }

  String get _resolutionLabel =>
      '${_frameSize.width.toInt()}x${_frameSize.height.toInt()}';

  double get _zoom => _zoomValue;

  double _clampZoom(double value) {
    return value.clamp(_zoomMin, _zoomMax);
  }

  Uri _buildVncWebsocketUri(VncSessionInfo info) {
    final baseUri = Uri.parse(widget.agentBaseUrl!);
    final scheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    var basePath = baseUri.path;
    if (basePath.isNotEmpty && !basePath.endsWith('/')) {
      basePath = '$basePath/';
    }
    final wsPath = info.wsPath.startsWith('/') ? info.wsPath.substring(1) : info.wsPath;
    final mergedPath = basePath.isEmpty ? '/$wsPath' : '$basePath$wsPath';
    final queryParameters = Map<String, String>.from(baseUri.queryParameters);
    queryParameters['token'] = info.token;
    final authToken = widget.authToken?.trim();
    if (authToken != null && authToken.isNotEmpty) {
      queryParameters['auth_token'] = authToken;
    }
    final clientId = widget.clientId?.trim();
    if (clientId != null && clientId.isNotEmpty) {
      queryParameters['client_id'] = clientId;
    }
    final clientName = widget.clientName?.trim();
    if (clientName != null && clientName.isNotEmpty) {
      queryParameters['client_name'] = clientName;
    }
    return baseUri.replace(
      scheme: scheme,
      path: mergedPath,
      queryParameters: queryParameters,
    );
  }

  void _handleFrame(VncFrame frame) {
    if (!mounted || _isDisposed) {
      return;
    }
    _lastFrameAt = DateTime.now();
    _noFrameTimer?.cancel();
    if (_isDecoding) {
      _pendingFrame = frame;
      return;
    }
    if (frame.width <= 0 || frame.height <= 0) {
      return;
    }
    _isDecoding = true;
    _pendingFrame = null;
    final pixels = frame.pixels;
    final expectedLength = frame.width * frame.height * 4;
    final safePixels = Uint8List(expectedLength);
    if (pixels.length >= expectedLength) {
      safePixels.setRange(0, expectedLength, pixels);
    } else {
      safePixels.setRange(0, pixels.length, pixels);
    }
    ui.decodeImageFromPixels(
      safePixels,
      frame.width,
      frame.height,
      frame.format,
      (image) {
        if (!mounted || _isDisposed) {
          image.dispose();
          _isDecoding = false;
          return;
        }
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        final fps = _recordFrameFps(nowMs);
        final latencyMs = _resolveLatencyMs(frame, nowMs);
        final newSize = Size(
          frame.width.toDouble(),
          frame.height.toDouble(),
        );
        final sizeChanged = newSize != _frameSize;
        setState(() {
          _frameImage?.dispose();
          _frameImage = image;
          _streamFps = fps;
          _streamLatencyMs = latencyMs;
          _roiRenderer ??= RoiRenderer(framebufferSize: newSize);
          if (sizeChanged) {
            // Scale pointer position proportionally when frame size changes.
            // This ensures the cursor stays at the same relative position.
            final oldWidth = _frameSize.width > 0 ? _frameSize.width : newSize.width;
            final oldHeight = _frameSize.height > 0 ? _frameSize.height : newSize.height;
            final scaleX = newSize.width / oldWidth;
            final scaleY = newSize.height / oldHeight;
            _frameSize = newSize;
            _pointerPosition = Offset(
              (_pointerPosition.dx * scaleX).clamp(0, _frameSize.width),
              (_pointerPosition.dy * scaleY).clamp(0, _frameSize.height),
            );
            _cameraCenter = _applyInputCalibration(_pointerPosition);
            for (final image in _roiImages.values) {
              image.dispose();
            }
            _roiImages.clear();
            _roiRenderer = RoiRenderer(framebufferSize: newSize);
            _roiRevision += 1;
          }
        });
        if (sizeChanged) {
          _maybeInvalidateCalibrationForFrameSize();
          // Sync cursor position to desktop when frame size changes.
          // This ensures coordinates stay aligned after dynamic resizing.
          _sendPointerEvent();
          _maybeResyncRoiForFrame(newSize);
        }
        _isDecoding = false;
        final pending = _pendingFrame;
        _pendingFrame = null;
        if (pending != null) {
          _handleFrame(pending);
        }
      },
      rowBytes: frame.width * 4,
    );
  }

  void _handleCursor(VncCursor? cursor) {
    if (!mounted || _isDisposed) {
      return;
    }
    if (cursor == null || cursor.width <= 0 || cursor.height <= 0) {
      _logCursorDebug('cursor_clear', {
        'reason': 'null_or_empty',
      });
      setState(() {
        _resetCursorState();
      });
      return;
    }
    _logCursorDebug('cursor_update', {
      'w': cursor.width,
      'h': cursor.height,
      'hotX': cursor.hotX,
      'hotY': cursor.hotY,
      'len': cursor.pixels.length,
    });
    final expectedLength = cursor.width * cursor.height * 4;
    final safePixels = cursor.pixels.length >= expectedLength
        ? cursor.pixels.sublist(0, expectedLength)
        : Uint8List.fromList(cursor.pixels);
    ui.decodeImageFromPixels(
      safePixels,
      cursor.width,
      cursor.height,
      cursor.format,
      (image) {
        if (!mounted || _isDisposed) {
          image.dispose();
          return;
        }
        setState(() {
          _cursorImage?.dispose();
          _cursorImage = image;
          _cursorSize = Size(
            cursor.width.toDouble(),
            cursor.height.toDouble(),
          );
          _cursorHotspot = Offset(
            cursor.hotX.toDouble(),
            cursor.hotY.toDouble(),
          );
        });
      },
      rowBytes: cursor.width * 4,
    );
  }

  Future<void> _startStream({
    Size? requestedSize,
    bool preserveExisting = false,
    bool silentFailure = false,
  }) async {
    if (_isConnecting || _isResizing || _isDisposed) {
      return;
    }
    if (preserveExisting) {
      _isResizing = true;
    } else {
      setState(() {
        _isConnecting = true;
        _connectionError = null;
        _resetCursorState();
        _resetStreamStats();
      });
      unawaited(_stopRoiSession());
      await _updateSession(status: 'connecting');
    }

    final agentClient = _agentClient;
    if (agentClient == null) {
      if (!preserveExisting) {
        await _setStreamFailure(
          'Connect to the desktop agent to start streaming.',
        );
      }
      _isResizing = false;
      return;
    }

    VncRfbClient? candidate;
    final previousClient = _vncClient;
    final previousFrameSize = _frameSize;
    try {
      if (!preserveExisting) {
        _streamStartedAt = DateTime.now();
        _lastFrameAt = null;
      }
      final desired = requestedSize ?? _preferredStreamSize();
      final sessionInfo = await agentClient.sendVncCommand(
        action: 'start',
        sessionId: widget.session.id,
        width: (desired?.width ?? _frameSize.width).round(),
        height: (desired?.height ?? _frameSize.height).round(),
        displayIndex: _selectedDisplayIndex,
        highPerfIntervalMs: _highPerfEnabled ? _highPerfIntervalMs : null,
      );
      _lastVncSessionInfo = sessionInfo;
      if (_cursorDebugEnabled) {
        _logCursorDebug('session_info', {
          'width': sessionInfo.width,
          'height': sessionInfo.height,
          'display': sessionInfo.displayIndex,
          'input': {
            'width': sessionInfo.inputWidth,
            'height': sessionInfo.inputHeight,
            'originX': sessionInfo.inputOriginX,
            'originY': sessionInfo.inputOriginY,
            'scaleX': sessionInfo.inputScaleX,
            'scaleY': sessionInfo.inputScaleY,
          },
          'screen': {
            'width': sessionInfo.screenWidth,
            'height': sessionInfo.screenHeight,
          },
        }, force: true);
      }
      final wsUri = _buildVncWebsocketUri(sessionInfo);
      candidate = VncRfbClient(
        uri: wsUri,
        onFrame: _handleFrame,
        onCursor: _handleCursor,
        onError: (message) {
          if (!mounted || _isDisposed) {
            return;
          }
          if (_vncClient != candidate) {
            return;
          }
          unawaited(_setStreamFailure(message));
        },
        preferredEncodings: _buildEncodingList(),
      );
      await candidate.connect();
      if (!mounted || _isDisposed) {
        return;
      }
      unawaited(_startRoiSession(sessionInfo));
      final shouldResetCalibration = !preserveExisting &&
          sessionInfo.inputWidth != null &&
          sessionInfo.inputHeight != null;
      final nextFrameSize = Size(
        sessionInfo.width.toDouble(),
        sessionInfo.height.toDouble(),
      );
      final shouldPreservePointer = preserveExisting &&
          previousFrameSize.width > 0 &&
          previousFrameSize.height > 0;
      final nextPointer = shouldPreservePointer
          ? Offset(
              (_pointerPosition.dx * nextFrameSize.width / previousFrameSize.width)
                  .clamp(0, nextFrameSize.width),
              (_pointerPosition.dy * nextFrameSize.height / previousFrameSize.height)
                  .clamp(0, nextFrameSize.height),
            )
          : Offset(
              nextFrameSize.width / 2,
              nextFrameSize.height / 2,
            );
      setState(() {
        if (!preserveExisting) {
          _isConnecting = false;
        }
        _connectionError = null;
        if (!preserveExisting) {
          _resetCursorState();
        }
        _frameSize = nextFrameSize;
        _pointerPosition = nextPointer;
        _cameraCenter = _applyInputCalibration(nextPointer);
        _hasStreamInfo = true;
        if (sessionInfo.displayIndex != null) {
          _selectedDisplayIndex = sessionInfo.displayIndex;
        }
      });
      if (shouldResetCalibration) {
        _applyCalibrationDefaults(sendPointer: false);
        unawaited(widget.storage.deleteKeyValue(_calibrationStorageKey()));
      }
      _maybeInvalidateCalibrationForFrameSize();
      _vncClient = candidate;
      _applyEncodingPreferences();
      _applyPixelFormatPreference();
      // Sync the cursor position to the desktop after session creation.
      // This ensures mobile and desktop cursors are aligned after zoom changes.
      _sendPointerEvent();
      previousClient?.close();
      if (sessionInfo.displayIndex != null) {
        unawaited(_persistDisplaySelection(sessionInfo.displayIndex));
      }
      await _updateSession(status: 'connected');
      _vncClient?.requestFullFrame();
      _maybeAutoResizeStream();
      if (!preserveExisting) {
        _armNoFrameTimeout();
      }
    } on AgentCommandFailure catch (error) {
      if (!preserveExisting) {
        await _setStreamFailure(error.message);
      } else if (!silentFailure && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.message)),
        );
      }
    } catch (error) {
      if (!preserveExisting) {
        await _setStreamFailure('VNC stream failed: ${error.toString()}');
      } else if (!silentFailure && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('VNC resize failed: ${error.toString()}'),
          ),
        );
      }
    } finally {
      if (preserveExisting) {
        _isResizing = false;
      }
    }
  }

  Future<void> _setStreamFailure(String message) async {
    if (!mounted || _isDisposed) {
      return;
    }
    setState(() {
      _isConnecting = false;
      _connectionError = message;
      _hasStreamInfo = false;
      _resetCursorState();
    });
    _noFrameTimer?.cancel();
    _vncClient?.close();
    unawaited(_stopRoiSession());
    await _updateSession(status: 'failed', errorMessage: message);
  }

  void _armNoFrameTimeout() {
    _noFrameTimer?.cancel();
    _noFrameTimer = Timer(_noFrameTimeout, () {
      if (!mounted || _isDisposed) {
        return;
      }
      if (_connectionError != null || _isConnecting) {
        return;
      }
      final startedAt = _streamStartedAt;
      final lastFrameAt = _lastFrameAt;
      if (startedAt == null) {
        return;
      }
      if (lastFrameAt != null && lastFrameAt.isAfter(startedAt)) {
        return;
      }
      unawaited(_setStreamFailure(
        'No frames received from the desktop agent. Check Screen Recording permission and ensure the agent is running.',
      ));
    });
  }

  Future<void> _updateSession({
    required String status,
    String? errorMessage,
  }) async {
    if (!mounted || _isDisposed) {
      return;
    }
    setState(() {
      _lastUpdatedAt = DateTime.now();
    });
    final updatedSession = ToolSession(
      id: widget.session.id,
      type: widget.session.type,
      label: widget.session.label,
      status: status,
      createdAt: widget.session.createdAt,
    );
    final payload = Map<String, dynamic>.from(widget.event.payload);
    payload['status'] = status;
    payload['resolution'] = _resolutionLabel;
    payload['zoom'] = _zoom;
    payload['updated_at'] = DateTime.now().toIso8601String();
    if (errorMessage != null) {
      payload['error'] = errorMessage;
    } else {
      payload.remove('error');
    }

    final updatedEvent = TimelineEvent(
      id: widget.event.id,
      sessionId: widget.event.sessionId,
      type: widget.event.type,
      title: widget.event.title,
      payload: payload,
      createdAt: widget.event.createdAt,
    );
    try {
      await widget.storage.insertToolSession(updatedSession);
      await widget.storage.insertTimelineEvent(updatedEvent);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save VNC state: ${error.toString()}',
          ),
        ),
      );
    }
  }

  void _updateZoomValue(double value, {bool commit = false}) {
    final clamped = _clampZoom(value);
    if (clamped == _zoomValue) {
      return;
    }
    final focus = _effectivePointerPosition();
    setState(() {
      _zoomValue = clamped;
      _cameraCenter = focus;
    });
    _scheduleRoiRequest();
    if (_cursorDebugEnabled) {
      _logCursorDebug('zoom_change', {'zoom': _zoom}, force: true);
    }
    _triggerFocusPulse();
    if (commit) {
      unawaited(_updateSession(status: _currentStatusLabel));
    }
  }

  void _commitZoomValue(double value) {
    final before = _zoomValue;
    _updateZoomValue(value, commit: true);
    if (before != _zoomValue) {
      _requestStreamRefresh(resetAutoResize: true);
    }
  }

  void _resetZoom() {
    _commitZoomValue(_zoomDefault);
  }

  String get _currentStatusLabel {
    if (_connectionError != null) {
      return 'failed';
    }
    if (_isConnecting) {
      return 'connecting';
    }
    return 'connected';
  }

  void _triggerClickPulse() {
    _clickTimer?.cancel();
    setState(() {
      _showClickPulse = true;
    });
    _clickTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) {
        setState(() {
          _showClickPulse = false;
        });
      }
    });
  }

  void _triggerFocusPulse() {
    _focusTimer?.cancel();
    setState(() {
      _showFocusPulse = true;
    });
    _focusTimer = Timer(const Duration(milliseconds: 220), () {
      if (mounted) {
        setState(() {
          _showFocusPulse = false;
        });
      }
    });
  }

  Offset _applyTrackpadAcceleration(Offset delta, {double scale = 1}) {
    final safeScale = scale <= 0 ? 1 : scale;
    final distance = delta.distance / safeScale;
    if (distance == 0) {
      return delta;
    }
    final boost = (distance / 22).clamp(0.0, 2.5);
    final factor = 1 + boost;
    return delta * factor;
  }

  void _updateTrackpadSize(Size size, {required String source}) {
    if (size.width <= 0 || size.height <= 0) {
      return;
    }
    if (_lastTrackpadSize == size) {
      return;
    }
    _lastTrackpadSize = size;
    if (_cursorDebugEnabled) {
      _logCursorDebug('trackpad_size', {
        'source': source,
        'w': size.width,
        'h': size.height,
      }, force: true);
    }
  }

  double _trackpadBaseScale(Size trackpadSize) {
    if (_frameSize.width <= 0 || _frameSize.height <= 0) {
      return 1;
    }
    final scaleX = trackpadSize.width / _frameSize.width;
    final scaleY = trackpadSize.height / _frameSize.height;
    if (!scaleX.isFinite || !scaleY.isFinite) {
      return 1;
    }
    return (scaleX + scaleY) / 2;
  }

  void _movePointerBy(Offset delta) {
    final trackpadSize = _lastTrackpadSize;
    final viewSize = _lastViewSize;
    final surfaceSize = (trackpadSize.width > 0 && trackpadSize.height > 0)
        ? trackpadSize
        : viewSize;
    if (surfaceSize.width <= 0 || surfaceSize.height <= 0) {
      final accelerated = _applyTrackpadAcceleration(delta);
      _setPointerPosition(_pointerPosition + accelerated / _zoom);
      return;
    }
    final scaleX = surfaceSize.width / _frameSize.width;
    final scaleY = surfaceSize.height / _frameSize.height;
    if (!scaleX.isFinite || !scaleY.isFinite || scaleX == 0 || scaleY == 0) {
      return;
    }
    final baseScale = _trackpadBaseScale(surfaceSize) * _zoom;
    final accelerated = _applyTrackpadAcceleration(delta, scale: baseScale);
    final scaled = Offset(
      accelerated.dx / (scaleX * _zoom),
      accelerated.dy / (scaleY * _zoom),
    );
    _setPointerPosition(_pointerPosition + scaled);
  }

  void _setPointerPosition(Offset position) {
    final clamped = Offset(
      position.dx.clamp(0, _frameSize.width),
      position.dy.clamp(0, _frameSize.height),
    );
    final adjusted = _applyInputCalibration(clamped);
    setState(() {
      _pointerPosition = clamped;
      _cameraCenter = adjusted;
    });
    if (_cursorDebugEnabled) {
      final last = _lastCursorDebugPointer;
      if (last == null || (clamped - last).distance >= 1) {
        _lastCursorDebugPointer = clamped;
        _logPointerSample('set_pointer', clamped);
      }
    }
    _sendPointerEvent();
    _scheduleRoiRequest();
  }

  Offset _applyInputCalibration(Offset position) {
    if (!_calibrationNormalized) {
      final scaled = Offset(
        position.dx * _inputScaleX + _inputOffsetX,
        position.dy * _inputScaleY + _inputOffsetY,
      );
      return Offset(
        scaled.dx.clamp(0, _frameSize.width),
        scaled.dy.clamp(0, _frameSize.height),
      );
    }
    final width = _frameSize.width;
    final height = _frameSize.height;
    if (width <= 0 || height <= 0) {
      return position;
    }
    final normalized = Offset(position.dx / width, position.dy / height);
    final adjusted = Offset(
      normalized.dx * _inputScaleX + _inputOffsetX,
      normalized.dy * _inputScaleY + _inputOffsetY,
    );
    final scaled = Offset(adjusted.dx * width, adjusted.dy * height);
    return Offset(
      scaled.dx.clamp(0, width),
      scaled.dy.clamp(0, height),
    );
  }

  Offset _removeInputCalibration(Offset position) {
    if (!_calibrationNormalized) {
      final scaleX = _inputScaleX == 0 ? 1 : _inputScaleX;
      final scaleY = _inputScaleY == 0 ? 1 : _inputScaleY;
      final raw = Offset(
        (position.dx - _inputOffsetX) / scaleX,
        (position.dy - _inputOffsetY) / scaleY,
      );
      return Offset(
        raw.dx.clamp(0, _frameSize.width),
        raw.dy.clamp(0, _frameSize.height),
      );
    }
    final width = _frameSize.width;
    final height = _frameSize.height;
    if (width <= 0 || height <= 0) {
      return position;
    }
    final scaleX = _inputScaleX == 0 ? 1 : _inputScaleX;
    final scaleY = _inputScaleY == 0 ? 1 : _inputScaleY;
    final normalized = Offset(position.dx / width, position.dy / height);
    final rawNormalized = Offset(
      (normalized.dx - _inputOffsetX) / scaleX,
      (normalized.dy - _inputOffsetY) / scaleY,
    );
    final raw = Offset(rawNormalized.dx * width, rawNormalized.dy * height);
    return Offset(
      raw.dx.clamp(0, width),
      raw.dy.clamp(0, height),
    );
  }

  Offset _effectivePointerPosition() {
    return _applyInputCalibration(_pointerPosition);
  }

  double _baseScale(Size viewSize) {
    if (_frameSize.width == 0 || _frameSize.height == 0) {
      return 1;
    }
    final scaleX = viewSize.width / _frameSize.width;
    final scaleY = viewSize.height / _frameSize.height;
    switch (_viewMode) {
      case VncViewMode.fit:
        return scaleX < scaleY ? scaleX : scaleY;
      case VncViewMode.fill:
        return scaleX > scaleY ? scaleX : scaleY;
      case VncViewMode.original:
        return 1;
    }
  }

  Offset _clampedCameraCenter(Size viewSize) {
    if (_frameSize.width == 0 || _frameSize.height == 0) {
      return _cameraCenter;
    }
    final scale = _baseScale(viewSize) * _zoom;
    if (scale <= 0) {
      return _cameraCenter;
    }
    final visibleWidth = viewSize.width / scale;
    final visibleHeight = viewSize.height / scale;
    final minX = visibleWidth >= _frameSize.width
        ? _frameSize.width / 2
        : visibleWidth / 2;
    final maxX = visibleWidth >= _frameSize.width
        ? _frameSize.width / 2
        : _frameSize.width - visibleWidth / 2;
    final minY = visibleHeight >= _frameSize.height
        ? _frameSize.height / 2
        : visibleHeight / 2;
    final maxY = visibleHeight >= _frameSize.height
        ? _frameSize.height / 2
        : _frameSize.height - visibleHeight / 2;
    return Offset(
      _cameraCenter.dx.clamp(minX, maxX),
      _cameraCenter.dy.clamp(minY, maxY),
    );
  }

  Offset _calculateTranslation(Size viewSize) {
    final center = Offset(viewSize.width / 2, viewSize.height / 2);
    final scale = _baseScale(viewSize) * _zoom;
    final camera = _clampedCameraCenter(viewSize);
    var translation = center - camera * scale;
    if (_zoom > 1.01 && _devicePixelRatio > 0) {
      final snappedX = (translation.dx * _devicePixelRatio).round() / _devicePixelRatio;
      final snappedY = (translation.dy * _devicePixelRatio).round() / _devicePixelRatio;
      translation = Offset(snappedX, snappedY);
    }
    return translation;
  }

  Offset _pointerToScreen(Size viewSize) {
    final scale = _baseScale(viewSize) * _zoom;
    final translation = _calculateTranslation(viewSize);
    return translation + _effectivePointerPosition() * scale;
  }

  Offset _frameToScreen(Offset framePosition, Size viewSize) {
    final scale = _baseScale(viewSize) * _zoom;
    final translation = _calculateTranslation(viewSize);
    return translation + framePosition * scale;
  }

  Offset _screenToFrame(Offset screenPosition, Size viewSize) {
    final scale = _baseScale(viewSize) * _zoom;
    final translation = _calculateTranslation(viewSize);
    if (scale == 0) {
      return Offset.zero;
    }
    final raw = (screenPosition - translation) / scale;
    return Offset(
      raw.dx.clamp(0, _frameSize.width),
      raw.dy.clamp(0, _frameSize.height),
    );
  }

  void _sendPointerEvent() {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    _markInputActivity();
    final adjusted = _applyInputCalibration(_pointerPosition);
    final maxX = _maxPointerX();
    final maxY = _maxPointerY();
    final x = adjusted.dx.round().clamp(0, maxX);
    final y = adjusted.dy.round().clamp(0, maxY);
    if (_cursorDebugEnabled) {
      _logCursorDebug('send_pointer', {
        'x': x,
        'y': y,
        'maxX': maxX,
        'maxY': maxY,
        'server': {
          'w': client.serverWidth,
          'h': client.serverHeight,
        },
      });
    }
    client.sendPointer(x: x, y: y, mask: _buttonMask);
    client.requestIncrementalFrame();
  }

  List<int> _buildEncodingList() {
    final ordered = <int>[];
    if (_lowLatencyEnabled) {
      ordered.add(_encodingZlib);
    } else {
      switch (_encodingPreference) {
        case VncEncodingPreference.zrle:
          ordered.add(_encodingZrle);
          break;
        case VncEncodingPreference.tight:
          ordered.add(_encodingTight);
          break;
        case VncEncodingPreference.zlib:
          ordered.add(_encodingZlib);
          break;
        case VncEncodingPreference.raw:
          ordered.add(_encodingRaw);
          break;
      }
    }
    const fallback = [
      _encodingZrle,
      _encodingTight,
      _encodingZlib,
      _encodingRaw,
    ];
    for (final encoding in fallback) {
      if (!ordered.contains(encoding)) {
        ordered.add(encoding);
      }
    }
    if (_highPerfEnabled) {
      ordered.add(_encodingHighPerf);
    } else if (_dataSaverEnabled) {
      ordered.add(_encodingDataSaver);
    }
    if (_colorDepth == VncColorDepth.depth16) {
      ordered.removeWhere(
        (encoding) => encoding == _encodingZrle || encoding == _encodingTight,
      );
    }
    if (!ordered.contains(_encodingCopyRect)) {
      ordered.add(_encodingCopyRect);
    }
    if (!ordered.contains(_encodingCursor)) {
      ordered.add(_encodingCursor);
    }
    if (ordered.contains(_encodingTight)) {
      ordered.add(_encodingCompressLevelBase + _tightCompressionLevel);
      if (_tightJpegEnabled) {
        ordered.add(_encodingQualityLevelBase + _tightQualityLevel);
      }
    }
    return ordered;
  }

  void _applyEncodingPreferences() {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    client.setEncodings(_buildEncodingList());
  }

  void _applyPixelFormatPreference() {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    client.setPixelFormat(use16Bit: _colorDepth == VncColorDepth.depth16);
  }

  void _setLowLatencyMode(bool enabled) {
    setState(() {
      _lowLatencyEnabled = enabled;
      if (enabled) {
        _encodingPreference = VncEncodingPreference.zlib;
        _tightCompressionLevel = 1;
        _tightJpegEnabled = false;
      }
    });
    _applyEncodingPreferences();
    _applyPixelFormatPreference();
    _requestStreamRefresh(resetAutoResize: true);
  }

  void _setDataSaverMode(bool enabled) {
    setState(() {
      _dataSaverEnabled = enabled;
      if (enabled) {
        _highPerfEnabled = false;
      }
    });
    _applyEncodingPreferences();
    _requestStreamRefresh(resetAutoResize: true);
  }

  void _setHighPerfMode(bool enabled) {
    setState(() {
      _highPerfEnabled = enabled;
      if (enabled) {
        _dataSaverEnabled = false;
      }
    });
    _applyEncodingPreferences();
    if (enabled) {
      unawaited(_startStream(preserveExisting: true));
    } else {
      _requestStreamRefresh(resetAutoResize: true);
    }
  }

  double _viewAspectRatio(Size screenSize) {
    final frameAspect = _frameSize.height == 0
        ? 1
        : _frameSize.width / _frameSize.height;
    if (_viewMode == VncViewMode.fill) {
      return screenSize.width / screenSize.height.toDouble();
    }
    return frameAspect.toDouble();
  }

  Size? _preferredStreamSize() {
    if (!mounted) {
      return null;
    }
    if (_lastViewSize.width <= 0 || _lastViewSize.height <= 0) {
      return null;
    }
    double aspect = _frameSize.width > 0 && _frameSize.height > 0
        ? _frameSize.width / _frameSize.height
        : 1;
    if (_selectedDisplayIndex != null && _availableDisplays.isNotEmpty) {
      final display = _availableDisplays.firstWhere(
        (item) => item.index == _selectedDisplayIndex,
        orElse: () => _availableDisplays.first,
      );
      if (display.width > 0 && display.height > 0) {
        aspect = display.width / display.height;
      }
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final zoomFactor = _zoom.clamp(0.7, 2.5);
    final display = _availableDisplays.isNotEmpty
        ? _availableDisplays.firstWhere(
            (item) => item.index == _selectedDisplayIndex,
            orElse: () => _availableDisplays.first,
          )
        : null;
    final maxDisplayWidth =
        (display?.width ?? 4096) > 0 ? (display?.width ?? 4096) : 4096;
    final maxDisplayHeight =
        (display?.height ?? 4096) > 0 ? (display?.height ?? 4096) : 4096;
    final preferNative = _zoom > 1.05 &&
        display != null &&
        display.width > 0 &&
        display.height > 0;
    var targetWidth = preferNative
        ? display!.width
        : (_lastViewSize.width * dpr * zoomFactor)
            .round()
            .clamp(1, maxDisplayWidth);
    var targetHeight = preferNative
        ? display!.height
        : (targetWidth / aspect).round().clamp(1, maxDisplayHeight);
    final viewMaxHeight = (_lastViewSize.height * dpr).round();
    if (zoomFactor <= 1.05 && viewMaxHeight > 0 && targetHeight > viewMaxHeight) {
      targetHeight = viewMaxHeight;
      targetWidth =
          (targetHeight * aspect).round().clamp(1, maxDisplayWidth);
    }
    return Size(targetWidth.toDouble(), targetHeight.toDouble());
  }

  void _maybeAutoResizeStream() {
    if (!mounted || _isDisposed) {
      return;
    }
    if (_autoSizedOnce ||
        _isResizing ||
        _isConnecting ||
        _vncClient == null ||
        _viewMode == VncViewMode.original) {
      return;
    }
    final desired = _preferredStreamSize();
    if (desired == null) {
      return;
    }
    final delta = (desired.width - _frameSize.width).abs() +
        (desired.height - _frameSize.height).abs();
    if (delta < 40) {
      _autoSizedOnce = true;
      return;
    }
    _autoSizedOnce = true;
    _autoResizeTimer?.cancel();
    _autoResizeTimer = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _isDisposed) {
        return;
      }
      unawaited(
        _startStream(
          requestedSize: desired,
          preserveExisting: true,
          silentFailure: true,
        ),
      );
    });
  }

  void _sendClick(int mask) {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    _buttonMask = mask;
    _sendPointerEvent();
    _buttonMask = 0;
    _sendPointerEvent();
    _triggerClickPulse();
  }

  void _sendScrollStep(double direction) {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    _markInputActivity();
    final adjusted = _applyInputCalibration(_pointerPosition);
    final maxX = _maxPointerX();
    final maxY = _maxPointerY();
    final x = adjusted.dx.round().clamp(0, maxX).toInt();
    final y = adjusted.dy.round().clamp(0, maxY).toInt();
    client.sendScroll(x: x, y: y, delta: direction.isNegative ? -1 : 1);
    client.requestIncrementalFrame();
  }

  int _maxPointerX() {
    final max = _frameSize.width.floor() - 1;
    return max < 0 ? 0 : max;
  }

  int _maxPointerY() {
    final max = _frameSize.height.floor() - 1;
    return max < 0 ? 0 : max;
  }

  void _cancelDragHold() {
    _dragHoldTimer?.cancel();
    _dragHoldTimer = null;
  }

  void _endDrag() {
    if (!_isDragging) {
      return;
    }
    _isDragging = false;
    _buttonMask &= ~1;
    _sendPointerEvent();
  }

  Offset _averagePointerPosition() {
    if (_activePointers.isEmpty) {
      return Offset.zero;
    }
    var sum = Offset.zero;
    for (final position in _activePointers.values) {
      sum += position;
    }
    return sum / _activePointers.length.toDouble();
  }

  bool _isTapCandidate(DateTime now) {
    if (_primaryDownTime == null || _primaryDownPosition == null) {
      return false;
    }
    if (now.difference(_primaryDownTime!) > _tapTimeout) {
      return false;
    }
    final last = _lastPrimaryPosition ?? _primaryDownPosition!;
    return (last - _primaryDownPosition!).distance <= _tapSlop;
  }

  void _resetPointerTracking() {
    _primaryDownPosition = null;
    _primaryDownTime = null;
    _lastPrimaryPosition = null;
    _cancelDragHold();
  }

  void _clearPointerState({bool sendPointer = true}) {
    final shouldRelease = _isDragging || _buttonMask != 0;
    setState(() {
      _activePointers.clear();
      _resetPointerTracking();
      _lastTapTime = null;
      _lastTapPosition = null;
      _directDragActive = false;
      _isDragging = false;
      _buttonMask = 0;
    });
    if (sendPointer && shouldRelease) {
      _sendPointerEvent();
    }
  }

  void _schedulePointerReset() {
    if (_pendingPointerReset) {
      return;
    }
    _pendingPointerReset = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposed) {
        return;
      }
      if (!_pendingPointerReset) {
        return;
      }
      _pendingPointerReset = false;
      _clearPointerState();
    });
  }

  void _handleTrackpadPointerDown(PointerDownEvent event) {
    if (_connectionError != null || _isConnecting) {
      return;
    }
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 1) {
      _primaryDownPosition = event.position;
      _primaryDownTime = DateTime.now();
      _lastPrimaryPosition = event.position;
    } else {
      _cancelDragHold();
    }
  }

  void _handleTrackpadPointerMove(PointerMoveEvent event) {
    if (_connectionError != null || _isConnecting) {
      return;
    }
    if (!_activePointers.containsKey(event.pointer)) {
      return;
    }
    _activePointers[event.pointer] = event.position;
    if (_activePointers.length == 1) {
      final last = _lastPrimaryPosition ?? event.position;
      final delta = event.position - last;
      if (_primaryDownPosition != null &&
          (event.position - _primaryDownPosition!).distance > _dragSlop) {
        _cancelDragHold();
      }
      if (delta.distance != 0) {
        _movePointerBy(delta);
      }
      _lastPrimaryPosition = event.position;
    } else {
      // Multi-finger gestures are handled by the OS, do not intercept.
    }
  }

  void _handleTrackpadPointerUp(PointerUpEvent event) {
    if (!_activePointers.containsKey(event.pointer)) {
      return;
    }
    final wasMultiFinger = _activePointers.length >= 2;
    _activePointers.remove(event.pointer);
    if (_activePointers.isEmpty) {
      final now = DateTime.now();
      final lastGestureTap = _lastGestureDoubleTapAt;
      if (lastGestureTap != null &&
          now.difference(lastGestureTap) <= _doubleTapTimeout) {
        _lastGestureDoubleTapAt = null;
        _resetPointerTracking();
        return;
      }
      if (_isDragging) {
        _endDrag();
      } else if (!wasMultiFinger && _isTapCandidate(now)) {
        final lastTap = _lastTapTime;
        final lastPos = _lastTapPosition;
        if (lastTap != null &&
            now.difference(lastTap) <= _doubleTapTimeout &&
            lastPos != null &&
            (_primaryDownPosition == null ||
                (_primaryDownPosition! - lastPos).distance <= _tapSlop)) {
          _sendClick(1);
          _lastTapTime = null;
          _lastTapPosition = null;
        } else {
          _lastTapTime = now;
          _lastTapPosition = _primaryDownPosition;
        }
      }
      _resetPointerTracking();
    } else if (_activePointers.length == 1) {
      final remaining = _activePointers.values.first;
      _primaryDownPosition = remaining;
      _primaryDownTime = DateTime.now();
      _lastPrimaryPosition = remaining;
    }
  }

  void _handleTrackpadPointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _endDrag();
    _resetPointerTracking();
  }

  void _sendKeyPress(int keysym) {
    final client = _vncClient;
    if (client == null || _connectionError != null || _isConnecting) {
      return;
    }
    _markInputActivity();
    client.sendKey(down: true, keysym: keysym);
    client.sendKey(down: false, keysym: keysym);
    client.requestIncrementalFrame();
  }

  Future<void> _showKeyboardInput() async {
    if (!mounted) {
      return;
    }
    if (_vncClient == null || _connectionError != null || _isConnecting) {
      return;
    }
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Send keystrokes',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  hintText: 'Type and send to the remote session',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) {
                  final trimmed = value.trim();
                  if (trimmed.isNotEmpty) {
                    _vncClient?.sendText(trimmed);
                  }
                  Navigator.of(context).maybePop();
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      final trimmed = controller.text.trim();
                      if (trimmed.isNotEmpty) {
                        _vncClient?.sendText(trimmed);
                      }
                      Navigator.of(context).maybePop();
                    },
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleSwipeUpdate(DragUpdateDetails details) {
    _swipeDistance += details.delta.dy;
  }

  void _handleSwipeEnd(DragEndDetails details) {
    if (_swipeDistance > _swipeThreshold) {
      Navigator.of(context).maybePop();
    }
    _swipeDistance = 0;
  }

  Future<void> _setFullscreen(bool value) async {
    if (!mounted || _isFullscreen == value) {
      return;
    }
    _clearPointerState();
    setState(() {
      _isFullscreen = value;
      _autoSizedOnce = false;
      if (value) {
        _directInputBackup = _directInputEnabled;
        _directInputEnabled = false;
      } else if (_directInputBackup != null) {
        _directInputEnabled = _directInputBackup ?? false;
        _directInputBackup = null;
      }
    });
    if (value) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleLayoutRecalibration();
    _requestStreamRefresh(resetAutoResize: true);
  }

  void _requestStreamRefresh({bool resetAutoResize = false}) {
    if (resetAutoResize) {
      _autoSizedOnce = false;
    }
    if (_pendingFullFrameRequest) {
      return;
    }
    _pendingFullFrameRequest = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingFullFrameRequest = false;
      if (!mounted || _isDisposed) {
        return;
      }
      _maybeAutoResizeStream();
      _vncClient?.requestFullFrame();
    });
  }

  void _scheduleLayoutRecalibration() {
    _pendingLayoutRecalibration = true;
    _layoutRecalibrationTimer?.cancel();
    _layoutRecalibrationTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || _isDisposed) {
        return;
      }
      if (!_pendingLayoutRecalibration) {
        return;
      }
      _pendingLayoutRecalibration = false;
      _performLayoutRecalibration();
    });
  }

  void _maybeHandleLayoutChange(Size viewSize, bool isLandscape) {
    if (_lastLayoutSize == Size.zero) {
      _lastLayoutSize = viewSize;
      _lastLayoutLandscape = isLandscape;
      _lastLayoutFullscreen = _isFullscreen;
      return;
    }
    final sizeDelta = (viewSize.width - _lastLayoutSize.width).abs() +
        (viewSize.height - _lastLayoutSize.height).abs();
    final landscapeChanged =
        _lastLayoutLandscape != null && _lastLayoutLandscape != isLandscape;
    final fullscreenChanged = _lastLayoutFullscreen != _isFullscreen;
    if (sizeDelta <= 6 && !landscapeChanged && !fullscreenChanged) {
      return;
    }
    if (landscapeChanged || fullscreenChanged) {
      _schedulePointerReset();
    }
    _lastLayoutSize = viewSize;
    _lastLayoutLandscape = isLandscape;
    _lastLayoutFullscreen = _isFullscreen;
    _scheduleLayoutRecalibration();
  }

  void _performLayoutRecalibration() {
    if (_connectionError != null || _isConnecting || _vncClient == null) {
      return;
    }
    if (_directInputEnabled) {
      return;
    }
    if (_isAutoCalibrating) {
      return;
    }
    final now = DateTime.now();
    if (_lastRecalibrationAt != null) {
      final elapsed = now.difference(_lastRecalibrationAt!);
      if (elapsed.inMilliseconds < 1500) {
        _pendingLayoutRecalibration = true;
        _layoutRecalibrationTimer?.cancel();
        _layoutRecalibrationTimer = Timer(
          Duration(milliseconds: 1500 - elapsed.inMilliseconds),
          () {
            if (!mounted || _isDisposed) {
              return;
            }
            if (_pendingLayoutRecalibration) {
              _pendingLayoutRecalibration = false;
              _performLayoutRecalibration();
            }
          },
        );
        return;
      }
    }
    _lastRecalibrationAt = now;
    setState(() {
      _trackpadMoreAnchor = _trackpadMoreAnchorDefault;
      _trackpadMoreRepositioning = false;
      _cameraCenter = _applyInputCalibration(_pointerPosition);
    });
    _sendPointerEvent();
  }

  void _startAutoCalibration() {
    final margin = (_frameSize.shortestSide * 0.12).clamp(24.0, 96.0);
    final targets = [
      Offset(margin, margin),
      Offset(_frameSize.width - margin, margin),
      Offset(_frameSize.width - margin, _frameSize.height - margin),
      Offset(margin, _frameSize.height - margin),
    ];
    setState(() {
      _calibrationBackupScaleX = _inputScaleX;
      _calibrationBackupScaleY = _inputScaleY;
      _calibrationBackupOffsetX = _inputOffsetX;
      _calibrationBackupOffsetY = _inputOffsetY;
      _inputScaleX = 1;
      _inputScaleY = 1;
      _inputOffsetX = 0;
      _inputOffsetY = 0;
      _calibrationNormalized = true;
      _calibrationAspectRatio = _currentAspectRatio();
      _cameraCenter = _applyInputCalibration(_pointerPosition);
      _isAutoCalibrating = true;
      _calibrationStep = 0;
      _calibrationTargets = targets;
      _calibrationSamples.clear();
    });
    _sendPointerEvent();
  }

  void _cancelAutoCalibration() {
    if (!mounted) {
      return;
    }
    setState(() {
      _isAutoCalibrating = false;
      _calibrationStep = 0;
      _calibrationTargets = const [];
      _calibrationSamples.clear();
      if (_calibrationBackupScaleX != null &&
          _calibrationBackupScaleY != null &&
          _calibrationBackupOffsetX != null &&
          _calibrationBackupOffsetY != null) {
        _inputScaleX = _calibrationBackupScaleX!;
        _inputScaleY = _calibrationBackupScaleY!;
        _inputOffsetX = _calibrationBackupOffsetX!;
        _inputOffsetY = _calibrationBackupOffsetY!;
      }
      _cameraCenter = _applyInputCalibration(_pointerPosition);
      _calibrationBackupScaleX = null;
      _calibrationBackupScaleY = null;
      _calibrationBackupOffsetX = null;
      _calibrationBackupOffsetY = null;
    });
    _sendPointerEvent();
  }

  void _captureCalibrationPoint() {
    if (!_isAutoCalibrating || _calibrationTargets.isEmpty) {
      return;
    }
    _calibrationSamples.add(_pointerPosition);
    if (_calibrationSamples.length < _calibrationTargets.length) {
      setState(() {
        _calibrationStep =
            (_calibrationStep + 1).clamp(0, _calibrationTargets.length - 1);
      });
      return;
    }
    if (_calibrationSamples.length >= 2) {
      final result = _solveLinearCalibration(
        _calibrationSamples,
        _calibrationTargets,
      );
      final scaleX = result.scaleX;
      final scaleY = result.scaleY;
      final offsetX = result.offsetX;
      final offsetY = result.offsetY;
      setState(() {
        _inputScaleX = scaleX;
        _inputScaleY = scaleY;
        _inputOffsetX = offsetX;
        _inputOffsetY = offsetY;
        _calibrationNormalized = true;
        _calibrationAspectRatio = _currentAspectRatio();
        _cameraCenter = _applyInputCalibration(_pointerPosition);
        _calibrationBackupScaleX = null;
        _calibrationBackupScaleY = null;
        _calibrationBackupOffsetX = null;
        _calibrationBackupOffsetY = null;
      });
      unawaited(_persistCalibration());
    }
    _cancelAutoCalibration();
  }

  void _updateTrackpadMoreAnchorByDelta(Offset delta, Size areaSize) {
    final width =
        areaSize.width - _trackpadMoreButtonSize - _trackpadMoreButtonMargin * 2;
    final height =
        areaSize.height - _trackpadMoreButtonSize - _trackpadMoreButtonMargin * 2;
    if (width <= 0 || height <= 0) {
      return;
    }
    final nextDx =
        (_trackpadMoreAnchor.dx * width + delta.dx).clamp(0.0, width);
    final nextDy =
        (_trackpadMoreAnchor.dy * height + delta.dy).clamp(0.0, height);
    setState(() {
      _trackpadMoreAnchor = Offset(nextDx / width, nextDy / height);
    });
  }

  Future<void> _openTrackpadMoreSheet({required bool isInteractive}) async {
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 42,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '更多操作',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  '快速校准与定位触控板操作。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.center_focus_strong),
                  title: const Text('输入校准'),
                  subtitle: const Text('打开校准面板'),
                  enabled: isInteractive,
                  onTap: isInteractive
                      ? () {
                          Navigator.of(context).maybePop();
                          _openCalibrationSheet(isInteractive: true);
                        }
                      : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.auto_fix_high),
                  title: const Text('自动校准（四点）'),
                  enabled: isInteractive,
                  onTap: isInteractive
                      ? () {
                          Navigator.of(context).maybePop();
                          _startAutoCalibration();
                        }
                      : null,
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.tune),
                  title: Text(
                    _trackpadMoreRepositioning ? '完成定位按钮' : '拖动定位按钮',
                  ),
                  onTap: () {
                    Navigator.of(context).maybePop();
                    setState(() {
                      _trackpadMoreRepositioning = !_trackpadMoreRepositioning;
                    });
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.refresh),
                  title: const Text('重置按钮位置'),
                  onTap: () {
                    Navigator.of(context).maybePop();
                    setState(() {
                      _trackpadMoreAnchor = _trackpadMoreAnchorDefault;
                      _trackpadMoreRepositioning = false;
                    });
                  },
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTrackpadMoreButton({
    required Size areaSize,
    required bool isInteractive,
  }) {
    final width =
        areaSize.width - _trackpadMoreButtonSize - _trackpadMoreButtonMargin * 2;
    final height =
        areaSize.height - _trackpadMoreButtonSize - _trackpadMoreButtonMargin * 2;
    final safeWidth = width <= 0 ? 0.0 : width;
    final safeHeight = height <= 0 ? 0.0 : height;
    final anchor = _trackpadMoreAnchor;
    final left =
        _trackpadMoreButtonMargin + safeWidth * anchor.dx.clamp(0.0, 1.0);
    final top =
        _trackpadMoreButtonMargin + safeHeight * anchor.dy.clamp(0.0, 1.0);
    final isDragging = _trackpadMoreRepositioning;
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanUpdate: isDragging
            ? (details) => _updateTrackpadMoreAnchorByDelta(
                  details.delta,
                  areaSize,
                )
            : null,
        onTap: isInteractive
            ? () => _openTrackpadMoreSheet(isInteractive: isInteractive)
            : null,
        onLongPress: isInteractive
            ? () {
                setState(() {
                  _trackpadMoreRepositioning = !_trackpadMoreRepositioning;
                });
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isDragging
                ? const Color(0xFFF59E0B)
                : Colors.black.withAlpha(140),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDragging
                  ? const Color(0xFFFBBF24)
                  : Colors.white.withAlpha(40),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(60),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: SizedBox(
            width: _trackpadMoreButtonSize - 16,
            height: _trackpadMoreButtonSize - 16,
            child: Icon(
              isDragging ? Icons.open_with_rounded : Icons.more_horiz,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  _CalibrationResult _solveLinearCalibration(
    List<Offset> samples,
    List<Offset> targets,
  ) {
    final count = samples.length.clamp(2, targets.length);
    final width = _frameSize.width <= 0 ? 1.0 : _frameSize.width;
    final height = _frameSize.height <= 0 ? 1.0 : _frameSize.height;
    double sumSX = 0;
    double sumSY = 0;
    double sumTX = 0;
    double sumTY = 0;
    for (var i = 0; i < count; i += 1) {
      sumSX += samples[i].dx / width;
      sumSY += samples[i].dy / height;
      sumTX += targets[i].dx / width;
      sumTY += targets[i].dy / height;
    }
    final meanSX = sumSX / count;
    final meanSY = sumSY / count;
    final meanTX = sumTX / count;
    final meanTY = sumTY / count;

    double varSX = 0;
    double varSY = 0;
    double covX = 0;
    double covY = 0;
    for (var i = 0; i < count; i += 1) {
      final dx = samples[i].dx / width - meanSX;
      final dy = samples[i].dy / height - meanSY;
      varSX += dx * dx;
      varSY += dy * dy;
      covX += dx * (targets[i].dx / width - meanTX);
      covY += dy * (targets[i].dy / height - meanTY);
    }

    var scaleX = varSX.abs() < 0.0001 ? 1.0 : covX / varSX;
    var scaleY = varSY.abs() < 0.0001 ? 1.0 : covY / varSY;
    if (scaleX.isNaN || scaleX.isInfinite) {
      scaleX = 1;
    }
    if (scaleY.isNaN || scaleY.isInfinite) {
      scaleY = 1;
    }
    scaleX = scaleX.clamp(0.5, 2.0);
    scaleY = scaleY.clamp(0.5, 2.0);

    var offsetX = meanTX - scaleX * meanSX;
    var offsetY = meanTY - scaleY * meanSY;
    offsetX = offsetX.clamp(-0.5, 0.5);
    offsetY = offsetY.clamp(-0.5, 0.5);

    return _CalibrationResult(
      scaleX: scaleX,
      scaleY: scaleY,
      offsetX: offsetX,
      offsetY: offsetY,
    );
  }

  Widget _buildVncCanvas({
    required ThemeData theme,
    required bool isInteractive,
    required bool isLandscape,
    required EdgeInsets safePadding,
    required Size screenSize,
    bool isFullscreen = false,
    bool expandToFit = false,
    bool showControls = true,
  }) {
    final canvas = LayoutBuilder(
      builder: (context, constraints) {
        _devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final viewSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        _maybeHandleLayoutChange(viewSize, isLandscape);
        final previousViewSize = _lastViewSize;
        _lastViewSize = viewSize;
        if (_roiSession != null && _roiLastRequestAt == null) {
          _scheduleRoiRequest();
        }
        final viewDelta = (viewSize.width - previousViewSize.width).abs() +
            (viewSize.height - previousViewSize.height).abs();
        if (isInteractive && viewDelta > 6) {
          _autoSizedOnce = false;
          _requestStreamRefresh();
        }
        if (isInteractive) {
          _maybeAutoResizeStream();
        }
        final pointerScreen = _pointerToScreen(viewSize);
        final targetScreen =
            _isAutoCalibrating && _calibrationTargets.isNotEmpty
                ? _frameToScreen(
                    _calibrationTargets[_calibrationStep
                        .clamp(0, _calibrationTargets.length - 1)],
                    viewSize,
                  )
                : null;
        final translation = _calculateTranslation(viewSize);
        final scale = _baseScale(viewSize) * _zoom;
        final cursorImage = _cursorImage;
        final cursorSize = _cursorSize;
        final cursorHotspot = _cursorHotspot;
        final roiRenderer = _roiRenderer;
        final roiImages = _roiImages;
        final roiRevision = _roiRevision;
        final hasFrame = _frameImage != null;
        return ClipRRect(
          borderRadius: BorderRadius.circular(isFullscreen ? 0 : 18),
          child: Stack(
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFF0B1120),
                        Color(0xFF1E293B),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              ),
              if (hasFrame)
                Positioned.fill(
                  child: OverflowBox(
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    alignment: Alignment.topLeft,
                    child: Transform(
                      alignment: Alignment.topLeft,
                      transform: Matrix4.identity()
                        ..translateByDouble(
                          translation.dx,
                          translation.dy,
                          0,
                          1,
                        )
                        ..scaleByDouble(scale, scale, 1, 1),
                      child: SizedBox(
                        width: _frameSize.width,
                        height: _frameSize.height,
                        child: RawImage(
                          image: _frameImage,
                          fit: BoxFit.fill,
                          filterQuality: _zoom > 1.01
                              ? FilterQuality.none
                              : FilterQuality.medium,
                        ),
                      ),
                    ),
                  ),
                ),
              if (hasFrame && roiRenderer != null && roiImages.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RoiTilePainter(
                      tiles: roiImages,
                      renderer: roiRenderer,
                      translation: translation,
                      scale: scale,
                      revision: roiRevision,
                    ),
                  ),
                ),
              if (!hasFrame)
                Center(
                  child: Text(
                    'Waiting for frames...',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (isInteractive && _directInputEnabled)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      final framePos =
                          _screenToFrame(details.localPosition, viewSize);
                      _setPointerPosition(_removeInputCalibration(framePos));
                    },
                    onPanStart: (details) {
                      _directDragActive = true;
                      final framePos =
                          _screenToFrame(details.localPosition, viewSize);
                      _setPointerPosition(_removeInputCalibration(framePos));
                    },
                    onPanUpdate: (details) {
                      if (!_directDragActive) {
                        return;
                      }
                      final framePos =
                          _screenToFrame(details.localPosition, viewSize);
                      _setPointerPosition(_removeInputCalibration(framePos));
                    },
                    onPanEnd: (_) {
                      if (!_directDragActive) {
                        return;
                      }
                      _directDragActive = false;
                    },
                    onPanCancel: () {
                      if (!_directDragActive) {
                        return;
                      }
                      _directDragActive = false;
                    },
                  ),
                ),
              if (showControls && !isLandscape)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _VncShortcutOverlay(
                    enabled: isInteractive,
                    onEsc: () => _sendKeyPress(0xff1b),
                    onCmd: () => _sendKeyPress(0xffe7),
                    onTab: () => _sendKeyPress(0xff09),
                    onCtrl: () => _sendKeyPress(0xffe3),
                    onKeyboard: _showKeyboardInput,
                  ),
                ),
              if (showControls && (isLandscape || isFullscreen))
                Positioned(
                  right: 12 + safePadding.right,
                  bottom: 12 + safePadding.bottom,
                  child: Tooltip(
                    message: 'Controls',
                    child: FloatingActionButton.small(
                      heroTag: 'vncControlsFab-${widget.session.id}',
                      onPressed: () => _openLandscapeControls(
                        isInteractive: isInteractive,
                      ),
                      backgroundColor: isInteractive
                          ? Colors.black.withAlpha(170)
                          : Colors.black.withAlpha(100),
                      foregroundColor: Colors.white,
                      child: Icon(
                        _controlsSheetOpen ? Icons.close : Icons.tune,
                      ),
                    ),
                  ),
                ),
              if (showControls)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _VncOverlayIconButton(
                    icon: _isFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    label: _isFullscreen ? 'Exit' : 'Full',
                    onPressed: () => _setFullscreen(!_isFullscreen),
                  ),
                ),
              if (showControls)
                Positioned(
                  right: 12,
                  top: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _VncStatsBadge(
                        latencyMs: _streamLatencyMs,
                        fps: _streamFps,
                      ),
                      const SizedBox(height: 6),
                      _VncZoomBadge(value: _zoom),
                    ],
                  ),
                ),
              if (!isInteractive)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withAlpha(80),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _connectionError != null
                                  ? 'Stream unavailable'
                                  : 'Connecting...',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_connectionError != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                _connectionError!,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (isFullscreen) ...[
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: _isConnecting ? null : _startStream,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry stream'),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_isAutoCalibrating && targetScreen != null)
                Positioned(
                  left: targetScreen.dx - 18,
                  top: targetScreen.dy - 18,
                  child: const _CalibrationTarget(),
                ),
              if (_isAutoCalibrating)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 56,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(160),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withAlpha(40)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '自动校准 ${_calibrationStep + 1}/${_calibrationTargets.length}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '依次对准四个角标记，然后点“记录当前点”。',
                          style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            TextButton(
                              onPressed: _cancelAutoCalibration,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white70,
                              ),
                              child: const Text('取消'),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: _captureCalibrationPoint,
                              child: Text(
                                _calibrationStep + 1 >=
                                        _calibrationTargets.length
                                    ? '完成'
                                    : '记录当前点',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              Positioned(
                left: 12 + safePadding.left,
                bottom: 12 + safePadding.bottom,
                child: _buildVncDebugPanel(theme: theme),
              ),
              if (cursorImage != null &&
                  scale > 0 &&
                  cursorSize.width > 0 &&
                  cursorSize.height > 0)
                Positioned(
                  left: pointerScreen.dx - cursorHotspot.dx * scale,
                  top: pointerScreen.dy - cursorHotspot.dy * scale,
                  child: IgnorePointer(
                    child: SizedBox(
                      width: cursorSize.width * scale,
                      height: cursorSize.height * scale,
                      child: RawImage(
                        image: cursorImage,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.none,
                      ),
                    ),
                  ),
                ),
              if (isInteractive && (_showLocalCursor || _isAutoCalibrating))
                Positioned(
                  left: pointerScreen.dx - 10,
                  top: pointerScreen.dy - 10,
                  child: _VncPointer(
                    isClicking: _showClickPulse,
                    isFocusing: _showFocusPulse,
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (expandToFit) {
      return SizedBox.expand(child: canvas);
    }
    return AspectRatio(
      aspectRatio: _viewAspectRatio(screenSize),
      child: canvas,
    );
  }

  Widget _buildVncDebugPanel({required ThemeData theme}) {
    final vncStatus = _connectionError != null
        ? '错误'
        : _isConnecting
            ? '连接中'
            : '已连接';
    final vncSessionId = _lastVncSessionInfo?.sessionId ?? '-';
    final frameLabel = _frameSize.width <= 0 || _frameSize.height <= 0
        ? '-'
        : '${_frameSize.width.toInt()}x${_frameSize.height.toInt()}';
    final viewLabel = _lastViewSize.width <= 0 || _lastViewSize.height <= 0
        ? '-'
        : '${_lastViewSize.width.toInt()}x${_lastViewSize.height.toInt()}';
    final fpsLabel = _streamFps > 0 ? _streamFps.toStringAsFixed(1) : '-';
    final latencyLabel = _streamLatencyMs?.toString() ?? '-';
    final encodingLabel = _encodingPreference.name;
    final roiStatus = _roiStatusLabel();
    final roiHost = _roiHost ?? '-';
    final roiPortValue = _roiSession?.quicPort ?? 0;
    final roiPortLabel = roiPortValue > 0 ? roiPortValue.toString() : '未知';
    final roiLastTileLabel = _formatSince(_roiLastTileAt);
    final roiLastRequestLabel = _formatSince(_roiLastRequestAt);
    final roiTileLabel = _roiTileCount == 0
        ? '-'
        : '${_roiTileCount} (${_formatBytes(_roiTileBytes)})';
    final roiCacheLabel = _roiImages.isEmpty ? '-' : '${_roiImages.length}';
    final roiErrorLabel =
        _roiLastError == null || _roiLastError!.isEmpty ? '-' : _roiLastError!;

    const panelWidth = 300.0;
    final background = Colors.black.withAlpha(165);
    final borderColor = Colors.white.withAlpha(50);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: Colors.white70,
      fontWeight: FontWeight.w600,
    );
    final valueStyle = theme.textTheme.bodySmall?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _debugPanelOpen
          ? ConstrainedBox(
              key: const ValueKey('debug-open'),
              constraints: const BoxConstraints(maxWidth: panelWidth),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'VNC 调试',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _debugPanelOpen = false;
                            });
                          },
                          icon: const Icon(
                            Icons.expand_more,
                            color: Colors.white70,
                          ),
                          tooltip: 'Collapse',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _VncDebugRow(
                      label: 'VNC 状态',
                      value: vncStatus,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'VNC 会话',
                      value: vncSessionId,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '帧尺寸',
                      value: frameLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '视图尺寸',
                      value: viewLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '缩放',
                      value: _zoom.toStringAsFixed(2),
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'FPS/延迟',
                      value: '$fpsLabel fps / ${latencyLabel}ms',
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '编码',
                      value: encodingLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    const SizedBox(height: 6),
                    Divider(color: Colors.white.withAlpha(30), height: 12),
                    _VncDebugRow(
                      label: 'ROI 状态',
                      value: roiStatus,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI Host',
                      value: roiHost,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 端口',
                      value: roiPortLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 最近帧',
                      value: roiLastTileLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 最近请求',
                      value: roiLastRequestLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI Tiles',
                      value: roiTileLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 缓存',
                      value: roiCacheLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 错误',
                      value: roiErrorLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                  ],
                ),
              ),
            )
          : GestureDetector(
              key: const ValueKey('debug-closed'),
              onTap: () {
                setState(() {
                  _debugPanelOpen = true;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.bug_report,
                      size: 14,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '调试',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'VNC:$vncStatus',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'ROI:$roiStatus',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.expand_more,
                      size: 14,
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildFullscreenInputPanel({
    required bool isInteractive,
    required bool isLandscape,
  }) {
    final trackpadEnabled = isInteractive && !_directInputEnabled;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final zoomOpacity = isLandscape ? 0.38 : 1.0;
        final trackpadOpacity = isLandscape ? 0.18 : 1.0;
        final zoomWidth = isLandscape ? 48.0 : 60.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Opacity(
              opacity: zoomOpacity,
              child: SizedBox(
                width: zoomWidth,
                child: _VncZoomBar(
                  value: _zoom,
                  min: _zoomMin,
                  max: _zoomMax,
                  enabled: isInteractive,
                  glassStyle: isLandscape,
                  onValueChanged: _updateZoomValue,
                  onValueCommitted: _commitZoomValue,
                  onReset: _resetZoom,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Opacity(
                opacity: trackpadOpacity,
                child: LayoutBuilder(
                  builder: (context, _) {
                    final surface = _VncTrackpadSurface(
                      enabled: trackpadEnabled,
                      glassStyle: isLandscape,
                      height: height,
                      showLabel: !isLandscape,
                      disabledMessage:
                          _directInputEnabled ? 'Direct touch enabled' : null,
                      onPointerDown: _handleTrackpadPointerDown,
                      onPointerMove: _handleTrackpadPointerMove,
                      onPointerUp: _handleTrackpadPointerUp,
                      onPointerCancel: _handleTrackpadPointerCancel,
                    );
                    final trackpadColumn = Column(
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, surfaceConstraints) {
                              final trackpadSize = Size(
                                surfaceConstraints.maxWidth,
                                surfaceConstraints.maxHeight,
                              );
                              _updateTrackpadSize(
                                trackpadSize,
                                source: isLandscape
                                    ? 'fullscreen_landscape'
                                    : 'fullscreen_portrait',
                              );
                              if (isLandscape) {
                                return surface;
                              }
                              return Stack(
                                children: [
                                  Positioned.fill(child: surface),
                                  _buildTrackpadMoreButton(
                                    areaSize: trackpadSize,
                                    isInteractive: isInteractive,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildTrackpadClickBar(
                          enabled: trackpadEnabled,
                          glassStyle: isLandscape,
                        ),
                      ],
                    );
                    return trackpadColumn;
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFullscreenPortrait({
    required ThemeData theme,
    required bool isInteractive,
    required EdgeInsets safePadding,
    required Size screenSize,
  }) {
    final safeWidth = screenSize.width - safePadding.left - safePadding.right;
    final safeHeight = screenSize.height - safePadding.top - safePadding.bottom;
    final aspect = _frameSize.height == 0
        ? 1.0
        : _frameSize.width / _frameSize.height;
    final minControlsHeight = 240.0;
    final maxViewHeight = safeHeight - minControlsHeight;
    final rawViewHeight =
        aspect <= 0 ? safeHeight * 0.6 : safeWidth / aspect;
    final viewHeight = maxViewHeight > 0
        ? (rawViewHeight <= maxViewHeight ? rawViewHeight : maxViewHeight)
        : safeHeight * 0.6;
    return Column(
      children: [
        Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: safeWidth,
                height: viewHeight,
                child: _buildVncCanvas(
                  theme: theme,
                  isInteractive: isInteractive,
                  isLandscape: false,
                  safePadding: EdgeInsets.zero,
                  screenSize: screenSize,
                  isFullscreen: true,
                  expandToFit: true,
                  showControls: false,
                ),
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: _VncOverlayIconButton(
                icon: Icons.fullscreen_exit,
                label: 'Exit',
                onPressed: () => _setFullscreen(false),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: _buildFullscreenInputPanel(
              isInteractive: isInteractive,
              isLandscape: false,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFullscreenLandscape({
    required ThemeData theme,
    required bool isInteractive,
    required EdgeInsets safePadding,
    required Size screenSize,
  }) {
    final trackpadEnabled = isInteractive && !_directInputEnabled;
    final overlayOpacity = isInteractive ? 0.8 : 0.5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final areaSize = Size(constraints.maxWidth, constraints.maxHeight);
        final zoomHeight =
            (constraints.maxHeight - 140).clamp(220.0, 360.0);
        _updateTrackpadSize(
          areaSize,
          source: 'fullscreen_landscape_overlay',
        );
        return Stack(
          children: [
            Positioned.fill(
              child: _buildVncCanvas(
                theme: theme,
                isInteractive: isInteractive,
                isLandscape: true,
                safePadding: EdgeInsets.zero,
                screenSize: screenSize,
                isFullscreen: true,
                expandToFit: true,
                showControls: false,
              ),
            ),
            if (trackpadEnabled)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onDoubleTap: () {
                    _lastGestureDoubleTapAt = DateTime.now();
                    _sendClick(1);
                  },
                  onSecondaryTap: () => _sendClick(2),
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _handleTrackpadPointerDown,
                    onPointerMove: _handleTrackpadPointerMove,
                    onPointerUp: _handleTrackpadPointerUp,
                    onPointerCancel: _handleTrackpadPointerCancel,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            Positioned(
              left: 12 + safePadding.left,
              top: 12 + safePadding.top,
              child: _VncOverlayIconButton(
                icon: Icons.fullscreen_exit,
                label: 'Exit',
                onPressed: () => _setFullscreen(false),
              ),
            ),
            Positioned(
              left: 12 + safePadding.left,
              top: 60 + safePadding.top,
              child: Opacity(
                opacity: overlayOpacity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(120),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withAlpha(60)),
                  ),
                  child: SizedBox(
                    width: 52,
                    height: zoomHeight,
                    child: _VncZoomBar(
                      value: _zoom,
                      min: _zoomMin,
                      max: _zoomMax,
                      enabled: isInteractive,
                      glassStyle: true,
                      onValueChanged: _updateZoomValue,
                      onValueCommitted: _commitZoomValue,
                      onReset: _resetZoom,
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16 + safePadding.left,
                    right: 16 + safePadding.right,
                    bottom: 12 + safePadding.bottom,
                  ),
                  child: Opacity(
                    opacity: overlayOpacity,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(110),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: Colors.white.withAlpha(60)),
                        ),
                        child: _buildTrackpadClickBar(
                          enabled: trackpadEnabled,
                          glassStyle: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTrackpadControls({
    required bool isInteractive,
    bool showCalibrationAction = true,
    bool glassStyle = false,
  }) {
    final trackpadEnabled = isInteractive && !_directInputEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '输入模式',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 6),
        ToggleButtons(
          isSelected: [_directInputEnabled == false, _directInputEnabled == true],
          onPressed: isInteractive
              ? (index) {
                  setState(() {
                    _directInputEnabled = index == 1;
                  });
                }
              : null,
          borderRadius: BorderRadius.circular(12),
          constraints: const BoxConstraints(minWidth: 96, minHeight: 36),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('触控板'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('直接触摸'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_directInputEnabled)
          Text(
            '提示：直接在 VNC 画面上滑动移动光标（不触发点击）。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF94A3B8),
                ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 52,
                child: _VncZoomBar(
                  value: _zoom,
                  min: _zoomMin,
                  max: _zoomMax,
                  enabled: isInteractive,
                  glassStyle: glassStyle,
                  onValueChanged: _updateZoomValue,
                  onValueCommitted: _commitZoomValue,
                  onReset: _resetZoom,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, surfaceConstraints) {
                          final trackpadSize = Size(
                            surfaceConstraints.maxWidth,
                            surfaceConstraints.maxHeight,
                          );
                          _updateTrackpadSize(
                            trackpadSize,
                            source: glassStyle ? 'trackpad_glass' : 'trackpad',
                          );
                          return _VncTrackpadSurface(
                            enabled: trackpadEnabled,
                            glassStyle: glassStyle,
                            disabledMessage: _directInputEnabled
                                ? 'Direct touch enabled'
                                : null,
                            onPointerDown: _handleTrackpadPointerDown,
                            onPointerMove: _handleTrackpadPointerMove,
                            onPointerUp: _handleTrackpadPointerUp,
                            onPointerCancel: _handleTrackpadPointerCancel,
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildTrackpadClickBar(
                      enabled: trackpadEnabled,
                      glassStyle: glassStyle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildGestureHints(glassStyle: glassStyle),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          title: const Text('显示本地光标'),
          subtitle: const Text('关闭后仅移动远端光标'),
          value: _showLocalCursor,
          onChanged: isInteractive
              ? (value) {
                  setState(() {
                    _showLocalCursor = value;
                  });
                  unawaited(_persistLocalCursorPreference(value));
                }
              : null,
        ),
        if (kDebugMode) ...[
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            title: const Text('光标调试日志'),
            subtitle: const Text('记录光标轨迹/坐标，便于排查偏移'),
            value: _cursorDebugEnabled,
            onChanged: isInteractive
                ? (value) {
                    setState(() {
                      _cursorDebugEnabled = value;
                    });
                    if (!value) {
                      _clearCursorDebugLog();
                    } else {
                      _logCursorDebug('debug_enabled', {
                        'enabled': true,
                      }, force: true);
                    }
                  }
                : null,
          ),
          if (_cursorDebugEnabled)
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _copyCursorDebugLog,
                  icon: const Icon(Icons.copy),
                  label: Text('复制日志 (${_cursorDebugLog.length})'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _clearCursorDebugLog();
                    });
                  },
                  child: const Text('清空'),
                ),
              ],
            ),
        ],
        const SizedBox(height: 12),
        Text(
          '视图模式',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: glassStyle ? Colors.white70 : const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 6),
        ToggleButtons(
          isSelected: [
            _viewMode == VncViewMode.fit,
            _viewMode == VncViewMode.fill,
            _viewMode == VncViewMode.original,
          ],
          onPressed: isInteractive
              ? (index) {
                  setState(() {
                    _viewMode = VncViewMode.values[index];
                    _autoSizedOnce = false;
                  });
                  if (_cursorDebugEnabled) {
                    _logCursorDebug(
                      'view_mode',
                      {'mode': _viewMode.name},
                      force: true,
                    );
                  }
                  _requestStreamRefresh(resetAutoResize: true);
                }
              : null,
          borderRadius: BorderRadius.circular(12),
          constraints: const BoxConstraints(minWidth: 84, minHeight: 36),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('适配'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('填满'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('原始'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Theme(
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
          ),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            title: Text(
              '高级选项',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: glassStyle ? Colors.white70 : const Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '编码与质量 / 压缩',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: glassStyle ? Colors.white54 : const Color(0xFF94A3B8),
                  ),
            ),
            children: [
              const SizedBox(height: 6),
              Text(
                '编码与质量',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          glassStyle ? Colors.white70 : const Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 6),
              SwitchListTile.adaptive(
                title: const Text('低延迟模式'),
                subtitle: const Text('优先响应，可能降低画质'),
                value: _lowLatencyEnabled,
                onChanged: isInteractive ? _setLowLatencyMode : null,
              ),
              SwitchListTile.adaptive(
                title: const Text('高性能模式'),
                subtitle: Text('空闲时也每 ${_highPerfIntervalMs}ms 推送一帧'),
                value: _highPerfEnabled,
                onChanged: isInteractive ? _setHighPerfMode : null,
              ),
              if (_highPerfEnabled)
                _CalibrationSlider(
                  label: '高性能采样间隔 (${_highPerfIntervalMs}ms)',
                  value: _highPerfIntervalMs.toDouble(),
                  min: 10,
                  max: 100,
                  divisions: 9,
                  enabled: isInteractive,
                  labelColor: glassStyle ? Colors.white70 : null,
                  onChanged: (value) {
                    setState(() {
                      _highPerfIntervalMs = value.round().clamp(10, 100);
                    });
                  },
                  onChangeEnd: (value) {
                    if (!isInteractive || !_highPerfEnabled) {
                      return;
                    }
                    final next = value.round().clamp(10, 100);
                    if (next != _highPerfIntervalMs) {
                      setState(() {
                        _highPerfIntervalMs = next;
                      });
                    }
                    unawaited(_startStream(preserveExisting: true));
                  },
                ),
              SwitchListTile.adaptive(
                title: const Text('省流模式'),
                subtitle: const Text('空闲时降低同步频率'),
                value: _dataSaverEnabled,
                onChanged: isInteractive ? _setDataSaverMode : null,
              ),
              SwitchListTile.adaptive(
                title: const Text('16-bit 色深'),
                subtitle: const Text('减少带宽，颜色更少'),
                value: _colorDepth == VncColorDepth.depth16,
                onChanged: isInteractive
                    ? (value) {
                        setState(() {
                          _colorDepth = value
                              ? VncColorDepth.depth16
                              : VncColorDepth.full;
                          if (value) {
                            _tightJpegEnabled = false;
                            _encodingPreference = VncEncodingPreference.zlib;
                          }
                        });
                        _applyEncodingPreferences();
                        _applyPixelFormatPreference();
                        _requestStreamRefresh(resetAutoResize: true);
                      }
                    : null,
              ),
              DropdownButtonFormField<VncEncodingPreference>(
                value: _encodingPreference,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: VncEncodingPreference.zrle,
                    child: Text('ZRLE（默认）'),
                  ),
                  DropdownMenuItem(
                    value: VncEncodingPreference.tight,
                    child: Text('Tight（可调压缩）'),
                  ),
                  DropdownMenuItem(
                    value: VncEncodingPreference.zlib,
                    child: Text('Zlib（兼容）'),
                  ),
                  DropdownMenuItem(
                    value: VncEncodingPreference.raw,
                    child: Text('Raw（无压缩）'),
                  ),
                ],
                onChanged: isInteractive && !_lowLatencyEnabled
                    ? (value) {
                        if (value == null) {
                          return;
                        }
                        setState(() {
                          _encodingPreference = value;
                        });
                        _applyEncodingPreferences();
                      }
                    : null,
              ),
              const SizedBox(height: 8),
              _CalibrationSlider(
                label: '压缩级别 (${_tightCompressionLevel})',
                value: _tightCompressionLevel.toDouble(),
                min: 0,
                max: 9,
                enabled: isInteractive && !_lowLatencyEnabled,
                labelColor: glassStyle ? Colors.white70 : null,
                onChanged: (value) {
                  setState(() {
                    _tightCompressionLevel = value.round().clamp(0, 9);
                  });
                  _applyEncodingPreferences();
                },
              ),
              if (_encodingPreference == VncEncodingPreference.tight) ...[
                SwitchListTile.adaptive(
                  title: const Text('JPEG 低带宽'),
                  subtitle: const Text('开启后画质会有损'),
                  value: _tightJpegEnabled,
                  onChanged: isInteractive
                      ? (value) {
                          setState(() {
                            _tightJpegEnabled = value;
                          });
                          _applyEncodingPreferences();
                        }
                      : null,
                ),
                if (_tightJpegEnabled)
                  _CalibrationSlider(
                    label: 'JPEG 质量 (${_tightQualityLevel})',
                    value: _tightQualityLevel.toDouble(),
                    min: 0,
                    max: 9,
                    enabled: isInteractive,
                    labelColor: glassStyle ? Colors.white70 : null,
                    onChanged: (value) {
                      setState(() {
                        _tightQualityLevel = value.round().clamp(0, 9);
                      });
                      _applyEncodingPreferences();
                    },
                  ),
              ],
            ],
          ),
        ),
        if (showCalibrationAction) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () =>
                  _openCalibrationSheet(isInteractive: isInteractive),
              icon: const Icon(Icons.tune),
              label: const Text('校准触控坐标'),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed:
                  isInteractive ? () => unawaited(_resetCalibration()) : null,
              icon: const Icon(Icons.restart_alt),
              label: const Text('重置校准'),
            ),
          ),
          if (_availableDisplays.length > 1) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _openDisplayPicker,
                icon: const Icon(Icons.monitor),
                label: const Text('选择显示器'),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildGestureHints({bool glassStyle = false}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _VncGestureHint(
          icon: Icons.open_with,
          label: 'Move',
          glassStyle: glassStyle,
        ),
        _VncGestureHint(
          icon: Icons.ads_click,
          label: 'Double tap = Left click',
          glassStyle: glassStyle,
        ),
        _VncGestureHint(
          icon: Icons.mouse,
          label: 'Use buttons to click',
          glassStyle: glassStyle,
        ),
        _VncGestureHint(
          icon: Icons.track_changes,
          label: 'System 2/3-finger gestures',
          glassStyle: glassStyle,
        ),
      ],
    );
  }

  Widget _buildTrackpadClickBar({
    required bool enabled,
    bool glassStyle = false,
  }) {
    final borderColor =
        glassStyle ? Colors.white.withAlpha(60) : const Color(0xFFE2E8F0);
    final background =
        glassStyle ? Colors.white.withAlpha(18) : Colors.white;
    final textColor = glassStyle ? Colors.white : const Color(0xFF0F172A);
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
        boxShadow: glassStyle
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withAlpha(12),
                  blurRadius: 10,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: enabled ? () => _sendClick(1) : null,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(12),
              ),
              child: Center(
                child: Text(
                  '左键',
                  style: TextStyle(
                    color: enabled ? textColor : textColor.withAlpha(120),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          Container(width: 1, color: borderColor),
          Expanded(
            child: InkWell(
              onTap: enabled ? () => _sendClick(2) : null,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(12),
              ),
              child: Center(
                child: Text(
                  '右键',
                  style: TextStyle(
                    color: enabled ? textColor : textColor.withAlpha(120),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openLandscapeControls({required bool isInteractive}) async {
    if (_controlsSheetOpen) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _controlsSheetOpen = true;
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  color: Colors.black.withAlpha(140),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 42,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white.withAlpha(160),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Text(
                                'Controls',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                              ),
                              const Spacer(),
                              if (_isFullscreen)
                                TextButton.icon(
                                  onPressed: () => _setFullscreen(false),
                                  icon: const Icon(Icons.fullscreen_exit),
                                  label: const Text('Exit'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              IconButton(
                                onPressed: () => Navigator.of(context).maybePop(),
                                icon: const Icon(Icons.close, color: Colors.white),
                                tooltip: 'Close',
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _VncControlAction(
                                icon: Icons.keyboard,
                                label: 'Keyboard',
                                onPressed:
                                    isInteractive ? _showKeyboardInput : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.close,
                                label: 'Esc',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xff1b)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.keyboard_command_key,
                                label: 'Cmd',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xffe7)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.keyboard_tab,
                                label: 'Tab',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xff09)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.keyboard_control_key,
                                label: 'Ctrl',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xffe3)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.zoom_out_map,
                                label: 'Reset zoom',
                                onPressed: isInteractive ? _resetZoom : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.monitor,
                                label: '显示器',
                                onPressed: _availableDisplays.length > 1
                                    ? _openDisplayPicker
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.tune,
                                label: '校准',
                                onPressed: () => _openCalibrationSheet(
                                  isInteractive: isInteractive,
                                ),
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.restart_alt,
                                label: '重置校准',
                                onPressed: () =>
                                    unawaited(_resetCalibration()),
                                glassStyle: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildTrackpadControls(
                            isInteractive: isInteractive,
                            showCalibrationAction: false,
                            glassStyle: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _controlsSheetOpen = false;
    });
  }

  Future<void> _openCalibrationSheet({required bool isInteractive}) async {
    if (!mounted) {
      return;
    }
    const maxOffsetNorm = 0.2;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              void updateState(VoidCallback fn) {
                if (mounted) {
                  setState(() {
                    fn();
                    _calibrationNormalized = true;
                    _calibrationAspectRatio = _currentAspectRatio();
                    _cameraCenter = _applyInputCalibration(_pointerPosition);
                  });
                  setSheetState(() {});
                  _scheduleCalibrationSave();
                  _sendPointerEvent();
                }
              }

              return SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    12,
                    20,
                    16 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE2E8F0),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '输入校准',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF0F172A),
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '调节缩放与偏移，让触摸板光标与远端光标对齐。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF64748B),
                            ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: isInteractive
                            ? () {
                                Navigator.of(context).maybePop();
                                _startAutoCalibration();
                              }
                            : null,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('自动校准（四点）'),
                      ),
                      const SizedBox(height: 16),
                      _CalibrationSlider(
                        label: 'X 缩放',
                        value: _inputScaleX,
                        min: 0.7,
                        max: 1.3,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputScaleX = value),
                      ),
                      _CalibrationSlider(
                        label: 'Y 缩放',
                        value: _inputScaleY,
                        min: 0.7,
                        max: 1.3,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputScaleY = value),
                      ),
                      _CalibrationSlider(
                        label:
                            'X 偏移 (${(_inputOffsetX * _frameSize.width).round()}px)',
                        value: _inputOffsetX,
                        min: -maxOffsetNorm,
                        max: maxOffsetNorm,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputOffsetX = value),
                      ),
                      _CalibrationSlider(
                        label:
                            'Y 偏移 (${(_inputOffsetY * _frameSize.height).round()}px)',
                        value: _inputOffsetY,
                        min: -maxOffsetNorm,
                        max: maxOffsetNorm,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputOffsetY = value),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('完成'),
                          ),
                          const Spacer(),
                          OutlinedButton.icon(
                            onPressed: isInteractive
                                ? () {
                                    _resetCalibration();
                                    setSheetState(() {});
                                  }
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重置'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _openDisplayPicker() async {
    if (!mounted) {
      return;
    }
    if (_availableDisplays.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择显示器',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                      ),
                ),
                const SizedBox(height: 12),
                ..._availableDisplays.map((display) {
                  final isSelected = _selectedDisplayIndex == display.index;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(display.label),
                    trailing:
                        isSelected ? const Icon(Icons.check) : const SizedBox(),
                    onTap: () async {
                      setState(() {
                        _selectedDisplayIndex = display.index;
                      });
                      final navigator = Navigator.of(context);
                      await _persistDisplaySelection(display.index);
                      await _loadCalibration();
                      if (!mounted) {
                        return;
                      }
                      navigator.maybePop();
                      unawaited(_startStream());
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final safePadding = MediaQuery.of(context).padding;
    final screenSize = MediaQuery.of(context).size;
    final target = widget.event.payload['target']?.toString();
    final targetLabel =
        target == null || target.trim().isEmpty ? 'Remote desktop' : target;
    final statusText = _connectionError != null
        ? 'Stream offline'
        : _isConnecting
            ? 'Connecting'
            : 'Streaming';
    final statusColor = _connectionError != null
        ? const Color(0xFFFEE2E2)
        : _isConnecting
            ? const Color(0xFFFEF3C7)
            : const Color(0xFFDCFCE7);
    final statusTextColor = _connectionError != null
        ? const Color(0xFF991B1B)
        : _isConnecting
            ? const Color(0xFF92400E)
            : const Color(0xFF166534);
    final isInteractive =
        _connectionError == null && !_isConnecting && _vncClient != null;
    final displayLabel = _selectedDisplayIndex == null
        ? null
        : _availableDisplays
            .firstWhere(
              (display) => display.index == _selectedDisplayIndex,
              orElse: () => VncDisplayInfo(
                index: _selectedDisplayIndex ?? 0,
                width: _frameSize.width.toInt(),
                height: _frameSize.height.toInt(),
                isPrimary: false,
              ),
            )
            .label;

    if (_isFullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: isLandscape
              ? _buildFullscreenLandscape(
                  theme: theme,
                  isInteractive: isInteractive,
                  safePadding: safePadding,
                  screenSize: screenSize,
                )
              : _buildFullscreenPortrait(
                  theme: theme,
                  isInteractive: isInteractive,
                  safePadding: safePadding,
                  screenSize: screenSize,
                ),
        ),
      );
    }

    return _TimelineDetailScaffold(
      title: 'VNC Viewer',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: GestureDetector(
                onVerticalDragUpdate: _handleSwipeUpdate,
                onVerticalDragEnd: _handleSwipeEnd,
                child: Column(
                  children: [
                    Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: const Color(0xFFE2E8F0),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Swipe down to exit',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF94A3B8),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              widget.session.label,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Requested ${_formatTimestamp(widget.event.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          statusText,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: statusTextColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _resolutionLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _KeyValueRow(label: 'Target', value: targetLabel),
                  if (displayLabel != null)
                    _KeyValueRow(label: 'Display', value: displayLabel),
                  _KeyValueRow(
                    label: 'Last update',
                    value: _formatTimestamp(_lastUpdatedAt),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (_connectionError != null) ...[
              _VncRecoveryCard(
                message: _connectionError!,
                onRetry: _startStream,
              ),
              const SizedBox(height: 16),
            ] else if (_isConnecting) ...[
              _InlineStatus(
                message: 'Connecting to the VNC stream...',
              ),
              const SizedBox(height: 16),
            ],
            _ContextSectionCard(
              title: 'VNC view',
              subtitle: isLandscape
                  ? 'Landscape stream with hidden controls. Tap the floating button to open trackpad and zoom.'
                  : 'Portrait stream with vertical zoom and a full-width trackpad.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildVncCanvas(
                    theme: theme,
                    isInteractive: isInteractive,
                    isLandscape: isLandscape,
                    safePadding: safePadding,
                    screenSize: screenSize,
                    isFullscreen: false,
                  ),
                  if (!isLandscape) ...[
                    const SizedBox(height: 12),
                    _buildTrackpadControls(isInteractive: isInteractive),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VncRecoveryCard extends StatelessWidget {
  const _VncRecoveryCard({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDA4AF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Color(0xFFBE123C),
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Stream unavailable',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF9F1239),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF9F1239),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry stream'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VncPointer extends StatelessWidget {
  const _VncPointer({
    required this.isClicking,
    required this.isFocusing,
  });

  final bool isClicking;
  final bool isFocusing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedOpacity(
          opacity: isClicking ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withAlpha(180),
                width: 2,
              ),
            ),
          ),
        ),
        AnimatedOpacity(
          opacity: isFocusing ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withAlpha(120),
                width: 1.5,
              ),
            ),
          ),
        ),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF0F172A), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 6,
                offset: const Offset(0, 4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VncZoomBadge extends StatelessWidget {
  const _VncZoomBadge({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${(value * 100).round()}%',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _VncStatsBadge extends StatelessWidget {
  const _VncStatsBadge({
    required this.latencyMs,
    required this.fps,
  });

  final int? latencyMs;
  final double fps;

  Color _latencyColor() {
    final value = latencyMs;
    if (value == null) {
      return Colors.white70;
    }
    if (value > 50) {
      return Colors.redAccent;
    }
    if (value > 20) {
      return const Color(0xFFFBBF24);
    }
    return Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final fpsValue = fps.isFinite ? fps : 0;
    final fpsLabel = fpsValue <= 0
        ? '--'
        : fpsValue >= 10
            ? fpsValue.toStringAsFixed(0)
            : fpsValue.toStringAsFixed(1);
    final latencyLabel =
        latencyMs == null ? '--' : '${latencyMs!.clamp(0, 9999)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Latency ',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              Text(
                '$latencyLabel ms',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _latencyColor(),
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$fpsLabel fps',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _VncDebugRow extends StatelessWidget {
  const _VncDebugRow({
    required this.label,
    required this.value,
    this.labelStyle,
    this.valueStyle,
  });

  final String label;
  final String value;
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final baseLabelStyle = labelStyle ??
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            );
    final baseValueStyle = valueStyle ??
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: baseLabelStyle,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: baseValueStyle,
            ),
          ),
        ],
      ),
    );
  }
}

class _VncOverlayIconButton extends StatelessWidget {
  const _VncOverlayIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withAlpha(140),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CalibrationTarget extends StatelessWidget {
  const _CalibrationTarget();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
          Container(
            width: 36,
            height: 2,
            color: Colors.white.withAlpha(200),
          ),
          Container(
            width: 2,
            height: 36,
            color: Colors.white.withAlpha(200),
          ),
        ],
      ),
    );
  }
}

class _CalibrationResult {
  const _CalibrationResult({
    required this.scaleX,
    required this.scaleY,
    required this.offsetX,
    required this.offsetY,
  });

  final double scaleX;
  final double scaleY;
  final double offsetX;
  final double offsetY;
}

class _CalibrationSlider extends StatelessWidget {
  const _CalibrationSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    this.labelColor,
    this.divisions,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final Color? labelColor;
  final int? divisions;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
                  color: labelColor ?? const Color(0xFF0F172A),
                  fontWeight: FontWeight.w600,
                ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled ? onChangeEnd : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _VncZoomBar extends StatefulWidget {
  const _VncZoomBar({
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    this.glassStyle = false,
    required this.onValueChanged,
    required this.onValueCommitted,
    required this.onReset,
  });

  final double value;
  final double min;
  final double max;
  final bool enabled;
  final bool glassStyle;
  final ValueChanged<double> onValueChanged;
  final ValueChanged<double> onValueCommitted;
  final VoidCallback onReset;

  @override
  State<_VncZoomBar> createState() => _VncZoomBarState();
}

class _VncZoomBarState extends State<_VncZoomBar> {
  late double _lastValue;

  @override
  void initState() {
    super.initState();
    _lastValue = widget.value;
  }

  @override
  void didUpdateWidget(covariant _VncZoomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lastValue = widget.value;
  }

  double _valueForPosition(double localY, double height) {
    if (height <= 0) {
      return widget.value;
    }
    final trackTop = 20.0;
    final trackBottom = height - 20.0;
    final clamped = localY.clamp(trackTop, trackBottom);
    final t = 1 - ((clamped - trackTop) / (trackBottom - trackTop));
    final next = widget.min + (widget.max - widget.min) * t;
    return next.clamp(widget.min, widget.max);
  }

  void _setValue(double value) {
    _lastValue = value;
    widget.onValueChanged(value);
  }

  void _commitValue([double? value]) {
    widget.onValueCommitted(value ?? _lastValue);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final trackTop = 20.0;
        final trackBottom = height - 20.0;
        final clamped = widget.value.clamp(widget.min, widget.max);
        final range = (widget.max - widget.min).abs();
        final t = range <= 0
            ? 0.5
            : ((clamped - widget.min) / range).clamp(0.0, 1.0);
        final knobY = trackBottom - (trackBottom - trackTop) * t;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: widget.enabled ? widget.onReset : null,
          onTapDown: widget.enabled
              ? (details) {
                  final nextValue =
                      _valueForPosition(details.localPosition.dy, height);
                  _setValue(nextValue);
                  _commitValue(nextValue);
                }
              : null,
          onVerticalDragUpdate: widget.enabled
              ? (details) =>
                  _setValue(_valueForPosition(details.localPosition.dy, height))
              : null,
          onVerticalDragEnd: widget.enabled ? (_) => _commitValue() : null,
          child: Container(
            width: 44,
            decoration: BoxDecoration(
              color: widget.glassStyle
                  ? Colors.white.withAlpha(40)
                  : Colors.black.withAlpha(120),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: widget.glassStyle
                    ? Colors.white.withAlpha(80)
                    : Colors.white.withAlpha(40),
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 6,
                  child: Text(
                    '${widget.max.toStringAsFixed(1)}x',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.glassStyle
                              ? Colors.white
                              : Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: Text(
                    '${widget.min.toStringAsFixed(1)}x',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.glassStyle
                              ? Colors.white
                              : Colors.white70,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: trackTop,
                  bottom: trackTop,
                  child: Center(
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(
                          widget.glassStyle ? 160 : 90,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 4,
                  right: 4,
                  top: knobY - 16,
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: widget.enabled
                          ? (widget.glassStyle
                              ? Colors.white.withAlpha(160)
                              : const Color(0xFF38BDF8))
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(80),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        '${(clamped * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: widget.glassStyle
                                  ? const Color(0xFF0F172A)
                                  : Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _VncShortcutOverlay extends StatelessWidget {
  const _VncShortcutOverlay({
    required this.enabled,
    required this.onEsc,
    required this.onCmd,
    required this.onTab,
    required this.onCtrl,
    required this.onKeyboard,
  });

  final bool enabled;
  final VoidCallback onEsc;
  final VoidCallback onCmd;
  final VoidCallback onTab;
  final VoidCallback onCtrl;
  final VoidCallback onKeyboard;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(40)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Wrap(
          spacing: 8,
          children: [
            _VncShortcutButton(
              label: 'Esc',
              onPressed: enabled ? onEsc : null,
            ),
            _VncShortcutButton(
              label: 'Cmd',
              onPressed: enabled ? onCmd : null,
            ),
            _VncShortcutButton(
              label: 'Tab',
              onPressed: enabled ? onTab : null,
            ),
            _VncShortcutButton(
              label: 'Ctrl',
              onPressed: enabled ? onCtrl : null,
            ),
            _VncShortcutButton(
              label: 'Kbd',
              onPressed: enabled ? onKeyboard : null,
              icon: Icons.keyboard,
            ),
          ],
        ),
      ),
    );
  }
}

class _VncShortcutButton extends StatelessWidget {
  const _VncShortcutButton({
    required this.label,
    this.icon,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withAlpha(20),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: Colors.white),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VncControlAction extends StatelessWidget {
  const _VncControlAction({
    required this.icon,
    required this.label,
    this.onPressed,
    this.glassStyle = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;
    final foreground = glassStyle
        ? (isEnabled ? Colors.white : Colors.white54)
        : (isEnabled ? const Color(0xFF0F172A) : const Color(0xFF94A3B8));
    final background = glassStyle
        ? Colors.white.withAlpha(isEnabled ? 30 : 12)
        : (isEnabled ? const Color(0xFFE0F2FE) : const Color(0xFFF1F5F9));
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VncTrackpadSurface extends StatelessWidget {
  const _VncTrackpadSurface({
    required this.enabled,
    this.glassStyle = false,
    this.height,
    this.showLabel = true,
    this.disabledMessage,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onPointerCancel,
  });

  final bool enabled;
  final bool glassStyle;
  final double? height;
  final bool showLabel;
  final String? disabledMessage;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final ValueChanged<PointerUpEvent> onPointerUp;
  final ValueChanged<PointerCancelEvent> onPointerCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = glassStyle
        ? Colors.white.withAlpha(enabled ? 30 : 12)
        : (enabled ? const Color(0xFFF1F5F9) : const Color(0xFFE2E8F0));
    final borderColor = glassStyle
        ? Colors.white.withAlpha(enabled ? 120 : 60)
        : (enabled ? const Color(0xFFCBD5F5) : const Color(0xFFE2E8F0));
    final iconColor = glassStyle
        ? (enabled ? Colors.white : Colors.white54)
        : (enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8));
    final textColor = glassStyle
        ? (enabled ? Colors.white : Colors.white54)
        : (enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8));
    return GestureDetector(
      onPanStart: enabled ? (_) {} : null,
      onPanUpdate: enabled ? (_) {} : null,
      behavior: HitTestBehavior.opaque,
      child: Listener(
        onPointerDown: enabled ? onPointerDown : null,
        onPointerMove: enabled ? onPointerMove : null,
        onPointerUp: enabled ? onPointerUp : null,
        onPointerCancel: enabled ? onPointerCancel : null,
        child: Container(
          height: height ?? 120,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Center(
            child: showLabel
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.touch_app,
                        color: iconColor,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        enabled
                            ? 'Trackpad ready'
                            : (disabledMessage ?? 'Connect to enable input'),
                        style: theme.textTheme.bodySmall?.copyWith(
                              color: textColor,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

class _VncGestureHint extends StatelessWidget {
  const _VncGestureHint({
    required this.icon,
    required this.label,
    this.glassStyle = false,
  });

  final IconData icon;
  final String label;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: glassStyle ? Colors.white.withAlpha(24) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: glassStyle
              ? Colors.white.withAlpha(80)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: glassStyle ? Colors.white70 : const Color(0xFF475569),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: glassStyle ? Colors.white70 : const Color(0xFF475569),
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class ContextMissingScreen extends StatelessWidget {
  const ContextMissingScreen({
    super.key,
    required this.title,
    required this.message,
    required this.event,
  });

  final String title;
  final String message;
  final TimelineEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TimelineDetailScaffold(
      title: title,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Color(0xFFB91C1C),
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Context unavailable',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF7F1D1D),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          message,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF7F1D1D),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _ContextSectionCard(
              title: 'Event details',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _KeyValueRow(
                    label: 'Type',
                    value: event.type.toUpperCase(),
                  ),
                  _KeyValueRow(label: 'Title', value: event.title),
                  _KeyValueRow(
                    label: 'Timestamp',
                    value: _formatTimestamp(event.createdAt),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeadersBlock extends StatelessWidget {
  const _HeadersBlock({required this.headers});

  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    if (headers.isEmpty) {
      return const _EmptyHint(text: 'No headers recorded.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: headers.entries
          .map(
            (entry) => _KeyValueRow(
              label: entry.key,
              value: entry.value,
            ),
          )
          .toList(),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF94A3B8),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _StatusPillColor {
  const _StatusPillColor(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

_StatusPillColor _statusPillColor(int? status) {
  if (status == null) {
    return const _StatusPillColor(
      Color(0xFFE2E8F0),
      Color(0xFF475569),
    );
  }
  if (status >= 200 && status < 300) {
    return const _StatusPillColor(
      Color(0xFFDCFCE7),
      Color(0xFF166534),
    );
  }
  if (status >= 400) {
    return const _StatusPillColor(
      Color(0xFFFEE2E2),
      Color(0xFFB91C1C),
    );
  }
  return const _StatusPillColor(
    Color(0xFFFEF3C7),
    Color(0xFF92400E),
  );
}

Map<String, String> _parseHeaders(dynamic raw) {
  final headers = <String, String>{};
  if (raw is Map) {
    raw.forEach((key, value) {
      if (key != null) {
        headers[key.toString()] = value?.toString() ?? '';
      }
    });
  } else if (raw is List) {
    for (final entry in raw) {
      if (entry is Map) {
        final key = entry['name'] ?? entry['key'];
        if (key != null) {
          headers[key.toString()] = entry['value']?.toString() ?? '';
        }
      }
    }
  }
  return headers;
}

String? _stringifyBody(dynamic raw) {
  if (raw == null) {
    return null;
  }
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : raw;
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(raw);
  } catch (_) {
    return raw.toString();
  }
}

Set<String> _collectChangedPaths(dynamic current, dynamic previous) {
  final changes = <String>{};
  if (previous == null) {
    return changes;
  }
  _diffJsonValues(current, previous, '', changes);
  return changes;
}

void _diffJsonValues(
  dynamic current,
  dynamic previous,
  String path,
  Set<String> changes,
) {
  if (current is Map && previous is Map) {
    final currentMap = Map<String, dynamic>.from(current);
    final previousMap = Map<String, dynamic>.from(previous);
    final keys = <String>{...currentMap.keys, ...previousMap.keys};
    for (final key in keys) {
      final childPath = _childJsonPath(path, key);
      if (!currentMap.containsKey(key) || !previousMap.containsKey(key)) {
        changes.add(childPath);
        continue;
      }
      _diffJsonValues(currentMap[key], previousMap[key], childPath, changes);
    }
    return;
  }
  if (current is List && previous is List) {
    final maxLength =
        current.length > previous.length ? current.length : previous.length;
    for (var index = 0; index < maxLength; index += 1) {
      final childPath = _childJsonPath(path, index.toString());
      if (index >= current.length || index >= previous.length) {
        changes.add(childPath);
        continue;
      }
      _diffJsonValues(current[index], previous[index], childPath, changes);
    }
    return;
  }

  if (!_jsonValueEquals(current, previous)) {
    changes.add(path.isEmpty ? '/' : path);
  }
}

bool _jsonValueEquals(dynamic left, dynamic right) {
  if (left is Map && right is Map) {
    final leftMap = Map<String, dynamic>.from(left);
    final rightMap = Map<String, dynamic>.from(right);
    if (leftMap.length != rightMap.length) {
      return false;
    }
    for (final entry in leftMap.entries) {
      if (!rightMap.containsKey(entry.key)) {
        return false;
      }
      if (!_jsonValueEquals(entry.value, rightMap[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!_jsonValueEquals(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

String _childJsonPath(String parent, String child) {
  if (parent.isEmpty || parent == '/') {
    return '/$child';
  }
  return '$parent/$child';
}

class AgentCommandFailure implements Exception {
  const AgentCommandFailure(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

class AgentApiResult {
  const AgentApiResult({required this.request, required this.response});

  final ApiRequestDetails request;
  final ApiResponseDetails response;
}

class VncSessionInfo {
  const VncSessionInfo({
    required this.sessionId,
    required this.token,
    required this.wsPath,
    required this.width,
    required this.height,
    this.displayIndex,
    this.inputWidth,
    this.inputHeight,
    this.inputOriginX,
    this.inputOriginY,
    this.inputScaleX,
    this.inputScaleY,
    this.screenWidth,
    this.screenHeight,
  });

  final String sessionId;
  final String token;
  final String wsPath;
  final int width;
  final int height;
  final int? displayIndex;
  final int? inputWidth;
  final int? inputHeight;
  final double? inputOriginX;
  final double? inputOriginY;
  final double? inputScaleX;
  final double? inputScaleY;
  final int? screenWidth;
  final int? screenHeight;

  factory VncSessionInfo.fromPayload(Map<String, dynamic> payload) {
    final sessionId = payload['session_id']?.toString() ?? '';
    final token = payload['token']?.toString() ?? '';
    final wsPath = payload['ws_path']?.toString() ?? '/vnc/$sessionId';
    final width = int.tryParse(payload['width']?.toString() ?? '') ?? 0;
    final height = int.tryParse(payload['height']?.toString() ?? '') ?? 0;
    final displayIndex =
        int.tryParse(payload['display_index']?.toString() ?? '');
    final inputWidth =
        int.tryParse(payload['input_width']?.toString() ?? '');
    final inputHeight =
        int.tryParse(payload['input_height']?.toString() ?? '');
    final inputOriginX =
        double.tryParse(payload['input_origin_x']?.toString() ?? '');
    final inputOriginY =
        double.tryParse(payload['input_origin_y']?.toString() ?? '');
    final inputScaleX =
        double.tryParse(payload['input_scale_x']?.toString() ?? '');
    final inputScaleY =
        double.tryParse(payload['input_scale_y']?.toString() ?? '');
    final screenWidth =
        int.tryParse(payload['screen_width']?.toString() ?? '');
    final screenHeight =
        int.tryParse(payload['screen_height']?.toString() ?? '');
    if (sessionId.isEmpty || token.isEmpty) {
      throw const AgentCommandFailure('VNC session response missing fields.');
    }
    return VncSessionInfo(
      sessionId: sessionId,
      token: token,
      wsPath: wsPath,
      width: width,
      height: height,
      displayIndex: displayIndex,
      inputWidth: inputWidth,
      inputHeight: inputHeight,
      inputOriginX: inputOriginX,
      inputOriginY: inputOriginY,
      inputScaleX: inputScaleX,
      inputScaleY: inputScaleY,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
    );
  }
}

class VncDisplayInfo {
  const VncDisplayInfo({
    required this.index,
    required this.width,
    required this.height,
    required this.isPrimary,
  });

  final int index;
  final int width;
  final int height;
  final bool isPrimary;

  String get label {
    final primaryTag = isPrimary ? ' · 主屏' : '';
    return '显示器 ${index + 1} · ${width}x$height$primaryTag';
  }

  factory VncDisplayInfo.fromPayload(Map<String, dynamic> payload) {
    final index = int.tryParse(payload['index']?.toString() ?? '') ?? 0;
    final width = int.tryParse(payload['width']?.toString() ?? '') ?? 0;
    final height = int.tryParse(payload['height']?.toString() ?? '') ?? 0;
    final isPrimary =
        payload['is_primary'] == true || payload['is_primary'] == 1;
    return VncDisplayInfo(
      index: index,
      width: width,
      height: height,
      isPrimary: isPrimary,
    );
  }
}

class RemoteTerminalSession {
  const RemoteTerminalSession({
    required this.id,
    required this.label,
    required this.status,
    required this.createdAt,
    required this.lastActivity,
    this.exitCode,
    this.lastOutput,
    this.closedReason,
  });

  final String id;
  final String label;
  final String status;
  final DateTime createdAt;
  final DateTime lastActivity;
  final int? exitCode;
  final String? lastOutput;
  final String? closedReason;

  factory RemoteTerminalSession.fromPayload(Map<String, dynamic> payload) {
    final id = payload['id']?.toString() ?? '';
    final status = payload['status']?.toString() ?? 'unknown';
    final createdRaw = int.tryParse(payload['created_at']?.toString() ?? '');
    final lastRaw = int.tryParse(payload['last_activity']?.toString() ?? '');
    final createdAt = createdRaw == null || createdRaw == 0
        ? DateTime.now()
        : DateTime.fromMillisecondsSinceEpoch(createdRaw * 1000);
    final lastActivity = lastRaw == null || lastRaw == 0
        ? createdAt
        : DateTime.fromMillisecondsSinceEpoch(lastRaw * 1000);
    final exitCode = int.tryParse(payload['exit_code']?.toString() ?? '');
    final lastOutput = payload['last_output']?.toString();
    final closedReasonRaw = payload['closed_reason']?.toString();
    final closedReason = closedReasonRaw != null && closedReasonRaw.trim().isNotEmpty
        ? closedReasonRaw.trim()
        : null;
    if (id.isEmpty) {
      throw const AgentCommandFailure('Terminal session missing id.');
    }
    final rawLabel = payload['label']?.toString() ?? '';
    final resolvedLabel =
        rawLabel.trim().isNotEmpty ? rawLabel.trim() : 'Terminal ${_truncate(id, 6)}';
    return RemoteTerminalSession(
      id: id,
      label: resolvedLabel,
      status: status,
      createdAt: createdAt,
      lastActivity: lastActivity,
      exitCode: exitCode,
      lastOutput: lastOutput,
      closedReason: closedReason,
    );
  }
}

class AgentCommandClient {
  AgentCommandClient({
    required this.baseUrl,
    http.Client? client,
    this.authToken,
    this.clientId,
    this.clientName,
  }) : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  final String? authToken;
  final String? clientId;
  final String? clientName;

  Future<AgentApiResult> sendApiCommand({
    required String method,
    required String url,
    required Map<String, String> headers,
    dynamic body,
  }) async {
    final response = await _sendCommand(
      command: 'api',
      payload: {
        'method': method,
        'url': url,
        'headers': headers,
        'body': body,
      },
    );
    final payload = response.payload;
    if (payload == null) {
      throw const AgentCommandFailure('Agent response missing payload.');
    }
    final requestPayload = payload['request'];
    final responsePayload = payload['response'];
    if (requestPayload is! Map || responsePayload is! Map) {
      throw const AgentCommandFailure(
        'Agent response missing request or response details.',
      );
    }
    return AgentApiResult(
      request: ApiRequestDetails.fromPayload(
        Map<String, dynamic>.from(requestPayload),
      ),
      response: ApiResponseDetails.fromPayload(
        Map<String, dynamic>.from(responsePayload),
      ),
    );
  }

  Future<Map<String, dynamic>> fetchIdentity() async {
    final response = await _sendCommand(
      command: 'identity',
      payload: const {},
    );
    final payload = response.payload;
    if (payload is! Map<String, dynamic>) {
      throw const AgentCommandFailure('Agent identity response missing payload.');
    }
    return payload;
  }

  Future<List<RemoteTerminalSession>> fetchTerminalSessions() async {
    final response = await sendTerminalAction(action: 'list');
    final sessions = response['sessions'];
    if (sessions is! List) {
      return const [];
    }
    final results = <RemoteTerminalSession>[];
    for (final entry in sessions) {
      if (entry is Map) {
        try {
          results.add(RemoteTerminalSession.fromPayload(
            Map<String, dynamic>.from(entry),
          ));
        } catch (_) {
          // Ignore malformed session entries.
        }
      }
    }
    return results;
  }

  Future<Map<String, dynamic>> sendTerminalAction({
    required String action,
    String? sessionId,
    String? label,
    String? input,
    int? cols,
    int? rows,
    int? since,
    int? limit,
    String? workingDir,
    Map<String, String>? env,
  }) async {
    final payload = <String, dynamic>{
      'action': action,
    };
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    if (label != null && label.trim().isNotEmpty) {
      payload['label'] = label.trim();
    }
    if (input != null && input.isNotEmpty) {
      payload['input'] = input;
    }
    if (cols != null) {
      payload['cols'] = cols;
    }
    if (rows != null) {
      payload['rows'] = rows;
    }
    if (since != null) {
      payload['since'] = since;
    }
    if (limit != null) {
      payload['limit'] = limit;
    }
    if (workingDir != null && workingDir.trim().isNotEmpty) {
      payload['working_dir'] = workingDir;
    }
    if (env != null && env.isNotEmpty) {
      payload['env'] = env;
    }
    final response = await _sendCommand(
      command: 'terminal',
      payload: payload,
    );
    final responsePayload = response.payload;
    if (responsePayload is! Map<String, dynamic>) {
      throw const AgentCommandFailure('Agent response missing payload.');
    }
    return responsePayload;
  }

  Future<VncSessionInfo> sendVncCommand({
    required String action,
    String? sessionId,
    int? width,
    int? height,
    int? displayIndex,
    int? highPerfIntervalMs,
  }) async {
    final payload = <String, dynamic>{
      'action': action,
    };
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    if (width != null) {
      payload['width'] = width;
    }
    if (height != null) {
      payload['height'] = height;
    }
    if (displayIndex != null) {
      payload['display_index'] = displayIndex;
    }
    if (highPerfIntervalMs != null) {
      payload['high_perf_interval_ms'] = highPerfIntervalMs;
    }
    final response = await _sendCommand(
      command: 'vnc',
      payload: payload,
    );
    final payloadData = response.payload;
    if (payloadData == null) {
      throw const AgentCommandFailure('VNC response missing payload.');
    }
    return VncSessionInfo.fromPayload(
      Map<String, dynamic>.from(payloadData),
    );
  }

  Future<RoiSessionInfo> sendRoiCommand({
    required String action,
    String? sessionId,
    String? vncSessionId,
    int? framebufferWidth,
    int? framebufferHeight,
    int? screenWidth,
    int? screenHeight,
    int? displayIndex,
  }) async {
    final payload = <String, dynamic>{
      'action': action,
    };
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    if (vncSessionId != null && vncSessionId.trim().isNotEmpty) {
      payload['vnc_session_id'] = vncSessionId;
    }
    if (framebufferWidth != null) {
      payload['framebuffer_width'] = framebufferWidth;
    }
    if (framebufferHeight != null) {
      payload['framebuffer_height'] = framebufferHeight;
    }
    if (screenWidth != null) {
      payload['screen_width'] = screenWidth;
    }
    if (screenHeight != null) {
      payload['screen_height'] = screenHeight;
    }
    if (displayIndex != null) {
      payload['display_index'] = displayIndex;
    }
    final response = await _sendCommand(
      command: 'roi',
      payload: payload,
    );
    final payloadData = response.payload;
    if (payloadData == null) {
      throw const AgentCommandFailure('ROI response missing payload.');
    }
    return RoiSessionInfo.fromPayload(
      Map<String, dynamic>.from(payloadData),
    );
  }

  Future<List<VncDisplayInfo>> fetchVncDisplays() async {
    final response = await _sendCommand(
      command: 'vnc',
      payload: const {
        'action': 'displays',
      },
    );
    final payloadData = response.payload;
    if (payloadData == null) {
      return const [];
    }
    final displays = payloadData['displays'];
    if (displays is! List) {
      return const [];
    }
    return displays
        .map((item) => VncDisplayInfo.fromPayload(
              Map<String, dynamic>.from(item as Map),
            ))
        .toList();
  }

  Future<_AgentCommandResponse> _sendCommand({
    required String command,
    required Map<String, dynamic> payload,
  }) async {
    final uri = _commandUri();
    final requestBody = jsonEncode({
      'request_id': createStorageId(),
      'command': command,
      'payload': payload,
    });
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final token = authToken?.trim();
    if (token != null && token.isNotEmpty) {
      headers['x-agent-token'] = token;
    }
    final resolvedClientId = clientId?.trim();
    if (resolvedClientId != null && resolvedClientId.isNotEmpty) {
      headers['x-client-id'] = resolvedClientId;
    }
    final resolvedClientName = clientName?.trim();
    if (resolvedClientName != null && resolvedClientName.isNotEmpty) {
      headers['x-client-name'] = resolvedClientName;
    }
    http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: headers,
        body: requestBody,
      ).timeout(const Duration(seconds: 6));
    } catch (error) {
      throw AgentCommandFailure('Failed to reach desktop agent.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AgentCommandFailure(
        'Desktop agent returned HTTP ${response.statusCode}.',
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw const AgentCommandFailure('Agent response was not JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const AgentCommandFailure('Agent response was malformed.');
    }
    final parsed = _AgentCommandResponse.fromJson(decoded);
    if (!parsed.isOk) {
      throw AgentCommandFailure(
        parsed.error?.message ?? 'Agent command failed.',
        code: parsed.error?.code,
      );
    }
    return parsed;
  }

  Uri _commandUri() {
    final base = Uri.parse(baseUrl);
    if (base.scheme.isEmpty) {
      throw const AgentCommandFailure(
        'Agent URL must include a scheme (https://).',
      );
    }
    final basePath =
        base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    final commandPath = basePath.isEmpty ? '/command' : '$basePath/command';
    return base.replace(path: commandPath);
  }
}

class _AgentCommandResponse {
  const _AgentCommandResponse({
    required this.status,
    this.payload,
    this.error,
  });

  final String status;
  final Map<String, dynamic>? payload;
  final _AgentCommandError? error;

  bool get isOk => status.toLowerCase() == 'ok';

  factory _AgentCommandResponse.fromJson(Map<String, dynamic> json) {
    return _AgentCommandResponse(
      status: json['status']?.toString() ?? 'error',
      payload: json['payload'] is Map
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : null,
      error: json['error'] is Map
          ? _AgentCommandError.fromJson(
              Map<String, dynamic>.from(json['error'] as Map),
            )
          : null,
    );
  }
}

class _AgentCommandError {
  const _AgentCommandError({required this.code, required this.message});

  final String code;
  final String message;

  factory _AgentCommandError.fromJson(Map<String, dynamic> json) {
    return _AgentCommandError(
      code: json['code']?.toString() ?? 'unknown',
      message: json['message']?.toString() ?? 'Agent error.',
    );
  }
}

enum CommandTool { api, terminal, ai, vnc }

extension CommandToolMetadata on CommandTool {
  String get label {
    switch (this) {
      case CommandTool.api:
        return 'API Explorer';
      case CommandTool.terminal:
        return 'Terminal';
      case CommandTool.ai:
        return 'AI Insight';
      case CommandTool.vnc:
        return 'VNC Viewer';
    }
  }

  String get storageKey {
    switch (this) {
      case CommandTool.api:
        return 'api';
      case CommandTool.terminal:
        return 'terminal';
      case CommandTool.ai:
        return 'ai';
      case CommandTool.vnc:
        return 'vnc';
    }
  }
}

class CommandIntent {
  const CommandIntent({
    required this.tool,
    required this.title,
    required this.sessionLabel,
    required this.payload,
    required this.preview,
  });

  final CommandTool tool;
  final String title;
  final String sessionLabel;
  final Map<String, dynamic> payload;
  final String preview;
}

CommandIntent _buildApiIntent(String command, {String? parseSource}) {
  final source =
      parseSource == null || parseSource.trim().isEmpty ? command : parseSource;
  final method = _extractHttpMethod(source);
  final url = _extractUrl(_stripLeadingHttpMethod(source)) ?? '/unknown';
  final displayUrl = url.isEmpty ? '/unknown' : url;
  final title = 'API $method ${_truncate(displayUrl, 28)}';
  final sessionLabel = 'API $method ${_truncate(displayUrl, 28)}';
  final preview = '$method $displayUrl';
  final payload = <String, dynamic>{
    'command': command,
    'request': {
      'method': method,
      'url': displayUrl,
      'headers': <String, String>{},
      'body': null,
    },
    'response': {
      'status': null,
      'headers': <String, String>{},
      'body': null,
      'latency_ms': null,
    },
  };
  return CommandIntent(
    tool: CommandTool.api,
    title: title,
    sessionLabel: sessionLabel,
    payload: payload,
    preview: preview,
  );
}

String _extractHttpMethod(String input) {
  final match = RegExp(
    r'\b(get|post|put|patch|delete|head|options)\b',
    caseSensitive: false,
  ).firstMatch(input);
  if (match != null) {
    return match.group(1)!.toUpperCase();
  }
  final lowered = input.toLowerCase();
  if (_containsKeyword(lowered, ['create', 'submit', 'post'])) {
    return 'POST';
  }
  if (_containsKeyword(lowered, ['update', 'put'])) {
    return 'PUT';
  }
  if (_containsKeyword(lowered, ['patch'])) {
    return 'PATCH';
  }
  if (_containsKeyword(lowered, ['delete', 'remove'])) {
    return 'DELETE';
  }
  return 'GET';
}

String _stripLeadingHttpMethod(String input) {
  final trimmed = input.trim();
  final match = RegExp(
    r'^(get|post|put|patch|delete|head|options)\b',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) {
    return trimmed;
  }
  return trimmed.substring(match.end).trim();
}

String? _extractUrl(String input) {
  final urlMatch = RegExp(
    r'(https?:\/\/[^\s]+)',
    caseSensitive: false,
  ).firstMatch(input);
  if (urlMatch != null) {
    return urlMatch.group(1);
  }
  final pathMatch = RegExp(r'(\/[^\s]+)').firstMatch(input);
  return pathMatch?.group(1);
}

bool _containsKeyword(String input, List<String> keywords) {
  for (final keyword in keywords) {
    final expression = RegExp(
      '\\b${RegExp.escape(keyword)}\\b',
      caseSensitive: false,
    );
    if (expression.hasMatch(input)) {
      return true;
    }
  }
  return false;
}

String _truncate(String input, int maxLength) {
  final trimmed = input.trim();
  if (trimmed.length <= maxLength) {
    return trimmed;
  }
  if (maxLength <= 3) {
    return trimmed.substring(0, maxLength);
  }
  return '${trimmed.substring(0, maxLength - 3)}...';
}

bool _parseBool(dynamic raw) {
  if (raw is bool) {
    return raw;
  }
  if (raw is num) {
    return raw != 0;
  }
  if (raw is String) {
    final normalized = raw.trim().toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}

int? _parsePort(dynamic raw) {
  if (raw == null) {
    return null;
  }
  final port = int.tryParse(raw.toString());
  if (port == null || port < 1 || port > 65535) {
    return null;
  }
  return port;
}

List<String> _parseLocalUrls(dynamic raw) {
  if (raw == null) {
    return [];
  }
  List<String> normalize(List<String> values) {
    final unique = values
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toSet()
        .toList();
    return unique.where((entry) => !_isIgnoredLocalUrl(entry)).toList();
  }
  if (raw is List) {
    return normalize(raw.map((entry) => entry.toString()).toList());
  }
  if (raw is String) {
    if (raw.trim().isEmpty) {
      return [];
    }
    return normalize(raw.split(','));
  }
  return [];
}

List<String> _parseLocalIps(dynamic raw) {
  if (raw == null) {
    return const [];
  }
  if (raw is List) {
    return raw.map((entry) => entry.toString().trim()).where((entry) => entry.isNotEmpty).toList();
  }
  if (raw is String) {
    if (raw.trim().isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty)
            .toList();
      }
    } catch (_) {
      return raw
          .split(',')
          .map((entry) => entry.trim())
          .where((entry) => entry.isNotEmpty)
          .toList();
    }
  }
  return const [];
}

bool _isIgnoredLocalUrl(String url) {
  Uri? uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) {
    uri = Uri.tryParse('http://$url');
  }
  final host = uri?.host ?? '';
  if (host.isEmpty) {
    return false;
  }
  final octets = host.split('.');
  if (octets.length != 4) {
    return false;
  }
  final values = octets.map(int.tryParse).toList();
  if (values.any((value) => value == null)) {
    return false;
  }
  final a = values[0]!;
  final b = values[1]!;
  if (a == 127) {
    return true;
  }
  if (a == 0) {
    return true;
  }
  if (a == 169 && b == 254) {
    return true;
  }
  if (a == 198 && (b == 18 || b == 19)) {
    return true;
  }
  return false;
}

class PairingPayload {
  const PairingPayload({
    required this.token,
    required this.secret,
    this.expiresAt,
    this.deviceId,
    this.hostName,
    this.wifiSsid,
    this.localIps = const [],
    this.tunnelUrl,
    this.frpUrl,
    this.roiQuicPort,
    this.tunnelError,
    this.localUrls = const [],
    this.requiresApproval = false,
  });

  final String token;
  final String secret;
  final DateTime? expiresAt;
  final String? deviceId;
  final String? hostName;
  final String? wifiSsid;
  final List<String> localIps;
  final String? tunnelUrl;
  final String? frpUrl;
  final int? roiQuicPort;
  final String? tunnelError;
  final List<String> localUrls;
  final bool requiresApproval;

  bool get isExpired {
    if (expiresAt == null) {
      return false;
    }
    return DateTime.now().isAfter(expiresAt!);
  }

  String get expiryLabel {
    if (expiresAt == null) {
      return 'Active';
    }
    final remaining = expiresAt!.difference(DateTime.now());
    if (remaining.isNegative) {
      return 'Expired';
    }
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    }
    return '${seconds}s';
  }

  static PairingPayload? tryParse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    Map<String, dynamic>? data;
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) {
        data = decoded;
      }
    } catch (_) {
      final uri = Uri.tryParse(trimmed);
      if (uri != null && uri.scheme == 'vibeinspect') {
        data = Map<String, dynamic>.from(uri.queryParameters);
      }
    }

    if (data == null) {
      return null;
    }

    final token = data['token']?.toString() ??
        data['pairing_token']?.toString() ??
        data['pairingToken']?.toString();
    final secret = data['secret']?.toString() ??
        data['pairing_secret']?.toString() ??
        data['pairingSecret']?.toString();
    final expiresValue = data['expires_at'] ?? data['expiresAt'];
    if (token == null || secret == null || expiresValue == null) {
      return null;
    }

    final deviceId =
        data['device_id']?.toString() ?? data['deviceId']?.toString();
    final hostName =
        data['host_name']?.toString() ?? data['hostName']?.toString();
    final wifiSsid =
        data['wifi_ssid']?.toString() ?? data['wifiSsid']?.toString();
    final localIps =
        _parseLocalIps(data['local_ips'] ?? data['localIps']);
    final tunnelUrl =
        data['tunnel_url']?.toString() ?? data['tunnelUrl']?.toString();
    final frpUrl = data['frp_url']?.toString() ?? data['frpUrl']?.toString();
    final roiQuicPort = _parsePort(
      data['roi_quic_port'] ?? data['roiQuicPort'],
    );
    final tunnelError =
        data['tunnel_error']?.toString() ?? data['tunnelError']?.toString();
    final localUrls = _parseLocalUrls(
      data['local_urls'] ?? data['localUrls'] ?? data['local_url'],
    );
    final requiresApprovalRaw =
        data['requires_approval'] ?? data['requiresApproval'];
    final requiresApproval = _parseBool(requiresApprovalRaw);
    final expiresAtRaw = int.tryParse(expiresValue.toString());
    if (expiresAtRaw == null) {
      return null;
    }
    final expiresAt = expiresAtRaw == 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(expiresAtRaw * 1000);

    return PairingPayload(
      token: token,
      secret: secret,
      expiresAt: expiresAt,
      deviceId: deviceId,
      hostName: hostName,
      wifiSsid: wifiSsid,
      localIps: localIps,
      tunnelUrl: tunnelUrl,
      frpUrl: frpUrl,
      roiQuicPort: roiQuicPort,
      tunnelError: tunnelError,
      localUrls: localUrls,
      requiresApproval: requiresApproval,
    );
  }

  List<String> get preferredUrls {
    final urls = <String>[];
    urls.addAll(localUrls);
    if (tunnelUrl != null && tunnelUrl!.trim().isNotEmpty) {
      urls.add(tunnelUrl!.trim());
    }
    if (frpUrl != null && frpUrl!.trim().isNotEmpty) {
      urls.add(frpUrl!.trim());
    }
    return urls.toSet().toList();
  }
}

class _ManualLoginInput {
  const _ManualLoginInput({required this.url, required this.token});

  final String url;
  final String token;
}

enum _PairingAttemptStatus { connected, pending, failed }

class _PairingAttemptResult {
  const _PairingAttemptResult({
    required this.status,
    this.message,
    this.detail,
    this.agentUrl,
    this.authToken,
    this.deviceId,
  });

  final _PairingAttemptStatus status;
  final String? message;
  final String? detail;
  final String? agentUrl;
  final String? authToken;
  final String? deviceId;
}

class _PairingCandidateSelection {
  const _PairingCandidateSelection({
    required this.candidates,
    this.message,
    this.detail,
  });

  final List<String> candidates;
  final String? message;
  final String? detail;
}

class _ReachabilityResult {
  const _ReachabilityResult({
    required this.url,
    required this.reachable,
    this.reason,
  });

  final String url;
  final bool reachable;
  final String? reason;
}

class _AgentRouteResolution {
  const _AgentRouteResolution({
    required this.record,
    this.errorDetail,
  });

  final ConnectionRecord record;
  final String? errorDetail;
}

String _agentLabel(ConnectionRecord agent) {
  final hostName = agent.hostName?.trim();
  if (hostName != null && hostName.isNotEmpty) {
    return hostName;
  }
  final deviceId = agent.deviceId?.trim();
  if (deviceId != null && deviceId.isNotEmpty) {
    return 'Agent ${_truncate(deviceId, 6)}';
  }
  final token = agent.token.trim();
  if (token.isEmpty) {
    return 'Agent';
  }
  return 'Agent ${_truncate(token, 6)}';
}

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$month/$day $hour:$minute';
}
