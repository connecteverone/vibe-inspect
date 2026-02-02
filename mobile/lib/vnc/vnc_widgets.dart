part of '../main.dart';

class _VncRecoveryCard extends StatelessWidget {
  const _VncRecoveryCard({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFDA4AF)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Color(0xFFBE123C),
            size: 28,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Stream unavailable',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFF9F1239),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFF9F1239),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry stream'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VncSpecialKeyButton extends StatelessWidget {
  const _VncSpecialKeyButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonal(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _VncPointer extends StatelessWidget {
  const _VncPointer({
    required this.isClicking,
    required this.isFocusing,
  });

  final bool isClicking;
  final bool isFocusing;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        AnimatedOpacity(
          opacity: isClicking ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withAlpha(180),
                width: 2,
              ),
            ),
          ),
        ),
        AnimatedOpacity(
          opacity: isFocusing ? 1 : 0,
          duration: const Duration(milliseconds: 160),
          child: Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withAlpha(120),
                width: 1.5,
              ),
            ),
          ),
        ),
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFF0F172A), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 6,
                offset: const Offset(0, 4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VncZoomBadge extends StatelessWidget {
  const _VncZoomBadge({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '${(value * 100).round()}%',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _VncStatsBadge extends StatelessWidget {
  const _VncStatsBadge({
    required this.latencyMs,
    required this.fps,
  });

  final int? latencyMs;
  final double fps;

  Color _latencyColor() {
    final value = latencyMs;
    if (value == null) {
      return Colors.white70;
    }
    if (value > 50) {
      return Colors.redAccent;
    }
    if (value > 20) {
      return const Color(0xFFFBBF24);
    }
    return Colors.white;
  }

  @override
  Widget build(BuildContext context) {
    final fpsValue = fps.isFinite ? fps : 0;
    final fpsLabel = fpsValue <= 0
        ? '--'
        : fpsValue >= 10
            ? fpsValue.toStringAsFixed(0)
            : fpsValue.toStringAsFixed(1);
    final latencyLabel =
        latencyMs == null ? '--' : '${latencyMs!.clamp(0, 9999)}';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Latency ',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              Text(
                '$latencyLabel ms',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _latencyColor(),
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '$fpsLabel fps',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _VncDebugRow extends StatelessWidget {
  const _VncDebugRow({
    required this.label,
    required this.value,
    this.labelStyle,
    this.valueStyle,
  });

  final String label;
  final String value;
  final TextStyle? labelStyle;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final baseLabelStyle = labelStyle ??
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white70,
              fontWeight: FontWeight.w600,
            );
    final baseValueStyle = valueStyle ??
        Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            );
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: baseLabelStyle,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: baseValueStyle,
            ),
          ),
        ],
      ),
    );
  }
}

class _VncOverlayIconButton extends StatelessWidget {
  const _VncOverlayIconButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withAlpha(140),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white,
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

class _CalibrationTarget extends StatelessWidget {
  const _CalibrationTarget();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 36,
      height: 36,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
          Container(
            width: 36,
            height: 2,
            color: Colors.white.withAlpha(200),
          ),
          Container(
            width: 2,
            height: 36,
            color: Colors.white.withAlpha(200),
          ),
        ],
      ),
    );
  }
}

class _CalibrationResult {
  const _CalibrationResult({
    required this.scaleX,
    required this.scaleY,
    required this.offsetX,
    required this.offsetY,
  });

  final double scaleX;
  final double scaleY;
  final double offsetX;
  final double offsetY;
}

class _CalibrationSlider extends StatelessWidget {
  const _CalibrationSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    this.labelColor,
    this.divisions,
    this.onChangeEnd,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final bool enabled;
  final ValueChanged<double> onChanged;
  final Color? labelColor;
  final int? divisions;
  final ValueChanged<double>? onChangeEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
                  color: labelColor ?? const Color(0xFF0F172A),
                  fontWeight: FontWeight.w600,
                ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: enabled ? onChanged : null,
              onChangeEnd: enabled ? onChangeEnd : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _VncZoomBar extends StatefulWidget {
  const _VncZoomBar({
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
  State<_VncZoomBar> createState() => _VncZoomBarState();
}

class _VncZoomBarState extends State<_VncZoomBar> {
  late double _lastValue;

  @override
  void initState() {
    super.initState();
    _lastValue = widget.value;
  }

  @override
  void didUpdateWidget(covariant _VncZoomBar oldWidget) {
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
                  final nextValue =
                      _valueForPosition(details.localPosition.dy, height);
                  _setValue(nextValue);
                  _commitValue(nextValue);
                }
              : null,
          onVerticalDragUpdate: widget.enabled
              ? (details) =>
                  _setValue(_valueForPosition(details.localPosition.dy, height))
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
                          color: widget.glassStyle
                              ? Colors.white
                              : Colors.white70,
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
                          color: widget.glassStyle
                              ? Colors.white
                              : Colors.white70,
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

class _VncShortcutOverlay extends StatelessWidget {
  const _VncShortcutOverlay({
    required this.enabled,
    required this.onEsc,
    required this.onCmd,
    required this.onTab,
    required this.onCtrl,
    required this.onKeyboard,
  });

  final bool enabled;
  final VoidCallback onEsc;
  final VoidCallback onCmd;
  final VoidCallback onTab;
  final VoidCallback onCtrl;
  final VoidCallback onKeyboard;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(140),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withAlpha(40)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Wrap(
          spacing: 8,
          children: [
            _VncShortcutButton(
              label: 'Esc',
              onPressed: enabled ? onEsc : null,
            ),
            _VncShortcutButton(
              label: 'Cmd',
              onPressed: enabled ? onCmd : null,
            ),
            _VncShortcutButton(
              label: 'Tab',
              onPressed: enabled ? onTab : null,
            ),
            _VncShortcutButton(
              label: 'Ctrl',
              onPressed: enabled ? onCtrl : null,
            ),
            _VncShortcutButton(
              label: 'Kbd',
              onPressed: enabled ? onKeyboard : null,
              icon: Icons.keyboard,
            ),
          ],
        ),
      ),
    );
  }
}

class _VncShortcutButton extends StatelessWidget {
  const _VncShortcutButton({
    required this.label,
    this.icon,
    this.onPressed,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withAlpha(20),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: Colors.white),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.white,
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

class _VncControlAction extends StatelessWidget {
  const _VncControlAction({
    required this.icon,
    required this.label,
    this.onPressed,
    this.glassStyle = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    final isEnabled = onPressed != null;
    final foreground = glassStyle
        ? (isEnabled ? Colors.white : Colors.white54)
        : (isEnabled ? const Color(0xFF0F172A) : const Color(0xFF94A3B8));
    final background = glassStyle
        ? Colors.white.withAlpha(isEnabled ? 30 : 12)
        : (isEnabled ? const Color(0xFFE0F2FE) : const Color(0xFFF1F5F9));
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: foreground),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
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

class _VncTrackpadSurface extends StatelessWidget {
  const _VncTrackpadSurface({
    required this.enabled,
    this.glassStyle = false,
    this.height,
    this.showLabel = true,
    this.disabledMessage,
    this.onDoubleTapDown,
    this.onDoubleTap,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerHover,
    required this.onPointerUp,
    required this.onPointerCancel,
    this.onPointerSignal,
    this.onPointerPanZoomUpdate,
  });

  final bool enabled;
  final bool glassStyle;
  final double? height;
  final bool showLabel;
  final String? disabledMessage;
  final GestureTapDownCallback? onDoubleTapDown;
  final VoidCallback? onDoubleTap;
  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final ValueChanged<PointerHoverEvent> onPointerHover;
  final ValueChanged<PointerUpEvent> onPointerUp;
  final ValueChanged<PointerCancelEvent> onPointerCancel;
  final ValueChanged<PointerSignalEvent>? onPointerSignal;
  final ValueChanged<PointerPanZoomUpdateEvent>? onPointerPanZoomUpdate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = glassStyle
        ? Colors.white.withAlpha(enabled ? 30 : 12)
        : (enabled ? const Color(0xFFF1F5F9) : const Color(0xFFE2E8F0));
    final borderColor = glassStyle
        ? Colors.white.withAlpha(enabled ? 120 : 60)
        : (enabled ? const Color(0xFFCBD5F5) : const Color(0xFFE2E8F0));
    final iconColor = glassStyle
        ? (enabled ? Colors.white : Colors.white54)
        : (enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8));
    final textColor = glassStyle
        ? (enabled ? Colors.white : Colors.white54)
        : (enabled ? const Color(0xFF475569) : const Color(0xFF94A3B8));
    return GestureDetector(
      onPanStart: enabled ? (_) {} : null,
      onPanUpdate: enabled ? (_) {} : null,
      onDoubleTapDown: enabled ? onDoubleTapDown : null,
      onDoubleTap: enabled ? onDoubleTap : null,
      behavior: HitTestBehavior.opaque,
      child: Listener(
        onPointerDown: enabled ? onPointerDown : null,
        onPointerMove: enabled ? onPointerMove : null,
        onPointerHover: enabled ? onPointerHover : null,
        onPointerUp: enabled ? onPointerUp : null,
        onPointerCancel: enabled ? onPointerCancel : null,
        onPointerSignal: enabled ? onPointerSignal : null,
        onPointerPanZoomUpdate: enabled ? onPointerPanZoomUpdate : null,
        child: Container(
          height: height ?? 120,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          child: Center(
            child: showLabel
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.touch_app,
                        color: iconColor,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        enabled
                            ? 'Trackpad ready'
                            : (disabledMessage ?? 'Connect to enable input'),
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

class _VncGestureHint extends StatelessWidget {
  const _VncGestureHint({
    required this.icon,
    required this.label,
    this.glassStyle = false,
  });

  final IconData icon;
  final String label;
  final bool glassStyle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: glassStyle ? Colors.white.withAlpha(24) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: glassStyle
              ? Colors.white.withAlpha(80)
              : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: glassStyle ? Colors.white70 : const Color(0xFF475569),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: glassStyle ? Colors.white70 : const Color(0xFF475569),
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class ContextMissingScreen extends StatelessWidget {
  const ContextMissingScreen({
    super.key,
    required this.title,
    required this.message,
    required this.event,
  });

  final String title;
  final String message;
  final TimelineEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _TimelineDetailScaffold(
      title: title,
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFFEE2E2),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFFFCA5A5)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Color(0xFFB91C1C),
                    size: 28,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Context unavailable',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF7F1D1D),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          message,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF7F1D1D),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            _ContextSectionCard(
              title: 'Event details',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _KeyValueRow(
                    label: 'Type',
                    value: event.type.toUpperCase(),
                  ),
                  _KeyValueRow(label: 'Title', value: event.title),
                  _KeyValueRow(
                    label: 'Timestamp',
                    value: _formatTimestamp(event.createdAt),
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

class _HeadersBlock extends StatelessWidget {
  const _HeadersBlock({required this.headers});

  final Map<String, String> headers;

  @override
  Widget build(BuildContext context) {
    if (headers.isEmpty) {
      return const _EmptyHint(text: 'No headers recorded.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: headers.entries
          .map(
            (entry) => _KeyValueRow(
              label: entry.key,
              value: entry.value,
            ),
          )
          .toList(),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF94A3B8),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

class _StatusPillColor {
  const _StatusPillColor(this.background, this.foreground);

  final Color background;
  final Color foreground;
}

_StatusPillColor _statusPillColor(int? status) {
  if (status == null) {
    return const _StatusPillColor(
      Color(0xFFE2E8F0),
      Color(0xFF475569),
    );
  }
  if (status >= 200 && status < 300) {
    return const _StatusPillColor(
      Color(0xFFDCFCE7),
      Color(0xFF166534),
    );
  }
  if (status >= 400) {
    return const _StatusPillColor(
      Color(0xFFFEE2E2),
      Color(0xFFB91C1C),
    );
  }
  return const _StatusPillColor(
    Color(0xFFFEF3C7),
    Color(0xFF92400E),
  );
}

Map<String, String> _parseHeaders(dynamic raw) {
  final headers = <String, String>{};
  if (raw is Map) {
    raw.forEach((key, value) {
      if (key != null) {
        headers[key.toString()] = value?.toString() ?? '';
      }
    });
  } else if (raw is List) {
    for (final entry in raw) {
      if (entry is Map) {
        final key = entry['name'] ?? entry['key'];
        if (key != null) {
          headers[key.toString()] = entry['value']?.toString() ?? '';
        }
      }
    }
  }
  return headers;
}

String? _stringifyBody(dynamic raw) {
  if (raw == null) {
    return null;
  }
  if (raw is String) {
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : raw;
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(raw);
  } catch (_) {
    return raw.toString();
  }
}

Set<String> _collectChangedPaths(dynamic current, dynamic previous) {
  final changes = <String>{};
  if (previous == null) {
    return changes;
  }
  _diffJsonValues(current, previous, '', changes);
  return changes;
}

void _diffJsonValues(
  dynamic current,
  dynamic previous,
  String path,
  Set<String> changes,
) {
  if (current is Map && previous is Map) {
    final currentMap = Map<String, dynamic>.from(current);
    final previousMap = Map<String, dynamic>.from(previous);
    final keys = <String>{...currentMap.keys, ...previousMap.keys};
    for (final key in keys) {
      final childPath = _childJsonPath(path, key);
      if (!currentMap.containsKey(key) || !previousMap.containsKey(key)) {
        changes.add(childPath);
        continue;
      }
      _diffJsonValues(currentMap[key], previousMap[key], childPath, changes);
    }
    return;
  }
  if (current is List && previous is List) {
    final maxLength =
        current.length > previous.length ? current.length : previous.length;
    for (var index = 0; index < maxLength; index += 1) {
      final childPath = _childJsonPath(path, index.toString());
      if (index >= current.length || index >= previous.length) {
        changes.add(childPath);
        continue;
      }
      _diffJsonValues(current[index], previous[index], childPath, changes);
    }
    return;
  }

  if (!_jsonValueEquals(current, previous)) {
    changes.add(path.isEmpty ? '/' : path);
  }
}

bool _jsonValueEquals(dynamic left, dynamic right) {
  if (left is Map && right is Map) {
    final leftMap = Map<String, dynamic>.from(left);
    final rightMap = Map<String, dynamic>.from(right);
    if (leftMap.length != rightMap.length) {
      return false;
    }
    for (final entry in leftMap.entries) {
      if (!rightMap.containsKey(entry.key)) {
        return false;
      }
      if (!_jsonValueEquals(entry.value, rightMap[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      if (!_jsonValueEquals(left[index], right[index])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}

String _childJsonPath(String parent, String child) {
  if (parent.isEmpty || parent == '/') {
    return '/$child';
  }
  return '$parent/$child';
}

class ErrorPresentation {
  const ErrorPresentation({
    required this.message,
    required this.code,
    this.endpoint,
    this.requestId,
    this.details,
  });

  final String message;
  final String code;
  final String? endpoint;
  final String? requestId;
  final Object? details;
}

class AgentCommandFailure implements Exception {
  const AgentCommandFailure(
    this.message, {
    this.code,
    this.endpoint,
    this.requestId,
    this.details,
  });

  final String message;
  final String? code;
  final String? endpoint;
  final String? requestId;
  final Object? details;

  @override
  String toString() => message;
}

String _describeNetworkError(Object error) {
  final raw = error.toString();
  final lower = raw.toLowerCase();
  if (lower.contains('no route to host') || lower.contains('errno = 65')) {
    return 'No route to host (errno 65). iOS may be blocking local network access for this app. Check Settings > Local Network and disable VPN/Private Relay.';
  }
  if (lower.contains('connection refused') || lower.contains('errno = 61')) {
    return 'Connection refused (errno 61). The host is reachable but the port was rejected by the OS/firewall.';
  }
  if (lower.contains('network is unreachable') || lower.contains('errno = 51')) {
    return 'Network is unreachable (errno 51). The app has no route to the LAN. Check Wi-Fi and local network permission.';
  }
  if (lower.contains('timed out') || lower.contains('timeout')) {
    return 'Network timed out. Check the desktop agent connection and try again.';
  }
  if (lower.contains('failed host lookup') ||
      lower.contains('name or service not known')) {
    return 'Host lookup failed. Check the agent address and DNS.';
  }
  final socketPrefix = 'SocketException: ';
  final clientPrefix = 'ClientException: ';
  if (raw.startsWith(socketPrefix)) {
    return raw.substring(socketPrefix.length).trim();
  }
  if (raw.startsWith(clientPrefix)) {
    return raw.substring(clientPrefix.length).trim();
  }
  return 'Unexpected network error. Please try again.';
}

ErrorPresentation _buildErrorPresentation({
  String? code,
  String? message,
  String? fallbackMessage,
  String? endpoint,
  String? requestId,
  Object? details,
}) {
  final normalizedCode =
      code != null && code.trim().isNotEmpty ? code.trim() : 'unknown_error';
  final resolvedFallback = (message ?? '').trim().isNotEmpty
      ? message!.trim()
      : (fallbackMessage ?? 'Something went wrong.');
  final friendlyMessage = _friendlyMessageForCode(normalizedCode);
  return ErrorPresentation(
    message: friendlyMessage ?? resolvedFallback,
    code: normalizedCode,
    endpoint: endpoint,
    requestId: requestId,
    details: details,
  );
}

ErrorPresentation _presentAgentFailure(
  AgentCommandFailure error, {
  String? fallbackMessage,
}) {
  return _buildErrorPresentation(
    code: error.code,
    message: error.message,
    fallbackMessage: fallbackMessage,
    endpoint: error.endpoint,
    requestId: error.requestId,
    details: error.details,
  );
}

ErrorPresentation _presentUnexpectedFailure(
  Object error, {
  String? fallbackMessage,
  String? endpoint,
  String? requestId,
}) {
  return _buildErrorPresentation(
    code: 'unexpected_error',
    message: fallbackMessage ?? 'Something went wrong. Please try again.',
    endpoint: endpoint,
    requestId: requestId,
    details: error.toString(),
  );
}

String _formatErrorMessage(ErrorPresentation error) {
  final trimmed = error.message.trim();
  final message =
      trimmed.isNotEmpty ? trimmed : 'Something went wrong. Please try again.';
  if (error.code.isNotEmpty && error.code != 'unknown_error') {
    return '$message (code: ${error.code})';
  }
  return message;
}

void _logErrorDetails(String context, ErrorPresentation error) {
  final detailParts = <String>[];
  if (error.code.isNotEmpty) {
    detailParts.add('code=${error.code}');
  }
  if (error.requestId != null && error.requestId!.trim().isNotEmpty) {
    detailParts.add('request_id=${error.requestId}');
  }
  if (error.endpoint != null && error.endpoint!.trim().isNotEmpty) {
    detailParts.add('endpoint=${error.endpoint}');
  }
  if (error.details != null) {
    try {
      detailParts.add('details=${jsonEncode(error.details)}');
    } catch (_) {
      detailParts.add('details=${error.details}');
    }
  }
  final detailText = detailParts.isEmpty ? '' : ' (${detailParts.join(' ')})';
  debugPrint('[error:$context] ${error.message}$detailText');
}

String? _friendlyMessageForCode(String code) {
  switch (code.toLowerCase()) {
    case 'invalid_token':
      return 'Invalid token. Check the token and try again.';
    case 'token_expired':
      return 'Token expired. Generate a new token.';
    case 'token_mismatch':
    case 'secret_mismatch':
      return 'Pairing token mismatch. Generate a new token and try again.';
    case 'missing_token':
      return 'Pairing token is missing. Generate a new token.';
    case 'requires_approval':
    case 'approval_pending':
      return 'Waiting for desktop approval.';
    case 'approval_timeout':
      return 'Approval timed out. Generate a new token and retry.';
    case 'invalid_port':
      return 'Port must be between 1 and 65535.';
    case 'listen_port_busy':
      return 'Listen port is already in use. Choose another port.';
    case 'roi_quic_port_busy':
    case 'roi_quic_port_unavailable':
      return 'ROI QUIC port is unavailable. Choose another port.';
    case 'local_server_unavailable':
      return 'Desktop agent is offline. Start it and try again.';
    case 'connection_failed':
      return 'Unable to reach the desktop agent. Check your connection.';
    case 'http_error':
      return 'Desktop agent returned an error response.';
    case 'invalid_url':
      return 'Agent URL is invalid. Include http:// or https://.';
    case 'invalid_json':
    case 'invalid_response':
      return 'Desktop agent returned an invalid response.';
    case 'api_request_failed':
      return 'API request failed. Check the target endpoint.';
    case 'session_not_found':
      return 'Terminal session not found. Refresh sessions and try again.';
    case 'missing_session':
      return 'Select a terminal session first.';
    case 'missing_input':
      return 'Enter a command before sending.';
    case 'missing_size':
      return 'Terminal size was missing. Try again.';
    case 'write_failed':
      return 'Failed to send input to the terminal.';
    case 'resize_failed':
      return 'Failed to resize the terminal.';
    case 'pty_error':
    case 'spawn_error':
      return 'Terminal backend unavailable. Restart the desktop agent.';
    case 'state_locked':
      return 'Desktop agent is busy. Try again.';
    case 'invalid_name':
      return 'Device name cannot be empty.';
    case 'identity_error':
      return 'Device update failed. Try again.';
  }
  return null;
}

class AgentApiResult {
  const AgentApiResult({required this.request, required this.response});

  final ApiRequestDetails request;
  final ApiResponseDetails response;
}
