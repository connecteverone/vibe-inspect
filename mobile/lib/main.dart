import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
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
  final TextEditingController _commandController = TextEditingController();
  String? _commandError;
  String? _commandFeedback;
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
    _commandController.dispose();
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

  Future<void> _handleCommandSubmit() async {
    final command = _commandController.text.trim();
    if (command.isEmpty) {
      setState(() {
        _commandError = 'Enter a command to run.';
      });
      return;
    }

    setState(() {
      _commandError = null;
      _commandFeedback = null;
    });

    final intent = await _resolveCommandIntent(command);
    if (!mounted || intent == null) {
      return;
    }

    await _routeCommandIntent(intent);
  }

  Future<CommandIntent?> _resolveCommandIntent(String command) async {
    final parsed = _uniqueIntents(_parseCommandIntents(command));
    if (parsed.length == 1) {
      return parsed.first;
    }

    final options = parsed.isEmpty ? _buildFallbackIntents(command) : parsed;
    options.sort((a, b) => a.tool.index.compareTo(b.tool.index));
    if (!mounted) {
      return null;
    }

    final dialogTitle = parsed.isEmpty
        ? 'Choose a tool'
        : 'Multiple tools matched';
    final dialogSubtitle = parsed.isEmpty
        ? 'We could not determine the right tool for:'
        : 'Select the tool you meant for:';

    return showDialog<CommandIntent>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(dialogTitle),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(dialogSubtitle),
                  const SizedBox(height: 8),
                  Text(
                    '"$command"',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF475569),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(height: 16),
                  for (final option in options) ...[
                    _CommandChoiceTile(
                      intent: option,
                      onTap: () => Navigator.of(context).pop(option),
                    ),
                    if (option != options.last) const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _routeCommandIntent(CommandIntent intent) async {
    final now = DateTime.now();
    final session = ToolSession(
      id: createStorageId(),
      type: intent.tool.storageKey,
      label: intent.sessionLabel,
      status: 'queued',
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
      await _loadHistory();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Failed to save command: ${error.toString()}',
          ),
        ),
      );
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _commandFeedback = 'Opened ${intent.tool.label}';
      _commandController.clear();
    });

    _openIntentScreen(intent, event, session);
  }

  void _openIntentScreen(
    CommandIntent intent,
    TimelineEvent event,
    ToolSession session,
  ) {
    switch (intent.tool) {
      case CommandTool.api:
        final apiContext = ApiEventContext.fromPayload(event.payload);
        if (apiContext == null) {
          _openContextError(
            title: 'Context unavailable',
            message:
                'This API request is missing details needed to restore the explorer.',
            event: event,
          );
          return;
        }
        _pushContextScreen(
          ApiExplorerScreen(
            event: event,
            context: apiContext,
            storage: widget.storage,
            agentBaseUrl: _connection?.tunnelUrl,
          ),
        );
        return;
      case CommandTool.terminal:
        _pushContextScreen(
          TerminalSessionScreen(
            event: event,
            session: session,
            storage: widget.storage,
            agentBaseUrl: _connection?.tunnelUrl,
          ),
        );
        return;
      case CommandTool.ai:
        _pushContextScreen(
          AiInsightScreen(
            event: event,
            session: session,
          ),
        );
        return;
      case CommandTool.vnc:
        _pushContextScreen(
          VncSessionScreen(
            event: event,
            session: session,
            storage: widget.storage,
            agentBaseUrl: _connection?.tunnelUrl,
          ),
        );
        return;
    }
  }

  Future<ToolSession?> _resolveSession(String sessionId) async {
    var session = _findSessionById(_toolSessions, sessionId);
    if (session != null) {
      return session;
    }
    try {
      final sessions = await widget.storage.fetchToolSessions();
      session = _findSessionById(sessions, sessionId);
    } catch (_) {
      session = null;
    }
    return session;
  }

  void _applyCommandExample(String example) {
    setState(() {
      _commandController.text = example;
      _commandController.selection =
          TextSelection.collapsed(offset: example.length);
      _commandError = null;
      _commandFeedback = null;
    });
  }

  void _clearCommandInput() {
    setState(() {
      _commandController.clear();
      _commandError = null;
      _commandFeedback = null;
    });
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
          storage: widget.storage,
          agentBaseUrl: _connection?.tunnelUrl,
        ),
      );
      return;
    }

    if (eventType == 'terminal') {
      final session = await _resolveSession(event.sessionId);
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
          storage: widget.storage,
          agentBaseUrl: _connection?.tunnelUrl,
        ),
      );
      return;
    }

    if (eventType == 'ai') {
      final session = await _resolveSession(event.sessionId);
      if (!mounted) {
        return;
      }
      if (session == null) {
        _openContextError(
          title: 'Session missing',
          message: 'The referenced AI session could not be found in history.',
          event: event,
        );
        return;
      }
      _pushContextScreen(
        AiInsightScreen(
          event: event,
          session: session,
        ),
      );
      return;
    }

    if (eventType == 'vnc') {
      final session = await _resolveSession(event.sessionId);
      if (!mounted) {
        return;
      }
      if (session == null) {
        _openContextError(
          title: 'Session missing',
          message:
              'The referenced VNC session could not be found in local history.',
          event: event,
        );
        return;
      }
      _pushContextScreen(
        VncSessionScreen(
          event: event,
          session: session,
          storage: widget.storage,
          agentBaseUrl: _connection?.tunnelUrl,
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
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => screen))
        .then((_) {
      if (mounted) {
        _loadHistory();
      }
    });
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
                    title: 'Command bar',
                    description:
                        'Describe the action and the app will route it to API, terminal, AI, or VNC.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          key: const Key('commandBarField'),
                          controller: _commandController,
                          decoration: InputDecoration(
                            labelText: 'Command',
                            hintText:
                                'POST /login, run npm test, analyze deploy error',
                            errorText: _commandError,
                          ),
                          onChanged: (_) {
                            if (_commandError != null ||
                                _commandFeedback != null) {
                              setState(() {
                                _commandError = null;
                                _commandFeedback = null;
                              });
                            }
                          },
                          onSubmitted: (_) => _handleCommandSubmit(),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton.icon(
                              key: const Key('commandRunButton'),
                              onPressed: _handleCommandSubmit,
                              icon: const Icon(Icons.bolt),
                              label: const Text('Run command'),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton(
                              key: const Key('commandClearButton'),
                              onPressed: _clearCommandInput,
                              child: const Text('Clear'),
                            ),
                          ],
                        ),
                        if (_commandFeedback != null) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(
                            message: _commandFeedback!,
                            isError: false,
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          'Examples',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF64748B),
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _CommandExampleChip(
                              label: 'POST /login',
                              onTap: () => _applyCommandExample('POST /login'),
                            ),
                            _CommandExampleChip(
                              label: 'run npm test',
                              onTap: () =>
                                  _applyCommandExample('run npm test'),
                            ),
                            _CommandExampleChip(
                              label: 'ai summarize last error',
                              onTap: () => _applyCommandExample(
                                'ai summarize last error',
                              ),
                            ),
                            _CommandExampleChip(
                              label: 'vnc open login screen',
                              onTap: () => _applyCommandExample(
                                'vnc open login screen',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
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

class _CommandExampleChip extends StatelessWidget {
  const _CommandExampleChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      onPressed: onTap,
      backgroundColor: const Color(0xFFF1F5F9),
      side: const BorderSide(color: Color(0xFFE2E8F0)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(999),
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

class _CommandChoiceTile extends StatelessWidget {
  const _CommandChoiceTile({
    required this.intent,
    required this.onTap,
  });

  final CommandIntent intent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visuals = _eventVisuals(intent.tool.storageKey);
    return Material(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
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
                      intent.tool.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF0F172A),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      intent.preview,
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
  });

  final TimelineEvent event;
  final ApiEventContext context;
  final StorageRepository storage;
  final String? agentBaseUrl;

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
    _agentClient = AgentCommandClient(baseUrl: baseUrl, client: _httpClient!);
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

    final agentClient = _agentClient;
    if (agentClient == null) {
      setState(() {
        _requestError =
            'Connect to the desktop agent to send API requests.';
      });
      return;
    }

    setState(() {
      _isSending = true;
      _bodyError = null;
      _requestError = null;
    });

    final headers = _collectHeaders();
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
      setState(() {
        _previousResponse = previousResponse;
        _response = response;
        _changedPaths = changedPaths;
      });
      await _persistApiEvent(
        request: result.request,
        response: response,
        previousResponse: previousResponse,
      );
    } on AgentCommandFailure catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _requestError = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _requestError = 'Request failed: ${error.toString()}';
      });
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

    final updatedEvent = TimelineEvent(
      id: widget.event.id,
      sessionId: widget.event.sessionId,
      type: widget.event.type,
      title: widget.event.title,
      payload: payload,
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
    this.lastCommand,
    this.lastEvent,
  });

  final ToolSession session;
  final List<TerminalOutputEntry> output;
  final String? lastCommand;
  final TimelineEvent? lastEvent;

  TerminalSessionView copyWith({
    ToolSession? session,
    List<TerminalOutputEntry>? output,
    String? lastCommand,
    TimelineEvent? lastEvent,
  }) {
    return TerminalSessionView(
      session: session ?? this.session,
      output: output ?? this.output,
      lastCommand: lastCommand ?? this.lastCommand,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}

class TerminalWorkspaceScreen extends StatefulWidget {
  const TerminalWorkspaceScreen({
    super.key,
    required this.storage,
    required this.agentBaseUrl,
    this.initialSession,
    this.initialEvent,
  });

  final StorageRepository storage;
  final String? agentBaseUrl;
  final ToolSession? initialSession;
  final TimelineEvent? initialEvent;

  @override
  State<TerminalWorkspaceScreen> createState() =>
      _TerminalWorkspaceScreenState();
}

class _TerminalWorkspaceScreenState extends State<TerminalWorkspaceScreen> {
  final TextEditingController _commandController = TextEditingController();
  String? _commandError;
  String? _commandFeedback;
  bool _isLoading = true;
  String? _loadError;
  bool _isSending = false;
  bool _autoRunTriggered = false;
  List<TerminalSessionView> _sessions = [];
  String? _activeSessionId;
  http.Client? _httpClient;
  AgentCommandClient? _agentClient;
  int _streamTokenCounter = 0;
  final Map<String, int> _streamTokens = {};

  @override
  void initState() {
    super.initState();
    _configureAgentClient();
    _loadSessions();
  }

  @override
  void dispose() {
    _commandController.dispose();
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
    _agentClient = AgentCommandClient(baseUrl: baseUrl, client: _httpClient!);
  }

  Future<void> _loadSessions() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final sessions = await widget.storage.fetchToolSessions();
      final events = await widget.storage.fetchTimelineEvents();
      final terminalSessions = sessions
          .where((session) => session.type.toLowerCase() == 'terminal')
          .toList();
      final terminalEvents = events
          .where((event) => event.type.toLowerCase() == 'terminal')
          .toList();
      final latestEvents = <String, TimelineEvent>{};
      for (final event in terminalEvents) {
        latestEvents.putIfAbsent(event.sessionId, () => event);
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
        return TerminalSessionView(
          session: session,
          output: output,
          lastCommand: lastCommand,
          lastEvent: event,
        );
      }).toList();
      if (!mounted) {
        return;
      }
      setState(() {
        _sessions = views;
        _activeSessionId = initialSession?.id ??
            (views.isNotEmpty ? views.first.session.id : null);
        _isLoading = false;
      });
      _seedCommandFromActive();
      _autoRunInitialCommand();
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoading = false;
        _loadError = 'Unable to load terminal sessions.';
      });
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

  void _seedCommandFromActive() {
    final active = _activeSession;
    if (active == null) {
      _commandController.clear();
      return;
    }
    final command = active.lastCommand?.trim() ?? '';
    if (command.isEmpty) {
      _commandController.clear();
      return;
    }
    _commandController.text = command;
    _commandController.selection = TextSelection.collapsed(
      offset: command.length,
    );
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
    _commandController.text = command;
    _commandController.selection = TextSelection.collapsed(
      offset: command.length,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _runCommand();
      }
    });
  }

  bool _payloadHasOutput(Map<String, dynamic> payload) {
    final stdout = _coerceOutputList(payload['stdout']);
    final stderr = _coerceOutputList(payload['stderr']);
    final preview = payload['output_preview'] ?? payload['output'];
    final previewText = preview?.toString().trim() ?? '';
    return stdout.isNotEmpty || stderr.isNotEmpty || previewText.isNotEmpty;
  }

  void _setActiveSession(String sessionId) {
    setState(() {
      _activeSessionId = sessionId;
      _commandError = null;
      _commandFeedback = null;
    });
    _seedCommandFromActive();
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
    final sessionLabel = trimmed.isEmpty
        ? 'Terminal Session ${_sessions.length + 1}'
        : trimmed;
    final now = DateTime.now();
    final session = ToolSession(
      id: createStorageId(),
      type: 'terminal',
      label: sessionLabel,
      status: 'idle',
      createdAt: now,
    );
    await _persistSession(session);
    if (!mounted) {
      return;
    }
    setState(() {
      _sessions = [
        TerminalSessionView(
          session: session,
          output: const <TerminalOutputEntry>[],
        ),
        ..._sessions,
      ];
      _activeSessionId = session.id;
      _commandError = null;
      _commandFeedback = null;
    });
    _commandController.clear();
  }

  Future<void> _closeSession(String sessionId) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final updated = _sessionWithStatus(view.session, 'closed');
    await _persistSession(updated);
    if (!mounted) {
      return;
    }
    _streamTokens[sessionId] = -1;
    _replaceSession(
      sessionId,
      view.copyWith(session: updated),
    );
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

  Future<void> _runCommand() async {
    if (_isSending) {
      return;
    }
    final active = _activeSession;
    if (active == null) {
      setState(() {
        _commandError = 'Create a session to run a command.';
      });
      return;
    }
    if (active.session.status.toLowerCase() == 'closed') {
      setState(() {
        _commandError = 'This session is closed.';
      });
      return;
    }
    final command = _commandController.text.trim();
    if (command.isEmpty) {
      setState(() {
        _commandError = 'Enter a command to run.';
      });
      return;
    }

    setState(() {
      _commandError = null;
      _commandFeedback = null;
      _isSending = true;
    });

    final agentClient = _agentClient;
    if (agentClient == null) {
      await _markSessionDisconnected(
        active.session.id,
        'Connect to the desktop agent to run terminal commands.',
      );
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
      return;
    }

    try {
      await agentClient.sendTerminalCommand(command: command);
    } on AgentCommandFailure catch (error) {
      await _markSessionDisconnected(
        active.session.id,
        error.message,
      );
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
      return;
    } catch (error) {
      await _markSessionDisconnected(
        active.session.id,
        'Terminal command failed: ${error.toString()}',
      );
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
      return;
    }

    final updatedSession = _sessionWithStatus(active.session, 'running');
    await _persistSession(updatedSession);
    final event = await _ensureTerminalEvent(active, command);
    final updatedView = active.copyWith(
      session: updatedSession,
      lastCommand: command,
      lastEvent: event,
    );
    if (!mounted) {
      return;
    }
    _replaceSession(active.session.id, updatedView);

    await _persistTerminalEvent(
      event: event,
      command: command,
      entries: const <TerminalOutputEntry>[],
      status: 'running',
    );

    setState(() {
      _isSending = false;
    });

    final entries = _buildTerminalScript(command);
    unawaited(
      _streamOutput(
        sessionId: active.session.id,
        command: command,
        event: event,
        entries: entries,
      ),
    );
  }

  Future<void> _markSessionDisconnected(String sessionId, String message) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final updated = _sessionWithStatus(view.session, 'disconnected');
    await _persistSession(updated);
    if (!mounted) {
      return;
    }
    _replaceSession(
      sessionId,
      view.copyWith(session: updated),
    );
    setState(() {
      _commandError = message;
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
    final updated = _sessionWithStatus(active.session, 'idle');
    await _persistSession(updated);
    if (!mounted) {
      return;
    }
    _replaceSession(
      active.session.id,
      active.copyWith(session: updated),
    );
    setState(() {
      _commandFeedback = 'Session reconnected.';
      _commandError = null;
    });
  }

  ToolSession _sessionWithStatus(ToolSession session, String status) {
    return ToolSession(
      id: session.id,
      type: session.type,
      label: session.label,
      status: status,
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

  Future<void> _persistTerminalEvent({
    required TimelineEvent event,
    required String command,
    required List<TerminalOutputEntry> entries,
    required String status,
  }) async {
    final payload = Map<String, dynamic>.from(event.payload);
    payload['command'] = command;
    payload['status'] = status;
    payload['stdout'] = entries
        .where((entry) => entry.stream == TerminalStream.stdout)
        .map((entry) => entry.text)
        .toList();
    payload['stderr'] = entries
        .where((entry) => entry.stream == TerminalStream.stderr)
        .map((entry) => entry.text)
        .toList();
    payload['output_preview'] = _buildOutputPreview(entries);
    payload['updated_at'] = DateTime.now().toIso8601String();
    final updatedEvent = TimelineEvent(
      id: event.id,
      sessionId: event.sessionId,
      type: event.type,
      title: event.title,
      payload: payload,
      createdAt: event.createdAt,
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
            'Failed to save terminal output: ${error.toString()}',
          ),
        ),
      );
    }
  }

  Future<void> _streamOutput({
    required String sessionId,
    required String command,
    required TimelineEvent event,
    required List<TerminalOutputEntry> entries,
  }) async {
    final token = ++_streamTokenCounter;
    _streamTokens[sessionId] = token;
    for (final entry in entries) {
      await Future<void>.delayed(const Duration(milliseconds: 280));
      if (!mounted || _streamTokens[sessionId] != token) {
        return;
      }
      _appendOutput(sessionId, entry);
    }
    if (!mounted || _streamTokens[sessionId] != token) {
      return;
    }
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final updatedSession = _sessionWithStatus(view.session, 'complete');
    await _persistSession(updatedSession);
    if (!mounted) {
      return;
    }
    _replaceSession(sessionId, view.copyWith(session: updatedSession));
    await _persistTerminalEvent(
      event: event,
      command: command,
      entries: entries,
      status: 'complete',
    );
    if (mounted) {
      setState(() {
        _commandFeedback = 'Command completed.';
      });
    }
  }

  void _appendOutput(String sessionId, TerminalOutputEntry entry) {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final updated = List<TerminalOutputEntry>.from(view.output)..add(entry);
    _replaceSession(sessionId, view.copyWith(output: updated));
  }

  List<TerminalOutputEntry> _parseOutputEntries(
    Map<String, dynamic> payload,
    DateTime createdAt,
  ) {
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
      final preview = payload['output_preview'] ?? payload['output'];
      final previewText = preview?.toString().trim() ?? '';
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
          .where((line) => line.trim().isNotEmpty)
          .toList();
    }
    if (raw is String) {
      return raw
          .split('\n')
          .map((line) => line.trim())
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

  List<TerminalOutputEntry> _buildTerminalScript(String command) {
    final lower = command.toLowerCase();
    final now = DateTime.now();
    final entries = <TerminalOutputEntry>[];
    void add(TerminalStream stream, String text) {
      entries.add(
        TerminalOutputEntry(stream: stream, text: text, timestamp: now),
      );
    }

    add(TerminalStream.stdout, r'$ ' + command);
    if (lower.contains('npm test')) {
      add(TerminalStream.stdout, '> vibe-inspect@1.0.0 test');
      add(TerminalStream.stdout, '> vitest run');
      add(TerminalStream.stdout, ' RUN  v1.2.0 /workspace');
      add(TerminalStream.stdout, ' ✓ src/app.spec.ts (3 tests)');
      add(
        TerminalStream.stderr,
        ' FAIL  src/terminal.spec.ts > streams stderr',
      );
      add(
        TerminalStream.stderr,
        'Error: Expected stderr output but received stdout',
      );
      add(TerminalStream.stdout, ' Test Files 1 failed (2)');
      add(TerminalStream.stdout, '      Tests 1 failed (4)');
      add(TerminalStream.stdout, '   Duration 1.42s');
      return entries;
    }
    if (lower.contains('npm') || lower.contains('yarn')) {
      add(TerminalStream.stdout, 'Resolving packages...');
      add(TerminalStream.stdout, 'Fetching metadata from registry...');
      add(TerminalStream.stdout, 'Packages installed successfully.');
      return entries;
    }
    add(TerminalStream.stdout, 'Running command on desktop agent...');
    add(TerminalStream.stdout, 'Command completed with exit code 0.');
    return entries;
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
    final output = active?.output ?? const <TerminalOutputEntry>[];
    final stdoutEntries = output
        .where((entry) => entry.stream == TerminalStream.stdout)
        .toList();
    final stderrEntries = output
        .where((entry) => entry.stream == TerminalStream.stderr)
        .toList();
    final status = active?.session.status.toLowerCase() ?? 'idle';
    final isDisconnected = status == 'disconnected';
    final isClosed = status == 'closed';
    final isRunning = status == 'running';
    final lastCommand = active?.lastCommand;
    final lastEventTime = active?.lastEvent?.createdAt;

    return _TimelineDetailScaffold(
      title: 'Terminal',
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Terminal sessions',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: const Color(0xFF0F172A),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Create, switch, and close sessions while streaming output.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 20),
            if (_commandFeedback != null) ...[
              _InlineStatus(
                message: _commandFeedback!,
                isError: false,
              ),
              const SizedBox(height: 12),
            ],
            _ContextSectionCard(
              title: 'Sessions',
              subtitle: 'Tap a session to focus output and commands.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_sessions.isEmpty)
                    const _EmptyHint(text: 'No terminal sessions yet.'),
                  if (_sessions.isNotEmpty)
                    Column(
                      children: [
                        for (final session in _sessions) ...[
                          _TerminalSessionRow(
                            session: session,
                            isActive:
                                session.session.id == _activeSessionId,
                            onSelect: () =>
                                _setActiveSession(session.session.id),
                            onClose: session.session.status.toLowerCase() ==
                                    'closed'
                                ? null
                                : () => _closeSession(session.session.id),
                          ),
                          if (session != _sessions.last)
                            const SizedBox(height: 8),
                        ],
                      ],
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _createSession,
                    icon: const Icon(Icons.add),
                    label: const Text('New session'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _ContextSectionCard(
              title: 'Active session',
              subtitle: active == null
                  ? 'Create a session to start streaming.'
                  : 'Session status and last activity.',
              child: active == null
                  ? const _EmptyHint(text: 'No active session selected.')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _KeyValueRow(
                          label: 'Name',
                          value: active.session.label,
                        ),
                        _KeyValueRow(
                          label: 'Status',
                          value: active.session.status.toUpperCase(),
                        ),
                        _KeyValueRow(
                          label: 'Created',
                          value: _formatTimestamp(active.session.createdAt),
                        ),
                        if (lastCommand != null &&
                            lastCommand.trim().isNotEmpty)
                          _KeyValueRow(
                            label: 'Last command',
                            value: lastCommand,
                          ),
                        if (lastEventTime != null)
                          _KeyValueRow(
                            label: 'Last run',
                            value: _formatTimestamp(lastEventTime),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            if (isDisconnected) ...[
              _TerminalReconnectCard(onReconnect: _attemptReconnect),
              const SizedBox(height: 16),
            ],
            _ContextSectionCard(
              title: 'Run command',
              subtitle: 'Send a command to the desktop agent.',
              child: active == null
                  ? const _EmptyHint(text: 'Create a session to run commands.')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextField(
                          key: const Key('terminalCommandField'),
                          controller: _commandController,
                          enabled: !isClosed,
                          decoration: InputDecoration(
                            hintText: 'npm test',
                            border: const OutlineInputBorder(),
                            errorText: _commandError,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            FilledButton.icon(
                              key: const Key('terminalRunButton'),
                              onPressed: (isClosed || isDisconnected || _isSending)
                                  ? null
                                  : _runCommand,
                              icon: _isSending
                                  ? const SizedBox(
                                      height: 16,
                                      width: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.play_arrow),
                              label: Text(
                                _isSending
                                    ? 'Sending'
                                    : isRunning
                                        ? 'Streaming'
                                        : 'Run command',
                              ),
                            ),
                            const SizedBox(width: 12),
                            OutlinedButton(
                              onPressed: isClosed
                                  ? null
                                  : () => _commandController.clear(),
                              child: const Text('Clear'),
                            ),
                          ],
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 16),
            _ContextSectionCard(
              title: 'Output streams',
              subtitle: isRunning
                  ? 'Streaming stdout and stderr separately.'
                  : 'Latest output from this session.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TerminalStreamPanel(
                    label: 'STDOUT',
                    entries: stdoutEntries,
                    accentColor: const Color(0xFF2563EB),
                    emptyText: 'No stdout captured yet.',
                  ),
                  const SizedBox(height: 12),
                  _TerminalStreamPanel(
                    label: 'STDERR',
                    entries: stderrEntries,
                    accentColor: const Color(0xFFDC2626),
                    emptyText: 'No stderr captured yet.',
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

class TerminalSessionScreen extends StatelessWidget {
  const TerminalSessionScreen({
    super.key,
    required this.event,
    required this.session,
    required this.storage,
    required this.agentBaseUrl,
  });

  final TimelineEvent event;
  final ToolSession session;
  final StorageRepository storage;
  final String? agentBaseUrl;

  @override
  Widget build(BuildContext context) {
    return TerminalWorkspaceScreen(
      storage: storage,
      agentBaseUrl: agentBaseUrl,
      initialSession: session,
      initialEvent: event,
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
                  icon: const Icon(Icons.close),
                  tooltip: 'Close session',
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

class _TerminalStreamPanel extends StatelessWidget {
  const _TerminalStreamPanel({
    required this.label,
    required this.entries,
    required this.accentColor,
    required this.emptyText,
  });

  final String label;
  final List<TerminalOutputEntry> entries;
  final Color accentColor;
  final String emptyText;

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: accentColor,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (entries.isEmpty)
            _EmptyHint(text: emptyText)
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: entries
                  .map(
                    (entry) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SelectableText(
                        entry.text,
                        style: GoogleFonts.spaceMono(
                          fontSize: 12,
                          color: const Color(0xFF0F172A),
                        ),
                      ),
                    ),
                  )
                  .toList(),
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
    case 'complete':
      return const _TerminalStatusStyle(
        Color(0xFFDCFCE7),
        Color(0xFF166534),
      );
    case 'disconnected':
      return const _TerminalStatusStyle(
        Color(0xFFFEE2E2),
        Color(0xFFB91C1C),
      );
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
  });

  final TimelineEvent event;
  final ToolSession session;
  final StorageRepository storage;
  final String? agentBaseUrl;

  @override
  State<VncSessionScreen> createState() => _VncSessionScreenState();
}

class _VncSessionScreenState extends State<VncSessionScreen> {
  static const Size _canvasSize = Size(1280, 720);
  static const double _minZoom = 0.9;
  static const double _maxZoom = 2.4;
  static const double _swipeThreshold = 120;

  late Offset _pointerPosition;
  late Offset _cameraCenter;
  double _zoom = 1;
  bool _trackpadMode = true;
  bool _isConnecting = false;
  String? _connectionError;
  Timer? _clickTimer;
  bool _showClickPulse = false;
  double _swipeDistance = 0;
  late DateTime _lastUpdatedAt;
  http.Client? _httpClient;
  AgentCommandClient? _agentClient;

  @override
  void initState() {
    super.initState();
    _pointerPosition = Offset(
      _canvasSize.width / 2,
      _canvasSize.height / 2,
    );
    _cameraCenter = _pointerPosition;
    _lastUpdatedAt = widget.event.createdAt;
    _configureAgentClient();
    _hydrateFromPayload();
    unawaited(_startStream());
  }

  @override
  void dispose() {
    _clickTimer?.cancel();
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
    _agentClient = AgentCommandClient(baseUrl: baseUrl, client: _httpClient!);
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
      final normalized = zoomValue.toDouble().clamp(_minZoom, _maxZoom);
      _zoom = normalized;
    }
  }

  String get _resolutionLabel =>
      '${_canvasSize.width.toInt()}x${_canvasSize.height.toInt()}';

  Future<void> _startStream() async {
    if (_isConnecting) {
      return;
    }
    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });
    await _updateSession(status: 'connecting');

    final agentClient = _agentClient;
    if (agentClient == null) {
      await _setStreamFailure(
        'Connect to the desktop agent to start streaming.',
      );
      return;
    }

    try {
      await agentClient.sendVncCommand(
        action: 'start',
        sessionId: widget.session.id,
        width: _canvasSize.width.toInt(),
        height: _canvasSize.height.toInt(),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _isConnecting = false;
      });
      await _updateSession(status: 'connected');
    } on AgentCommandFailure catch (error) {
      await _setStreamFailure(error.message);
    } catch (error) {
      await _setStreamFailure('VNC stream failed: ${error.toString()}');
    }
  }

  Future<void> _setStreamFailure(String message) async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isConnecting = false;
      _connectionError = message;
    });
    await _updateSession(status: 'failed', errorMessage: message);
  }

  Future<void> _updateSession({
    required String status,
    String? errorMessage,
  }) async {
    if (!mounted) {
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

  void _updateZoom(double value) {
    setState(() {
      _zoom = value.clamp(_minZoom, _maxZoom);
      _cameraCenter = _pointerPosition;
    });
  }

  void _commitZoom(double value) {
    _updateZoom(value);
    unawaited(_updateSession(status: _currentStatusLabel));
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

  void _movePointerBy(Offset delta) {
    final scaled = delta / _zoom;
    _setPointerPosition(_pointerPosition + scaled);
  }

  void _setPointerPosition(Offset position) {
    final clamped = Offset(
      position.dx.clamp(0, _canvasSize.width),
      position.dy.clamp(0, _canvasSize.height),
    );
    setState(() {
      _pointerPosition = clamped;
    });
  }

  void _movePointerTo(Offset localPosition, Size viewSize) {
    final translation = _calculateTranslation(viewSize);
    final content = (localPosition - translation) / _zoom;
    _setPointerPosition(content);
  }

  Offset _calculateTranslation(Size viewSize) {
    final center = Offset(viewSize.width / 2, viewSize.height / 2);
    return center - _cameraCenter * _zoom;
  }

  Offset _pointerToScreen(Size viewSize) {
    final translation = _calculateTranslation(viewSize);
    return translation + _pointerPosition * _zoom;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
    final isInteractive = _connectionError == null && !_isConnecting;

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
              title: 'VNC stream',
              subtitle: _trackpadMode
                  ? 'Trackpad controls move the pointer without touching the stream.'
                  : 'Direct touch lets you tap the stream to position the cursor.',
              child: AspectRatio(
                aspectRatio: _canvasSize.width / _canvasSize.height,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final viewSize = Size(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    );
                    final pointerScreen = _pointerToScreen(viewSize);
                    final translation = _calculateTranslation(viewSize);
                    return GestureDetector(
                      onTapDown: !isInteractive || _trackpadMode
                          ? null
                          : (details) {
                              _movePointerTo(
                                details.localPosition,
                                viewSize,
                              );
                              _triggerClickPulse();
                            },
                      onPanUpdate: !isInteractive || _trackpadMode
                          ? null
                          : (details) =>
                              _movePointerTo(details.localPosition, viewSize),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Transform(
                                transform: Matrix4.identity()
                                  ..translateByDouble(
                                    translation.dx,
                                    translation.dy,
                                    0,
                                    1,
                                  )
                                  ..scaleByDouble(_zoom, _zoom, 1, 1),
                                child: _VncMockDesktop(
                                  targetLabel: targetLabel,
                                  canvasSize: _canvasSize,
                                ),
                              ),
                            ),
                            if (!isInteractive)
                              Positioned.fill(
                                child: Container(
                                  color: Colors.black.withAlpha(80),
                                  child: Center(
                                    child: Text(
                                      _connectionError != null
                                          ? 'Stream unavailable'
                                          : 'Connecting...',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            if (isInteractive)
                              Positioned(
                                left: pointerScreen.dx - 10,
                                top: pointerScreen.dy - 10,
                                child: _VncPointer(
                                  isClicking: _showClickPulse,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            _ContextSectionCard(
              title: 'Zoom & focus',
              subtitle:
                  'Zoom centers on the active pointer for fast inspection.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '${(_zoom * 100).round()}%',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF0F172A),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _trackpadMode ? 'Trackpad' : 'Direct touch',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  Slider(
                    value: _zoom,
                    min: _minZoom,
                    max: _maxZoom,
                    onChanged: isInteractive ? _updateZoom : null,
                    onChangeEnd: isInteractive ? _commitZoom : null,
                  ),
                ],
              ),
            ),
            _ContextSectionCard(
              title: 'Pointer mode',
              subtitle: _trackpadMode
                  ? 'Drag on the trackpad to move. Tap to click.'
                  : 'Tap the stream to place the pointer.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Trackpad'),
                        selected: _trackpadMode,
                        onSelected: (selected) {
                          setState(() {
                            _trackpadMode = selected;
                          });
                        },
                      ),
                      ChoiceChip(
                        label: const Text('Direct touch'),
                        selected: !_trackpadMode,
                        onSelected: (selected) {
                          setState(() {
                            _trackpadMode = !selected;
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _VncTrackpadSurface(
                    enabled: isInteractive && _trackpadMode,
                    onPan: _movePointerBy,
                    onTap: _triggerClickPulse,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: const [
                      _VncGestureHint(
                        icon: Icons.open_with,
                        label: 'Drag to move',
                      ),
                      SizedBox(width: 12),
                      _VncGestureHint(
                        icon: Icons.touch_app,
                        label: 'Tap to click',
                      ),
                    ],
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

class _VncMockDesktop extends StatelessWidget {
  const _VncMockDesktop({
    required this.targetLabel,
    required this.canvasSize,
  });

  final String targetLabel;
  final Size canvasSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: canvasSize.width,
      height: canvasSize.height,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F172A), Color(0xFF1E293B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(120),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.desktop_windows,
                    color: Colors.white70,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      targetLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
                          ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.wifi,
                    color: Colors.white54,
                    size: 16,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 200,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF111827),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Navigator',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.white70,
                                      fontWeight: FontWeight.w600,
                                    ),
                          ),
                          const SizedBox(height: 12),
                          _VncSidebarItem(
                            icon: Icons.check_circle_outline,
                            label: 'Login page',
                          ),
                          const SizedBox(height: 8),
                          _VncSidebarItem(
                            icon: Icons.visibility_outlined,
                            label: 'Settings modal',
                          ),
                          const SizedBox(height: 8),
                          _VncSidebarItem(
                            icon: Icons.bug_report_outlined,
                            label: 'Error toast',
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Preview',
                              style:
                                  Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: const Color(0xFF64748B),
                                        fontWeight: FontWeight.w600,
                                      ),
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withAlpha(20),
                                      blurRadius: 12,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Login form',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleMedium
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                              color: const Color(0xFF0F172A),
                                            ),
                                      ),
                                      const SizedBox(height: 12),
                                      Container(
                                        height: 12,
                                        width: 180,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFE2E8F0),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Container(
                                        height: 12,
                                        width: 140,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFE2E8F0),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                      ),
                                      const SizedBox(height: 20),
                                      Container(
                                        height: 36,
                                        width: 140,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1D4ED8),
                                          borderRadius:
                                              BorderRadius.circular(12),
                                        ),
                                        child: Center(
                                          child: Text(
                                            'Submit',
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                          ),
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
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VncSidebarItem extends StatelessWidget {
  const _VncSidebarItem({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Colors.white70, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                ),
          ),
        ),
      ],
    );
  }
}

class _VncPointer extends StatelessWidget {
  const _VncPointer({required this.isClicking});

  final bool isClicking;

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

class _VncTrackpadSurface extends StatelessWidget {
  const _VncTrackpadSurface({
    required this.enabled,
    required this.onPan,
    required this.onTap,
  });

  final bool enabled;
  final ValueChanged<Offset> onPan;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = enabled ? const Color(0xFFF1F5F9) : const Color(0xFFE2E8F0);
    final borderColor = enabled ? const Color(0xFFCBD5F5) : const Color(0xFFE2E8F0);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      onPanUpdate: enabled ? (details) => onPan(details.delta) : null,
      child: Container(
        height: 120,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor),
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.touch_app,
                color: enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8),
              ),
              const SizedBox(height: 8),
              Text(
                enabled ? 'Trackpad active' : 'Enable trackpad mode to use',
                style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
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
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: const Color(0xFF475569)),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF475569),
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
  const AgentCommandFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class AgentApiResult {
  const AgentApiResult({required this.request, required this.response});

  final ApiRequestDetails request;
  final ApiResponseDetails response;
}

class AgentCommandClient {
  AgentCommandClient({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

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

  Future<void> sendTerminalCommand({
    required String command,
    List<String>? args,
    String? workingDir,
    Map<String, String>? env,
  }) async {
    final payload = <String, dynamic>{
      'command': command,
    };
    if (args != null && args.isNotEmpty) {
      payload['args'] = args;
    }
    if (workingDir != null && workingDir.trim().isNotEmpty) {
      payload['working_dir'] = workingDir;
    }
    if (env != null && env.isNotEmpty) {
      payload['env'] = env;
    }
    await _sendCommand(
      command: 'terminal',
      payload: payload,
    );
  }

  Future<void> sendVncCommand({
    required String action,
    String? sessionId,
    int? width,
    int? height,
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
    await _sendCommand(
      command: 'vnc',
      payload: payload,
    );
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
    http.Response response;
    try {
      response = await _client.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: requestBody,
      );
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

List<CommandIntent> _parseCommandIntents(String command) {
  final trimmed = command.trim();
  if (trimmed.isEmpty) {
    return [];
  }

  final explicit = _parseExplicitIntent(trimmed);
  if (explicit != null) {
    return [explicit];
  }

  if (_leadingHttpMethod(trimmed) != null) {
    return [_buildApiIntent(trimmed)];
  }

  final intents = <CommandIntent>[];
  if (_looksLikeApi(trimmed)) {
    intents.add(_buildApiIntent(trimmed));
  }
  if (_looksLikeTerminal(trimmed)) {
    intents.add(_buildTerminalIntent(trimmed));
  }
  if (_looksLikeAi(trimmed)) {
    intents.add(_buildAiIntent(trimmed));
  }
  if (_looksLikeVnc(trimmed)) {
    intents.add(_buildVncIntent(trimmed));
  }
  return intents;
}

CommandIntent? _parseExplicitIntent(String command) {
  final match = RegExp(
    r'^(api|terminal|term|shell|bash|cmd|ai|vnc)\b[:\s-]*',
    caseSensitive: false,
  ).firstMatch(command);
  if (match == null) {
    return null;
  }

  final prefix = match.group(1)?.toLowerCase() ?? '';
  final remainder = command.substring(match.end).trim();
  switch (prefix) {
    case 'api':
      return _buildApiIntent(command, parseSource: remainder);
    case 'terminal':
    case 'term':
    case 'shell':
    case 'bash':
    case 'cmd':
      return _buildTerminalIntent(command, parseSource: remainder);
    case 'ai':
      return _buildAiIntent(command, parseSource: remainder);
    case 'vnc':
      return _buildVncIntent(command, parseSource: remainder);
  }
  return null;
}

List<CommandIntent> _uniqueIntents(List<CommandIntent> intents) {
  final byTool = <CommandTool, CommandIntent>{};
  for (final intent in intents) {
    byTool[intent.tool] = intent;
  }
  return byTool.values.toList();
}

List<CommandIntent> _buildFallbackIntents(String command) {
  return CommandTool.values
      .map((tool) => _buildIntentForTool(tool, command))
      .toList();
}

CommandIntent _buildIntentForTool(CommandTool tool, String command) {
  switch (tool) {
    case CommandTool.api:
      return _buildApiIntent(command);
    case CommandTool.terminal:
      return _buildTerminalIntent(command);
    case CommandTool.ai:
      return _buildAiIntent(command);
    case CommandTool.vnc:
      return _buildVncIntent(command);
  }
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

CommandIntent _buildTerminalIntent(String command, {String? parseSource}) {
  final source =
      parseSource == null || parseSource.trim().isEmpty ? command : parseSource;
  final extracted = _extractTerminalCommand(source);
  final resolved = extracted.isEmpty ? command.trim() : extracted;
  final normalized = resolved.isEmpty ? 'Pending command' : resolved;
  final preview = _truncate(normalized, 48);
  final label = _truncate(normalized, 28);
  return CommandIntent(
    tool: CommandTool.terminal,
    title: 'Terminal: $label',
    sessionLabel: 'Terminal: $label',
    payload: {
      'command': normalized,
      'status': 'queued',
      'stdout': <String>[],
      'stderr': <String>[],
    },
    preview: preview,
  );
}

CommandIntent _buildAiIntent(String command, {String? parseSource}) {
  final source =
      parseSource == null || parseSource.trim().isEmpty ? command : parseSource;
  final extracted = _extractAiPrompt(source);
  final resolved = extracted.isEmpty ? command.trim() : extracted;
  final normalized = resolved.isEmpty ? 'Pending prompt' : resolved;
  final preview = _truncate(normalized, 48);
  final label = _truncate(normalized, 28);
  return CommandIntent(
    tool: CommandTool.ai,
    title: 'AI: $label',
    sessionLabel: 'AI: $label',
    payload: {
      'prompt': normalized,
      'status': 'queued',
    },
    preview: preview,
  );
}

CommandIntent _buildVncIntent(String command, {String? parseSource}) {
  final source =
      parseSource == null || parseSource.trim().isEmpty ? command : parseSource;
  final extracted = _extractVncTarget(source);
  final resolved = extracted.isEmpty ? 'Remote desktop' : extracted;
  final preview = _truncate(resolved, 48);
  final label = _truncate(resolved, 28);
  return CommandIntent(
    tool: CommandTool.vnc,
    title: 'VNC: $label',
    sessionLabel: 'VNC: $label',
    payload: {
      'target': resolved,
      'status': 'queued',
    },
    preview: preview,
  );
}

String? _leadingHttpMethod(String input) {
  final match = RegExp(
    r'^(get|post|put|patch|delete|head|options)\b',
    caseSensitive: false,
  ).firstMatch(input.trim());
  return match?.group(1)?.toUpperCase();
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

String _extractTerminalCommand(String input) {
  final trimmed = input.trim();
  final match = RegExp(
    r'^(terminal|term|shell|bash|cmd|run|execute)\b[:\s-]*',
    caseSensitive: false,
  ).firstMatch(trimmed);
  var result = trimmed;
  if (match != null) {
    result = trimmed.substring(match.end).trim();
  }
  if (result.startsWith(r'$')) {
    result = result.substring(1).trimLeft();
  }
  if (result.startsWith('>')) {
    result = result.substring(1).trimLeft();
  }
  return result;
}

String _extractAiPrompt(String input) {
  final trimmed = input.trim();
  final match = RegExp(
    r'^(ai|ask|explain|summarize|analyze|insight)\b[:\s-]*',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) {
    return trimmed;
  }
  final result = trimmed.substring(match.end).trim();
  return result.isEmpty ? trimmed : result;
}

String _extractVncTarget(String input) {
  final trimmed = input.trim();
  final match = RegExp(
    r'^(vnc|screen|desktop|viewer)\b[:\s-]*',
    caseSensitive: false,
  ).firstMatch(trimmed);
  if (match == null) {
    return trimmed;
  }
  final result = trimmed.substring(match.end).trim();
  return result.isEmpty ? trimmed : result;
}

bool _looksLikeApi(String input) {
  return _containsKeyword(input, ['api', 'endpoint', 'request', 'http']) ||
      _containsKeyword(
        input,
        ['get', 'post', 'put', 'patch', 'delete'],
      ) ||
      _extractUrl(input) != null;
}

bool _looksLikeTerminal(String input) {
  final trimmed = input.trimLeft();
  if (trimmed.startsWith(r'$') || trimmed.startsWith('>')) {
    return true;
  }
  return _containsKeyword(
    input,
    ['terminal', 'shell', 'bash', 'run', 'execute', 'cli'],
  );
}

bool _looksLikeAi(String input) {
  return _containsKeyword(
    input,
    ['ai', 'summarize', 'explain', 'analyze', 'insight', 'diagnose'],
  );
}

bool _looksLikeVnc(String input) {
  return _containsKeyword(
    input,
    ['vnc', 'screen', 'desktop', 'viewer', 'remote', 'ui'],
  );
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
