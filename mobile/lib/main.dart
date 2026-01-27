import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile/storage/local_storage.dart';

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

class VibeInspectApp extends StatelessWidget {
  const VibeInspectApp({super.key, required this.storageInitializer});

  final StorageInitializer storageInitializer;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Vibe Inspect',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: const ColorScheme(
          brightness: Brightness.light,
          primary: Color(0xFF1F2937),
          onPrimary: Color(0xFFF9FAFB),
          secondary: Color(0xFFE07A5F),
          onSecondary: Color(0xFFF9FAFB),
          error: Color(0xFFB91C1C),
          onError: Color(0xFFF9FAFB),
          surface: Color(0xFFF8FAFC),
          onSurface: Color(0xFF111827),
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.spaceGroteskTextTheme(),
      ),
      home: StorageGate(storageInitializer: storageInitializer),
    );
  }
}

class StorageGate extends StatefulWidget {
  const StorageGate({super.key, required this.storageInitializer});

  final StorageInitializer storageInitializer;

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
        return PairingScreen(storage: storage);
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
  const PairingScreen({super.key, required this.storage});

  final StorageRepository storage;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  PairingPayload? _payload;
  PairedConnection? _connection;
  String? _scanError;
  String? _secretError;
  final TextEditingController _secretController = TextEditingController();
  List<TimelineEvent> _timelineEvents = [];
  List<ToolSession> _toolSessions = [];
  bool _isHistoryLoading = true;
  String? _historyError;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _secretController.dispose();
    super.dispose();
  }

  Future<void> _scanQrPayload() async {
    final controller = TextEditingController();
    final payload = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Scan pairing QR'),
          content: TextField(
            key: const Key('qrPayloadField'),
            controller: controller,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'Paste QR payload JSON',
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

    if (payload == null) {
      return;
    }

    final parsed = PairingPayload.tryParse(payload);
    setState(() {
      _payload = parsed;
      _connection = null;
      _scanError = parsed == null ? 'Invalid QR payload.' : null;
      _secretError = null;
      _secretController.clear();
      if (parsed != null && parsed.isExpired) {
        _scanError = 'Token expired. Request a new token and retry.';
      }
    });
  }

  Future<void> _confirmSecret() async {
    final payload = _payload;
    if (payload == null) {
      setState(() {
        _secretError = 'Scan a pairing token first.';
      });
      return;
    }

    if (payload.isExpired) {
      setState(() {
        _scanError = 'Token expired. Request a new token and retry.';
        _secretError = null;
      });
      return;
    }

    if (_secretController.text.trim() != payload.secret) {
      setState(() {
        _secretError = 'Shared secret does not match.';
      });
      return;
    }

    setState(() {
      _connection = PairedConnection(
        token: payload.token,
        connectedAt: DateTime.now(),
        tunnelUrl: payload.tunnelUrl,
        tunnelError: payload.tunnelError,
      );
      _secretError = null;
    });

    await _recordPairingEvent(payload);
  }

  void _resetPairing() {
    setState(() {
      _payload = null;
      _connection = null;
      _scanError = null;
      _secretError = null;
      _secretController.clear();
    });
  }

  Future<void> _recordPairingEvent(PairingPayload payload) async {
    try {
      final now = DateTime.now();
      final session = ToolSession(
        id: createStorageId(),
        type: 'pairing',
        label: 'Pairing ${payload.token}',
        status: 'connected',
        createdAt: now,
      );
      final event = TimelineEvent(
        id: createStorageId(),
        sessionId: session.id,
        type: 'pairing',
        title: 'Paired with desktop agent',
        payload: {
          'token': payload.token,
          'tunnel_url': payload.tunnelUrl ?? '',
          'connected_at': now.toIso8601String(),
        },
        createdAt: now,
      );
      await widget.storage.insertToolSession(session);
      await widget.storage.insertTimelineEvent(event);
      await _loadHistory();
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

  Future<void> _loadHistory() async {
    setState(() {
      _isHistoryLoading = true;
      _historyError = null;
    });
    try {
      final events = await widget.storage.fetchTimelineEvents();
      final sessions = await widget.storage.fetchToolSessions();
      if (!mounted) {
        return;
      }
      setState(() {
        _timelineEvents = events;
        _toolSessions = sessions;
        _isHistoryLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isHistoryLoading = false;
        _historyError = 'Unable to load stored history.';
      });
    }
  }

  Future<void> _handleTimelineEventTap(TimelineEvent event) async {
    final eventType = event.type.toLowerCase();
    if (eventType == 'api') {
      final apiContext = ApiEventContext.fromPayload(event.payload);
      if (apiContext == null) {
        _openContextError(
          title: 'Context unavailable',
          message:
              'This API event is missing request or response details needed to restore the explorer.',
          event: event,
        );
        return;
      }
      _pushContextScreen(
        ApiExplorerScreen(
          event: event,
          context: apiContext,
        ),
      );
      return;
    }

    if (eventType == 'terminal') {
      var session = _findSessionById(_toolSessions, event.sessionId);
      if (session == null) {
        try {
          final sessions = await widget.storage.fetchToolSessions();
          session = _findSessionById(sessions, event.sessionId);
        } catch (_) {
          session = null;
        }
      }
      if (!mounted) {
        return;
      }
      if (session == null) {
        _openContextError(
          title: 'Session missing',
          message:
              'The referenced terminal session could not be found in local history.',
          event: event,
        );
        return;
      }
      _pushContextScreen(
        TerminalSessionScreen(
          event: event,
          session: session,
        ),
      );
      return;
    }

    _openContextError(
      title: 'Context unavailable',
      message: 'This event type does not yet support context restore.',
      event: event,
    );
  }

  ToolSession? _findSessionById(
    List<ToolSession> sessions,
    String sessionId,
  ) {
    for (final session in sessions) {
      if (session.id == sessionId) {
        return session;
      }
    }
    return null;
  }

  void _pushContextScreen(Widget screen) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  void _openContextError({
    required String title,
    required String message,
    required TimelineEvent event,
  }) {
    if (!mounted) {
      return;
    }
    _pushContextScreen(
      ContextMissingScreen(
        title: title,
        message: message,
        event: event,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
                    title: 'Scan QR token',
                    description:
                        'Capture the desktop QR to import a short-lived token.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FilledButton.icon(
                          key: const Key('scanQrButton'),
                          onPressed: _scanQrPayload,
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text('Scan QR payload'),
                        ),
                        const SizedBox(height: 16),
                        if (_payload == null)
                          const Text(
                            'No pairing token scanned yet.',
                          )
                        else
                          _PairingTokenDetails(payload: _payload!),
                        if (_scanError != null) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(
                            message: _scanError!,
                            isError: true,
                          ),
                        ],
                        if (_payload?.tunnelError != null) ...[
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
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  PairingStepCard(
                    title: 'Confirm shared secret',
                    description:
                        'Enter the secret shown on your desktop to finish pairing.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          key: const Key('secretField'),
                          controller: _secretController,
                          obscureText: true,
                          decoration: InputDecoration(
                            labelText: 'Shared secret',
                            errorText: _secretError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          key: const Key('confirmSecretButton'),
                          onPressed: _connection == null ? _confirmSecret : null,
                          child: const Text('Confirm secret'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _ConnectionStatusCard(
                    connection: _connection,
                    hasToken: _payload != null,
                  ),
                  const SizedBox(height: 20),
                  PairingStepCard(
                    title: 'Local timeline',
                    description:
                        'Timeline events are stored on-device and survive restarts.',
                    child: _TimelineHistory(
                      isLoading: _isHistoryLoading,
                      errorMessage: _historyError,
                      events: _timelineEvents,
                      onEventTap: _handleTimelineEventTap,
                    ),
                  ),
                  const SizedBox(height: 20),
                  PairingStepCard(
                    title: 'Tool history',
                    description:
                        'Recent tool sessions saved locally for quick recall.',
                    child: _ToolHistory(
                      isLoading: _isHistoryLoading,
                      errorMessage: _historyError,
                      sessions: _toolSessions,
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

class _PairingBackground extends StatelessWidget {
  const _PairingBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFFFCE7D2),
            Color(0xFFF8FAFC),
            Color(0xFFE0F2FE),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Stack(
        children: const [
          Positioned(
            top: -80,
            left: -40,
            child: _GlowCircle(
              size: 180,
              color: Color(0xFFFFE0B2),
            ),
          ),
          Positioned(
            bottom: -60,
            right: -30,
            child: _GlowCircle(
              size: 200,
              color: Color(0xFFCFFAFE),
            ),
          ),
        ],
      ),
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

class _PairingHeader extends StatelessWidget {
  const _PairingHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Pair your desktop agent',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
        ),
        const SizedBox(height: 8),
        Text(
          'Use a short-lived token and a shared secret to link devices securely.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFF475569),
              ),
        ),
      ],
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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(15),
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
  const _InlineStatus({required this.message, this.isError = false});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final background = isError ? const Color(0xFFFEE2E2) : const Color(0xFFDCFCE7);
    final textColor = isError ? const Color(0xFF991B1B) : const Color(0xFF166534);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: textColor,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _ConnectionStatusCard extends StatelessWidget {
  const _ConnectionStatusCard({required this.connection, required this.hasToken});

  final PairedConnection? connection;
  final bool hasToken;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConnected = connection != null;
    final title = isConnected ? 'Connected' : 'Not connected';
    final subtitle = isConnected
        ? 'Connection saved for ${connection!.token}.'
        : hasToken
            ? 'Enter the shared secret to finish pairing.'
            : 'Scan a QR token to begin pairing.';
    final tunnelUrl = connection?.tunnelUrl;
    final tunnelError = connection?.tunnelError;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isConnected ? const Color(0xFFDCFCE7) : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: isConnected ? const Color(0xFF86EFAC) : const Color(0xFFBFDBFE),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: isConnected
                    ? const Color(0xFF22C55E)
                    : const Color(0xFF60A5FA),
                child: Icon(
                  isConnected ? Icons.check : Icons.link,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (isConnected && tunnelUrl != null && tunnelUrl.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Tunnel URL',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              tunnelUrl,
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF1E293B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          if (isConnected &&
              (tunnelUrl == null || tunnelUrl.isEmpty) &&
              tunnelError != null) ...[
            const SizedBox(height: 12),
            _InlineStatus(
              message: tunnelError,
              isError: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _TimelineHistory extends StatelessWidget {
  const _TimelineHistory({
    required this.isLoading,
    required this.errorMessage,
    required this.events,
    required this.onEventTap,
  });

  final bool isLoading;
  final String? errorMessage;
  final List<TimelineEvent> events;
  final ValueChanged<TimelineEvent> onEventTap;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (errorMessage != null) {
      return _InlineStatus(
        message: errorMessage!,
        isError: true,
      );
    }

    if (events.isEmpty) {
      return Text(
        'No timeline events saved yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF64748B),
            ),
      );
    }

    final visibleEvents = events.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final event in visibleEvents) ...[
          _TimelineEventRow(
            event: event,
            onTap: () => onEventTap(event),
          ),
          if (event != visibleEvents.last) const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _ToolHistory extends StatelessWidget {
  const _ToolHistory({
    required this.isLoading,
    required this.errorMessage,
    required this.sessions,
  });

  final bool isLoading;
  final String? errorMessage;
  final List<ToolSession> sessions;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (errorMessage != null) {
      return _InlineStatus(
        message: errorMessage!,
        isError: true,
      );
    }

    if (sessions.isEmpty) {
      return Text(
        'No tool sessions stored yet.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: const Color(0xFF64748B),
            ),
      );
    }

    final visibleSessions = sessions.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final session in visibleSessions) ...[
          _ToolSessionRow(session: session),
          if (session != visibleSessions.last) const SizedBox(height: 12),
        ],
      ],
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

class _TimelineEventRow extends StatelessWidget {
  const _TimelineEventRow({required this.event, required this.onTap});

  final TimelineEvent event;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visuals = _eventVisuals(event.type);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: Key('timelineEvent-${event.id}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 16,
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
                      event.title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${event.type.toUpperCase()} • ${_formatTimestamp(event.createdAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: Color(0xFF94A3B8),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolSessionRow extends StatelessWidget {
  const _ToolSessionRow({required this.session});

  final ToolSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 16,
            backgroundColor: Color(0xFFDBEAFE),
            child: Icon(
              Icons.work_outline,
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
                  session.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: const Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${session.status.toUpperCase()} • ${_formatTimestamp(session.createdAt)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF64748B),
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
  final String? body;

  factory ApiRequestDetails.fromPayload(Map<String, dynamic> payload) {
    final methodValue =
        payload['method'] ?? payload['http_method'] ?? payload['httpMethod'];
    final urlValue = payload['url'] ?? payload['endpoint'] ?? payload['path'];
    return ApiRequestDetails(
      method: methodValue?.toString().toUpperCase() ?? 'UNKNOWN',
      url: urlValue?.toString() ?? 'Unknown URL',
      headers: _parseHeaders(payload['headers']),
      body: _stringifyBody(payload['body'] ?? payload['data']),
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
  final String? body;

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
      body: _stringifyBody(payload['body'] ?? payload['data']),
    );
  }
}

class ApiEventContext {
  const ApiEventContext({required this.request, required this.response});

  final ApiRequestDetails request;
  final ApiResponseDetails response;

  static ApiEventContext? fromPayload(Map<String, dynamic> payload) {
    final rawRequest = payload['request'] ?? payload['api_request'];
    final rawResponse = payload['response'] ?? payload['api_response'];
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
    );
  }
}

class ApiExplorerScreen extends StatelessWidget {
  const ApiExplorerScreen({
    super.key,
    required this.event,
    required this.context,
  });

  final TimelineEvent event;
  final ApiEventContext context;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final responseStatus = this.context.response.status;
    final statusLabel =
        responseStatus == null ? 'Unknown' : responseStatus.toString();
    final statusColor = _statusPillColor(responseStatus);

    return _TimelineDetailScaffold(
      title: 'API Explorer',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              event.title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Recorded ${_formatTimestamp(event.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 20),
            _ContextSectionCard(
              title: 'Request',
              subtitle: 'Method, URL, headers, and payload',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _InfoPill(
                        label: this.context.request.method,
                        backgroundColor: const Color(0xFFE0F2FE),
                        textColor: const Color(0xFF0369A1),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          this.context.request.url,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: const Color(0xFF0F172A),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _HeadersBlock(headers: this.context.request.headers),
                  if (this.context.request.body != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Body',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _CodeBlock(content: this.context.request.body!),
                  ] else
                    _EmptyHint(text: 'No request body recorded.'),
                ],
              ),
            ),
            _ContextSectionCard(
              title: 'Response',
              subtitle: 'Status, latency, headers, and body',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _InfoPill(
                        label: 'Status $statusLabel',
                        backgroundColor: statusColor.background,
                        textColor: statusColor.foreground,
                      ),
                      if (this.context.response.latencyMs != null) ...[
                        const SizedBox(width: 12),
                        _InfoPill(
                          label: '${this.context.response.latencyMs} ms',
                          backgroundColor: const Color(0xFFEDE9FE),
                          textColor: const Color(0xFF6D28D9),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 16),
                  _HeadersBlock(headers: this.context.response.headers),
                  if (this.context.response.body != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      'Body',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF64748B),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _CodeBlock(content: this.context.response.body!),
                  ] else
                    _EmptyHint(text: 'No response body recorded.'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TerminalSessionScreen extends StatelessWidget {
  const TerminalSessionScreen({
    super.key,
    required this.event,
    required this.session,
  });

  final TimelineEvent event;
  final ToolSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final command = event.payload['command']?.toString();
    final outputPreview =
        event.payload['output_preview'] ?? event.payload['output'];
    final outputText = _stringifyBody(outputPreview);

    return _TimelineDetailScaffold(
      title: 'Terminal Session',
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
              'Last updated ${_formatTimestamp(event.createdAt)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 20),
            _ContextSectionCard(
              title: 'Session details',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _KeyValueRow(
                    label: 'Status',
                    value: session.status.toUpperCase(),
                  ),
                  _KeyValueRow(
                    label: 'Created',
                    value: _formatTimestamp(session.createdAt),
                  ),
                ],
              ),
            ),
            if (command != null && command.trim().isNotEmpty)
              _ContextSectionCard(
                title: 'Last command',
                child: _CodeBlock(content: command),
              ),
            if (outputText != null && outputText.trim().isNotEmpty)
              _ContextSectionCard(
                title: 'Output preview',
                child: _CodeBlock(content: outputText),
              ),
          ],
        ),
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

class PairingPayload {
  const PairingPayload({
    required this.token,
    required this.secret,
    required this.expiresAt,
    this.tunnelUrl,
    this.tunnelError,
  });

  final String token;
  final String secret;
  final DateTime expiresAt;
  final String? tunnelUrl;
  final String? tunnelError;

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  String get expiryLabel {
    final remaining = expiresAt.difference(DateTime.now());
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

    final token = data['token']?.toString();
    final secret = data['secret']?.toString();
    final expiresValue = data['expires_at'] ?? data['expiresAt'];
    if (token == null || secret == null || expiresValue == null) {
      return null;
    }

    final tunnelUrl = data['tunnel_url']?.toString() ??
        data['tunnelUrl']?.toString();
    final tunnelError = data['tunnel_error']?.toString() ??
        data['tunnelError']?.toString();
    final expiresAt = int.tryParse(expiresValue.toString());
    if (expiresAt == null) {
      return null;
    }

    return PairingPayload(
      token: token,
      secret: secret,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000),
      tunnelUrl: tunnelUrl,
      tunnelError: tunnelError,
    );
  }
}

class PairedConnection {
  const PairedConnection({
    required this.token,
    required this.connectedAt,
    this.tunnelUrl,
    this.tunnelError,
  });

  final String token;
  final DateTime connectedAt;
  final String? tunnelUrl;
  final String? tunnelError;
}

String _formatTimestamp(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$month/$day $hour:$minute';
}
