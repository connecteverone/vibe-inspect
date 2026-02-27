part of '../main.dart';

extension _TerminalWorkspaceLogic on _TerminalWorkspaceScreenState {
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
    _agentClient = AgentCommandClient(
      baseUrl: baseUrl,
      client: _httpClient!,
      authToken: widget.authToken,
      clientId: widget.clientId,
      clientName: widget.clientName,
    );
  }

  Future<_RemoteTerminalFetchResult> _fetchRemoteTerminalSessions() async {
    final client = _agentClient;
    if (client == null) {
      return _RemoteTerminalFetchResult.failure(
        'Connect to the desktop agent to load sessions.',
        shouldRetry: false,
      );
    }
    try {
      final sessions = await client.fetchTerminalSessions();
      return _RemoteTerminalFetchResult.success(sessions);
    } on AgentCommandFailure catch (error) {
      final presentation = _presentAgentFailure(
        error,
        fallbackMessage: 'Unable to load terminal sessions.',
      );
      _logErrorDetails('terminal_sessions', presentation);
      final code = (error.code ?? '').trim().toLowerCase();
      final shouldRetry =
          code != 'unsupported_action' &&
          code != 'not_supported' &&
          code != 'unauthorized' &&
          code != 'forbidden' &&
          code != 'invalid_token';
      return _RemoteTerminalFetchResult.failure(
        _formatErrorMessage(presentation),
        shouldRetry: shouldRetry,
      );
    } catch (_) {
      return _RemoteTerminalFetchResult.failure(
        'Unable to load terminal sessions.',
      );
    }
  }

  Uri? _terminalWsUri(String baseUrl, String sessionId, {String? wsTicket}) {
    Uri base;
    try {
      base = Uri.parse(baseUrl);
    } catch (_) {
      return null;
    }
    final scheme = switch (base.scheme) {
      'https' => 'wss',
      'http' => 'ws',
      'wss' => 'wss',
      'ws' => 'ws',
      _ => '',
    };
    if (scheme.isEmpty) {
      return null;
    }
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final path = basePath.isEmpty
        ? '/terminal/$sessionId'
        : '$basePath/terminal/$sessionId';
    final queryParameters = Map<String, String>.from(base.queryParameters);
    final ticket = wsTicket?.trim();
    if (ticket != null && ticket.isNotEmpty) {
      queryParameters['ws_ticket'] = ticket;
      queryParameters.remove('auth_token');
    } else {
      final token = widget.authToken?.trim();
      if (token != null && token.isNotEmpty) {
        queryParameters['auth_token'] = token;
      }
    }
    final clientId = widget.clientId?.trim();
    if (clientId != null && clientId.isNotEmpty) {
      queryParameters['client_id'] = clientId;
    }
    final clientName = widget.clientName?.trim();
    if (clientName != null && clientName.isNotEmpty) {
      queryParameters['client_name'] = clientName;
    }
    return base.replace(
      scheme: scheme,
      path: path,
      queryParameters: queryParameters,
    );
  }

  TerminalTargetPlatform _resolveTerminalPlatform() {
    if (kIsWeb) {
      return TerminalTargetPlatform.web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return TerminalTargetPlatform.android;
      case TargetPlatform.iOS:
        return TerminalTargetPlatform.ios;
      case TargetPlatform.fuchsia:
        return TerminalTargetPlatform.fuchsia;
      case TargetPlatform.linux:
        return TerminalTargetPlatform.linux;
      case TargetPlatform.macOS:
        return TerminalTargetPlatform.macos;
      case TargetPlatform.windows:
        return TerminalTargetPlatform.windows;
    }
  }

  Terminal _buildTerminalForSession(String sessionId) {
    final terminal = Terminal(
      maxLines: _terminalMaxLines,
      platform: _resolveTerminalPlatform(),
      onOutput: (data) => _handleTerminalInput(sessionId, data),
    );
    terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
      // Keep pixel values unused for now; grid size drives PTY resize.
      unawaited(_sendTerminalResize(sessionId, cols, rows));
    };
    return terminal;
  }

  KeyEventResult _handleTerminalViewKeyEvent(FocusNode _, KeyEvent event) {
    final deferToTextInput = shouldDeferTerminalHardwareKeyToTextInput(
      event,
      ctrlPressed: HardwareKeyboard.instance.isControlPressed || _ctrlModifier,
      altPressed: HardwareKeyboard.instance.isAltPressed || _altModifier,
      metaPressed: HardwareKeyboard.instance.isMetaPressed,
    );
    if (deferToTextInput) {
      return KeyEventResult.skipRemainingHandlers;
    }
    return KeyEventResult.ignored;
  }

  void _hydrateTerminal(
    String sessionId,
    Terminal terminal,
    List<TerminalOutputEntry> entries,
  ) {
    if (entries.isEmpty) {
      return;
    }
    final buffer = StringBuffer();
    for (final entry in entries) {
      buffer.write(entry.text);
    }
    terminal.write(buffer.toString());
    if (sessionId == _activeSessionId) {
      if (_isTerminalAtBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _jumpToTerminalBottom();
          }
        });
      }
      _scheduleTerminalSearchRefresh();
    }
  }

  void _focusTerminal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      FocusScope.of(context).requestFocus(_terminalFocusNode);
    });
  }

  Terminal? _activeTerminal() {
    final active = _activeSession;
    if (active == null) {
      return null;
    }
    return _terminals[active.session.id];
  }

  String? _sessionStatusReason(TerminalSessionView? session) {
    if (session == null) {
      return null;
    }
    final status = session.session.status.toLowerCase();
    if (!_isTerminalClosed(status) &&
        status != 'disconnected' &&
        status != 'error') {
      return null;
    }
    final reason = session.lastEvent?.payload['error_message']?.toString();
    if (reason == null) {
      return null;
    }
    final trimmed = reason.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  void _setTerminalStatusMessage(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    _updateState(() {
      _statusMessage = message;
      _statusIsError = isError;
    });
  }

  Terminal? _requireActiveTerminal() {
    final active = _activeSession;
    if (active == null) {
      _setTerminalStatusMessage('Create a session to start.');
      return null;
    }
    final status = active.session.status.toLowerCase();
    if (_isTerminalClosed(status)) {
      _setTerminalStatusMessage(
        'This session is no longer active.',
        isError: true,
      );
      return null;
    }
    if (status == 'disconnected' || status == 'error') {
      _setTerminalStatusMessage(
        'Session disconnected. Reconnect to type.',
        isError: true,
      );
      return null;
    }
    return _terminals[active.session.id];
  }

  void _toggleCtrlModifier() {
    _updateState(() {
      if (_ctrlLocked) {
        _ctrlLocked = false;
        _ctrlModifier = false;
      } else {
        _ctrlModifier = !_ctrlModifier;
        _ctrlLocked = false;
      }
    });
    _focusTerminal();
  }

  void _toggleCtrlLock() {
    _updateState(() {
      _ctrlLocked = !_ctrlLocked;
      _ctrlModifier = _ctrlLocked;
    });
    _focusTerminal();
  }

  void _toggleAltModifier() {
    _updateState(() {
      if (_altLocked) {
        _altLocked = false;
        _altModifier = false;
      } else {
        _altModifier = !_altModifier;
        _altLocked = false;
      }
    });
    _focusTerminal();
  }

  void _toggleAltLock() {
    _updateState(() {
      _altLocked = !_altLocked;
      _altModifier = _altLocked;
    });
    _focusTerminal();
  }

  void _toggleShiftModifier() {
    _updateState(() {
      if (_shiftLocked) {
        _shiftLocked = false;
        _shiftModifier = false;
      } else {
        _shiftModifier = !_shiftModifier;
        _shiftLocked = false;
      }
    });
    _focusTerminal();
  }

  void _toggleShiftLock() {
    _updateState(() {
      _shiftLocked = !_shiftLocked;
      _shiftModifier = _shiftLocked;
    });
    _focusTerminal();
  }

  void _toggleFnRow() {
    _updateState(() {
      _showFnRow = !_showFnRow;
    });
    _focusTerminal();
  }

  void _showBaseKeys() {
    _updateState(() {
      _secondaryKeyPage = 0;
    });
    _focusTerminal();
  }

  void _showAdvancedKeys() {
    _updateState(() {
      _secondaryKeyPage = 1;
    });
    _focusTerminal();
  }

  void _showSymbolKeys() {
    _updateState(() {
      _secondaryKeyPage = 2;
    });
    _focusTerminal();
  }

  void _toggleNavOnly() {
    _updateState(() {
      _showNavOnly = !_showNavOnly;
    });
    _focusTerminal();
  }

  void _toggleTerminalDock() {
    _updateState(() {
      _showTerminalDock = !_showTerminalDock;
      if (!_showTerminalDock) {
        _terminalDockHeight = 0;
      }
    });
    if (_showTerminalDock) {
      _focusTerminal();
    }
  }

  void _toggleKeyBar() {
    _updateState(() {
      _showKeyBar = !_showKeyBar;
    });
    _focusTerminal();
  }

  void _toggleTerminalKeyboard({required bool isVisible}) {
    if (isVisible) {
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
      return;
    }
    if (_hardwareKeyboardOnly) {
      _updateState(() {
        _hardwareKeyboardOnly = false;
      });
    }
    _focusTerminal();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.show'));
  }

  void _clearModifiers() {
    _updateState(() {
      _ctrlModifier = false;
      _ctrlLocked = false;
      _altModifier = false;
      _altLocked = false;
      _shiftModifier = false;
      _shiftLocked = false;
    });
    _focusTerminal();
  }

  void _consumeOneShotModifiers() {
    if ((!_ctrlModifier || _ctrlLocked) &&
        (!_altModifier || _altLocked) &&
        (!_shiftModifier || _shiftLocked)) {
      return;
    }
    _updateState(() {
      if (_ctrlModifier && !_ctrlLocked) {
        _ctrlModifier = false;
      }
      if (_altModifier && !_altLocked) {
        _altModifier = false;
      }
      if (_shiftModifier && !_shiftLocked) {
        _shiftModifier = false;
      }
    });
  }

  void _applyPointerInputMode() {
    _terminalController.setPointerInputs(
      _mouseInputEnabled
          ? const PointerInputs.all()
          : const PointerInputs.none(),
    );
  }

  void _handleTerminalScroll() {
    if (!_terminalScrollController.hasClients) {
      return;
    }
    final position = _terminalScrollController.position;
    final isAtBottom = position.pixels >= position.maxScrollExtent - 4;
    if (isAtBottom == _isTerminalAtBottom) {
      return;
    }
    _updateState(() {
      _isTerminalAtBottom = isAtBottom;
    });
  }

  void _jumpToTerminalBottom() {
    if (!_terminalScrollController.hasClients) {
      return;
    }
    _terminalScrollController.animateTo(
      _terminalScrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _toggleMouseInput() {
    _updateState(() {
      _mouseInputEnabled = !_mouseInputEnabled;
    });
    _applyPointerInputMode();
    _focusTerminal();
  }

  void _toggleHardwareKeyboardOnly() {
    _updateState(() {
      _hardwareKeyboardOnly = !_hardwareKeyboardOnly;
    });
    _focusTerminal();
  }

  void _toggleSelectionMode() {
    _updateState(() {
      _selectionMode = _selectionMode == SelectionMode.line
          ? SelectionMode.block
          : SelectionMode.line;
    });
    _terminalController.setSelectionMode(_selectionMode);
    _focusTerminal();
  }

  void _adjustTerminalFontSize(double nextSize) {
    _updateState(() {
      _terminalFontSize = nextSize;
    });
    _focusTerminal();
  }

  void _setTerminalTheme(int index) {
    _updateState(() {
      _terminalThemeIndex = index;
    });
    _focusTerminal();
  }

  void _sendTerminalKey(TerminalKey key, {bool shift = false}) {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.keyInput(
      key,
      ctrl: _ctrlModifier,
      alt: _altModifier,
      shift: shift || _shiftModifier,
    );
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendTerminalKeyCombo(
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.keyInput(key, ctrl: ctrl, alt: alt, shift: shift);
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendTerminalChar(String value) {
    final terminal = _requireActiveTerminal();
    if (terminal == null || value.isEmpty) {
      return;
    }
    if (_ctrlModifier && value == ' ') {
      terminal.textInput('\x00');
      _focusTerminal();
      return;
    }
    if (_altModifier && value == ' ') {
      terminal.textInput('\x1b ');
      _focusTerminal();
      return;
    }
    final normalized = _shiftModifier ? value.toUpperCase() : value;
    final charCode = normalized.runes.first;
    if (_ctrlModifier || _altModifier) {
      final handled = terminal.charInput(
        charCode,
        ctrl: _ctrlModifier,
        alt: _altModifier,
      );
      if (!handled) {
        terminal.textInput(normalized);
      }
    } else {
      terminal.textInput(normalized);
    }
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendCtrlCombo(String value) {
    final terminal = _requireActiveTerminal();
    if (terminal == null || value.isEmpty) {
      return;
    }
    terminal.charInput(value.runes.first, ctrl: true);
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendCtrlNull() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.textInput('\x00');
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendAltCombo(String value) {
    final terminal = _requireActiveTerminal();
    if (terminal == null || value.isEmpty) {
      return;
    }
    terminal.charInput(value.runes.first, alt: true);
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendPairedChars(String open, String close) {
    if (_hasActiveModifiers) {
      _sendTerminalChar(open);
      return;
    }
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.textInput('$open$close');
    terminal.keyInput(TerminalKey.arrowLeft);
    _focusTerminal();
  }

  String _applyTerminalModifiers(String data) {
    if (!_hasActiveModifiers || data.isEmpty) {
      return data;
    }
    final runes = data.runes.toList(growable: false);
    if (runes.length != 1) {
      return data;
    }
    final rune = runes.first;
    if (rune < 32 || rune == 127) {
      return data;
    }
    if (_ctrlModifier && rune == 32) {
      return '\x00';
    }
    if (_altModifier && rune == 32) {
      return '\x1b ';
    }
    var normalized = data;
    if (_shiftModifier) {
      final upper = data.toUpperCase();
      if (upper.runes.length == 1) {
        normalized = upper;
      }
    }
    final normalizedRune = normalized.runes.first;
    if (_ctrlModifier) {
      final mapped = _mapCtrlRune(normalizedRune);
      if (mapped != null) {
        return String.fromCharCode(mapped);
      }
    }
    if (_altModifier &&
        _resolveTerminalPlatform() != TerminalTargetPlatform.macos) {
      final mapped = _mapAltRune(normalizedRune);
      if (mapped != null) {
        return String.fromCharCodes([0x1b, mapped]);
      }
    }
    return normalized;
  }

  int? _mapCtrlRune(int rune) {
    if (rune >= 97 && rune <= 122) {
      return rune - 96;
    }
    if (rune >= 91 && rune <= 95) {
      return rune - 91 + 27;
    }
    return null;
  }

  int? _mapAltRune(int rune) {
    if (rune >= 97 && rune <= 122) {
      return rune - 97 + 65;
    }
    return null;
  }

  Future<void> _copySelection() async {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    final selection = _terminalController.selection;
    if (selection == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No selection to copy.')));
      return;
    }
    final text = terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Copied to clipboard.')));
  }

  Future<void> _pasteClipboard() async {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) {
      return;
    }
    terminal.paste(text);
    _focusTerminal();
  }

  void _selectAllInTerminal() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    _terminalController.setSelection(
      terminal.buffer.createAnchor(
        0,
        terminal.buffer.height - terminal.viewHeight,
      ),
      terminal.buffer.createAnchor(
        terminal.viewWidth,
        terminal.buffer.height - 1,
      ),
      mode: SelectionMode.line,
    );
    _focusTerminal();
  }

  void _clearSelection() {
    _terminalController.clearSelection();
    _focusTerminal();
  }

  void _clearTerminal() {
    _sendCtrlCombo('l');
  }

  void _resetTerminal() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.textInput('\x1bc');
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _sendAltBackspace() {
    final terminal = _requireActiveTerminal();
    if (terminal == null) {
      return;
    }
    terminal.keyInput(TerminalKey.backspace, alt: true);
    _consumeOneShotModifiers();
    _focusTerminal();
  }

  void _clearTerminalSearchHighlights({bool clearQuery = false}) {
    for (final highlight in _terminalSearchHighlights) {
      highlight.dispose();
    }
    _terminalSearchHighlights.clear();
    _terminalSearchMatches.clear();
    _terminalSearchIndex = -1;
    if (clearQuery) {
      _terminalSearchQuery = '';
    }
  }

  void _runTerminalSearch(
    String query, {
    bool? caseSensitive,
    bool preserveSelection = false,
  }) {
    final terminal = _activeTerminal();
    if (terminal == null) {
      return;
    }
    final useCase = caseSensitive ?? _terminalSearchCaseSensitive;
    _clearTerminalSearchHighlights(clearQuery: false);
    if (query.trim().isEmpty) {
      _updateState(() {
        _terminalSearchQuery = '';
        _terminalSearchCaseSensitive = useCase;
      });
      return;
    }
    final matches = <_TerminalSearchMatch>[];
    final needle = useCase ? query : query.toLowerCase();
    final buffer = terminal.buffer;
    const maxMatches = 240;
    for (var lineIndex = 0; lineIndex < buffer.height; lineIndex++) {
      final lineText = buffer.lines[lineIndex].getText();
      if (lineText.isEmpty) {
        continue;
      }
      final haystack = useCase ? lineText : lineText.toLowerCase();
      var searchIndex = 0;
      while (true) {
        final found = haystack.indexOf(needle, searchIndex);
        if (found == -1) {
          break;
        }
        matches.add(
          _TerminalSearchMatch(
            line: lineIndex,
            start: found,
            end: found + needle.length,
          ),
        );
        if (matches.length >= maxMatches) {
          break;
        }
        searchIndex = found + needle.length;
      }
      if (matches.length >= maxMatches) {
        break;
      }
    }

    final highlights = <TerminalHighlight>[];
    for (final match in matches) {
      final start = match.start.clamp(0, buffer.viewWidth);
      final end = match.end.clamp(start, buffer.viewWidth);
      if (end == start) {
        continue;
      }
      highlights.add(
        _terminalController.highlight(
          p1: buffer.createAnchor(start, match.line),
          p2: buffer.createAnchor(end, match.line),
          color: const Color(0x5538BDF8),
        ),
      );
    }

    _updateState(() {
      _terminalSearchQuery = query;
      _terminalSearchCaseSensitive = useCase;
      _terminalSearchMatches.addAll(matches);
      _terminalSearchHighlights.addAll(highlights);
      if (matches.isEmpty) {
        _terminalSearchIndex = -1;
      } else if (preserveSelection && _terminalSearchIndex >= 0) {
        _terminalSearchIndex = _terminalSearchIndex.clamp(
          0,
          matches.length - 1,
        );
      } else {
        _terminalSearchIndex = 0;
      }
    });

    if (_terminalSearchIndex >= 0) {
      _selectTerminalSearchMatch(_terminalSearchIndex);
    }
  }

  void _scheduleTerminalSearchRefresh() {
    if (_terminalSearchQuery.isEmpty) {
      return;
    }
    _terminalSearchRefreshTimer?.cancel();
    _terminalSearchRefreshTimer = Timer(const Duration(milliseconds: 260), () {
      if (!mounted) {
        return;
      }
      _runTerminalSearch(
        _terminalSearchQuery,
        caseSensitive: _terminalSearchCaseSensitive,
        preserveSelection: true,
      );
    });
  }

  void _navigateTerminalSearch(int delta) {
    if (_terminalSearchMatches.isEmpty) {
      return;
    }
    if (_terminalSearchIndex < 0) {
      _selectTerminalSearchMatch(0);
      return;
    }
    final nextIndex =
        (_terminalSearchIndex + delta) % _terminalSearchMatches.length;
    _selectTerminalSearchMatch(
      nextIndex < 0 ? _terminalSearchMatches.length - 1 : nextIndex,
    );
  }

  void _selectTerminalSearchMatch(int index) {
    if (index < 0 || index >= _terminalSearchMatches.length) {
      return;
    }
    final terminal = _activeTerminal();
    if (terminal == null) {
      return;
    }
    final match = _terminalSearchMatches[index];
    final buffer = terminal.buffer;
    final start = match.start.clamp(0, buffer.viewWidth);
    final end = match.end.clamp(start, buffer.viewWidth);
    if (start == end) {
      return;
    }
    _terminalController.setSelection(
      buffer.createAnchor(start, match.line),
      buffer.createAnchor(end, match.line),
      mode: SelectionMode.line,
    );
    _updateState(() {
      _terminalSearchIndex = index;
    });
    _scrollToTerminalLine(match.line);
  }

  void _scrollToTerminalLine(int lineIndex) {
    if (!_terminalScrollController.hasClients) {
      return;
    }
    final terminal = _activeTerminal();
    if (terminal == null) {
      return;
    }
    final extraLines = terminal.buffer.height - terminal.viewHeight;
    if (extraLines <= 0) {
      return;
    }
    final maxExtent = _terminalScrollController.position.maxScrollExtent;
    final lineHeight = maxExtent / extraLines;
    final target = (lineIndex * lineHeight).clamp(0.0, maxExtent);
    _terminalScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  List<_TerminalThemeSpec> _terminalThemeOptions() {
    const midnight = TerminalTheme(
      cursor: Color(0xFFE2E8F0),
      selection: Color(0x33475569),
      foreground: Color(0xFFE2E8F0),
      background: Color(0xFF0B1120),
      black: Color(0xFF020617),
      red: Color(0xFFF87171),
      green: Color(0xFF4ADE80),
      yellow: Color(0xFFFACC15),
      blue: Color(0xFF60A5FA),
      magenta: Color(0xFFD946EF),
      cyan: Color(0xFF22D3EE),
      white: Color(0xFFF8FAFC),
      brightBlack: Color(0xFF334155),
      brightRed: Color(0xFFFCA5A5),
      brightGreen: Color(0xFF86EFAC),
      brightYellow: Color(0xFFFDE047),
      brightBlue: Color(0xFF93C5FD),
      brightMagenta: Color(0xFFF0ABFC),
      brightCyan: Color(0xFF67E8F9),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFF1F2937),
      searchHitBackgroundCurrent: Color(0xFF334155),
      searchHitForeground: Color(0xFFE2E8F0),
    );
    const slate = TerminalTheme(
      cursor: Color(0xFFE2E8F0),
      selection: Color(0x332E3A59),
      foreground: Color(0xFFE2E8F0),
      background: Color(0xFF111827),
      black: Color(0xFF020617),
      red: Color(0xFFFB7185),
      green: Color(0xFF22C55E),
      yellow: Color(0xFFFBBF24),
      blue: Color(0xFF38BDF8),
      magenta: Color(0xFFC084FC),
      cyan: Color(0xFF2DD4BF),
      white: Color(0xFFF8FAFC),
      brightBlack: Color(0xFF334155),
      brightRed: Color(0xFFFDA4AF),
      brightGreen: Color(0xFF86EFAC),
      brightYellow: Color(0xFFFCD34D),
      brightBlue: Color(0xFF7DD3FC),
      brightMagenta: Color(0xFFE9D5FF),
      brightCyan: Color(0xFF5EEAD4),
      brightWhite: Color(0xFFFFFFFF),
      searchHitBackground: Color(0xFF1F2937),
      searchHitBackgroundCurrent: Color(0xFF475569),
      searchHitForeground: Color(0xFFE2E8F0),
    );
    const paper = TerminalTheme(
      cursor: Color(0xFF0F172A),
      selection: Color(0x33475569),
      foreground: Color(0xFF0F172A),
      background: Color(0xFFF8FAFC),
      black: Color(0xFF0F172A),
      red: Color(0xFFDC2626),
      green: Color(0xFF16A34A),
      yellow: Color(0xFFD97706),
      blue: Color(0xFF2563EB),
      magenta: Color(0xFF7C3AED),
      cyan: Color(0xFF0891B2),
      white: Color(0xFFE2E8F0),
      brightBlack: Color(0xFF64748B),
      brightRed: Color(0xFFF87171),
      brightGreen: Color(0xFF4ADE80),
      brightYellow: Color(0xFFFACC15),
      brightBlue: Color(0xFF60A5FA),
      brightMagenta: Color(0xFFC4B5FD),
      brightCyan: Color(0xFF22D3EE),
      brightWhite: Color(0xFF0F172A),
      searchHitBackground: Color(0xFFE2E8F0),
      searchHitBackgroundCurrent: Color(0xFFCBD5F5),
      searchHitForeground: Color(0xFF0F172A),
    );
    return const [
      _TerminalThemeSpec(label: 'Midnight', theme: midnight),
      _TerminalThemeSpec(label: 'Slate', theme: slate),
      _TerminalThemeSpec(label: 'Paper', theme: paper),
    ];
  }

  Future<void> _showTerminalSearchSheet() async {
    final controller = TextEditingController(text: _terminalSearchQuery);
    bool caseSensitive = _terminalSearchCaseSensitive;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final matches = _terminalSearchMatches.length;
            final index = _terminalSearchIndex >= 0
                ? _terminalSearchIndex + 1
                : 0;
            return Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 12,
                bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Search in terminal',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Find text...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      _runTerminalSearch(value, caseSensitive: caseSensitive);
                      setSheetState(() {});
                    },
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      FilterChip(
                        label: const Text('Case sensitive'),
                        selected: caseSensitive,
                        onSelected: (selected) {
                          caseSensitive = selected;
                          _runTerminalSearch(
                            controller.text,
                            caseSensitive: caseSensitive,
                          );
                          setSheetState(() {});
                        },
                      ),
                      if (_terminalSearchQuery.isNotEmpty)
                        ActionChip(
                          label: const Text('Clear'),
                          onPressed: () {
                            controller.clear();
                            _clearTerminalSearchHighlights(clearQuery: true);
                            _updateState(() {});
                            setSheetState(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Text(
                        matches == 0 ? 'No matches' : '$index / $matches',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFF475569),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Previous match',
                        onPressed: matches == 0
                            ? null
                            : () => _navigateTerminalSearch(-1),
                        icon: const Icon(Icons.keyboard_arrow_up),
                      ),
                      IconButton(
                        tooltip: 'Next match',
                        onPressed: matches == 0
                            ? null
                            : () => _navigateTerminalSearch(1),
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showTerminalFontSheet() async {
    var current = _terminalFontSize;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Font size',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Slider(
                    value: current,
                    min: 11,
                    max: 18,
                    divisions: 14,
                    label: current.toStringAsFixed(1),
                    onChanged: (value) {
                      setSheetState(() {
                        current = value;
                      });
                      _adjustTerminalFontSize(value);
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Tap outside to close.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showTerminalThemeSheet() async {
    final options = _terminalThemeOptions();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFF8FAFC),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Terminal theme',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              ...List.generate(options.length, (index) {
                final theme = options[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.theme.background,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: index == _terminalThemeIndex
                          ? const Color(0xFF38BDF8)
                          : const Color(0xFFE2E8F0),
                      width: index == _terminalThemeIndex ? 2 : 1,
                    ),
                  ),
                  child: ListTile(
                    onTap: () => _setTerminalTheme(index),
                    leading: Icon(
                      index == _terminalThemeIndex
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: theme.theme.foreground,
                    ),
                    title: Text(
                      theme.label,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: theme.theme.foreground,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      theme.theme.background == const Color(0xFFF8FAFC)
                          ? 'Light surface'
                          : 'Dark surface',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: theme.theme.foreground.withAlpha(180),
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  Widget _buildKeyRow(List<_TerminalKeySpec> keys) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: keys
            .map(
              (key) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _TerminalKeyButton(spec: key),
              ),
            )
            .toList(),
      ),
    );
  }
}
