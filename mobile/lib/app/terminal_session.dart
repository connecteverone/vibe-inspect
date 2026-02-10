part of '../main.dart';

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
    final reason = rawReason?.trim() ?? '';
    final status = session.session.status.toLowerCase();
    final showReason = reason.isNotEmpty &&
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
                        _truncate(reason, 60),
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
