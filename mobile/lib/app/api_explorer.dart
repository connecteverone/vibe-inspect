part of '../main.dart';

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
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'API request failed.',
      );
      _logErrorDetails('api_request', presentation);
      final message = _formatErrorMessage(presentation);
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
    } catch (error) {
      if (!mounted) {
        return;
      }
      final presentation = _presentUnexpectedFailure(
        error,
        fallbackMessage: 'Request failed. Please try again.',
      );
      _logErrorDetails('api_request', presentation);
      final message = _formatErrorMessage(presentation);
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
