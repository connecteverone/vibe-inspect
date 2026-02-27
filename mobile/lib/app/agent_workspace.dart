part of '../main.dart';

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
  String? _remoteFetchError;
  late ConnectionRecord _activeAgent;
  bool _showEndedTerminalSessions = false;
  int _workspaceLoadRequestId = 0;

  @override
  void initState() {
    super.initState();
    _activeAgent = widget.agent;
    _loadWorkspace();
  }

  Future<void> _loadWorkspace() async {
    final requestId = ++_workspaceLoadRequestId;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _remoteFetchError = null;
    });
    try {
      final sessions = await widget.storage.fetchToolSessions();
      final mergedSessions = <String, ToolSession>{
        for (final session in sessions) session.id: session,
      };
      final remoteFetch = await _fetchRemoteTerminalSessions();
      for (final remote in remoteFetch.sessions) {
        final existing = mergedSessions[remote.id];
        if (existing != null) {
          if (existing.type.toLowerCase() != 'terminal') {
            continue;
          }
          final nextLabel = remote.label.trim().isNotEmpty
              ? remote.label
              : existing.label;
          final nextStatus = remote.status.trim().isNotEmpty
              ? remote.status
              : existing.status;
          final nextAgentId = existing.agentId ?? _activeAgent.id;
          if (nextLabel != existing.label ||
              nextStatus != existing.status ||
              nextAgentId != existing.agentId) {
            final updated = ToolSession(
              id: existing.id,
              type: existing.type,
              label: nextLabel,
              status: nextStatus,
              agentId: nextAgentId,
              createdAt: existing.createdAt,
            );
            await widget.storage.insertToolSession(updated);
            mergedSessions[updated.id] = updated;
          }
          continue;
        }
        final created = ToolSession(
          id: remote.id,
          type: 'terminal',
          label: _fallbackRemoteTerminalLabel(remote.id, remote.label),
          status: remote.status,
          agentId: _activeAgent.id,
          createdAt: remote.createdAt,
        );
        await widget.storage.insertToolSession(created);
        mergedSessions[created.id] = created;
      }
      final events = await widget.storage.fetchTimelineEvents();
      final agentSessions = mergedSessions.values
          .where((session) => session.agentId == _activeAgent.id)
          .toList();
      agentSessions.sort(
        (left, right) => right.createdAt.compareTo(left.createdAt),
      );
      final sessionIds = agentSessions.map((session) => session.id).toSet();
      final agentEvents = events
          .where((event) => sessionIds.contains(event.sessionId))
          .toList();
      if (!mounted || requestId != _workspaceLoadRequestId) {
        return;
      }
      setState(() {
        _sessions = agentSessions;
        _events = agentEvents;
        _isLoading = false;
        _remoteFetchError = remoteFetch.errorMessage;
      });
    } catch (error) {
      if (!mounted || requestId != _workspaceLoadRequestId) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to load workspace.';
        _remoteFetchError = null;
      });
    }
  }

  String? get _agentBaseUrl {
    final url = _activeAgent.agentUrl?.trim();
    return url == null || url.isEmpty ? null : url;
  }

  String _fallbackRemoteTerminalLabel(String id, String label) {
    final trimmed = label.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
    return 'Terminal ${_truncate(id, 6)}';
  }

  Future<_AgentRemoteTerminalFetchResult> _fetchRemoteTerminalSessions() async {
    final baseUrl = _agentBaseUrl;
    if (baseUrl == null) {
      return _AgentRemoteTerminalFetchResult.success(<RemoteTerminalSession>[]);
    }
    final client = http.Client();
    final commandClient = AgentCommandClient(
      baseUrl: baseUrl,
      client: client,
      authToken: _activeAgent.token,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
    try {
      final sessions = await commandClient.fetchTerminalSessions();
      return _AgentRemoteTerminalFetchResult.success(sessions);
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Unable to load terminal sessions.',
      );
      _logErrorDetails('agent_workspace_terminal_sessions', presentation);
      return _AgentRemoteTerminalFetchResult.failure(
        _formatErrorMessage(presentation),
      );
    } catch (error) {
      final presentation = _presentUnexpectedFailure(
        error,
        fallbackMessage: 'Unable to load terminal sessions.',
      );
      _logErrorDetails('agent_workspace_terminal_sessions', presentation);
      return _AgentRemoteTerminalFetchResult.failure(
        _formatErrorMessage(presentation),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _openTerminalSession() async {
    final now = DateTime.now();
    final terminalCount = _sessions
        .where((session) => session.type == 'terminal')
        .length;
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
              agentId: _activeAgent.id,
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
          content: Text('Failed to create API session: ${error.toString()}'),
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
            content: Text('Failed to create VNC session: ${error.toString()}'),
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
      payload: {'target': _agentLabel(_activeAgent), 'status': 'queued'},
      createdAt: now,
    );
    try {
      await widget.storage.insertTimelineEvent(event);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start VNC: ${error.toString()}')),
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

  Future<void> _openRemoteView() async {
    final baseUrl = _agentBaseUrl;
    if (baseUrl == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Agent URL missing. Re-pair to enable remote control.'),
        ),
      );
      return;
    }
    final existingSession = _sessions.firstWhere(
      (session) => session.type == 'remote',
      orElse: () => ToolSession(
        id: '',
        type: 'remote',
        label: '',
        status: 'queued',
        createdAt: DateTime.now(),
      ),
    );
    final now = DateTime.now();
    final session = existingSession.id.isEmpty
        ? ToolSession(
            id: createStorageId(),
            type: 'remote',
            label: 'Remote Control',
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
              'Failed to create remote session: ${error.toString()}',
            ),
          ),
        );
        return;
      }
    }
    final event = TimelineEvent(
      id: createStorageId(),
      sessionId: session.id,
      type: 'remote',
      title: 'Remote: ${_agentLabel(_activeAgent)}',
      payload: {'target': _agentLabel(_activeAgent), 'status': 'queued'},
      createdAt: now,
    );
    try {
      await widget.storage.insertTimelineEvent(event);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to start remote: ${error.toString()}')),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    await Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => RemoteSessionScreen(
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
        SnackBar(content: Text('Failed to remove agent: ${error.toString()}')),
      );
      return;
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openSession(ToolSession session) async {
    final baseUrl = _agentBaseUrl;
    final latestEvent = _latestEventForSession(
      session.id,
      sessionType: session.type,
    );
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
              builder: (_) =>
                  AiInsightScreen(event: latestEvent, session: session),
            ),
          )
          .then((_) => _loadWorkspace());
      return;
    }
    if (session.type == 'remote') {
      if (!mounted) {
        return;
      }
      await Navigator.of(context)
          .push(
            MaterialPageRoute(
              builder: (_) => RemoteSessionScreen(
                event:
                    latestEvent ??
                    TimelineEvent(
                      id: createStorageId(),
                      sessionId: session.id,
                      type: 'remote',
                      title: 'Remote: ${_agentLabel(_activeAgent)}',
                      payload: const {'status': 'queued'},
                      createdAt: DateTime.now(),
                    ),
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
      return;
    }
    _showMissingContext('This session type is not supported yet.');
  }

  Future<void> _deleteSession(ToolSession session) async {
    final status = session.status.toLowerCase();
    final isRunning =
        status != 'closed' &&
        status != 'killed' &&
        status != 'exited' &&
        status != 'disconnected' &&
        status != 'error';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            isRunning ? 'Delete running session?' : 'Delete session?',
          ),
          content: Text(
            isRunning
                ? 'Deleting ${session.label} will remove it from mobile and request desktop cleanup.'
                : 'Delete ${session.label} from mobile session history?',
          ),
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
    if (confirmed != true) {
      return;
    }
    String? localOnlyDeleteHint;
    if (session.type.toLowerCase() == 'terminal') {
      final baseUrl = _agentBaseUrl;
      if (baseUrl != null) {
        final client = http.Client();
        final commandClient = AgentCommandClient(
          baseUrl: baseUrl,
          client: client,
          authToken: _activeAgent.token,
          clientId: widget.clientId,
          clientName: widget.clientName,
        );
        try {
          await commandClient.sendTerminalAction(
            action: 'delete',
            sessionId: session.id,
          );
        } on AgentCommandFailure catch (error) {
          final code = (error.code ?? '').toLowerCase();
          final canDeleteLocallyOnly =
              code == 'session_not_found' ||
              code == 'unsupported_action' ||
              code == 'not_supported';
          if (!canDeleteLocallyOnly) {
            final presentation = _presentAgentFailure(
              error,
              fallbackMessage: 'Failed to delete terminal session.',
            );
            _logErrorDetails('agent_workspace_terminal_delete', presentation);
            _showMissingContext(_formatErrorMessage(presentation));
            return;
          }
          if (code == 'unsupported_action' || code == 'not_supported') {
            localOnlyDeleteHint =
                'Desktop agent does not support remote delete yet. Removed locally.';
          }
        } catch (error) {
          final presentation = _presentUnexpectedFailure(
            error,
            fallbackMessage: 'Failed to delete terminal session.',
          );
          _logErrorDetails('agent_workspace_terminal_delete', presentation);
          _showMissingContext(_formatErrorMessage(presentation));
          return;
        } finally {
          client.close();
        }
      }
    }
    try {
      await widget.storage.deleteToolSession(session.id);
    } catch (error) {
      _showMissingContext('Failed to delete session: ${error.toString()}');
      return;
    }
    await _loadWorkspace();
    if (!mounted) {
      return;
    }
    if (localOnlyDeleteHint != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(localOnlyDeleteHint)));
    }
  }

  void _showMissingContext(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  TimelineEvent? _latestEventForSession(
    String sessionId, {
    String? sessionType,
  }) {
    final normalizedType = sessionType?.toLowerCase();
    for (final event in _events) {
      if (event.sessionId == sessionId) {
        if (normalizedType != null &&
            event.type.toLowerCase() != normalizedType) {
          continue;
        }
        return event;
      }
    }
    return null;
  }

  List<ToolSession> _visibleSessions() {
    return _sessions
        .where(
          (session) =>
              session.type != 'pairing' &&
              session.type != 'vnc' &&
              session.type != 'remote',
        )
        .toList();
  }

  bool _isEndedTerminalSession(ToolSession session) {
    if (session.type.toLowerCase() != 'terminal') {
      return false;
    }
    final status = session.status.toLowerCase();
    return status == 'closed' || status == 'killed' || status == 'exited';
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
    final activeSessions = sessions
        .where((session) => !_isEndedTerminalSession(session))
        .toList();
    final endedTerminalSessions = sessions
        .where((session) => _isEndedTerminalSession(session))
        .toList();
    final hasVisibleSessions =
        activeSessions.isNotEmpty || endedTerminalSessions.isNotEmpty;
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
              subtitle: 'Create sessions or launch remote control.',
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
                    onPressed: _loadWorkspace,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh sessions'),
                  ),
                  if (kEnableRemoteControl)
                    OutlinedButton.icon(
                      onPressed: hasAgentUrl ? _openRemoteView : null,
                      icon: const Icon(Icons.computer_outlined),
                      label: const Text('Open remote control'),
                    ),
                  if (kEnableLegacyVnc)
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_remoteFetchError case final remoteFetchError?) ...[
                    _InlineStatus(message: remoteFetchError, isError: true),
                    const SizedBox(height: 12),
                  ],
                  if (!hasVisibleSessions)
                    const _EmptyHint(text: 'No sessions yet.')
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (
                          var index = 0;
                          index < activeSessions.length;
                          index++
                        ) ...[
                          _AgentSessionRow(
                            session: activeSessions[index],
                            event: _latestEventForSession(
                              activeSessions[index].id,
                              sessionType: activeSessions[index].type,
                            ),
                            onTap: () => _openSession(activeSessions[index]),
                            onDelete: () =>
                                _deleteSession(activeSessions[index]),
                          ),
                          if (index != activeSessions.length - 1)
                            const SizedBox(height: 10),
                        ],
                        if (endedTerminalSessions.isNotEmpty) ...[
                          if (activeSessions.isNotEmpty)
                            const SizedBox(height: 12),
                          TextButton.icon(
                            onPressed: () {
                              setState(() {
                                _showEndedTerminalSessions =
                                    !_showEndedTerminalSessions;
                              });
                            },
                            icon: Icon(
                              _showEndedTerminalSessions
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                            ),
                            label: Text(
                              _showEndedTerminalSessions
                                  ? 'Hide ended terminal sessions (${endedTerminalSessions.length})'
                                  : 'Show ended terminal sessions (${endedTerminalSessions.length})',
                            ),
                          ),
                          if (_showEndedTerminalSessions)
                            for (
                              var index = 0;
                              index < endedTerminalSessions.length;
                              index++
                            ) ...[
                              if (index == 0)
                                const SizedBox(height: 4)
                              else
                                const SizedBox(height: 10),
                              _AgentSessionRow(
                                session: endedTerminalSessions[index],
                                event: _latestEventForSession(
                                  endedTerminalSessions[index].id,
                                  sessionType:
                                      endedTerminalSessions[index].type,
                                ),
                                onTap: () =>
                                    _openSession(endedTerminalSessions[index]),
                                onDelete: () => _deleteSession(
                                  endedTerminalSessions[index],
                                ),
                              ),
                            ],
                        ],
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
    final borderColor = isActive
        ? const Color(0xFF38BDF8)
        : const Color(0xFFE2E8F0);
    final background = isActive
        ? const Color(0xFFF0F9FF)
        : const Color(0xFFF8FAFC);
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
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
    this.onDelete,
  });

  final ToolSession session;
  final TimelineEvent? event;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

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
    final timeLabel = event == null
        ? 'Never run'
        : _formatTimestamp(event!.createdAt);
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
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
              const SizedBox(width: 4),
              PopupMenuButton<_SessionAction>(
                tooltip: 'Manage session',
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == _SessionAction.open) {
                    onTap();
                    return;
                  }
                  onDelete?.call();
                },
                itemBuilder: (context) => [
                  const PopupMenuItem<_SessionAction>(
                    value: _SessionAction.open,
                    child: Text('Open'),
                  ),
                  if (onDelete != null)
                    const PopupMenuItem<_SessionAction>(
                      value: _SessionAction.delete,
                      child: Text('Delete'),
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

enum _SessionAction { open, delete }

class _AgentRemoteTerminalFetchResult {
  const _AgentRemoteTerminalFetchResult({
    required this.sessions,
    this.errorMessage,
  });

  final List<RemoteTerminalSession> sessions;
  final String? errorMessage;

  factory _AgentRemoteTerminalFetchResult.success(
    List<RemoteTerminalSession> sessions,
  ) {
    return _AgentRemoteTerminalFetchResult(sessions: sessions);
  }

  factory _AgentRemoteTerminalFetchResult.failure(String message) {
    return _AgentRemoteTerminalFetchResult(
      sessions: const <RemoteTerminalSession>[],
      errorMessage: message,
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
      return const _SessionStatusStyle(Color(0xFFDCFCE7), Color(0xFF166534));
    case 'queued':
    case 'idle':
      return const _SessionStatusStyle(Color(0xFFFEF3C7), Color(0xFF92400E));
    case 'disconnected':
    case 'error':
    case 'failed':
      return const _SessionStatusStyle(Color(0xFFFEE2E2), Color(0xFFB91C1C));
    case 'exited':
    case 'killed':
    case 'closed':
      return const _SessionStatusStyle(Color(0xFFE2E8F0), Color(0xFF475569));
    default:
      return const _SessionStatusStyle(Color(0xFFE2E8F0), Color(0xFF475569));
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
      return const _AgentStatusStyle(Color(0xFFDCFCE7), Color(0xFF166534));
    case 'pending':
    case 'connecting':
      return const _AgentStatusStyle(Color(0xFFFEF3C7), Color(0xFF92400E));
    case 'disconnected':
    case 'offline':
    case 'error':
      return const _AgentStatusStyle(Color(0xFFFEE2E2), Color(0xFFB91C1C));
    default:
      return const _AgentStatusStyle(Color(0xFFE2E8F0), Color(0xFF475569));
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
              colors: [Color(0xFFF8FAFC), Color(0xFFE2E8F0), Color(0xFFE0F2FE)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        const Positioned(
          top: -80,
          left: -40,
          child: _GlowCircle(size: 180, color: Color(0xFFDCFCE7)),
        ),
        const Positioned(
          bottom: -60,
          right: -30,
          child: _GlowCircle(size: 200, color: Color(0xFFE0F2FE)),
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
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF475569)),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: const [
            _FeatureChip(label: 'Multi-agent'),
            _FeatureChip(label: 'Session workspaces'),
            _FeatureChip(label: 'Remote ready'),
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
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              description,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: const Color(0xFF64748B)),
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
            const _TokenRow(label: 'Desktop approval', value: 'Required'),
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
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
        ),
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
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
    final background = isError
        ? const Color(0xFFFEE2E2)
        : const Color(0xFFDCFCE7);
    final textColor = isError
        ? const Color(0xFF991B1B)
        : const Color(0xFF166534);
    final icon = isError
        ? Icons.error_outline_rounded
        : Icons.check_circle_outline_rounded;
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
    case 'terminal_notification':
      return const _EventVisuals(
        icon: Icons.notifications_active,
        backgroundColor: Color(0xFFFEF3C7),
        foregroundColor: Color(0xFF92400E),
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
  const _TimelineDetailScaffold({required this.title, required this.body});

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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: const Color(0xFF64748B)),
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
  const _JsonTreeView({required this.data, required this.changedPaths});

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
            _JsonTreeEntry(label: key, pathKey: key, value: map[key]),
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
      final countLabel = value is List
          ? '${entries.length} items'
          : '${entries.length} fields';
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
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
            color: isChanged
                ? const Color(0xFFF59E0B)
                : const Color(0xFFE2E8F0),
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
  return changes.any((entry) => entry == path || entry.startsWith('$path/'));
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
            _InlineStatus(message: summary, isError: true)
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
    return AiInsightSummary(status: 'unavailable', summary: message);
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
  final hasError =
      stderrLines.isNotEmpty ||
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
    final missingValues =
        body['missing'] ??
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
      final trimmed = raw.replaceAll(RegExp(r'''^['"]|['"]$'''), '').trim();
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
