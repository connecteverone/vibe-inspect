part of '../main.dart';

const int _defaultCols = 120;
const int _defaultRows = 32;
const int _maxOutputEntries = 800;
const int _terminalLabelMax = 80;
const int _terminalMaxLines = 8000;
const Duration _pollInterval = Duration(milliseconds: 900);
const Duration _terminalPersistInterval = Duration(milliseconds: 900);
const String _missingRemoteSessionReason =
    'Session closed because the desktop agent restarted.';

class TerminalWorkspaceScreen extends StatefulWidget {
  const TerminalWorkspaceScreen({
    super.key,
    required this.storage,
    required this.agentBaseUrl,
    required this.authToken,
    required this.clientId,
    required this.clientName,
    this.initialSession,
    this.initialEvent,
    this.agentId,
  });

  final StorageRepository storage;
  final String? agentBaseUrl;
  final String? authToken;
  final String? clientId;
  final String? clientName;
  final ToolSession? initialSession;
  final TimelineEvent? initialEvent;
  final String? agentId;

  @override
  State<TerminalWorkspaceScreen> createState() =>
      _TerminalWorkspaceScreenState();
}

class _TerminalWorkspaceScreenState extends State<TerminalWorkspaceScreen> {
  final FocusNode _terminalFocusNode = FocusNode();
  final TerminalController _terminalController = TerminalController();
  final ScrollController _terminalScrollController = ScrollController();
  Map<String, Terminal> _terminals = {};
  final Map<String, List<int>> _commandBuffers = {};
  String? _statusMessage;
  bool _statusIsError = false;
  bool _isLoading = true;
  String? _loadError;
  String? _remoteFetchError;
  bool _autoRunTriggered = false;
  List<TerminalSessionView> _sessions = [];
  String? _activeSessionId;
  http.Client? _httpClient;
  AgentCommandClient? _agentClient;
  Timer? _pollTimer;
  bool _isPolling = false;
  WebSocketChannel? _terminalChannel;
  StreamSubscription<dynamic>? _terminalChannelSub;
  String? _terminalChannelSessionId;
  bool _terminalChannelReady = false;
  final Map<String, _TerminalGrid> _terminalSizes = {};
  final Map<String, DateTime> _terminalPersistedAt = {};
  DateTime? _lastNotificationToastAt;
  Timer? _terminalReconnectTimer;
  Timer? _terminalKeepaliveTimer;
  int _terminalReconnectAttempts = 0;
  bool _ctrlModifier = false;
  bool _ctrlLocked = false;
  bool _altModifier = false;
  bool _altLocked = false;
  bool _shiftModifier = false;
  bool _shiftLocked = false;
  bool _showFnRow = false;
  int _secondaryKeyPage = 0;
  bool _showKeyBar = true;
  bool _showNavOnly = false;
  bool _mouseInputEnabled = false;
  bool _hardwareKeyboardOnly = false;
  bool _isTerminalAtBottom = true;
  final Set<String> _terminalGapWarned = {};
  final Set<String> _terminalTruncateWarned = {};
  SelectionMode _selectionMode = SelectionMode.line;
  double _terminalFontSize = 13;
  int _terminalThemeIndex = 0;
  String _terminalSearchQuery = '';
  bool _terminalSearchCaseSensitive = false;
  int _terminalSearchIndex = -1;
  final List<_TerminalSearchMatch> _terminalSearchMatches = [];
  final List<TerminalHighlight> _terminalSearchHighlights = [];
  Timer? _terminalSearchRefreshTimer;

  void _updateState(VoidCallback fn) {
    setState(fn);
  }

  bool get _hasActiveModifiers =>
      _ctrlModifier || _altModifier || _shiftModifier;

  @override
  void initState() {
    super.initState();
    _configureAgentClient();
    _terminalController.setSelectionMode(_selectionMode);
    _applyPointerInputMode();
    _terminalScrollController.addListener(_handleTerminalScroll);
    _loadSessions();
  }

  @override
  void dispose() {
    _terminalFocusNode.dispose();
    _terminalScrollController
      ..removeListener(_handleTerminalScroll)
      ..dispose();
    _pollTimer?.cancel();
    _disconnectTerminalStream();
    _terminalReconnectTimer?.cancel();
    _terminalKeepaliveTimer?.cancel();
    _terminalSearchRefreshTimer?.cancel();
    _httpClient?.close();
    super.dispose();
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
    final status = active?.session.status.toLowerCase() ?? 'idle';
    final isDisconnected = status == 'disconnected' || status == 'error';
    final isEnded = _isTerminalClosed(status);
    final statusStyle = _terminalStatusStyle(status);
    final terminal = active == null ? null : _terminals[active.session.id];
    final terminalThemes = _terminalThemeOptions();
    final resolvedThemeIndex = _terminalThemeIndex
        .clamp(0, terminalThemes.length - 1)
        .toInt();
    final terminalTheme = terminalThemes[resolvedThemeIndex].theme;
    final terminalBackground = terminalTheme.background;
    final terminalForeground = terminalTheme.foreground;
    final isLightTerminal =
        ThemeData.estimateBrightnessForColor(terminalBackground) ==
            Brightness.light;
    final terminalBorderColor =
        isLightTerminal ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B);
    final terminalOverlayBackground =
        isLightTerminal ? const Color(0xFFE2E8F0) : const Color(0xFF0F172A);
    final terminalOverlayForeground =
        isLightTerminal ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0);
    final terminalStyle = TerminalStyle.fromTextStyle(
      GoogleFonts.jetBrainsMono(
        fontSize: _terminalFontSize,
        height: 1.4,
      ),
    );
    final sessionLabel = active?.session.label ?? 'No session selected';
    final sessionStatus =
        active == null ? 'IDLE' : active.session.status.toUpperCase();
    final connectionLabel = active == null
        ? 'Create a session to start.'
        : _terminalChannelReady
            ? 'Live stream'
            : 'Polling updates';
    final resolvedStatusMessage =
        _statusMessage ?? _sessionStatusReason(active);
    final resolvedStatusIsError =
        _statusMessage != null ? _statusIsError : resolvedStatusMessage != null;
    final showEmptyHint = _sessions.isEmpty && _remoteFetchError == null;
    final headerStyle = theme.textTheme.bodyMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: const Color(0xFF0F172A),
    );
    const dockBackground = Color(0xFF0B1220);
    final keyRowPrimary = [
      _TerminalKeySpec(
        label: 'Esc',
        onTap: () => _sendTerminalKey(TerminalKey.escape),
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'Tab',
        onTap: () => _sendTerminalKey(TerminalKey.tab),
      ),
      _TerminalKeySpec(
        label: 'S-Tab',
        onTap: () => _sendTerminalKey(TerminalKey.backtab),
      ),
      _TerminalKeySpec(
        label: 'Ctrl',
        onTap: _toggleCtrlModifier,
        onLongPress: _toggleCtrlLock,
        isActive: _ctrlModifier,
        isLocked: _ctrlLocked,
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'Alt',
        onTap: _toggleAltModifier,
        onLongPress: _toggleAltLock,
        isActive: _altModifier,
        isLocked: _altLocked,
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'Shift',
        onTap: _toggleShiftModifier,
        onLongPress: _toggleShiftLock,
        isActive: _shiftModifier,
        isLocked: _shiftLocked,
      ),
      _TerminalKeySpec(
        label: _showFnRow ? 'Fn On' : 'Fn',
        onTap: _toggleFnRow,
        isActive: _showFnRow,
      ),
      _TerminalKeySpec(
        label: '←',
        onTap: () => _sendTerminalKey(TerminalKey.arrowLeft),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: '↓',
        onTap: () => _sendTerminalKey(TerminalKey.arrowDown),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: '↑',
        onTap: () => _sendTerminalKey(TerminalKey.arrowUp),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: '→',
        onTap: () => _sendTerminalKey(TerminalKey.arrowRight),
        isRepeatable: true,
      ),
    ];
    final keyRowSecondaryBase = [
      _TerminalKeySpec(
        label: 'Bksp',
        onTap: () => _sendTerminalKey(TerminalKey.backspace),
        isRepeatable: true,
      ),
      _TerminalKeySpec(
        label: 'Enter',
        onTap: () => _sendTerminalKey(TerminalKey.enter),
        isEmphasis: true,
      ),
      _TerminalKeySpec(
        label: 'PgUp',
        onTap: () => _sendTerminalKey(TerminalKey.pageUp),
      ),
      _TerminalKeySpec(
        label: 'PgDn',
        onTap: () => _sendTerminalKey(TerminalKey.pageDown),
      ),
      _TerminalKeySpec(
        label: 'Home',
        onTap: () => _sendTerminalKey(TerminalKey.home),
      ),
      _TerminalKeySpec(
        label: 'End',
        onTap: () => _sendTerminalKey(TerminalKey.end),
      ),
      _TerminalKeySpec(
        label: 'Del',
        onTap: () => _sendTerminalKey(TerminalKey.delete),
      ),
      _TerminalKeySpec(
        label: 'Ins',
        onTap: () => _sendTerminalKey(TerminalKey.insert),
      ),
      _TerminalKeySpec(
        label: '/',
        onTap: () => _sendTerminalChar('/'),
      ),
      _TerminalKeySpec(
        label: ':',
        onTap: () => _sendTerminalChar(':'),
      ),
      _TerminalKeySpec(
        label: '-',
        onTap: () => _sendTerminalChar('-'),
      ),
      _TerminalKeySpec(
        label: '|',
        onTap: () => _sendTerminalChar('|'),
      ),
      _TerminalKeySpec(
        label: '~',
        onTap: () => _sendTerminalChar('~'),
      ),
      _TerminalKeySpec(
        label: '_',
        onTap: () => _sendTerminalChar('_'),
      ),
      _TerminalKeySpec(
        label: '=',
        onTap: () => _sendTerminalChar('='),
      ),
      _TerminalKeySpec(
        label: '.',
        onTap: () => _sendTerminalChar('.'),
      ),
      _TerminalKeySpec(
        label: 'Space',
        onTap: () => _sendTerminalChar(' '),
        minWidth: 72,
      ),
    ];

    final keyRowSecondarySymbols = [
      _TerminalKeySpec(
        label: '[]',
        onTap: () => _sendPairedChars('[', ']'),
        onLongPress: () => _sendTerminalChar('['),
      ),
      _TerminalKeySpec(
        label: '()',
        onTap: () => _sendPairedChars('(', ')'),
        onLongPress: () => _sendTerminalChar('('),
      ),
      _TerminalKeySpec(
        label: '{}',
        onTap: () => _sendPairedChars('{', '}'),
        onLongPress: () => _sendTerminalChar('{'),
      ),
      _TerminalKeySpec(
        label: "''",
        onTap: () => _sendPairedChars("'", "'"),
        onLongPress: () => _sendTerminalChar("'"),
      ),
      _TerminalKeySpec(
        label: '""',
        onTap: () => _sendPairedChars('"', '"'),
        onLongPress: () => _sendTerminalChar('"'),
      ),
      _TerminalKeySpec(
        label: '<>',
        onTap: () => _sendPairedChars('<', '>'),
        onLongPress: () => _sendTerminalChar('<'),
      ),
      _TerminalKeySpec(
        label: '`',
        onTap: () => _sendTerminalChar('`'),
      ),
      _TerminalKeySpec(
        label: '?',
        onTap: () => _sendTerminalChar('?'),
      ),
      _TerminalKeySpec(
        label: '!',
        onTap: () => _sendTerminalChar('!'),
      ),
      _TerminalKeySpec(
        label: '&',
        onTap: () => _sendTerminalChar('&'),
      ),
      _TerminalKeySpec(
        label: '#',
        onTap: () => _sendTerminalChar('#'),
      ),
      _TerminalKeySpec(
        label: '@',
        onTap: () => _sendTerminalChar('@'),
      ),
      _TerminalKeySpec(
        label: r'$',
        onTap: () => _sendTerminalChar(r'$'),
      ),
      _TerminalKeySpec(
        label: '%',
        onTap: () => _sendTerminalChar('%'),
      ),
      _TerminalKeySpec(
        label: '^',
        onTap: () => _sendTerminalChar('^'),
      ),
    ];

    final keyRowSecondaryAdvanced = [
      _TerminalKeySpec(
        label: 'Ctrl+A',
        onTap: () => _sendCtrlCombo('a'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+C',
        onTap: () => _sendCtrlCombo('c'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+R',
        onTap: () => _sendCtrlCombo('r'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+L',
        onTap: () => _sendCtrlCombo('l'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+D',
        onTap: () => _sendCtrlCombo('d'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+Z',
        onTap: () => _sendCtrlCombo('z'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+K',
        onTap: () => _sendCtrlCombo('k'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+U',
        onTap: () => _sendCtrlCombo('u'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+W',
        onTap: () => _sendCtrlCombo('w'),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+Space',
        onTap: _sendCtrlNull,
      ),
      _TerminalKeySpec(
        label: 'Ctrl+Bksp',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.backspace,
          ctrl: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Alt+B',
        onTap: () => _sendAltCombo('b'),
      ),
      _TerminalKeySpec(
        label: 'Alt+F',
        onTap: () => _sendAltCombo('f'),
      ),
      _TerminalKeySpec(
        label: 'Alt+Bksp',
        onTap: _sendAltBackspace,
      ),
      _TerminalKeySpec(
        label: 'Ctrl+←',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowLeft,
          ctrl: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Ctrl+→',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowRight,
          ctrl: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Alt+←',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowLeft,
          alt: true,
        ),
      ),
      _TerminalKeySpec(
        label: 'Alt+→',
        onTap: () => _sendTerminalKeyCombo(
          TerminalKey.arrowRight,
          alt: true,
        ),
      ),
    ];

    final keyRowFn = [
      _TerminalKeySpec(
        label: 'F1',
        onTap: () => _sendTerminalKey(TerminalKey.f1),
      ),
      _TerminalKeySpec(
        label: 'F2',
        onTap: () => _sendTerminalKey(TerminalKey.f2),
      ),
      _TerminalKeySpec(
        label: 'F3',
        onTap: () => _sendTerminalKey(TerminalKey.f3),
      ),
      _TerminalKeySpec(
        label: 'F4',
        onTap: () => _sendTerminalKey(TerminalKey.f4),
      ),
      _TerminalKeySpec(
        label: 'F5',
        onTap: () => _sendTerminalKey(TerminalKey.f5),
      ),
      _TerminalKeySpec(
        label: 'F6',
        onTap: () => _sendTerminalKey(TerminalKey.f6),
      ),
      _TerminalKeySpec(
        label: 'F7',
        onTap: () => _sendTerminalKey(TerminalKey.f7),
      ),
      _TerminalKeySpec(
        label: 'F8',
        onTap: () => _sendTerminalKey(TerminalKey.f8),
      ),
      _TerminalKeySpec(
        label: 'F9',
        onTap: () => _sendTerminalKey(TerminalKey.f9),
      ),
      _TerminalKeySpec(
        label: 'F10',
        onTap: () => _sendTerminalKey(TerminalKey.f10),
      ),
      _TerminalKeySpec(
        label: 'F11',
        onTap: () => _sendTerminalKey(TerminalKey.f11),
      ),
      _TerminalKeySpec(
        label: 'F12',
        onTap: () => _sendTerminalKey(TerminalKey.f12),
      ),
    ];

    final isWideLayout = MediaQuery.of(context).size.width >= 900;
    final allowPaging = !_showFnRow && !isWideLayout;
    final baseKeys = List<_TerminalKeySpec>.from(keyRowSecondaryBase);
    final advancedKeys = List<_TerminalKeySpec>.from(keyRowSecondaryAdvanced);
    final symbolKeys = List<_TerminalKeySpec>.from(keyRowSecondarySymbols);
    if (allowPaging) {
      baseKeys.insert(
        baseKeys.length - 1,
        _TerminalKeySpec(
          label: 'More',
          onTap: _showAdvancedKeys,
          isEmphasis: true,
        ),
      );
      baseKeys.insert(
        baseKeys.length - 1,
        _TerminalKeySpec(
          label: 'Sym',
          onTap: _showSymbolKeys,
          isEmphasis: true,
        ),
      );
      advancedKeys.insert(
        0,
        _TerminalKeySpec(
          label: 'Back',
          onTap: _showBaseKeys,
          isEmphasis: true,
        ),
      );
      advancedKeys.insert(
        1,
        _TerminalKeySpec(
          label: 'Sym',
          onTap: _showSymbolKeys,
          isEmphasis: true,
        ),
      );
      symbolKeys.insert(
        0,
        _TerminalKeySpec(
          label: 'Back',
          onTap: _showBaseKeys,
          isEmphasis: true,
        ),
      );
      symbolKeys.insert(
        1,
        _TerminalKeySpec(
          label: 'More',
          onTap: _showAdvancedKeys,
          isEmphasis: true,
        ),
      );
    } else if (!_showFnRow) {
      baseKeys.insert(
        baseKeys.length - 1,
        _TerminalKeySpec(
          label: 'Sym',
          onTap: _showSymbolKeys,
          isEmphasis: true,
        ),
      );
      symbolKeys.insert(
        0,
        _TerminalKeySpec(
          label: 'Back',
          onTap: _showBaseKeys,
          isEmphasis: true,
        ),
      );
    }
    final keyRowSecondary = _showFnRow
        ? keyRowFn
        : (isWideLayout
            ? baseKeys
            : (_secondaryKeyPage == 2
                ? symbolKeys
                : (_secondaryKeyPage == 1 && allowPaging
                    ? advancedKeys
                    : baseKeys)));
    final toolActions = [
      _TerminalToolAction(
        label: 'Paste',
        icon: Icons.content_paste,
        onTap: () => unawaited(_pasteClipboard()),
      ),
      _TerminalToolAction(
        label: 'Copy',
        icon: Icons.content_copy,
        onTap: () => unawaited(_copySelection()),
      ),
      _TerminalToolAction(
        label: 'Search',
        icon: Icons.search,
        onTap: () => unawaited(_showTerminalSearchSheet()),
      ),
      _TerminalToolAction(
        label: _showNavOnly ? 'Nav On' : 'Nav',
        icon: Icons.navigation,
        onTap: _toggleNavOnly,
        isActive: _showNavOnly,
      ),
      _TerminalToolAction(
        label: 'Select',
        icon: Icons.select_all,
        onTap: _selectAllInTerminal,
      ),
      _TerminalToolAction(
        label: 'Unselect',
        icon: Icons.highlight_off_outlined,
        onTap: _clearSelection,
      ),
      _TerminalToolAction(
        label: 'Clear',
        icon: Icons.cleaning_services_outlined,
        onTap: _clearTerminal,
      ),
      _TerminalToolAction(
        label: 'Reset',
        icon: Icons.restart_alt,
        onTap: _resetTerminal,
      ),
      if (!_isTerminalAtBottom)
        _TerminalToolAction(
          label: 'Bottom',
          icon: Icons.vertical_align_bottom,
          onTap: _jumpToTerminalBottom,
        ),
      if (_hasActiveModifiers)
        _TerminalToolAction(
          label: 'Mods Off',
          icon: Icons.backspace_outlined,
          onTap: _clearModifiers,
          isActive: true,
        ),
      _TerminalToolAction(
        label: _selectionMode == SelectionMode.block ? 'Block' : 'Line',
        icon: Icons.text_fields,
        onTap: _toggleSelectionMode,
        isActive: _selectionMode == SelectionMode.block,
      ),
      _TerminalToolAction(
        label: _mouseInputEnabled ? 'Mouse On' : 'Mouse',
        icon: _mouseInputEnabled ? Icons.mouse : Icons.mouse_outlined,
        onTap: _toggleMouseInput,
        isActive: _mouseInputEnabled,
      ),
      _TerminalToolAction(
        label: _hardwareKeyboardOnly ? 'HW KB' : 'Soft KB',
        icon:
            _hardwareKeyboardOnly ? Icons.keyboard_alt_outlined : Icons.keyboard,
        onTap: _toggleHardwareKeyboardOnly,
        isActive: _hardwareKeyboardOnly,
      ),
      _TerminalToolAction(
        label: 'Font',
        icon: Icons.format_size,
        onTap: () => unawaited(_showTerminalFontSheet()),
      ),
      _TerminalToolAction(
        label: 'Theme',
        icon: Icons.palette_outlined,
        onTap: () => unawaited(_showTerminalThemeSheet()),
      ),
    ];
    return _TimelineDetailScaffold(
      title: 'Terminal',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        sessionLabel,
                        style: headerStyle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Rename session',
                      onPressed: active == null ? null : _renameActiveSession,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                    IconButton(
                      tooltip: 'Switch session',
                      onPressed: _sessions.isEmpty
                          ? null
                          : () => _openSessionPicker(),
                      icon: const Icon(Icons.layers_outlined),
                    ),
                    IconButton(
                      tooltip: 'New session',
                      onPressed: _createSession,
                      icon: const Icon(Icons.add),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusStyle.background,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          sessionStatus,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: statusStyle.foreground,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        connectionLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF64748B),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_terminalSearchQuery.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE2E8F0),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            'Search: "${_terminalSearchQuery}"',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: const Color(0xFF334155),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (_remoteFetchError != null) ...[
                  const SizedBox(height: 8),
                  _InlineStatus(
                    message: _remoteFetchError!,
                    isError: true,
                  ),
                ] else if (showEmptyHint) ...[
                  const SizedBox(height: 8),
                  const _InlineStatus(
                    message: 'No terminal sessions yet.',
                  ),
                ],
                if (resolvedStatusMessage != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    resolvedStatusMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: resolvedStatusIsError
                          ? const Color(0xFFB91C1C)
                          : const Color(0xFF16A34A),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (isDisconnected) ...[
                  const SizedBox(height: 6),
                  _TerminalReconnectCard(onReconnect: _attemptReconnect),
                ],
              ],
            ),
          ),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: terminalBackground,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: terminalBorderColor),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: terminal == null
                          ? Center(
                              child: Text(
                                'Create a session to start.',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: terminalForeground.withAlpha(180),
                                ),
                              ),
                            )
                          : TerminalView(
                              terminal,
                              controller: _terminalController,
                              focusNode: _terminalFocusNode,
                              scrollController: _terminalScrollController,
                              autofocus: true,
                              theme: terminalTheme,
                              textStyle: terminalStyle,
                              padding:
                                  const EdgeInsets.fromLTRB(10, 8, 10, 12),
                              backgroundOpacity: 0,
                              cursorType: TerminalCursorType.block,
                              keyboardType: TextInputType.text,
                              keyboardAppearance: isLightTerminal
                                  ? Brightness.light
                                  : Brightness.dark,
                              deleteDetection: true,
                              hardwareKeyboardOnly: _hardwareKeyboardOnly,
                              readOnly:
                                  active == null || isEnded || isDisconnected,
                            ),
                    ),
                    if (terminal != null && !_isTerminalAtBottom)
                      Positioned(
                        right: 12,
                        bottom: 12,
                        child: InkWell(
                          onTap: _jumpToTerminalBottom,
                          borderRadius: BorderRadius.circular(999),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: terminalOverlayBackground,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: terminalOverlayForeground
                                    .withAlpha(isLightTerminal ? 40 : 70),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.vertical_align_bottom,
                                  size: 14,
                                  color: terminalOverlayForeground,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  'Bottom',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: terminalOverlayForeground,
                                    fontWeight: FontWeight.w700,
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
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
              10,
              6,
              10,
              _showKeyBar ? 10 : 6,
            ),
            decoration: const BoxDecoration(
              color: dockBackground,
              border: Border(
                top: BorderSide(color: Color(0xFF1E293B)),
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Spacer(),
                    IconButton(
                      tooltip: _showKeyBar ? 'Hide keys' : 'Show keys',
                      onPressed: () {
                        setState(() {
                          _showKeyBar = !_showKeyBar;
                        });
                      },
                      icon: Icon(
                        _showKeyBar
                            ? Icons.keyboard_hide_outlined
                            : Icons.keyboard_outlined,
                        color: const Color(0xFFE2E8F0),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: toolActions
                        .map(
                          (action) => Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: _TerminalToolButton(action: action),
                          ),
                        )
                        .toList(),
                  ),
                ),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 200),
                  crossFadeState: _showKeyBar
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: const SizedBox.shrink(),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      children: [
                        _buildKeyRow(keyRowPrimary),
                        if (!_showNavOnly) ...[
                          const SizedBox(height: 6),
                          _buildKeyRow(keyRowSecondary),
                          if (isWideLayout && !_showFnRow) ...[
                            const SizedBox(height: 6),
                            _buildKeyRow(keyRowSecondaryAdvanced),
                            if (_secondaryKeyPage == 2) ...[
                              const SizedBox(height: 6),
                              _buildKeyRow(keyRowSecondarySymbols),
                            ],
                          ],
                        ],
                      ],
                    ),
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

enum TerminalStream { stdout, stderr }
