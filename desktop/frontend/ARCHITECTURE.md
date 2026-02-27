# Desktop Frontend Architecture

The frontend is split into focused files so UI changes do not require editing a single monolithic HTML file.

## File layout

- `index.html`
  - Structure and semantic markup only
  - Loads styles and scripts in explicit order
- `styles/agent.css`
  - Shared design tokens
  - Layout, component styling, and responsive behavior
- `scripts/agent-mock-bridge.js`
  - Browser-only mock backend for local UI interaction checks
  - Never overrides a real Tauri bridge (`__TAURI__` or `__TAURI_INTERNALS__`)
- `scripts/modules/agent-core.js`
  - DOM handles
  - App state and status/toast system
  - Error normalization
  - Bridge invocation helpers
  - Terminal transport helpers
- `scripts/modules/agent-views.js`
  - Rendering functions for all cards/lists/status panes
- `scripts/modules/agent-bootstrap.js`
  - Feature binding (`bind*` functions)
  - Timers/polling bootstrap
  - Startup initialization sequence
- `scripts/agent-app.js`
  - Legacy compatibility loader that injects the module files in order

## Initialization order

`index.html` loads scripts in this order:

1. `agent-mock-bridge.js`
2. `modules/agent-core.js`
3. `modules/agent-views.js`
4. `modules/agent-bootstrap.js`

This guarantees:

- bridge setup exists before invoke calls
- shared state/helpers exist before view rendering
- view functions exist before event binding
- final bootstrap runs exactly once

## Interaction reliability rules

- All async button actions use `runButtonAction(...)`
  - prevents double click races
  - applies busy label
  - restores button state
  - surfaces user-facing errors
- Button interactivity is gated by real `disabled` state; `.button-disabled` is visual-only styling.
- Global status uses a short pin window (`statusPinnedUntil`) to avoid refresh overwriting operation feedback.
- Operation results are mirrored as toasts (`setOperationStatus(...)`) so users get immediate visual acknowledgment.
- `refreshStatus(...)` uses request sequencing and in-flight guards to avoid stale polling responses overwriting newer UI state.

## Terminal session UX contract

- Session rows expose **primary actions** directly (`Open/View log`, `Rename`), while high-risk/advanced actions stay behind `More` by default.
- Destructive session operations (`Delete`) require explicit two-step confirmation within a short window.
- Terminal detail panel mirrors list capabilities:
  - `Disconnect` is shown/enabled for running sessions.
  - `Delete` is shown/enabled for ended sessions.
- When a session is ended, write controls are disabled, but read/inspection controls remain available (`Copy output`, `Clear screen`, display toggles).

## Image upload UX contract

- Upload entry supports both drag-and-drop and explicit picker button actions.
- Validation runs in `agent-core.js` (type/size/duplicates/max-count) before state mutation.
- Rendering is owned by `renderImageUploadState(...)` in `agent-views.js`; binding is owned by `bindImageUploadActions(...)` in `agent-bootstrap.js`.
- Preview object URLs are revoked on remove/clear/unload to avoid leaking browser memory.
- Upload affordance state stays synchronized via `syncImageUploadInteractivity(...)` so drag/drop, browse, and clear controls always reflect current limits.

## Permission UX contract

- Location permission and system settings are **user-triggered only**.
- UI must not auto-open system settings or auto-request permission from passive status rendering.
- Alert actions map by permission state:
  - `not_determined` -> show `Request permission`
  - `denied/restricted/disabled` -> show `Open settings`

## Accessibility contract

- Overview/Settings switch uses ARIA tabs (`tablist`, `tab`, `tabpanel`) and supports keyboard navigation (`ArrowLeft/ArrowRight/Home/End`).
- Live status surfaces are announced with semantic roles:
  - top status badge and terminal detail status use `role="status"`
  - terminal output stream uses `role="log"`
- Inputs that rely on placeholders also provide accessible names (`label` or `aria-label`).

## Local UI verification mode

Open with `?mock=1` (or from file/localhost with no Tauri bridge) to use mock invoke handlers.

Examples:

- `file:///.../desktop/frontend/index.html?mock=1`
- `http://127.0.0.1:8030/index.html?mock=1&mock_update=1`

The mock mode supports:

- pairing flow actions
- token actions
- config save actions
- terminal session open/input/resize/poll/disconnect/delete
- ended-session log viewing with retained output snapshot
- terminal daemon restart update prompt path
