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

