# Desktop Frontend Smoke Checklist

Use this checklist before merging UI changes in `desktop/frontend`.

## Setup

1. Serve frontend locally:
   - `cd desktop/frontend`
   - `python3 -m http.server 8133 --bind 127.0.0.1`
2. Open mock mode:
   - `http://127.0.0.1:8133/index.html?mock=1`

## Core interactions

- [ ] **Tabs + keyboard navigation**
  - Click `Overview` / `Settings`.
  - Focus tabs and use `ArrowLeft/ArrowRight/Home/End`.
  - Confirm only one tab has `aria-selected="true"`.

- [ ] **Session list action density**
  - Confirm each terminal row shows only primary actions by default.
  - Click `More` to reveal advanced actions.
  - Confirm `More` toggles to `Less` and back.
  - Keep row expanded and wait for polling refresh; confirm expanded state is preserved.

- [ ] **Manual refresh path**
  - Click `Refresh` in `Terminal sessions` card.
  - Confirm button enters busy state then returns to enabled.

## Terminal lifecycle closure

- [ ] **Running session controls**
  - Open a running session.
  - Confirm `Disconnect` is available in detail panel.

- [ ] **Ended session controls**
  - Disconnect session.
  - Confirm detail panel shows `Delete` and hides/disables write controls.
  - Confirm `Copy output` / `Clear screen` remain usable.

- [ ] **Delete confirmation guardrail**
  - Click delete once -> should only arm confirmation.
  - Click delete again within the confirmation window -> session is removed.

## Image upload flow

- [ ] **Picker upload path**
  - Click `Upload images` and select valid image files.
  - Confirm selected files render thumbnails, name, and size.
  - Confirm counter updates and `Clear all` becomes enabled.

- [ ] **Drag-and-drop upload path**
  - Drag valid images over the dropzone.
  - Confirm drag highlight appears, then files are added on drop.
  - Drop invalid type or oversize image and confirm inline error appears.

- [ ] **Capacity and cleanup**
  - Add images up to the max count.
  - Confirm browse/drop interactions disable at max.
  - Remove one file and confirm interactions re-enable.
  - Click `Clear all` and confirm list resets to empty state.

## Permission flow

- [ ] **No automatic OS jumps**
  - Confirm page load does not auto-open location settings.
  - Confirm permission/system settings actions require button click.

- [ ] **Permission state mapping**
  - `not_determined` => `Request permission`
  - `denied/restricted/disabled` => `Open settings`

## Accessibility basics

- [ ] Top status and terminal detail status are announced as live status (`role="status"`).
- [ ] Terminal output uses log semantics (`role="log"`).
- [ ] Inputs with placeholders still have accessible names (label or `aria-label`).

## Quick syntax checks

Run after JS changes:

```bash
node --check desktop/frontend/scripts/modules/agent-core.js
node --check desktop/frontend/scripts/modules/agent-views.js
node --check desktop/frontend/scripts/modules/agent-bootstrap.js
node --check desktop/frontend/scripts/agent-mock-bridge.js
```
