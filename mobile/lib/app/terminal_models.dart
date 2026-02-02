part of '../main.dart';

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
    this.nextSeq = 0,
    this.notificationSeq = 0,
    this.exitCode,
    this.lastCommand,
    this.lastEvent,
  });

  final ToolSession session;
  final List<TerminalOutputEntry> output;
  final int nextSeq;
  final int notificationSeq;
  final int? exitCode;
  final String? lastCommand;
  final TimelineEvent? lastEvent;

  TerminalSessionView copyWith({
    ToolSession? session,
    List<TerminalOutputEntry>? output,
    int? nextSeq,
    int? notificationSeq,
    int? exitCode,
    String? lastCommand,
    TimelineEvent? lastEvent,
  }) {
    return TerminalSessionView(
      session: session ?? this.session,
      output: output ?? this.output,
      nextSeq: nextSeq ?? this.nextSeq,
      notificationSeq: notificationSeq ?? this.notificationSeq,
      exitCode: exitCode ?? this.exitCode,
      lastCommand: lastCommand ?? this.lastCommand,
      lastEvent: lastEvent ?? this.lastEvent,
    );
  }
}

class _TerminalGrid {
  const _TerminalGrid({required this.cols, required this.rows});

  final int cols;
  final int rows;

  @override
  bool operator ==(Object other) {
    return other is _TerminalGrid &&
        other.cols == cols &&
        other.rows == rows;
  }

  @override
  int get hashCode => Object.hash(cols, rows);
}

class _TerminalKeySpec {
  const _TerminalKeySpec({
    required this.label,
    required this.onTap,
    this.onLongPress,
    this.isActive = false,
    this.isLocked = false,
    this.isEmphasis = false,
    this.isRepeatable = false,
    this.minWidth,
  });

  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool isActive;
  final bool isLocked;
  final bool isEmphasis;
  final bool isRepeatable;
  final double? minWidth;
}

class _TerminalSearchMatch {
  const _TerminalSearchMatch({
    required this.line,
    required this.start,
    required this.end,
  });

  final int line;
  final int start;
  final int end;
}

class _TerminalThemeSpec {
  const _TerminalThemeSpec({
    required this.label,
    required this.theme,
  });

  final String label;
  final TerminalTheme theme;
}

class _TerminalToolAction {
  const _TerminalToolAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isActive = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;
}

class _TerminalKeyButton extends StatefulWidget {
  const _TerminalKeyButton({required this.spec});

  final _TerminalKeySpec spec;

  @override
  State<_TerminalKeyButton> createState() => _TerminalKeyButtonState();
}

class _TerminalKeyButtonState extends State<_TerminalKeyButton> {
  Timer? _repeatTimer;
  Timer? _repeatStartTimer;

  @override
  void dispose() {
    _cancelRepeat();
    super.dispose();
  }

  void _cancelRepeat() {
    _repeatStartTimer?.cancel();
    _repeatStartTimer = null;
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  void _startRepeat() {
    if (!widget.spec.isRepeatable) {
      return;
    }
    widget.spec.onTap();
    _repeatStartTimer = Timer(const Duration(milliseconds: 300), () {
      _repeatTimer = Timer.periodic(
        const Duration(milliseconds: 70),
        (_) => widget.spec.onTap(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final isLocked = spec.isLocked;
    final isActive = spec.isActive;
    final baseColor = isLocked
        ? const Color(0xFF7DD3FC)
        : (isActive
            ? const Color(0xFF34D399)
            : (spec.isEmphasis
                ? const Color(0xFFF8FAFC)
                : const Color(0xFFCBD5F5)));
    final background = isLocked
        ? const Color(0xFF0B1F33)
        : (isActive ? const Color(0xFF0B3B2E) : const Color(0xFF111827));
    final borderColor = isLocked
        ? const Color(0xFF38BDF8)
        : (isActive
            ? const Color(0xFF34D399)
            : (spec.isEmphasis
                ? const Color(0xFF475569)
                : const Color(0xFF1F2937)));
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        spec.onTap();
      },
      onLongPressStart: (_) {
        if (spec.onLongPress != null) {
          HapticFeedback.selectionClick();
          spec.onLongPress!();
          return;
        }
        _startRepeat();
      },
      onLongPressEnd: (_) => _cancelRepeat(),
      onLongPressCancel: _cancelRepeat,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(minWidth: spec.minWidth ?? 0),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 6,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Text(
          spec.label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: baseColor,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
        ),
      ),
    );
  }
}

class _TerminalToolButton extends StatelessWidget {
  const _TerminalToolButton({required this.action});

  final _TerminalToolAction action;

  @override
  Widget build(BuildContext context) {
    final foreground = action.isActive
        ? const Color(0xFFE2E8F0)
        : const Color(0xFFCBD5F5);
    final background = action.isActive
        ? const Color(0xFF1E293B)
        : const Color(0xFF0F172A);
    final borderColor = action.isActive
        ? const Color(0xFF38BDF8)
        : const Color(0xFF1F2937);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          action.onTap();
        },
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            children: [
              Icon(action.icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                action.label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteTerminalFetchResult {
  const _RemoteTerminalFetchResult({
    required this.sessions,
    required this.isSuccess,
    this.errorMessage,
  });

  final List<RemoteTerminalSession> sessions;
  final bool isSuccess;
  final String? errorMessage;

  factory _RemoteTerminalFetchResult.success(
    List<RemoteTerminalSession> sessions,
  ) {
    return _RemoteTerminalFetchResult(
      sessions: sessions,
      isSuccess: true,
    );
  }

  factory _RemoteTerminalFetchResult.failure(String message) {
    return _RemoteTerminalFetchResult(
      sessions: const [],
      isSuccess: false,
      errorMessage: message,
    );
  }
}

