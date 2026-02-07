part of '../main.dart';

class RustdeskIconButton extends StatelessWidget {
  const RustdeskIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.glassStyle = false,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    final background = glassStyle
        ? Colors.white.withAlpha(40)
        : const Color(0xFFE2E8F0);
    final foreground = glassStyle ? Colors.white : const Color(0xFF0F172A);
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, size: 18, color: foreground),
        ),
      ),
    );
  }
}

class RustdeskMoreMenuButton extends StatelessWidget {
  const RustdeskMoreMenuButton({
    super.key,
    required this.onKeyboard,
    required this.onExitFullscreen,
  });

  final VoidCallback onKeyboard;
  final VoidCallback onExitFullscreen;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_RustdeskMoreAction>(
      tooltip: 'More',
      color: const Color(0xFF0F172A),
      icon: const Icon(Icons.more_horiz, color: Colors.white),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _RustdeskMoreAction.keyboard,
          child: _RustdeskMoreMenuItem(icon: Icons.keyboard, label: 'Keyboard'),
        ),
        PopupMenuItem(
          value: _RustdeskMoreAction.exitFullscreen,
          child: _RustdeskMoreMenuItem(
            icon: Icons.fullscreen_exit,
            label: 'Exit fullscreen',
          ),
        ),
      ],
      onSelected: (value) {
        switch (value) {
          case _RustdeskMoreAction.keyboard:
            onKeyboard();
            break;
          case _RustdeskMoreAction.exitFullscreen:
            onExitFullscreen();
            break;
        }
      },
    );
  }
}

enum _RustdeskMoreAction { keyboard, exitFullscreen }

class _RustdeskMoreMenuItem extends StatelessWidget {
  const _RustdeskMoreMenuItem({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.white),
        const SizedBox(width: 8),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class RustdeskZoomBar extends StatefulWidget {
  const RustdeskZoomBar({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    this.glassStyle = false,
    required this.onValueChanged,
    required this.onValueCommitted,
    required this.onReset,
  });

  final double value;
  final double min;
  final double max;
  final bool enabled;
  final bool glassStyle;
  final ValueChanged<double> onValueChanged;
  final ValueChanged<double> onValueCommitted;
  final VoidCallback onReset;

  @override
  State<RustdeskZoomBar> createState() => _RustdeskZoomBarState();
}

class _RustdeskZoomBarState extends State<RustdeskZoomBar> {
  late double _lastValue;

  @override
  void initState() {
    super.initState();
    _lastValue = widget.value;
  }

  @override
  void didUpdateWidget(covariant RustdeskZoomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _lastValue = widget.value;
  }

  double _valueForPosition(double localY, double height) {
    if (height <= 0) {
      return widget.value;
    }
    final trackTop = 20.0;
    final trackBottom = height - 20.0;
    final clamped = localY.clamp(trackTop, trackBottom);
    final t = 1 - ((clamped - trackTop) / (trackBottom - trackTop));
    final next = widget.min + (widget.max - widget.min) * t;
    return next.clamp(widget.min, widget.max);
  }

  void _setValue(double value) {
    _lastValue = value;
    widget.onValueChanged(value);
  }

  void _commitValue([double? value]) {
    widget.onValueCommitted(value ?? _lastValue);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final trackTop = 20.0;
        final trackBottom = height - 20.0;
        final clamped = widget.value.clamp(widget.min, widget.max);
        final range = (widget.max - widget.min).abs();
        final t = range <= 0
            ? 0.5
            : ((clamped - widget.min) / range).clamp(0.0, 1.0);
        final knobY = trackBottom - (trackBottom - trackTop) * t;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onDoubleTap: widget.enabled ? widget.onReset : null,
          onTapDown: widget.enabled
              ? (details) {
                  final nextValue = _valueForPosition(
                    details.localPosition.dy,
                    height,
                  );
                  _setValue(nextValue);
                  _commitValue(nextValue);
                }
              : null,
          onVerticalDragUpdate: widget.enabled
              ? (details) => _setValue(
                  _valueForPosition(details.localPosition.dy, height),
                )
              : null,
          onVerticalDragEnd: widget.enabled ? (_) => _commitValue() : null,
          child: Container(
            width: 44,
            decoration: BoxDecoration(
              color: widget.glassStyle
                  ? Colors.white.withAlpha(40)
                  : Colors.black.withAlpha(120),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: widget.glassStyle
                    ? Colors.white.withAlpha(80)
                    : Colors.white.withAlpha(40),
              ),
            ),
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 6,
                  child: Text(
                    '${widget.max.toStringAsFixed(1)}x',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.glassStyle ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: Text(
                    '${widget.min.toStringAsFixed(1)}x',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: widget.glassStyle ? Colors.white : Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  top: trackTop,
                  bottom: trackTop,
                  child: Center(
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(
                          widget.glassStyle ? 160 : 90,
                        ),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 4,
                  right: 4,
                  top: knobY - 16,
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: widget.enabled
                          ? (widget.glassStyle
                                ? Colors.white.withAlpha(160)
                                : const Color(0xFF38BDF8))
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withAlpha(80),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        '${(clamped * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: widget.glassStyle
                              ? const Color(0xFF0F172A)
                              : Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class RustdeskTrackpadSurface extends StatefulWidget {
  const RustdeskTrackpadSurface({
    super.key,
    required this.input,
    this.glassStyle = false,
    this.height,
    this.showLabel = true,
    this.onInteractionChanged,
  });

  final RustdeskInputController input;
  final bool glassStyle;
  final double? height;
  final bool showLabel;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<RustdeskTrackpadSurface> createState() =>
      _RustdeskTrackpadSurfaceState();
}

class _RustdeskTrackpadSurfaceState extends State<RustdeskTrackpadSurface> {
  final TrackpadMotionEngine _motionEngine = TrackpadMotionEngine();
  final Set<int> _activePointers = <int>{};
  bool _isInteracting = false;

  void _setInteracting(bool value) {
    if (_isInteracting == value) {
      return;
    }
    _isInteracting = value;
    widget.onInteractionChanged?.call(value);
  }

  void _dispatchActions(List<TrackpadAction> actions) {
    for (final action in actions) {
      if (action is TrackpadMoveAction) {
        widget.input.moveRelative(action.delta);
      } else if (action is TrackpadScrollAction) {
        widget.input.scrollVertical(action.deltaY);
      }
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    _setInteracting(true);
    _motionEngine.onPointerDown(event.pointer, event.localPosition);
  }

  void _handlePointerMove(PointerMoveEvent event) {
    final actions = _motionEngine.onPointerMove(
      event.pointer,
      event.localPosition,
      event.delta,
    );
    if (actions.isNotEmpty) {
      _dispatchActions(actions);
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    _motionEngine.onPointerUp(event.pointer);
    if (_activePointers.isEmpty) {
      _setInteracting(false);
    }
  }

  void _handlePointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _motionEngine.onPointerCancel(event.pointer);
    if (_activePointers.isEmpty) {
      _setInteracting(false);
    }
  }

  @override
  void dispose() {
    _activePointers.clear();
    _setInteracting(false);
    _motionEngine.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = widget.glassStyle
        ? Colors.white.withAlpha(30)
        : const Color(0xFFF1F5F9);
    final borderColor = widget.glassStyle
        ? Colors.white.withAlpha(120)
        : const Color(0xFFCBD5F5);
    final iconColor = widget.glassStyle
        ? Colors.white
        : const Color(0xFF475569);
    final textColor = widget.glassStyle
        ? Colors.white70
        : const Color(0xFF475569);
    return GestureDetector(
      onDoubleTap: widget.input.clickLeft,
      onPanStart: (_) {},
      onPanUpdate: (_) {},
      onPanEnd: (_) {},
      onPanCancel: () {},
      behavior: HitTestBehavior.opaque,
      child: Listener(
        onPointerDown: _handlePointerDown,
        onPointerMove: _handlePointerMove,
        onPointerUp: _handlePointerUp,
        onPointerCancel: _handlePointerCancel,
        child: Container(
          height: widget.height ?? 120,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Center(
            child: widget.showLabel
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.touch_app, color: iconColor),
                      const SizedBox(height: 8),
                      Text(
                        'Trackpad',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: textColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

class RustdeskMouseButton extends StatelessWidget {
  const RustdeskMouseButton({
    super.key,
    required this.label,
    required this.onDown,
    required this.onUp,
    this.glassStyle = false,
  });

  final String label;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    final background = glassStyle
        ? Colors.white.withAlpha(30)
        : const Color(0xFFE2E8F0);
    final borderColor = glassStyle
        ? Colors.white.withAlpha(120)
        : const Color(0xFFCBD5F5);
    final textColor = glassStyle ? Colors.white : const Color(0xFF0F172A);
    return GestureDetector(
      onTapDown: (_) => onDown(),
      onTapUp: (_) => onUp(),
      onTapCancel: onUp,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: _rustdeskMouseButtonHeight,
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: textColor,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
