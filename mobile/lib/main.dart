import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:mobile/storage/local_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VibeInspectApp(storageInitializer: LocalStorageInitializer()));
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
  });

  final bool isLoading;
  final String? errorMessage;
  final List<TimelineEvent> events;

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
          _TimelineEventRow(event: event),
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

class _TimelineEventRow extends StatelessWidget {
  const _TimelineEventRow({required this.event});

  final TimelineEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 16,
            backgroundColor: Color(0xFFE2E8F0),
            child: Icon(
              Icons.timeline,
              size: 18,
              color: Color(0xFF475569),
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
        ],
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
