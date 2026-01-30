# Agent Pairing & Connectivity Plan

## Goals
- QR code is **on-demand**: only generated after user clicks “Generate”, hidden when expired.
- Mobile can connect via **LAN-first** with SSID + subnet checks and health probes, or **FRP public URL** when LAN is unavailable.
- Two authentication tracks:
  - Static tokens (named, revocable)
  - QR handshake (temporary) that yields a **device-bound** long-lived token (reuse if device already paired).
- UI/UX for desktop agent is consistent, reliable, and reflects the real system state.
- Security posture is safe for public exposure.

## Architecture Summary
- **Pairing QR payload** includes: `device_id`, `wifi_ssid`, `local_ips`, `local_urls`, `frp_url`, `pairing_token`, `pairing_secret`, `expires_at`.
- **Token model**:
  - Static token list (name + token + revoked status)
  - Device-bound token (client_id → token), reused across re-handshakes
- **Connectivity strategy** (mobile):
  - If SSID + subnet match, probe LAN (2s) and FRP (3s) concurrently; prefer LAN if reachable.
  - If LAN/FRP both fail → mark offline.
  - If one succeeds → fetch identity + status and update cached route preference.

---

## Protocol Fields (Draft)

### QR Payload (pairing session)
- `token` / `pairing_token`: short pairing token (QR handshake).
- `secret` / `pairing_secret`: pairing secret used with token.
- `expires_at`: unix timestamp (seconds) when QR expires.
- `device_id`: hashed stable device ID for the agent.
- `wifi_ssid`: current Wi-Fi SSID (if available).
- `local_ips`: list of local IPv4 addresses for subnet matching.
- `local_urls`: list of local URLs (http://ip:port) for LAN checks.
- `frp_url`: optional public FRP URL configured by user.
- `tunnel_url`: optional cloud tunnel URL (if enabled).
- `tunnel_error`: diagnostics if tunnel URL unavailable.
- `requires_approval`: whether desktop approval is required.

### Identity Command (mobile -> agent)
- `device_id`: agent device ID.
- `auth_token`: primary token (for UI display).
- `wifi_ssid`: current SSID (if available).
- `local_ips`: local IPv4 addresses for subnet matching.
- `local_urls`: local URLs for LAN checks.
- `frp_url`: configured FRP URL.

### Token Rules
- Static tokens are 64 chars, named, revocable.
- Device-bound tokens are bound to `client_id` and reused on re-handshake.
- Revoked tokens are invalid immediately.

---

## Connection Logic (Draft)

### Initial Pairing (QR)
1. User generates QR in desktop UI (expires ~2 minutes).
2. Mobile scans payload and validates `token`, `secret`, `expires_at`.
3. Determine LAN eligibility via SSID match + /24 subnet match.
4. Endpoint selection:
   - Manual override wins if set.
   - If force tunnel → use remote only.
   - Else prefer local URLs if same LAN, fallback to remote URLs.
5. Probe local `/health` (2s) and remote `/health` (3s) concurrently.
6. Choose first reachable local URL; otherwise fallback to reachable remote URL.
7. Call `/pairing/confirm` with `token`, `secret`, `client_id`, `client_name`.
8. If device is already paired, server reuses existing device-bound token.
9. Store connection with token, device_id, local + remote metadata.

### Reconnect / Routine App Launch
1. On app launch, load stored agents.
2. Compare current SSID + local IPs to stored agent metadata.
3. Probe LAN (2s) and FRP (3s) concurrently when applicable.
4. If any endpoint reachable → mark connected and refresh identity metadata.
5. If none reachable → mark offline and show inline probe errors.

---

## Work Breakdown (Detailed)

### Phase 0 — Context Audit & Baseline Checks
- [x] Review desktop pairing pipeline (token, QR payload, session expiry, approval, client tracking)
- [x] Review mobile pairing pipeline (QR parsing, confirm flow, LAN/Tunnel selection)
- [x] Identify token validation path for local server + websocket endpoints
- [x] Enumerate UI elements needed for QR, devices, tokens, FRP config

### Phase 1 — Desktop UI Hardening (QR, Device List, Settings)
- [x] Fix DOM structure so QR and device list render correctly
- [x] Make QR **on-demand** (no auto-create on load)
- [x] Hide QR when expired and require re-generate
- [x] Add Settings view with token management list
- [x] Add Settings field for FRP public URL
- [x] Surface token revoke + primary-token actions in UI

### Phase 2 — QR Payload & Pairing Protocol
- [x] Extend QR payload with `wifi_ssid` and `local_ips`
- [x] Add `frp_url` to payload when configured
- [x] Add explicit `pairing_token` / `pairing_secret` aliases for stability
- [x] Implement expiry policy (default TTL = 120s, configurable later)
- [x] Ensure QR payload includes local URLs + device ID

### Phase 3 — Token Model & Security
- [x] Add 64-char static token creation / add / revoke in identity
- [x] Bind tokens to client_id; reuse on re-handshake
- [x] Implement token list API for UI (ensure only active tokens are valid)
- [x] Add rate limiting / cooldown for invalid token attempts (public safety)
- [x] Extend identity response with LAN metadata for mobile refresh

### Phase 4 — Mobile Connectivity Logic
- [x] SSID + subnet matching logic (LAN inference)
- [x] Concurrent probes (LAN 2s / FRP 3s) with preference rules
- [x] Offline detection and UI state
- [x] Fetch identity/status on connect and refresh cached route
- [x] Persist refreshed Wi-Fi + LAN metadata back to local storage

### Phase 5 — UX Polish & Documentation
- [x] Clarify QR expiry behavior in UI copy
- [x] Add inline error messages for LAN/FRP probe failures
- [x] Document protocol fields + connection logic

---

## Progress Log
- **2026-01-30**: Created detailed plan and logged initial UI fixes + token model groundwork.
- **2026-01-30**: QR is now on-demand, auto-hidden on expiry; TTL set to 120s by default.
- **2026-01-30**: FRP URL configuration added to Settings and included in QR payload/status.
- **2026-01-30**: Mobile LAN/FRP probing with SSID/subnet matching and offline status updates added.
- **2026-01-30**: Identity command now returns Wi-Fi + LAN metadata; mobile refreshes cached agent info after connectivity.
- **2026-01-30**: QR expiry copy clarified; mobile shows inline probe failure details; protocol fields documented.
- **2026-01-30**: Added mobile app flags for test runs to disable connectivity refresh/network hints; widget tests updated accordingly.
- **2026-01-30**: Fixed desktop pairing move error and cleaned VNC input scaling init to satisfy Rust build.
- **2026-01-30**: Desktop bridge-unavailable banner localized to CN and status pill hidden when bridge missing.
- **2026-01-30**: Enabled Tauri global API and added invoke fallback for v1/v2 to restore desktop UI functionality.
- **2026-01-30**: Mobile offline detection now probes LAN even when SSID unknown; retry pairing triggers status refresh.
