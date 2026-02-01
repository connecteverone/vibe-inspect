# Terminal Open Failures + High Performance Mode Review

Date: 2026-02-01  
Scope: Mobile (Flutter) + Desktop agent (Rust/Tauri)

## Verified Issues (confirmed in code)

### Terminal cannot open reliably
1) Wrong agentId passed when creating a new terminal session after switching agents.
   - Mobile creates the session with `_activeAgent.id` but opens the terminal screen with `widget.agent.id`.
   - File: `mobile/lib/main.dart` (`_openTerminalSession`).
   - Impact: session is attached to a different agent than the screen expects, so the terminal view loads empty or errors.

2) Newly created terminal sessions are force-closed when remote list does not contain them.
   - `_loadSessions()` merges local + remote sessions and closes any local session missing from the remote list.
   - New sessions start as `idle`, so they are immediately set to `closed` before they can be started remotely.
   - File: `mobile/lib/main.dart` (`_loadSessions` merge logic).
   - Impact: the session never reaches the “start” call; terminal appears to fail to open.

3) Desktop agent shell fallback is hard-coded to `/bin/zsh`.
   - File: `desktop/src/terminal.rs` (`start_session`).
   - Impact: on Windows/Linux this fails to spawn, producing terminal startup errors.

### High Performance Mode is not truly “high performance”
4) High Performance lowers frame rate by default (desktop).
   - High perf interval defaults to 100ms and overrides the active interval (~33ms).
   - File: `desktop/src/vnc.rs` (`resolve_high_perf_interval_ms`, `spawn_capture_thread`).
   - Impact: enabling High Performance can reduce FPS instead of increasing it.

5) High Performance sends full-frame updates when idle (desktop).
   - When no changes are sent, high perf forces a full frame on interval.
   - File: `desktop/src/vnc.rs` (full-frame path in capture loop).
   - Impact: high CPU/bandwidth with limited benefit.

6) Mobile High Performance does not switch to faster encoding defaults.
   - High perf only toggles an encoding flag and interval; it does not lower compression or favor faster encodings.
   - File: `mobile/lib/main.dart` (`_setHighPerfMode`, `_buildEncodingList`).
   - Impact: high perf can still use slow encodings under load.

### ROI performance constraints (affects perceived “high performance” while zoomed)
7) ROI stream loop is fixed at 80ms cadence (desktop).
   - File: `desktop/src/quic/mod.rs` (`run_roi_stream`).
   - Impact: ROI tiles refresh at ~12.5 fps regardless of zoom/viewport.

8) ROI tile assembly has no TTL cleanup (mobile).
   - Partial buffers never expire if chunks are lost.
   - File: `mobile/lib/roi/roi_client.dart` (`RoiTileAssembler`).
   - Impact: memory can grow over time in poor networks.

9) ROI tile cache is fixed at 256 tiles (mobile).
   - File: `mobile/lib/main.dart` (`_handleRoiTile` eviction).
   - Impact: under zoom or large viewports, tiles churn or stay blurry.

## Plan to Fix and Optimize (high performance truly high performance)

### Phase 1: Terminal correctness
1) Fix `agentId` passed to `TerminalWorkspaceScreen`.
2) In `_loadSessions`, do **not** auto-close local `idle/queued` sessions that are missing remotely.
   - Only close if local status was `running`/`connected` or if the remote explicitly reports closure.
3) Desktop: implement platform-aware shell selection:
   - Windows: `powershell.exe` (fallback `cmd.exe`)
   - Linux: `/bin/bash` (fallback `/bin/sh`)
   - macOS: keep `SHELL` or `/bin/zsh`.

### Phase 2: High Performance mode semantics (VNC)
1) Desktop: ensure High Performance never reduces active FPS.
   - Use `min(active_interval, high_perf_interval)` or apply high-perf interval only when idle.
2) Desktop: replace idle full-frame pushes with a low-cost keepalive or small diff-only update.
3) Mobile: default high-perf interval to 33ms (or 16ms if targeting 60fps).
4) Mobile: when High Performance is enabled, switch to “fast encoding” preset:
   - Prefer Zlib (low compression), disable JPEG, reduce compression levels.
   - Keep this independent of low-latency toggle (or auto-enable low latency).
5) Update UI copy to reflect new semantics (high perf = higher fps, not lower).

### Phase 3: ROI throughput and stability
1) Desktop: make ROI loop cadence adaptive to zoom + viewport size.
2) Mobile: adaptive ROI cache size based on zoom / viewport area.
3) Mobile: add TTL or max-entry cleanup to ROI chunk buffers.

### Phase 4: Validation
1) Terminal: verify new sessions start and persist without auto-closing.
2) High perf: verify FPS >= baseline active rate after enabling.
3) ROI: verify improved sharpness at zoom with no sustained tile backlog.
4) Long-run memory: ROI buffers remain bounded.

## Applied Changes (2026-02-01)
- Mobile: pass `_activeAgent.id` to `TerminalWorkspaceScreen` to avoid agent mismatch.
- Mobile: only auto-close missing remote terminal sessions when local status is `running/connected`.
- Desktop: add platform-aware shell selection for terminal startup.

## Deferred Changes
- VNC/ROI optimizations are deferred per request (“vnc 不要动”), so no VNC behavior changes were applied in this fix set.
