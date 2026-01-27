import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  runApp(const VibeInspectApp());
}

class VibeInspectApp extends StatelessWidget {
  const VibeInspectApp({super.key});

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
      home: const PairingScreen(),
    );
  }
}

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  PairingPayload? _payload;
  PairedConnection? _connection;
  String? _scanError;
  String? _secretError;
  final TextEditingController _secretController = TextEditingController();

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

  void _confirmSecret() {
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
