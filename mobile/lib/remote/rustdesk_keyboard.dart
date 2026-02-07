part of '../main.dart';

Future<void> showRustdeskKeyboardSheet(
  BuildContext context,
  RustdeskInputController input,
) async {
  final controller = TextEditingController();
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (context) {
      return Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Keyboard input',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 3,
              minLines: 1,
              textInputAction: TextInputAction.send,
              decoration: const InputDecoration(
                hintText: 'Type and send to the remote session',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                final trimmed = value.trim();
                if (trimmed.isNotEmpty) {
                  input.inputString(trimmed);
                }
                controller.clear();
              },
            ),
            const SizedBox(height: 12),
            Text(
              'Special keys',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _RustdeskSpecialKeyButton(
                  label: 'Backspace',
                  onPressed: () => input.inputKey('VK_BACK'),
                ),
                _RustdeskSpecialKeyButton(
                  label: 'Enter',
                  onPressed: () => input.inputKey('VK_ENTER'),
                ),
                _RustdeskSpecialKeyButton(
                  label: 'Command',
                  onPressed: () => input.inputKey('Meta'),
                ),
                _RustdeskSpecialKeyButton(
                  label: 'Alt',
                  onPressed: () => input.inputKey('VK_MENU'),
                ),
                _RustdeskSpecialKeyButton(
                  label: 'Option',
                  onPressed: () => input.inputKey('RAlt'),
                ),
                _RustdeskSpecialKeyButton(
                  label: 'Ctrl',
                  onPressed: () => input.inputKey('VK_CONTROL'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Close'),
                ),
                const Spacer(),
                FilledButton(
                  onPressed: () {
                    final trimmed = controller.text.trim();
                    if (trimmed.isNotEmpty) {
                      input.inputString(trimmed);
                    }
                    Navigator.of(context).maybePop();
                  },
                  child: const Text('Send'),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );
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
