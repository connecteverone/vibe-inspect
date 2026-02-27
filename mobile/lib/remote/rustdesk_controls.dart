part of '../main.dart';

class _RustdeskOverlayPalette {
  const _RustdeskOverlayPalette({
    required this.iconBackground,
    required this.iconForeground,
    required this.menuBackground,
    required this.menuForeground,
    required this.zoomBackground,
    required this.zoomBorder,
    required this.zoomLabel,
    required this.zoomTick,
    required this.zoomKnob,
    required this.zoomKnobText,
    required this.trackpadBackground,
    required this.trackpadBorder,
    required this.trackpadIcon,
    required this.trackpadText,
    required this.mouseBackground,
    required this.mouseBorder,
    required this.mouseText,
    required this.shadow,
  });

  final Color iconBackground;
  final Color iconForeground;
  final Color menuBackground;
  final Color menuForeground;
  final Color zoomBackground;
  final Color zoomBorder;
  final Color zoomLabel;
  final Color zoomTick;
  final Color zoomKnob;
  final Color zoomKnobText;
  final Color trackpadBackground;
  final Color trackpadBorder;
  final Color trackpadIcon;
  final Color trackpadText;
  final Color mouseBackground;
  final Color mouseBorder;
  final Color mouseText;
  final Color shadow;

  static _RustdeskOverlayPalette resolve({
    required bool glassStyle,
    required bool darkBackground,
    required bool enabled,
  }) {
    if (!glassStyle) {
      return _RustdeskOverlayPalette(
        iconBackground: const Color(0xFFE2E8F0),
        iconForeground: const Color(0xFF0F172A),
        menuBackground: const Color(0xFF0F172A),
        menuForeground: Colors.white,
        zoomBackground: Colors.black.withAlpha(120),
        zoomBorder: Colors.white.withAlpha(40),
        zoomLabel: Colors.white70,
        zoomTick: Colors.white.withAlpha(90),
        zoomKnob: enabled ? const Color(0xFF38BDF8) : Colors.white24,
        zoomKnobText: Colors.white,
        trackpadBackground: const Color(0xFFF1F5F9),
        trackpadBorder: const Color(0xFFCBD5F5),
        trackpadIcon: const Color(0xFF475569),
        trackpadText: const Color(0xFF475569),
        mouseBackground: const Color(0xFFE2E8F0),
        mouseBorder: const Color(0xFFCBD5F5),
        mouseText: const Color(0xFF0F172A),
        shadow: Colors.black.withAlpha(80),
      );
    }

    if (darkBackground) {
      return _RustdeskOverlayPalette(
        iconBackground: Colors.white.withAlpha(40),
        iconForeground: Colors.white,
        menuBackground: const Color(0xFF0F172A),
        menuForeground: Colors.white,
        zoomBackground: Colors.white.withAlpha(40),
        zoomBorder: Colors.white.withAlpha(90),
        zoomLabel: Colors.white,
        zoomTick: Colors.white.withAlpha(160),
        zoomKnob: enabled ? Colors.white.withAlpha(170) : Colors.white24,
        zoomKnobText: const Color(0xFF0F172A),
        trackpadBackground: Colors.white.withAlpha(30),
        trackpadBorder: Colors.white.withAlpha(120),
        trackpadIcon: Colors.white,
        trackpadText: Colors.white70,
        mouseBackground: Colors.white.withAlpha(30),
        mouseBorder: Colors.white.withAlpha(120),
        mouseText: Colors.white,
        shadow: Colors.black.withAlpha(90),
      );
    }

    return _RustdeskOverlayPalette(
      iconBackground: Colors.black.withAlpha(38),
      iconForeground: const Color(0xFF0F172A),
      menuBackground: Colors.white,
      menuForeground: const Color(0xFF0F172A),
      zoomBackground: Colors.black.withAlpha(38),
      zoomBorder: Colors.black.withAlpha(80),
      zoomLabel: const Color(0xFF0F172A),
      zoomTick: Colors.black.withAlpha(140),
      zoomKnob: enabled ? Colors.black.withAlpha(170) : Colors.black26,
      zoomKnobText: Colors.white,
      trackpadBackground: Colors.black.withAlpha(30),
      trackpadBorder: Colors.black.withAlpha(110),
      trackpadIcon: const Color(0xFF0F172A),
      trackpadText: const Color(0xFF334155),
      mouseBackground: Colors.black.withAlpha(30),
      mouseBorder: Colors.black.withAlpha(110),
      mouseText: const Color(0xFF0F172A),
      shadow: Colors.black.withAlpha(55),
    );
  }
}

class RustdeskIconButton extends StatelessWidget {
  const RustdeskIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.tooltip,
    this.glassStyle = false,
    this.darkBackground = true,
  });

  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool glassStyle;
  final bool darkBackground;

  @override
  Widget build(BuildContext context) {
    final palette = _RustdeskOverlayPalette.resolve(
      glassStyle: glassStyle,
      darkBackground: darkBackground,
      enabled: true,
    );
    final iconChild = Padding(
      padding: const EdgeInsets.all(10),
      child: Icon(icon, size: 18, color: palette.iconForeground),
    );
    return Material(
      color: palette.iconBackground,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: tooltip == null || tooltip!.isEmpty
            ? iconChild
            : Tooltip(message: tooltip!, child: iconChild),
      ),
    );
  }
}

class RustdeskMoreMenuButton extends StatelessWidget {
  const RustdeskMoreMenuButton({
    super.key,
    this.onKeyboard,
    this.showKeyboardAction = true,
    this.keyboardVisible = false,
    required this.onExitFullscreen,
    this.darkBackground = true,
  });

  final VoidCallback? onKeyboard;
  final bool showKeyboardAction;
  final bool keyboardVisible;
  final VoidCallback onExitFullscreen;
  final bool darkBackground;

  @override
  Widget build(BuildContext context) {
    final palette = _RustdeskOverlayPalette.resolve(
      glassStyle: true,
      darkBackground: darkBackground,
      enabled: true,
    );
    final items = <PopupMenuEntry<_RustdeskMoreAction>>[
      if (showKeyboardAction && onKeyboard != null)
        PopupMenuItem(
          value: _RustdeskMoreAction.keyboard,
          child: _RustdeskMoreMenuItem(
            icon: keyboardVisible ? Icons.keyboard_hide : Icons.keyboard,
            label: keyboardVisible ? 'Hide keyboard input' : 'Keyboard input',
            color: palette.menuForeground,
          ),
        ),
      PopupMenuItem(
        value: _RustdeskMoreAction.exitFullscreen,
        child: _RustdeskMoreMenuItem(
          icon: Icons.fullscreen_exit,
          label: 'Exit fullscreen mode',
          color: palette.menuForeground,
        ),
      ),
    ];
    return PopupMenuButton<_RustdeskMoreAction>(
      tooltip: 'More controls',
      color: palette.menuBackground,
      icon: Icon(Icons.more_horiz, color: palette.menuForeground),
      itemBuilder: (context) => items,
      onSelected: (value) {
        switch (value) {
          case _RustdeskMoreAction.keyboard:
            onKeyboard?.call();
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
  const _RustdeskMoreMenuItem({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
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
    this.darkBackground = true,
    required this.onValueChanged,
    required this.onValueCommitted,
    required this.onReset,
  });

  final double value;
  final double min;
  final double max;
  final bool enabled;
  final bool glassStyle;
  final bool darkBackground;
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
        final palette = _RustdeskOverlayPalette.resolve(
          glassStyle: widget.glassStyle,
          darkBackground: widget.darkBackground,
          enabled: widget.enabled,
        );
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
              color: palette.zoomBackground,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.zoomBorder),
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
                      color: palette.zoomLabel,
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
                      color: palette.zoomLabel,
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
                        color: palette.zoomTick,
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
                      color: palette.zoomKnob,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: palette.shadow,
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        '${(clamped * 100).round()}%',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: palette.zoomKnobText,
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
    this.darkBackground = true,
  });

  final RustdeskInputController input;
  final bool glassStyle;
  final double? height;
  final bool showLabel;
  final ValueChanged<bool>? onInteractionChanged;
  final bool darkBackground;

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
    final palette = _RustdeskOverlayPalette.resolve(
      glassStyle: widget.glassStyle,
      darkBackground: widget.darkBackground,
      enabled: true,
    );
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
            color: palette.trackpadBackground,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: palette.trackpadBorder),
          ),
          child: Center(
            child: widget.showLabel
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.touch_app, color: palette.trackpadIcon),
                      const SizedBox(height: 8),
                      Text(
                        'Trackpad',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: palette.trackpadText,
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
    this.darkBackground = true,
  });

  final String label;
  final VoidCallback onDown;
  final VoidCallback onUp;
  final bool glassStyle;
  final bool darkBackground;

  @override
  Widget build(BuildContext context) {
    final palette = _RustdeskOverlayPalette.resolve(
      glassStyle: glassStyle,
      darkBackground: darkBackground,
      enabled: true,
    );
    return GestureDetector(
      onTapDown: (_) => onDown(),
      onTapUp: (_) => onUp(),
      onTapCancel: onUp,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: _rustdeskMouseButtonHeight,
        decoration: BoxDecoration(
          color: palette.mouseBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.mouseBorder),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: palette.mouseText,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
