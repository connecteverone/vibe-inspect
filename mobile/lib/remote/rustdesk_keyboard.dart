part of '../main.dart';

const double _rustdeskKeyboardSheetMaxHeightFactor = 0.62;

Future<void> showRustdeskKeyboardSheet(
  BuildContext context,
  RustdeskInputController input,
) async {
  final controller = TextEditingController();
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final mediaQuery = MediaQuery.of(context);
        final maxHeight =
            mediaQuery.size.height * _rustdeskKeyboardSheetMaxHeightFactor;
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            16 + mediaQuery.viewInsets.bottom,
          ),
          child: SizedBox(
            height: maxHeight,
            child: RustdeskKeyboardPanel(
              input: input,
              controller: controller,
              autofocus: true,
              closeLabel: 'Close',
              onClose: () => Navigator.of(context).maybePop(),
            ),
          ),
        );
      },
    );
  } finally {
    controller.dispose();
  }
}

class RustdeskKeyboardPanel extends StatefulWidget {
  const RustdeskKeyboardPanel({
    super.key,
    required this.input,
    required this.controller,
    this.autofocus = false,
    this.closeLabel = 'Close',
    this.onClose,
  });

  final RustdeskInputController input;
  final TextEditingController controller;
  final bool autofocus;
  final String closeLabel;
  final VoidCallback? onClose;

  @override
  State<RustdeskKeyboardPanel> createState() => _RustdeskKeyboardPanelState();
}

class _RustdeskKeyboardPanelState extends State<RustdeskKeyboardPanel> {
  bool _showFunctionKeys = false;

  void _sendCurrentText() {
    final trimmed = widget.controller.text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    widget.input.inputString(trimmed);
    widget.controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final functionKeyIndexes = List<int>.generate(12, (index) => index + 1);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Keyboard input',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: widget.controller,
                      autofocus: widget.autofocus,
                      maxLines: 3,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      decoration: const InputDecoration(
                        hintText: 'Type and send to the remote session',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _sendCurrentText(),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(
                          'Special keys',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF64748B),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _showFunctionKeys = !_showFunctionKeys;
                                });
                              },
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                              ),
                              icon: Icon(
                                _showFunctionKeys
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 18,
                              ),
                              label: Text(
                                _showFunctionKeys
                                    ? 'Hide F1-F12'
                                    : 'Show F1-F12',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _RustdeskSpecialKeyButton(
                          label: 'Backspace',
                          onPressed: () => widget.input.inputKey('VK_BACK'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Enter',
                          onPressed: () => widget.input.inputKey('VK_ENTER'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Tab',
                          onPressed: () => widget.input.inputKey('VK_TAB'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Space',
                          onPressed: () => widget.input.inputKey('VK_SPACE'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Esc',
                          onPressed: () => widget.input.inputKey('VK_ESCAPE'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Delete',
                          onPressed: () => widget.input.inputKey('VK_DELETE'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: '←',
                          onPressed: () => widget.input.inputKey('VK_LEFT'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: '↑',
                          onPressed: () => widget.input.inputKey('VK_UP'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: '↓',
                          onPressed: () => widget.input.inputKey('VK_DOWN'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: '→',
                          onPressed: () => widget.input.inputKey('VK_RIGHT'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Ctrl',
                          onPressed: () => widget.input.inputKey('VK_CONTROL'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Alt',
                          onPressed: () => widget.input.inputKey('VK_MENU'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Shift',
                          onPressed: () => widget.input.inputKey('VK_SHIFT'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Command',
                          onPressed: () => widget.input.inputKey('Meta'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Option',
                          onPressed: () => widget.input.inputKey('RAlt'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Ctrl+Alt+Del',
                          onPressed: () => widget.input.inputKeyWithModifiers(
                            'VK_DELETE',
                            ctrl: true,
                            alt: true,
                          ),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Home',
                          onPressed: () => widget.input.inputKey('VK_HOME'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'End',
                          onPressed: () => widget.input.inputKey('VK_END'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'PgUp',
                          onPressed: () => widget.input.inputKey('VK_PRIOR'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'PgDn',
                          onPressed: () => widget.input.inputKey('VK_NEXT'),
                        ),
                        _RustdeskSpecialKeyButton(
                          label: 'Insert',
                          onPressed: () => widget.input.inputKey('VK_INSERT'),
                        ),
                      ],
                    ),
                    if (_showFunctionKeys) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final keyIndex in functionKeyIndexes)
                            _RustdeskSpecialKeyButton(
                              label: 'F$keyIndex',
                              onPressed: () =>
                                  widget.input.inputKey('VK_F$keyIndex'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                if (widget.onClose != null)
                  TextButton(
                    onPressed: widget.onClose,
                    child: Text(widget.closeLabel),
                  ),
                if (widget.onClose != null) const Spacer(),
                FilledButton(
                  onPressed: _sendCurrentText,
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RustdeskSpecialKeyButton extends StatelessWidget {
  const _RustdeskSpecialKeyButton({
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFE2E8F0),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFF0F172A),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
