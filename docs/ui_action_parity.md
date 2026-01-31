# UI Action Parity Map

This map lists action labels that appear on both mobile and desktop. The same label must trigger the same type of behavior so users can predict outcomes across platforms.

## Shared Actions

| Action label | Expected behavior | Mobile surface | Desktop surface |
| --- | --- | --- | --- |
| Disconnect | Stop the active terminal session without removing the pairing or device record. Sends terminal action `stop` and updates the session status locally. | Terminal session picker: stop icon tooltip "Disconnect" | Terminal sessions list: "Disconnect" button |
| Copy | Copy the selected/visible data to the clipboard. | Terminal tools: "Copy" action copies selected terminal text | Token list: "Copy" action copies token to clipboard |

## Manual QA Checklist (Parity)

- Verify the desktop terminal "Disconnect" button stops the session but leaves the paired device intact.
- Verify the mobile terminal session "Disconnect" control stops the session but leaves the paired agent intact.
- Verify "Copy" on desktop tokens and "Copy" on mobile terminal both copy data to the clipboard.
- If any same-labeled action behaves differently across platforms, update the label or handler before release.
