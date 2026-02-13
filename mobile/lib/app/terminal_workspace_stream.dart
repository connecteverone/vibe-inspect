part of '../main.dart';

extension _TerminalWorkspaceStream on _TerminalWorkspaceScreenState {
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
    String? wsTicket;
    final agentClient = _agentClient;
    if (agentClient != null) {
      try {
        final ticket = await agentClient.createWsTicket(
          scope: 'terminal_ws',
          sessionId: active.session.id,
        );
        if (ticket.expiresAt.isAfter(DateTime.now())) {
          wsTicket = ticket.token;
        }
      } on AgentCommandFailure catch (error) {
        final presentation = _presentAgentFailure(
          error,
          fallbackMessage: 'Unable to create websocket ticket.',
        );
        _logErrorDetails('terminal_ws_ticket', presentation);
      } catch (_) {
        // Fallback to auth token query path for compatibility.
      }
    }
    final uri = _terminalWsUri(baseUrl, active.session.id, wsTicket: wsTicket);
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
    _terminalKeepaliveTimer = Timer.periodic(const Duration(seconds: 12), (_) {
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
    });
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
    _terminalReconnectAttempts = (_terminalReconnectAttempts + 1).clamp(1, 6);
    final seconds = 1 << (_terminalReconnectAttempts - 1);
    final delay = Duration(seconds: seconds > 12 ? 12 : seconds);
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
    if (_handleTerminalControlEvent(sessionId, decoded)) {
      _terminalReconnectAttempts = 0;
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

  bool _handleTerminalControlEvent(
    String sessionId,
    Map<String, dynamic> payload,
  ) {
    final action = payload['action']?.toString().toLowerCase() ?? '';
    if (action.isEmpty) {
      return false;
    }

    switch (action) {
      case 'stream_paused':
        final reason = payload['reason']?.toString().trim();
        final retryAfterMs = payload['retry_after_ms'];
        final retrySeconds = retryAfterMs is num
            ? (retryAfterMs / 1000).ceil().clamp(1, 30)
            : 1;
        final suffix = reason == null || reason.isEmpty ? '' : ' ($reason)';
        _setTerminalStatusMessage(
          'Terminal stream paused$suffix, retrying in ${retrySeconds}s.',
        );
        return true;
      case 'stream_resumed':
        if (sessionId == _activeSessionId) {
          _updateState(() {
            _statusMessage = null;
            _statusIsError = false;
          });
        }
        return true;
      case 'session_warning':
        final message = payload['message']?.toString().trim() ?? '';
        final reason = payload['reason']?.toString().toLowerCase() ?? '';
        if (message.isNotEmpty) {
          _setTerminalStatusMessage(
            message,
            isError: reason == 'payload_too_large',
          );
        }
        return true;
      case 'request_error':
        final error = payload['error'];
        if (error is Map) {
          final message = error['message']?.toString().trim() ?? '';
          if (message.isNotEmpty) {
            _setTerminalStatusMessage(message, isError: true);
          }
        }
        return true;
      default:
        return false;
    }
  }

  Future<void> _loadSessions() async {
    _updateState(() {
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
            final status = session.status.toLowerCase();
            if (_isTerminalClosed(status) ||
                !_shouldCloseMissingRemote(status)) {
              merged.add(session);
            } else {
              final closedSession = _sessionWithStatus(session, 'closed');
              await widget.storage.insertToolSession(closedSession);
              merged.add(closedSession);
              closedReasons[session.id] = _missingRemoteSessionReason;
            }
            continue;
          }
          final remoteStatus = remote.status.trim().isNotEmpty
              ? remote.status
              : session.status;
          final remoteLabel = remote.label.trim().isNotEmpty
              ? remote.label
              : session.label;
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
        remoteError =
            remoteResult.errorMessage ?? 'Unable to load terminal sessions.';
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
        final parsedOutput = event == null
            ? <TerminalOutputEntry>[]
            : _parseOutputEntries(event.payload, event.createdAt);
        final output = _sanitizeTerminalEntries(session.id, parsedOutput);
        final lastCommand = event?.payload['command']?.toString();
        final nextSeq = event == null ? 0 : _parseNextSeq(event.payload);
        final notificationSeq = event == null
            ? 0
            : _parseNotificationSeq(event.payload);
        final exitCode = event == null ? null : _parseExitCode(event.payload);
        return TerminalSessionView(
          session: session,
          output: output,
          nextSeq: nextSeq,
          notificationSeq: notificationSeq,
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
      _updateState(() {
        _sessions = views;
        _activeSessionId =
            initialSession?.id ??
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
      _updateState(() {
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
        notifySince: view.notificationSeq,
      );
      await _applyTerminalPayload(
        sessionId: view.session.id,
        payload: payload,
        event: view.lastEvent,
        command: view.lastCommand,
      );
      return true;
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Unable to load terminal session.',
      );
      _logErrorDetails('terminal_status', presentation);
      await _markSessionDisconnected(
        view.session.id,
        _formatErrorMessage(presentation),
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
      await _applyTerminalPayload(sessionId: session.id, payload: payload);
      return true;
    } on AgentCommandFailure catch (error) {
      if (error.code == 'session_exists') {
        final view = _sessionById(session.id);
        if (view != null) {
          return _attachRemoteSession(view);
        }
      }
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Unable to start terminal session.',
      );
      _logErrorDetails('terminal_start', presentation);
      await _markSessionDisconnected(
        session.id,
        _formatErrorMessage(presentation),
      );
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
      if (force) {
        final snapshotPayload = await agentClient.sendTerminalAction(
          action: 'status',
          sessionId: active.session.id,
          notifySince: active.notificationSeq,
        );
        await _applyTerminalPayload(
          sessionId: active.session.id,
          payload: snapshotPayload,
          event: active.lastEvent,
          command: active.lastCommand,
          preferSnapshot: true,
        );
      }
      final latest = _sessionById(active.session.id) ?? active;
      final payload = await agentClient.sendTerminalAction(
        action: 'poll',
        sessionId: latest.session.id,
        since: _terminalSince(latest.nextSeq),
        limit: _maxOutputEntries,
        notifySince: latest.notificationSeq,
      );
      await _applyTerminalPayload(
        sessionId: latest.session.id,
        payload: payload,
        event: latest.lastEvent,
        command: latest.lastCommand,
      );
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Unable to refresh terminal output.',
      );
      _logErrorDetails('terminal_poll', presentation);
      await _markSessionDisconnected(
        active.session.id,
        _formatErrorMessage(presentation),
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
    _updateState(() {
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
                        final canDisconnect =
                            status != 'closed' &&
                            status != 'killed' &&
                            status != 'exited' &&
                            status != 'disconnected' &&
                            status != 'error';
                        return _TerminalSessionRow(
                          session: session,
                          isActive: session.session.id == _activeSessionId,
                          onSelect: () {
                            Navigator.of(sheetContext).pop();
                            _setActiveSession(session.session.id);
                          },
                          onClose: canDisconnect
                              ? () {
                                  Navigator.of(sheetContext).pop();
                                  unawaited(_closeSession(session.session.id));
                                }
                              : null,
                          onDelete: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(_deleteSession(session.session.id));
                          },
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
    _updateState(() {
      _sessions = [
        TerminalSessionView(
          session: session,
          output: const <TerminalOutputEntry>[],
        ),
        ..._sessions,
      ];
      _activeSessionId = session.id;
      _terminals = {..._terminals, session.id: terminal};
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _renameActiveSession() async {
    final active = _activeSession;
    if (active == null) {
      _setTerminalStatusMessage('Select a session to rename.', isError: true);
      return;
    }
    await _renameSession(active);
  }

  Future<void> _deleteActiveSession() async {
    final active = _activeSession;
    if (active == null) {
      _setTerminalStatusMessage('Select a session to delete.', isError: true);
      return;
    }
    await _deleteSession(active.session.id);
  }

  Future<void> _deleteSession(String sessionId) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final status = view.session.status.toLowerCase();
        final isRunning = status == 'running' || status == 'connected';
        final title = isRunning
            ? 'Delete running session?'
            : 'Delete terminal session?';
        final message = isRunning
            ? 'This will stop the running session and delete its saved history from mobile and desktop.'
            : 'This will delete this session and its saved history.';
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirm != true) {
      return;
    }

    final agentClient = _agentClient;
    if (agentClient != null) {
      try {
        await agentClient.sendTerminalAction(
          action: 'delete',
          sessionId: sessionId,
        );
      } on AgentCommandFailure catch (error) {
        if ((error.code ?? '').toLowerCase() != 'session_not_found') {
          final presentation = _presentAgentFailure(
            error,
            fallbackMessage: 'Failed to delete session.',
          );
          _logErrorDetails('terminal_delete', presentation);
          _showSessionLabelError(_formatErrorMessage(presentation));
          return;
        }
      } catch (error) {
        final presentation = _presentUnexpectedFailure(
          error,
          fallbackMessage: 'Failed to delete session.',
        );
        _logErrorDetails('terminal_delete', presentation);
        _showSessionLabelError(_formatErrorMessage(presentation));
        return;
      }
    }

    final removed = await _removeSessionFromWorkspace(sessionId);
    if (removed) {
      _setTerminalStatusMessage('Session deleted.');
    }
  }

  Future<bool> _removeSessionFromWorkspace(String sessionId) async {
    final activeBefore = _activeSessionId;
    final wasActive = activeBefore == sessionId;
    final remaining = _sessions
        .where((entry) => entry.session.id != sessionId)
        .toList();
    String? nextActiveId = activeBefore;
    if (remaining.isEmpty) {
      nextActiveId = null;
    } else if (wasActive ||
        activeBefore == null ||
        !remaining.any((entry) => entry.session.id == activeBefore)) {
      nextActiveId = remaining.first.session.id;
    }

    try {
      await widget.storage.deleteToolSession(sessionId);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to delete terminal session: ${error.toString()}',
            ),
          ),
        );
      }
      return false;
    }

    if (sessionId == _terminalChannelSessionId) {
      _disconnectTerminalStream();
    }
    _commandBuffers.remove(sessionId);
    _terminalOutputSanitizers.remove(sessionId);
    _terminalSizes.remove(sessionId);
    _terminalPersistedAt.remove(sessionId);
    _terminalGapWarned.remove(sessionId);
    _terminalTruncateWarned.remove(sessionId);

    if (!mounted) {
      return false;
    }

    _updateState(() {
      final nextTerminals = Map<String, Terminal>.from(_terminals);
      nextTerminals.remove(sessionId);
      _terminals = nextTerminals;
      _sessions = remaining;
      _activeSessionId = nextActiveId;
      _clearTerminalSearchHighlights(clearQuery: true);
      _statusIsError = false;
    });

    if (nextActiveId == null) {
      _disconnectTerminalStream();
      _pollTimer?.cancel();
      _terminalReconnectTimer?.cancel();
      _terminalReconnectTimer = null;
      return true;
    }

    if (wasActive) {
      _setActiveSession(nextActiveId);
    } else {
      _startPolling();
      if (_activeSessionId == nextActiveId) {
        unawaited(_connectTerminalStream());
      }
    }
    return true;
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
    _replaceSession(previousSession.id, view.copyWith(session: updatedSession));
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
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Failed to rename session.',
      );
      _logErrorDetails('terminal_rename', presentation);
      await revert();
      _showSessionLabelError(_formatErrorMessage(presentation));
    } catch (error) {
      final presentation = _presentUnexpectedFailure(
        error,
        fallbackMessage: 'Failed to rename session.',
      );
      _logErrorDetails('terminal_rename', presentation);
      await revert();
      _showSessionLabelError(_formatErrorMessage(presentation));
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
    _replaceSession(sessionId, view.copyWith(session: updated));
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
    _updateState(() {
      _sessions = _sessions
          .map((session) => session.session.id == sessionId ? updated : session)
          .toList();
    });
  }

  bool _isTerminalClosed(String status) {
    return status == 'closed' || status == 'killed' || status == 'exited';
  }

  bool _shouldCloseMissingRemote(String status) {
    switch (status) {
      case 'running':
      case 'connected':
        return true;
      default:
        return false;
    }
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
    final encodedInput = _encodeTerminalInputBytes(resolved);
    _updateCommandBuffer(sessionId, encodedInput);
    unawaited(
      _sendTerminalInput(
        sessionId,
        resolved,
        inputBytes: encodedInput,
        view: view,
      ),
    );
    _consumeOneShotModifiers();
  }

  void _updateCommandBuffer(String sessionId, List<int> inputBytes) {
    if (inputBytes.isEmpty) {
      return;
    }
    final buffer = _commandBuffers.putIfAbsent(sessionId, () => <int>[]);
    var skippingEscape = false;
    for (final byte in inputBytes) {
      if (skippingEscape) {
        if (byte >= 64 && byte <= 126) {
          skippingEscape = false;
        }
        continue;
      }
      if (byte == 27) {
        skippingEscape = true;
        continue;
      }
      if (byte == 10 || byte == 13) {
        final command = utf8.decode(buffer, allowMalformed: true).trim();
        buffer.clear();
        if (command.isNotEmpty) {
          unawaited(_recordCommand(sessionId, command));
        }
        continue;
      }
      if (byte == 8 || byte == 127) {
        _trimCommandBufferTrailingScalar(buffer);
        continue;
      }
      if (byte < 32) {
        continue;
      }
      buffer.add(byte);
    }
  }

  List<int> _encodeTerminalInputBytes(String data) {
    if (data.isEmpty) {
      return const <int>[];
    }
    final codeUnits = data.codeUnits;
    final isByteStream = codeUnits.every((unit) => unit >= 0 && unit <= 0xFF);
    if (isByteStream) {
      final bytes = List<int>.from(codeUnits, growable: false);
      if (_isLikelyUtf16LeInput(bytes)) {
        final decoded = _decodeUtf16LeInput(bytes);
        if (_looksLikeReadableUtf16Text(decoded)) {
          return utf8.encode(decoded);
        }
      }
      return bytes;
    }
    return utf8.encode(data);
  }

  bool _isLikelyUtf16LeInput(List<int> bytes) {
    if (bytes.length < 2 || bytes.length.isOdd) {
      return false;
    }

    final hasExtendedByte = bytes.any((value) => value >= 0x80);
    if (!hasExtendedByte) {
      return false;
    }

    return !_isValidUtf8Sequence(bytes);
  }

  bool _isValidUtf8Sequence(List<int> bytes) {
    try {
      utf8.decode(bytes, allowMalformed: false);
      return true;
    } catch (_) {
      return false;
    }
  }

  String _decodeUtf16LeInput(List<int> bytes) {
    final codeUnits = <int>[];
    for (var index = 0; index + 1 < bytes.length; index += 2) {
      codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
    }
    return String.fromCharCodes(codeUnits);
  }

  bool _looksLikeReadableUtf16Text(String text) {
    if (text.isEmpty) {
      return false;
    }
    var nonAsciiCount = 0;
    for (final rune in text.runes) {
      if (!_isReadableRune(rune)) {
        return false;
      }
      if (rune > 0x7F) {
        nonAsciiCount += 1;
      }
    }
    return nonAsciiCount > 0;
  }

  bool _isReadableRune(int rune) {
    if (rune == 0x09 || rune == 0x0A || rune == 0x0D) {
      return true;
    }
    if (rune < 0x20) {
      return false;
    }
    if (rune == 0x7F) {
      return false;
    }
    if (rune >= 0x80 && rune <= 0x9F) {
      return false;
    }
    return true;
  }

  void _trimCommandBufferTrailingScalar(List<int> buffer) {
    if (buffer.isEmpty) {
      return;
    }
    final trailing = buffer.removeLast();
    if ((trailing & 0x80) == 0) {
      return;
    }
    while (buffer.isNotEmpty && (buffer.last & 0xC0) == 0x80) {
      buffer.removeLast();
    }
    if (buffer.isEmpty) {
      return;
    }
    final lead = buffer.last;
    if ((lead & 0xE0) == 0xC0 ||
        (lead & 0xF0) == 0xE0 ||
        (lead & 0xF8) == 0xF0) {
      buffer.removeLast();
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
      _updateState(() {
        _statusMessage = 'Create a session to run commands.';
        _statusIsError = true;
      });
      return;
    }
    final status = active.session.status.toLowerCase();
    if (_isTerminalClosed(status)) {
      _updateState(() {
        _statusMessage = 'This session is no longer active.';
        _statusIsError = true;
      });
      return;
    }
    final event = await _ensureTerminalEvent(active, command);
    if (!mounted) {
      return;
    }
    final updatedView = active.copyWith(lastCommand: command, lastEvent: event);
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
    List<int>? inputBytes,
    TerminalSessionView? view,
    bool triggerPoll = false,
  }) async {
    final activeView = view ?? _sessionById(sessionId);
    if (activeView == null) {
      return;
    }
    final resolvedInputBytes = inputBytes ?? _encodeTerminalInputBytes(data);
    if (resolvedInputBytes.isEmpty) {
      return;
    }
    final inputB64 = base64Encode(resolvedInputBytes);
    if (_terminalChannelReady && _terminalChannelSessionId == sessionId) {
      try {
        _terminalChannel?.sink.add(
          jsonEncode({'action': 'input', 'data_b64': inputB64}),
        );
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
        inputBytes: resolvedInputBytes,
      );
      if (triggerPoll) {
        _startPolling();
        unawaited(_pollActiveSession());
      }
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Terminal command failed.',
      );
      _logErrorDetails('terminal_input', presentation);
      await _markSessionDisconnected(
        sessionId,
        _formatErrorMessage(presentation),
        event: activeView.lastEvent,
        command: activeView.lastCommand,
      );
    } catch (error) {
      final presentation = _presentUnexpectedFailure(
        error,
        fallbackMessage: 'Terminal command failed.',
      );
      _logErrorDetails('terminal_input', presentation);
      await _markSessionDisconnected(
        sessionId,
        _formatErrorMessage(presentation),
        event: activeView.lastEvent,
        command: activeView.lastCommand,
      );
    }
  }

  Future<void> _sendTerminalResize(String sessionId, int cols, int rows) async {
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
        _terminalChannel?.sink.add(
          jsonEncode({'action': 'resize', 'cols': cols, 'rows': rows}),
        );
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
    _updateState(() {
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
    _updateState(() {
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
          content: Text('Failed to save terminal session: ${error.toString()}'),
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
            content: Text('Failed to save terminal event: ${error.toString()}'),
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
    int? notificationSeq,
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
    if (notificationSeq != null) {
      payload['notification_next_seq'] = notificationSeq;
    } else {
      payload.remove('notification_next_seq');
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
          content: Text('Failed to save terminal output: ${error.toString()}'),
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
    bool preferSnapshot = false,
  }) async {
    final view = _sessionById(sessionId);
    if (view == null) {
      return;
    }
    final status = payload['status']?.toString() ?? view.session.status;
    final labelRaw = payload['label']?.toString() ?? '';
    final resolvedLabel = labelRaw.trim().isNotEmpty
        ? labelRaw.trim()
        : view.session.label;
    final action = payload['action']?.toString() ?? '';
    final nextSeq = _parseNextSeq(payload, fallback: view.nextSeq);
    final notificationNextSeq = _parseNotificationSeq(
      payload,
      fallback: view.notificationSeq,
    );
    final firstSeq =
        _parseChunkSeq(payload['first_seq']) ??
        _extractFirstSeq(payload['output']);
    final lastDelivered = _terminalSince(view.nextSeq);
    final expectedNext = view.nextSeq;
    final truncated = payload['truncated'] == true;
    final hasGap =
        truncated ||
        (view.nextSeq > 0 && firstSeq != null && firstSeq > expectedNext);
    final missingHistory =
        (truncated && view.nextSeq <= 1) ||
        (view.nextSeq <= 1 && firstSeq != null && firstSeq > 1);
    final shouldReset = action == 'start' || nextSeq < view.nextSeq || hasGap;
    if (shouldReset) {
      _terminalOutputSanitizers[sessionId]?.reset();
    }
    final parsedExitCode = _parseExitCode(payload);
    final exitCode =
        parsedExitCode ??
        (status.toLowerCase() == 'running' ? null : view.exitCode);
    final snapshotRaw = payload['snapshot']?.toString();
    final snapshot = snapshotRaw != null && snapshotRaw.isNotEmpty
        ? snapshotRaw
        : null;
    final outputEntries = _parseTerminalChunks(
      payload['output'],
      DateTime.now(),
      minSeq: shouldReset ? 0 : lastDelivered,
    );
    final sanitizedOutputEntries = _sanitizeTerminalEntries(
      sessionId,
      outputEntries,
    );
    final mergedOutput = shouldReset
        ? sanitizedOutputEntries
        : _mergeOutputEntries(view.output, sanitizedOutputEntries);
    final updatedSession = _sessionWithStatus(
      view.session,
      status,
      label: resolvedLabel,
    );
    final updatedView = view.copyWith(
      session: updatedSession,
      output: mergedOutput,
      nextSeq: nextSeq,
      notificationSeq: notificationNextSeq,
      exitCode: exitCode,
    );
    _replaceSession(sessionId, updatedView);
    await _handleTerminalNotifications(
      sessionId: sessionId,
      sessionLabel: resolvedLabel,
      rawNotifications: payload['notifications'],
    );
    if (action == 'start' || nextSeq < view.nextSeq) {
      _terminalGapWarned.remove(sessionId);
      _terminalTruncateWarned.remove(sessionId);
    }
    if (sessionId == _activeSessionId) {
      if (hasGap && !_terminalGapWarned.contains(sessionId)) {
        _terminalGapWarned.add(sessionId);
        _setTerminalStatusMessage('Terminal output dropped; screen re-synced.');
      } else if (missingHistory &&
          !_terminalTruncateWarned.contains(sessionId)) {
        _terminalTruncateWarned.add(sessionId);
        _setTerminalStatusMessage(
          'Terminal history truncated; screen may be incomplete.',
        );
      }
    }
    await _persistSession(updatedSession);
    final shouldApplySnapshot = snapshot != null
        ? (preferSnapshot || shouldReset || action == 'status')
        : false;
    if (shouldApplySnapshot) {
      _resetTerminalSession(sessionId);
      _writeTerminalSnapshot(sessionId, snapshot);
    } else {
      if (shouldReset) {
        _resetTerminalSession(sessionId);
      }
      _appendTerminalOutput(sessionId, sanitizedOutputEntries);
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
          notificationSeq: notificationNextSeq,
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
      _updateState(() {
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

  TerminalOutputSanitizer _terminalOutputSanitizer(String sessionId) {
    return _terminalOutputSanitizers.putIfAbsent(
      sessionId,
      () => TerminalOutputSanitizer(),
    );
  }

  List<TerminalOutputEntry> _sanitizeTerminalEntries(
    String sessionId,
    List<TerminalOutputEntry> entries,
  ) {
    if (entries.isEmpty) {
      return entries;
    }
    final sanitizer = _terminalOutputSanitizer(sessionId);
    final sanitized = <TerminalOutputEntry>[];
    for (final entry in entries) {
      final text = sanitizer.sanitize(entry.text);
      if (text.isEmpty) {
        continue;
      }
      sanitized.add(
        TerminalOutputEntry(
          stream: entry.stream,
          text: text,
          timestamp: entry.timestamp,
        ),
      );
    }
    return sanitized;
  }

  void _writeTerminalSnapshot(String sessionId, String? snapshot) {
    if (snapshot == null || snapshot.isEmpty) {
      return;
    }
    final terminal = _terminals[sessionId];
    if (terminal == null) {
      return;
    }
    final sanitized = _terminalOutputSanitizer(sessionId).sanitize(snapshot);
    if (sanitized.isEmpty) {
      return;
    }
    terminal.write(sanitized);
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
    if (last == null || now.difference(last) > _terminalPersistInterval) {
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
    _terminalOutputSanitizers[sessionId]?.reset();
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

  int _parseNotificationSeq(Map<String, dynamic> payload, {int fallback = 0}) {
    final raw = payload['notification_next_seq'] ?? payload['notify_next_seq'];
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

  int _terminalSince(int nextSeq) {
    if (nextSeq <= 0) {
      return 0;
    }
    return nextSeq - 1;
  }

  String _notificationTitle(String level) {
    switch (level.toLowerCase()) {
      case 'warning':
        return 'Terminal warning';
      case 'error':
        return 'Terminal error';
      case 'info':
        return 'Terminal notice';
      default:
        return 'Terminal notification';
    }
  }

  bool _shouldToastNotification(String level) {
    final normalized = level.toLowerCase();
    return normalized == 'warning' || normalized == 'error';
  }

  Future<void> _handleTerminalNotifications({
    required String sessionId,
    required String sessionLabel,
    required dynamic rawNotifications,
  }) async {
    if (rawNotifications is! List || rawNotifications.isEmpty) {
      return;
    }
    final parsed = <Map<String, dynamic>>[];
    for (final item in rawNotifications) {
      if (item is! Map) {
        continue;
      }
      parsed.add(Map<String, dynamic>.from(item));
    }
    if (parsed.isEmpty) {
      return;
    }
    TimelineEvent? latestEvent;
    for (final item in parsed) {
      final messageRaw = item['message']?.toString() ?? '';
      final message = messageRaw.trim();
      if (message.isEmpty) {
        continue;
      }
      final rawId = item['id']?.toString() ?? '';
      final notificationId = rawId.trim().isNotEmpty
          ? rawId.trim()
          : createStorageId();
      final level = item['level']?.toString().toLowerCase() ?? 'info';
      final createdAt =
          _parseEpochSeconds(item['created_at']) ?? DateTime.now();
      final source = item['source']?.toString() ?? 'terminal';
      final event = TimelineEvent(
        id: notificationId,
        sessionId: sessionId,
        type: 'terminal_notification',
        title: _notificationTitle(level),
        payload: {
          'message': message,
          'level': level,
          'source': source,
          'session_id': sessionId,
          'session_label': sessionLabel,
          'notification_id': notificationId,
          'created_at': createdAt.toIso8601String(),
        },
        createdAt: createdAt,
      );
      try {
        await widget.storage.insertTimelineEvent(event);
        latestEvent = event;
      } catch (_) {
        // Ignore notification storage failures.
      }
    }
    if (!mounted || latestEvent == null) {
      return;
    }
    final level = latestEvent.payload['level']?.toString() ?? 'info';
    if (!_shouldToastNotification(level)) {
      return;
    }
    final now = DateTime.now();
    final lastToast = _lastNotificationToastAt;
    if (lastToast != null && now.difference(lastToast).inSeconds < 3) {
      return;
    }
    _lastNotificationToastAt = now;
    final message = latestEvent.payload['message']?.toString() ?? '';
    if (message.trim().isEmpty) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${_notificationTitle(level)}: ${_truncate(message, 120)}',
        ),
      ),
    );
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
      return raw.split('\n').where((line) => line.isNotEmpty).toList();
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
}
