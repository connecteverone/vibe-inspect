part of '../main.dart';

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
  String? _pairingErrorCode;
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
  static const String _expiredTokenMessage =
      'Token expired. Scan a new token to continue.';
  static const String _scanQrTokenButtonLabel = 'Scan QR token';
  static const String _connectFixedTokenButtonLabel = 'Connect via fixed token';
  static const String _useEndpointButtonLabel = 'Use endpoint';
  static const String _scanNewTokenButtonLabel = 'Scan new token';
  static const String _retryCurrentTokenButtonLabel = 'Retry current token';
  static const String _clearSelectedEndpointButtonLabel =
      'Clear selected endpoint';
  static const String _rescanQrTokenButtonLabel = 'Rescan QR token';

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

    final scanned = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const _QrScannerScreen()));
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
          title: const Text('Connect via fixed token'),
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
      final resolvedClientId = await _resolveClientId();
      final normalizedClientId =
          resolvedClientId != null && resolvedClientId.trim().isNotEmpty
          ? resolvedClientId.trim()
          : null;
      final client = AgentCommandClient(
        baseUrl: url,
        client: httpClient,
        authToken: token,
        clientId: normalizedClientId,
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
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Failed to connect with fixed token.',
      );
      _logErrorDetails('manual_login', presentation);
      if (!mounted) {
        return;
      }
      setState(() {
        _pairingStatus = 'Failed to connect with fixed token.';
        _pairingStatusIsError = true;
        _pairingDetailStatus = _formatErrorMessage(presentation);
        _pairingDetailStatusIsError = true;
      });
    } catch (error) {
      final presentation = _presentUnexpectedFailure(
        error,
        fallbackMessage: 'Failed to connect with fixed token.',
      );
      _logErrorDetails('manual_login', presentation);
      if (!mounted) {
        return;
      }
      setState(() {
        _pairingStatus = 'Failed to connect with fixed token.';
        _pairingStatusIsError = true;
        _pairingDetailStatus = _formatErrorMessage(presentation);
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
      _pairingErrorCode = null;
      _manualAgentUrl = null;
      _isPairing = false;
      _pairingAgentUrl = null;
      _pairingUsesTunnel = null;
      if (parsed != null && parsed.isExpired) {
        _scanError = _expiredTokenMessage;
      } else if (parsed != null && !parsed.isProtocolSupported) {
        _scanError = _unsupportedProtocolMessage(parsed);
      }
    });
    if (parsed != null && !parsed.isExpired && parsed.isProtocolSupported) {
      await _attemptAutoPairing(parsed);
    }
  }

  Future<void> _attemptAutoPairing(PairingPayload payload) async {
    if (!payload.isProtocolSupported) {
      if (mounted) {
        setState(() {
          _isPairing = false;
          _pairingStatus = _unsupportedProtocolMessage(payload);
          _pairingStatusIsError = true;
        });
      }
      return;
    }
    if (_isPairing) {
      return;
    }
    setState(() {
      _isPairing = true;
      _pairingStatus = 'Contacting the desktop agent...';
      _pairingStatusIsError = false;
      _pairingDetailStatus = null;
      _pairingDetailStatusIsError = false;
      _pairingErrorCode = null;
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
          _pairingUsesTunnel = result.agentUrl == null
              ? null
              : _isTunnelUrl(payload, result.agentUrl!);
          _pairingStatus = 'Waiting for desktop approval.';
          _pairingStatusIsError = false;
          _pairingDetailStatus = null;
          _pairingDetailStatusIsError = false;
          _pairingErrorCode = null;
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
          _pairingErrorCode = result.errorCode?.trim();
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
        _scanError = _expiredTokenMessage;
      });
      if (widget.enableConnectivityRefresh) {
        await _refreshAgentConnectivity();
      }
      return;
    }
    if (!payload.isProtocolSupported) {
      setState(() {
        _scanError = _unsupportedProtocolMessage(payload);
      });
      return;
    }
    await _attemptAutoPairing(payload);
    if (widget.enableConnectivityRefresh) {
      await _refreshAgentConnectivity();
    }
  }

  void _startPendingPolling(PairingPayload payload, String agentUrl) {
    _pairingPoller?.cancel();
    _pairingPoller = Timer.periodic(const Duration(seconds: 2), (_) async {
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
          _pairingStatus = _expiredTokenMessage;
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
          _pairingStatus = result.message ?? 'Desktop approval check failed.';
          _pairingStatusIsError = true;
          _pairingDetailStatus = result.detail;
          _pairingDetailStatusIsError =
              result.detail != null && result.detail!.trim().isNotEmpty;
          _pairingErrorCode = result.errorCode?.trim();
        });
      }
    } finally {
      _isPendingPollActive = false;
    }
  }

  Future<void> _completePairing(
    PairingPayload payload,
    String agentUrl, {
    String? authToken,
    String? deviceId,
  }) async {
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
    final resolvedDeviceId =
        deviceId ??
        (payload.deviceId?.trim().isNotEmpty == true ? payload.deviceId : null);
    setState(() {
      _pairingAgentUrl = agentUrl;
      _pairingUsesTunnel = _isTunnelUrl(payload, agentUrl);
      _pairingStatus = 'Connected.';
      _pairingStatusIsError = false;
      _isPairing = false;
      _pairingDetailStatus = null;
      _pairingDetailStatusIsError = false;
      _pairingErrorCode = null;
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
        message:
            selection.message ??
            payload.tunnelError ??
            'No desktop URL found in the pairing payload.',
        detail: selection.detail,
      );
    }
    final errors = <String>[];
    final errorCodes = <String>[];
    final attemptDetails = <String>[];
    for (final url in candidates) {
      final result = await _confirmPairingAtUrl(payload, url);
      if (result.status != _PairingAttemptStatus.failed) {
        return result;
      }
      if (result.message != null) {
        errors.add(result.message!);
      }
      final errorCode = result.errorCode?.trim();
      if (errorCode != null && errorCode.isNotEmpty) {
        errorCodes.add(errorCode);
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
      errorCode: errorCodes.isNotEmpty ? errorCodes.first : null,
    );
  }

  Future<_PairingCandidateSelection> _selectPairingCandidates(
    PairingPayload payload,
  ) async {
    final transportCandidates = payload.transports
        .where((transport) => transport.enabled)
        .toList();
    final localUrls = transportCandidates
        .where((transport) => transport.isLan)
        .map((transport) => transport.url.trim())
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList();
    final remoteUrls = transportCandidates
        .where((transport) => transport.isRemote)
        .map((transport) => transport.url.trim())
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList();
    if (localUrls.isEmpty) {
      localUrls.addAll(payload.localUrls);
    }
    if (remoteUrls.isEmpty) {
      final tunnelUrl = payload.tunnelUrl?.trim() ?? '';
      final frpUrl = payload.frpUrl?.trim() ?? '';
      if (tunnelUrl.isNotEmpty) {
        remoteUrls.add(tunnelUrl);
      }
      if (frpUrl.isNotEmpty && frpUrl != tunnelUrl) {
        remoteUrls.add(frpUrl);
      }
    }
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
      final candidates = <String>[normalizedManual, ...rest, ...remoteUrls];
      return _PairingCandidateSelection(
        candidates: candidates,
        message: 'Using manually selected endpoint.',
      );
    }
    if (_forceTunnel) {
      if (remoteUrls.isNotEmpty) {
        return _PairingCandidateSelection(candidates: remoteUrls);
      }
      final message =
          payload.tunnelError != null && payload.tunnelError!.trim().isNotEmpty
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

    final fallbackMessage =
        payload.tunnelError != null && payload.tunnelError!.trim().isNotEmpty
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
    final reason = message == null || message.trim().isEmpty
        ? 'Failed.'
        : message;
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
    final lines = diagnostics
        .map((result) {
          final label = _shortUrlLabel(result.url);
          final requestLabel = _appendPath(result.url, '/health');
          final reason = result.reason ?? 'Unreachable.';
          return '- $label ($requestLabel): $reason';
        })
        .join('\n');
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
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
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

  _PairingErrorInfo? _extractPairingErrorInfo(String body) {
    if (body.trim().isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map) {
          final rawMessage = error['message'];
          final rawCode = error['code'];
          final message = rawMessage?.toString().trim();
          final code = rawCode?.toString().trim();
          if ((message != null && message.isNotEmpty) ||
              (code != null && code.isNotEmpty)) {
            return _PairingErrorInfo(message: message, code: code);
          }
        }
      }
    } catch (_) {}
    return null;
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
    } catch (error) {
      final presentation = _buildErrorPresentation(
        code: 'invalid_url',
        message: 'Invalid agent URL: $baseUrl',
        endpoint: baseUrl,
        details: error.toString(),
      );
      _logErrorDetails('pairing_url', presentation);
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: _formatErrorMessage(presentation),
        agentUrl: baseUrl,
        errorCode: presentation.code,
      );
    }
    http.Response response;
    try {
      final resolvedClientId = await _resolveClientId();
      final requestBody = <String, dynamic>{
        'token': payload.token,
        'secret': payload.secret,
        'client_name': _resolveDeviceName(),
      };
      final protocolVersion = payload.protocolVersion?.trim();
      if (protocolVersion != null && protocolVersion.isNotEmpty) {
        requestBody['protocol_version'] = protocolVersion;
      }
      final nonce = payload.nonce?.trim();
      if (nonce != null && nonce.isNotEmpty) {
        requestBody['nonce'] = nonce;
      }
      if (resolvedClientId != null && resolvedClientId.trim().isNotEmpty) {
        requestBody['client_id'] = resolvedClientId.trim();
      }
      response = await client
          .post(
            uri,
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 4));
    } catch (error) {
      final detail = _describeNetworkError(error);
      final presentation = _buildErrorPresentation(
        code: 'connection_failed',
        fallbackMessage: _describeReachFailure(baseUrl, error),
        endpoint: baseUrl,
        details: error.toString(),
      );
      _logErrorDetails('pairing_reach', presentation);
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: _formatErrorMessage(presentation),
        detail: detail,
        agentUrl: baseUrl,
        errorCode: presentation.code,
      );
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final errorInfo = _extractPairingErrorInfo(response.body);
      final presentation = _buildErrorPresentation(
        code: errorInfo?.code,
        message: errorInfo?.message,
        fallbackMessage: 'Desktop agent returned HTTP ${response.statusCode}.',
        endpoint: baseUrl,
        details: errorInfo?.message ?? response.body,
      );
      _logErrorDetails('pairing_http', presentation);
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: _formatErrorMessage(presentation),
        detail:
            errorInfo?.message != null &&
                errorInfo!.message!.trim().isNotEmpty &&
                errorInfo.message != presentation.message
            ? errorInfo.message
            : null,
        agentUrl: baseUrl,
        errorCode: presentation.code,
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      final presentation = _buildErrorPresentation(
        code: 'invalid_json',
        fallbackMessage: 'Desktop agent response was not JSON.',
        endpoint: baseUrl,
        details: response.body,
      );
      _logErrorDetails('pairing_json', presentation);
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: _formatErrorMessage(presentation),
        agentUrl: baseUrl,
        errorCode: presentation.code,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      final presentation = _buildErrorPresentation(
        code: 'invalid_response',
        fallbackMessage: 'Desktop agent response was malformed.',
        endpoint: baseUrl,
        details: decoded.toString(),
      );
      _logErrorDetails('pairing_response', presentation);
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: _formatErrorMessage(presentation),
        agentUrl: baseUrl,
        errorCode: presentation.code,
      );
    }

    final status = decoded['status']?.toString();
    if (status == 'connected') {
      final authTokenRaw =
          decoded['auth_token']?.toString().trim() ??
          decoded['authToken']?.toString().trim();
      final resolvedAuthToken = authTokenRaw != null && authTokenRaw.isNotEmpty
          ? authTokenRaw
          : null;
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
      final resolvedDeviceId = deviceIdRaw != null && deviceIdRaw.isNotEmpty
          ? deviceIdRaw
          : null;
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
      final presentation = _buildErrorPresentation(
        code: error['code']?.toString(),
        message: error['message']?.toString(),
        fallbackMessage: 'Desktop agent returned an error.',
        endpoint: baseUrl,
        details: error,
      );
      _logErrorDetails('pairing_error', presentation);
      return _PairingAttemptResult(
        status: _PairingAttemptStatus.failed,
        message: _formatErrorMessage(presentation),
        detail: error['message']?.toString(),
        agentUrl: baseUrl,
        errorCode: presentation.code,
      );
    }

    final presentation = _buildErrorPresentation(
      code: 'invalid_response',
      fallbackMessage: 'Desktop agent returned an unexpected response.',
      endpoint: baseUrl,
      details: decoded,
    );
    _logErrorDetails('pairing_unexpected', presentation);
    return _PairingAttemptResult(
      status: _PairingAttemptStatus.failed,
      message: _formatErrorMessage(presentation),
      agentUrl: baseUrl,
      errorCode: presentation.code,
    );
  }

  Uri _pairingUri(String baseUrl) {
    final base = Uri.parse(baseUrl);
    if (base.scheme.isEmpty) {
      throw const FormatException(
        'Agent URL must include a scheme (https://).',
      );
    }
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final confirmPath = basePath.isEmpty
        ? '/pairing/confirm'
        : '$basePath/pairing/confirm';
    return base.replace(path: confirmPath);
  }

  Uri _healthUri(String baseUrl) {
    final base = Uri.parse(baseUrl);
    if (base.scheme.isEmpty) {
      throw const FormatException(
        'Agent URL must include a scheme (https://).',
      );
    }
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final healthPath = basePath.isEmpty ? '/health' : '$basePath/health';
    return base.replace(path: healthPath);
  }

  bool _isTunnelUrl(PairingPayload payload, String agentUrl) {
    if (payload.transports.isNotEmpty) {
      final normalizedTarget = _normalizeUrl(agentUrl);
      for (final transport in payload.transports) {
        if (!transport.enabled || !transport.isRemote) {
          continue;
        }
        if (_normalizeUrl(transport.url) == normalizedTarget) {
          return true;
        }
      }
    }
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
      _pairingErrorCode = null;
      _isPairing = false;
      _pairingAgentUrl = null;
      _pairingUsesTunnel = null;
    });
  }

  Future<void> _resetAndScanNewToken() async {
    _resetPairing();
    await _scanQrPayload();
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
          content: Text('Failed to save local history: ${error.toString()}'),
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
      final exportJson = const JsonEncoder.withIndent(
        '  ',
      ).convert(bundle.toJson());
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
            child: SingleChildScrollView(child: SelectableText(exportJson)),
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

  String _unsupportedProtocolMessage(PairingPayload payload) {
    final version = payload.protocolVersionNormalized ?? 'unknown';
    return 'Pairing protocol $version is unsupported. Update mobile/desktop app and regenerate QR.';
  }

  String? _extractErrorCodeFromStatusText(String? value) {
    if (value == null) {
      return null;
    }
    final match = RegExp(
      r'\(code:\s*([a-z0-9_]+)\)',
      caseSensitive: false,
    ).firstMatch(value);
    final code = match?.group(1)?.trim().toLowerCase();
    if (code == null || code.isEmpty) {
      return null;
    }
    return code;
  }

  String? _resolvedPairingErrorCode() {
    final directCode = _pairingErrorCode?.trim().toLowerCase();
    if (directCode != null && directCode.isNotEmpty) {
      return directCode;
    }
    final statusCode = _extractErrorCodeFromStatusText(_pairingStatus);
    if (statusCode != null) {
      return statusCode;
    }
    return _extractErrorCodeFromStatusText(_pairingDetailStatus);
  }

  String? _pairingRecoveryHintForCode(String? code) {
    switch (code) {
      case 'missing_nonce':
        return '请在桌面端点击“New handshake”重新生成二维码后再扫码。';
      default:
        return null;
    }
  }

  bool _requiresRegenerateQrAction(String? code) {
    switch (code) {
      case 'missing_nonce':
      case 'nonce_mismatch':
      case 'token_mismatch':
      case 'secret_mismatch':
      case 'token_expired':
        return true;
      default:
        return false;
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
      final ssid = await info.getWifiName().timeout(const Duration(seconds: 1));
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
        return _ReachabilityResult(url: baseUrl, reachable: true, reason: 'OK');
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
    final remoteUrls = {
      if (agent.frpUrl != null && agent.frpUrl!.trim().isNotEmpty)
        agent.frpUrl!.trim(),
      if (agent.tunnelUrl != null && agent.tunnelUrl!.trim().isNotEmpty)
        agent.tunnelUrl!.trim(),
    }.toList();

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
      fallbackMessage: (localUrls.isEmpty && remoteUrls.isEmpty)
          ? 'No LAN/FRP endpoints available.'
          : null,
    );
    return _AgentRouteResolution(
      record: agent.copyWith(status: 'offline'),
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
      final localIps = _parseLocalIps(
        identity['local_ips'] ?? identity['localIps'],
      );
      final transportEndpoints = _parseTransportEndpoints(
        identity['transports'],
      );
      final transportLocalUrls = transportEndpoints
          .where((transport) => transport.enabled && transport.isLan)
          .map((transport) => transport.url.trim())
          .where((url) => url.isNotEmpty)
          .toSet()
          .toList();
      final localUrlsFromPayload = _parseLocalUrls(
        identity['local_urls'] ??
            identity['localUrls'] ??
            identity['local_url'],
      );
      final localUrls = transportLocalUrls.isNotEmpty
          ? transportLocalUrls
          : localUrlsFromPayload;
      final frpTransportUrl = transportEndpoints
          .where((transport) => transport.enabled && transport.type == 'frp')
          .map((transport) => transport.url.trim())
          .firstWhere((url) => url.isNotEmpty, orElse: () => '');
      final tunTransportUrl = transportEndpoints
          .where((transport) => transport.enabled && transport.type == 'tun')
          .map((transport) => transport.url.trim())
          .firstWhere((url) => url.isNotEmpty, orElse: () => '');
      final frpUrl = frpTransportUrl.isNotEmpty
          ? frpTransportUrl
          : identity['frp_url']?.toString() ?? identity['frpUrl']?.toString();
      final tunnelUrl = tunTransportUrl.isNotEmpty
          ? tunTransportUrl
          : identity['tunnel_url']?.toString() ??
                identity['tunnelUrl']?.toString();
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

  Future<String?> _resolveClientId() async {
    final current = _clientId;
    if (current != null && current.trim().isNotEmpty) {
      return current;
    }
    await _ensureClientId();
    final updated = _clientId;
    if (updated != null && updated.trim().isNotEmpty) {
      return updated;
    }
    return null;
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
          _activeAgentId = _connections.isNotEmpty
              ? _connections.first.id
              : null;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to remove agent: ${error.toString()}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAgents = _connections.isNotEmpty;
    final pairingErrorCode = _resolvedPairingErrorCode();
    final pairingRecoveryHint = _pairingRecoveryHintForCode(pairingErrorCode);
    final showRegenerateQrAction =
        _requiresRegenerateQrAction(pairingErrorCode) && !_isPairing;
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
                    description: 'Scan a pairing token to add a desktop agent.',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FilledButton.icon(
                          key: const Key('scanQrButton'),
                          onPressed: _scanQrPayload,
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text(_scanQrTokenButtonLabel),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _connectWithFixedToken,
                          icon: const Icon(Icons.vpn_key),
                          label: const Text(_connectFixedTokenButtonLabel),
                        ),
                        const SizedBox(height: 16),
                        if (_payload == null)
                          const Text('No pairing token scanned yet.')
                        else
                          _PairingTokenDetails(payload: _payload!),
                        if (_payload != null &&
                            _payload!.localUrls.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            'LAN endpoints',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
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
                                        child: const Text(
                                          _useEndpointButtonLabel,
                                        ),
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
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: const Color(0xFF64748B),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _payload!.frpUrl!,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(color: const Color(0xFF0F172A)),
                          ),
                        ],
                        if (_scanError != null) ...[
                          const SizedBox(height: 12),
                          _InlineStatus(message: _scanError!, isError: true),
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
                            onPressed: _resetAndScanNewToken,
                            child: const Text(_scanNewTokenButtonLabel),
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
                                  style: Theme.of(context).textTheme.bodyMedium
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
                              child: const Text(
                                _clearSelectedEndpointButtonLabel,
                              ),
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
                        if (pairingRecoveryHint != null) ...[
                          const SizedBox(height: 8),
                          _InlineStatus(
                            key: const Key('pairingRecoveryHint'),
                            message: pairingRecoveryHint,
                            isError: true,
                          ),
                        ],
                        if (showRegenerateQrAction) ...[
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: const Key('regenerateQrButton'),
                              onPressed: _scanQrPayload,
                              icon: const Icon(Icons.qr_code_2),
                              label: const Text(_rescanQrTokenButtonLabel),
                            ),
                          ),
                        ],
                        if (_pairingAgentUrl != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Agent: $_pairingAgentUrl',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: const Color(0xFF64748B),
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          if (_pairingUsesTunnel != null) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Mode: ${_pairingUsesTunnel! ? 'Tunnel' : 'Local network'}',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
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
                          label: const Text(_retryCurrentTokenButtonLabel),
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
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Use the cloud tunnel even when the agent is on the same LAN.',
                                    style: Theme.of(context).textTheme.bodySmall
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
                            message:
                                _payload?.tunnelError ??
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
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: const Color(0xFF64748B)),
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
