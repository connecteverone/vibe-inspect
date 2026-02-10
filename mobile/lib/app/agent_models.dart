part of '../main.dart';

class VncSessionInfo {
  const VncSessionInfo({
    required this.sessionId,
    required this.token,
    required this.wsPath,
    this.quicPort,
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
  final int? quicPort;
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
    final quicPort =
        int.tryParse(payload['quic_port']?.toString() ?? '') ??
        int.tryParse(payload['quicPort']?.toString() ?? '');
    final width = int.tryParse(payload['width']?.toString() ?? '') ?? 0;
    final height = int.tryParse(payload['height']?.toString() ?? '') ?? 0;
    final displayIndex = int.tryParse(
      payload['display_index']?.toString() ?? '',
    );
    final inputWidth = int.tryParse(payload['input_width']?.toString() ?? '');
    final inputHeight = int.tryParse(payload['input_height']?.toString() ?? '');
    final inputOriginX = double.tryParse(
      payload['input_origin_x']?.toString() ?? '',
    );
    final inputOriginY = double.tryParse(
      payload['input_origin_y']?.toString() ?? '',
    );
    final inputScaleX = double.tryParse(
      payload['input_scale_x']?.toString() ?? '',
    );
    final inputScaleY = double.tryParse(
      payload['input_scale_y']?.toString() ?? '',
    );
    final screenWidth = int.tryParse(payload['screen_width']?.toString() ?? '');
    final screenHeight = int.tryParse(
      payload['screen_height']?.toString() ?? '',
    );
    if (sessionId.isEmpty || token.isEmpty) {
      throw const AgentCommandFailure(
        'VNC session response missing fields.',
        code: 'invalid_response',
      );
    }
    return VncSessionInfo(
      sessionId: sessionId,
      token: token,
      wsPath: wsPath,
      quicPort: quicPort,
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
    final closedReason =
        closedReasonRaw != null && closedReasonRaw.trim().isNotEmpty
        ? closedReasonRaw.trim()
        : null;
    if (id.isEmpty) {
      throw const AgentCommandFailure(
        'Terminal session missing id.',
        code: 'invalid_response',
      );
    }
    final rawLabel = payload['label']?.toString() ?? '';
    final resolvedLabel = rawLabel.trim().isNotEmpty
        ? rawLabel.trim()
        : 'Terminal ${_truncate(id, 6)}';
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


class AgentWsTicket {
  const AgentWsTicket({
    required this.token,
    required this.scope,
    required this.expiresAt,
  });

  final String token;
  final String scope;
  final DateTime expiresAt;

  factory AgentWsTicket.fromPayload(Map<String, dynamic> payload) {
    final token = payload['token']?.toString().trim() ?? '';
    if (token.isEmpty) {
      throw const AgentCommandFailure(
        'WebSocket ticket missing token.',
        code: 'invalid_response',
      );
    }
    final scope = payload['scope']?.toString().trim() ?? '';
    final expiresRaw = payload['expires_at'];
    int expiresEpoch = 0;
    if (expiresRaw is int) {
      expiresEpoch = expiresRaw;
    } else if (expiresRaw is num) {
      expiresEpoch = expiresRaw.toInt();
    } else if (expiresRaw is String) {
      expiresEpoch = int.tryParse(expiresRaw) ?? 0;
    }
    final expiresAt = expiresEpoch > 0
        ? DateTime.fromMillisecondsSinceEpoch(expiresEpoch * 1000)
        : DateTime.now().add(const Duration(seconds: 20));
    return AgentWsTicket(
      token: token,
      scope: scope,
      expiresAt: expiresAt,
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
      payload: {'method': method, 'url': url, 'headers': headers, 'body': body},
    );
    final payload = response.payload;
    if (payload == null) {
      throw AgentCommandFailure(
        'Agent response missing payload.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
      );
    }
    final requestPayload = payload['request'];
    final responsePayload = payload['response'];
    if (requestPayload is! Map || responsePayload is! Map) {
      throw AgentCommandFailure(
        'Agent response missing request or response details.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
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
    final response = await _sendCommand(command: 'identity', payload: const {});
    final payload = response.payload;
    if (payload is! Map<String, dynamic>) {
      throw AgentCommandFailure(
        'Agent identity response missing payload.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
      );
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
          results.add(
            RemoteTerminalSession.fromPayload(Map<String, dynamic>.from(entry)),
          );
        } catch (_) {
          // Ignore malformed session entries.
        }
      }
    }
    return results;
  }

  Future<AgentWsTicket> createWsTicket({
    required String scope,
    String? sessionId,
  }) async {
    final payload = <String, dynamic>{'scope': scope};
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['session_id'] = sessionId.trim();
    }
    final response = await _sendCommand(command: 'ws_ticket', payload: payload);
    final responsePayload = response.payload;
    if (responsePayload is! Map<String, dynamic>) {
      throw AgentCommandFailure(
        'Agent websocket ticket response missing payload.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
      );
    }
    return AgentWsTicket.fromPayload(responsePayload);
  }

  Future<Map<String, dynamic>> sendTerminalAction({
    required String action,
    String? sessionId,
    String? label,
    String? input,
    List<int>? inputBytes,
    int? cols,
    int? rows,
    int? since,
    int? limit,
    int? notifySince,
    String? workingDir,
    Map<String, String>? env,
  }) async {
    final payload = <String, dynamic>{'action': action};
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      payload['session_id'] = sessionId;
    }
    if (label != null && label.trim().isNotEmpty) {
      payload['label'] = label.trim();
    }
    if (input != null && input.isNotEmpty) {
      payload['input'] = input;
    }
    if (inputBytes != null && inputBytes.isNotEmpty) {
      payload['input_b64'] = base64Encode(inputBytes);
      payload.remove('input');
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
    if (notifySince != null) {
      payload['notify_since'] = notifySince;
    }
    if (workingDir != null && workingDir.trim().isNotEmpty) {
      payload['working_dir'] = workingDir;
    }
    if (env != null && env.isNotEmpty) {
      payload['env'] = env;
    }
    final response = await _sendCommand(command: 'terminal', payload: payload);
    final responsePayload = response.payload;
    if (responsePayload is! Map<String, dynamic>) {
      throw AgentCommandFailure(
        'Agent response missing payload.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
      );
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
    final payload = <String, dynamic>{'action': action};
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
    final response = await _sendCommand(command: 'vnc', payload: payload);
    final payloadData = response.payload;
    if (payloadData == null) {
      throw AgentCommandFailure(
        'VNC response missing payload.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
      );
    }
    return VncSessionInfo.fromPayload(Map<String, dynamic>.from(payloadData));
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
    final payload = <String, dynamic>{'action': action};
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
    final response = await _sendCommand(command: 'roi', payload: payload);
    final payloadData = response.payload;
    if (payloadData == null) {
      throw AgentCommandFailure(
        'ROI response missing payload.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
      );
    }
    return RoiSessionInfo.fromPayload(Map<String, dynamic>.from(payloadData));
  }

  Future<List<VncDisplayInfo>> fetchVncDisplays() async {
    final response = await _sendCommand(
      command: 'vnc',
      payload: const {'action': 'displays'},
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
        .map(
          (item) => VncDisplayInfo.fromPayload(
            Map<String, dynamic>.from(item as Map),
          ),
        )
        .toList();
  }

  Future<_AgentCommandResponse> _sendCommand({
    required String command,
    required Map<String, dynamic> payload,
  }) async {
    final uri = _commandUri();
    final requestId = createStorageId();
    final requestBody = jsonEncode({
      'request_id': requestId,
      'command': command,
      'payload': payload,
    });
    final headers = <String, String>{'Content-Type': 'application/json'};
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
      response = await _client
          .post(uri, headers: headers, body: requestBody)
          .timeout(const Duration(seconds: 6));
    } catch (error) {
      throw AgentCommandFailure(
        'Failed to reach desktop agent.',
        code: 'connection_failed',
        endpoint: uri.toString(),
        requestId: requestId,
        details: error.toString(),
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AgentCommandFailure(
        'Desktop agent returned HTTP ${response.statusCode}.',
        code: 'http_error',
        endpoint: uri.toString(),
        requestId: requestId,
        details: {'status': response.statusCode},
      );
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw AgentCommandFailure(
        'Agent response was not JSON.',
        code: 'invalid_json',
        endpoint: uri.toString(),
        requestId: requestId,
        details: response.body,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw AgentCommandFailure(
        'Agent response was malformed.',
        code: 'invalid_response',
        endpoint: uri.toString(),
        requestId: requestId,
        details: decoded.toString(),
      );
    }
    final parsed = _AgentCommandResponse.fromJson(decoded);
    if (!parsed.isOk) {
      throw AgentCommandFailure(
        parsed.error?.message ?? 'Agent command failed.',
        code: parsed.error?.code ?? 'command_failed',
        endpoint: uri.toString(),
        requestId: parsed.requestId.isNotEmpty ? parsed.requestId : requestId,
        details: parsed.error?.details,
      );
    }
    return parsed;
  }

  Uri _commandUri() {
    final base = Uri.parse(baseUrl);
    if (base.scheme.isEmpty) {
      throw const AgentCommandFailure(
        'Agent URL must include a scheme (https://).',
        code: 'invalid_url',
      );
    }
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final commandPath = basePath.isEmpty ? '/command' : '$basePath/command';
    return base.replace(path: commandPath);
  }

  Future<RemoteSessionInfo> sendRemoteCommand({
    required String action,
    String? sessionId,
    int? width,
    int? height,
    int? displayIndex,
  }) async {
    final payload = <String, dynamic>{'action': action};
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
    final response = await _sendCommand(command: 'remote', payload: payload);
    final payloadData = response.payload;
    if (payloadData == null) {
      throw AgentCommandFailure(
        'Remote response missing payload.',
        code: 'invalid_response',
        endpoint: _commandUri().toString(),
        requestId: response.requestId,
      );
    }
    return RemoteSessionInfo.fromPayload(
      Map<String, dynamic>.from(payloadData),
    );
  }
}

class RemoteSessionInfo {
  const RemoteSessionInfo({
    required this.sessionId,
    required this.backend,
    this.connectUri,
    this.token,
    this.displayIndex,
    this.width,
    this.height,
    this.quicPort,
    this.codecPreference,
    this.hwcodecEnabled,
    this.capabilities,
    this.inputPreferences,
  });

  final String sessionId;
  final String backend;
  final String? connectUri;
  final String? token;
  final int? displayIndex;
  final int? width;
  final int? height;
  final int? quicPort;
  final String? codecPreference;
  final bool? hwcodecEnabled;
  final RemoteCodecCapabilities? capabilities;
  final RemoteInputPreferences? inputPreferences;

  factory RemoteSessionInfo.fromPayload(Map<String, dynamic> payload) {
    final sessionPayload = payload['session'] is Map
        ? Map<String, dynamic>.from(payload['session'] as Map)
        : payload;
    bool? parseBool(dynamic value) {
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == 'yes' || normalized == 'y') {
          return true;
        }
        if (normalized == 'false' || normalized == 'no' || normalized == 'n') {
          return false;
        }
        final parsed = int.tryParse(normalized);
        if (parsed != null) return parsed != 0;
      }
      return null;
    }

    RemoteCodecCapabilities? capabilities;
    final capabilitiesPayload = sessionPayload['capabilities'];
    if (capabilitiesPayload is Map) {
      capabilities = RemoteCodecCapabilities.fromPayload(
        Map<String, dynamic>.from(capabilitiesPayload),
      );
    }
    RemoteInputPreferences? inputPreferences;
    final inputPreferencesPayload = sessionPayload['input_preferences'];
    if (inputPreferencesPayload is Map) {
      inputPreferences = RemoteInputPreferences.fromPayload(
        Map<String, dynamic>.from(inputPreferencesPayload),
      );
    }
    return RemoteSessionInfo(
      sessionId: sessionPayload['session_id']?.toString() ?? '',
      backend: sessionPayload['backend']?.toString() ?? 'rustdesk',
      connectUri: sessionPayload['connect_uri']?.toString(),
      token: sessionPayload['token']?.toString(),
      displayIndex: sessionPayload['display_index'] is int
          ? sessionPayload['display_index'] as int
          : int.tryParse(sessionPayload['display_index']?.toString() ?? ''),
      width: sessionPayload['width'] is int
          ? sessionPayload['width'] as int
          : int.tryParse(sessionPayload['width']?.toString() ?? ''),
      height: sessionPayload['height'] is int
          ? sessionPayload['height'] as int
          : int.tryParse(sessionPayload['height']?.toString() ?? ''),
      quicPort: sessionPayload['quic_port'] is int
          ? sessionPayload['quic_port'] as int
          : int.tryParse(sessionPayload['quic_port']?.toString() ?? ''),
      codecPreference: sessionPayload['codec_preference']?.toString(),
      hwcodecEnabled: parseBool(sessionPayload['hwcodec']),
      capabilities: capabilities,
      inputPreferences: inputPreferences,
    );
  }
}

class RemoteInputPreferences {
  const RemoteInputPreferences({this.naturalScroll});

  final bool? naturalScroll;

  factory RemoteInputPreferences.fromPayload(Map<String, dynamic> payload) {
    bool? parseBool(dynamic value) {
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == 'yes' || normalized == 'y') {
          return true;
        }
        if (normalized == 'false' || normalized == 'no' || normalized == 'n') {
          return false;
        }
        final parsed = int.tryParse(normalized);
        if (parsed != null) return parsed != 0;
      }
      return null;
    }

    return RemoteInputPreferences(
      naturalScroll: parseBool(payload['natural_scroll']),
    );
  }
}

class RemoteCodecCapabilities {
  const RemoteCodecCapabilities({
    required this.h264,
    required this.h265,
    required this.av1,
    required this.zeroCopy,
  });

  final bool h264;
  final bool h265;
  final bool av1;
  final bool zeroCopy;

  String get summary {
    final codecs = <String>[];
    if (h264) codecs.add('H264');
    if (h265) codecs.add('H265');
    if (av1) codecs.add('AV1');
    if (codecs.isEmpty) return 'None';
    return codecs.join('/');
  }

  factory RemoteCodecCapabilities.fromPayload(Map<String, dynamic> payload) {
    bool readBool(dynamic value) {
      if (value is bool) return value;
      if (value is num) return value != 0;
      if (value is String) {
        final normalized = value.trim().toLowerCase();
        if (normalized == 'true' || normalized == 'yes' || normalized == 'y') {
          return true;
        }
        if (normalized == 'false' || normalized == 'no' || normalized == 'n') {
          return false;
        }
        final parsed = int.tryParse(normalized);
        if (parsed != null) return parsed != 0;
      }
      return false;
    }

    return RemoteCodecCapabilities(
      h264: readBool(payload['h264']),
      h265: readBool(payload['h265']),
      av1: readBool(payload['av1']),
      zeroCopy: readBool(payload['zero_copy']),
    );
  }
}

class _AgentCommandResponse {
  const _AgentCommandResponse({
    required this.status,
    required this.requestId,
    this.payload,
    this.error,
  });

  final String status;
  final String requestId;
  final Map<String, dynamic>? payload;
  final _AgentCommandError? error;

  bool get isOk => status.toLowerCase() == 'ok';

  factory _AgentCommandResponse.fromJson(Map<String, dynamic> json) {
    return _AgentCommandResponse(
      status: json['status']?.toString() ?? 'error',
      requestId:
          json['request_id']?.toString() ?? json['requestId']?.toString() ?? '',
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
  const _AgentCommandError({
    required this.code,
    required this.message,
    this.details,
  });

  final String code;
  final String message;
  final Map<String, dynamic>? details;

  factory _AgentCommandError.fromJson(Map<String, dynamic> json) {
    return _AgentCommandError(
      code: json['code']?.toString() ?? 'unknown',
      message: json['message']?.toString() ?? 'Agent error.',
      details: json['details'] is Map
          ? Map<String, dynamic>.from(json['details'] as Map)
          : null,
    );
  }
}

enum CommandTool { api, terminal, ai, vnc, remote }

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
      case CommandTool.remote:
        return 'Remote Control';
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
      case CommandTool.remote:
        return 'remote';
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
  final source = parseSource == null || parseSource.trim().isEmpty
      ? command
      : parseSource;
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
    return raw
        .map((entry) => entry.toString().trim())
        .where((entry) => entry.isNotEmpty)
        .toList();
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
  static const Set<String> supportedProtocolVersions = {'1.0', '1.1'};

  const PairingPayload({
    required this.token,
    required this.secret,
    this.protocolVersion,
    this.nonce,
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
    this.transports = const [],
    this.requiresApproval = false,
  });

  final String token;
  final String secret;
  final String? protocolVersion;
  final String? nonce;
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
  final List<TransportEndpointModel> transports;
  final bool requiresApproval;

  String? get protocolVersionNormalized {
    final value = protocolVersion?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  bool get isProtocolSupported {
    final value = protocolVersionNormalized;
    if (value == null) {
      return true;
    }
    return supportedProtocolVersions.contains(value);
  }

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

    final token =
        data['token']?.toString() ??
        data['pairing_token']?.toString() ??
        data['pairingToken']?.toString();
    final secret =
        data['secret']?.toString() ??
        data['pairing_secret']?.toString() ??
        data['pairingSecret']?.toString();
    final protocolVersion =
        data['protocol_version']?.toString() ??
        data['protocolVersion']?.toString();
    final nonce = data['nonce']?.toString();
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
    final localIps = _parseLocalIps(data['local_ips'] ?? data['localIps']);
    final tunnelUrl =
        data['tunnel_url']?.toString() ?? data['tunnelUrl']?.toString();
    final frpUrl = data['frp_url']?.toString() ?? data['frpUrl']?.toString();
    final roiQuicPort = _parsePort(
      data['roi_quic_port'] ?? data['roiQuicPort'],
    );
    final tunnelError =
        data['tunnel_error']?.toString() ?? data['tunnelError']?.toString();
    final transports = _parseTransportEndpoints(data['transports']);
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
      protocolVersion: protocolVersion,
      nonce: nonce,
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
      transports: transports,
      requiresApproval: requiresApproval,
    );
  }

  List<String> get preferredUrls {
    if (transports.isNotEmpty) {
      final urls = transports
          .where((transport) => transport.enabled)
          .map((transport) => transport.url.trim())
          .where((url) => url.isNotEmpty)
          .toSet()
          .toList();
      if (urls.isNotEmpty) {
        return urls;
      }
    }
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

class TransportEndpointModel {
  const TransportEndpointModel({
    required this.type,
    required this.url,
    required this.priority,
    required this.probeTimeoutMs,
    required this.enabled,
  });

  final String type;
  final String url;
  final int priority;
  final int probeTimeoutMs;
  final bool enabled;

  bool get isLan => type.trim().toLowerCase() == 'lan';

  bool get isRemote {
    final normalized = type.trim().toLowerCase();
    return normalized == 'frp' || normalized == 'tun';
  }
}

List<TransportEndpointModel> _parseTransportEndpoints(dynamic raw) {
  if (raw is! List) {
    return const [];
  }
  final parsed = <TransportEndpointModel>[];
  for (final item in raw) {
    if (item is! Map) {
      continue;
    }
    final map = Map<String, dynamic>.from(item);
    final type = map['type']?.toString().trim().toLowerCase() ?? '';
    final url = map['url']?.toString().trim() ?? '';
    if (type.isEmpty || url.isEmpty) {
      continue;
    }
    final priority = int.tryParse(map['priority']?.toString() ?? '') ?? 0;
    final probeTimeoutMs =
        int.tryParse(map['probe_timeout_ms']?.toString() ?? '') ??
        int.tryParse(map['probeTimeoutMs']?.toString() ?? '') ??
        (type == 'lan' ? 2000 : 3000);
    final enabledRaw = map['enabled'];
    final enabled = enabledRaw == null ? true : _parseBool(enabledRaw);
    parsed.add(
      TransportEndpointModel(
        type: type,
        url: url,
        priority: priority,
        probeTimeoutMs: probeTimeoutMs,
        enabled: enabled,
      ),
    );
  }
  parsed.sort((a, b) {
    final priorityCompare = b.priority.compareTo(a.priority);
    if (priorityCompare != 0) {
      return priorityCompare;
    }
    return a.url.compareTo(b.url);
  });
  return parsed;
}

class _ManualLoginInput {
  const _ManualLoginInput({required this.url, required this.token});

  final String url;
  final String token;
}

class _PairingErrorInfo {
  const _PairingErrorInfo({this.message, this.code});

  final String? message;
  final String? code;
}

enum _PairingAttemptStatus { connected, pending, failed }

class _PairingAttemptResult {
  const _PairingAttemptResult({
    required this.status,
    this.message,
    this.detail,
    this.errorCode,
    this.agentUrl,
    this.authToken,
    this.deviceId,
  });

  final _PairingAttemptStatus status;
  final String? message;
  final String? detail;
  final String? errorCode;
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
  const _AgentRouteResolution({required this.record, this.errorDetail});

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
