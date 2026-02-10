# Terminal Compatibility Matrix

This document defines the compatibility baseline for `terminald` and the mobile/desktop terminal pipeline.

## Goals

- Keep output fidelity close to mature terminals (`xterm`/`iTerm2`/`kitty`) for common developer workflows.
- Guarantee protocol safety and predictable behavior under load.
- Turn compatibility requirements into automated regression tests.

## Scope

- Backend stream path: PTY -> `terminal_core` -> `terminald` WS events.
- Agent bridge path: desktop `/command` and `/terminal/{session_id}`.
- Mobile render path: WS payload -> Flutter terminal widget.

## Compatibility Matrix

| Area | Capability | Target | Current status | Automated check |
| --- | --- | --- | --- | --- |
| Encoding | UTF-8 CJK/emoji | No garble, no truncation | ✅ | `terminald_ws_integration` |
| Encoding | Split UTF-8 bytes | Reassemble across chunk boundaries | ✅ | unit test `utf8_chunks_reassemble` |
| Encoding | Invalid UTF-8 | Replace with U+FFFD, no panic | ✅ | unit test `malformed_utf8_replaced` |
| Encoding | Grapheme clusters / ZWJ | Combining chars and ZWJ emoji remain intact | ✅ | `unicode_grapheme_clusters_and_zwj_sequences_are_streamed` |
| ANSI | 16/256/24-bit color sequences | Escape sequences preserved end-to-end | ✅ | `terminald_ws_integration` |
| ANSI | Frequent clear/home (`CSI 2J/H`) | Stream remains responsive, no deadlock | ✅ | `terminald_ws_integration` |
| ANSI | Alternate screen (`CSI ?1049 h/l`) | Sequence delivery preserved | ✅ | `osc8_truecolor_and_alt_screen_sequences_are_streamed` |
| ANSI | Cursor save/restore (`CSI s/u`) | Sequence delivery preserved | ✅ | `csi_sequences_and_bracketed_paste_are_streamed` |
| ANSI | Scroll region (`CSI r`) | Sequence delivery preserved | ✅ | `csi_sequences_and_bracketed_paste_are_streamed` |
| ANSI | Insert/Delete line (`CSI L/M`) | Sequence delivery preserved | ✅ | `csi_sequences_and_bracketed_paste_are_streamed` |
| ANSI | Bracketed paste (`?2004`, `200~/201~`) | Sequence delivery preserved | ✅ | `csi_sequences_and_bracketed_paste_are_streamed` |
| OSC | OSC 8 hyperlinks | Sequence delivery preserved | ✅ | `osc8_truecolor_and_alt_screen_sequences_are_streamed` |
| OSC | OSC 8 with BEL terminator | BEL-terminated hyperlinks preserved | ✅ | `split_escape_sequences_and_bel_osc8_are_streamed` |
| ANSI | Split escape sequence chunks | Fragmented ESC/CSI sequences reassemble in stream | ✅ | `split_escape_sequences_and_bel_osc8_are_streamed` |
| Stress | Rapid ANSI clear+color bursts | Stream alive, no deadlock | ✅ | `rapid_ansi_clear_stress_keeps_stream_alive` |
| Stress | Sustained high-volume UTF-8+ANSI burst | Tail markers preserved under long burst output | ✅ | `sustained_high_volume_utf8_ansi_burst_keeps_tail_integrity` |
| Regression | Golden stream fixture replay | Deterministic ANSI/OSC/CSI regression baseline | ✅ | `golden_terminal_stream_fixtures_replay` |
| Failure budget | Nominal stream run | `dropped_chunks_total=0`, `ws_backpressure_events_total=0` | ✅ | `golden_terminal_stream_fixtures_replay` |
| Failure budget | Backpressure stress run | `ws_backpressure_events_total>=1`, service remains healthy | ✅ | `backpressure_triggers_snapshot_or_disconnect` |
| Failure budget | Reconnect success rate | `reconnect_success_rate_percent` stays within target range | ✅ | `golden_terminal_stream_fixtures_replay` |
| Failure budget | Pause duration percentiles | `pause_duration_p95_ms >= pause_duration_p50_ms` and samples tracked | ✅ | `backpressure_triggers_snapshot_or_disconnect` |
| Backpressure | High-volume output | Pause/resume or controlled close; no OOM | ✅ | `backpressure_triggers_snapshot_or_disconnect` |
| Bridge | Control events (`stream_paused/resumed`, `session_warning`) | Forwarded to mobile UI with stable payloads | ✅ | unit tests in `desktop/src/terminal.rs` |
| Auth | WS header/query token fallback | Header preferred, query fallback for compatibility | ✅ | unit tests in `desktop/src/server.rs` |
| Auth | Short-lived WS ticket (`ws_ticket`) | One-time scoped ticket (30s TTL) with static-token fallback | ✅ | unit tests in `desktop/src/server.rs` + mobile fallback path |
| Safety | Post-auth request size bound | Reject oversized request/input payloads | ✅ | `terminald_ws_integration` + unit checks |
| Auth | First frame auth required | Reject unauthenticated commands | ✅ | `rejects_non_auth_first_message` |
| Auth | Invalid token reject | Reject and close with explicit error | ✅ | `rejects_invalid_auth_token` |
| Auth | Oversized auth payload reject | Bound pre-auth frame size, fail closed | ✅ | `rejects_oversized_auth_payload` |
| Auth | Version mismatch reject | Fail closed when major protocol version differs | ✅ | `rejects_auth_version_mismatch` |
| Auth | Missing token payload reject | Fail closed when auth token missing | ✅ | `rejects_missing_auth_token_payload` |
| Auth | Binary frame before auth reject | First frame must be valid auth request | ✅ | `rejects_binary_message_during_auth_handshake` |
| Transport | Local-only daemon socket | Loopback only | ✅ | code path enforced |

## Non-goals (for this phase)

- Full conformance to every DEC private mode.
- Full parity with terminal-specific extensions (iTerm2 inline image protocol, kitty graphics protocol).
- Wasm/web build enablement for all Flutter dependencies.

## Phase Plan

### Phase 1 (done)

- Security baseline: auth-first handshake + token validation + loopback restriction.
- Backpressure guardrails and metrics.
- Core UTF-8 handling and compatibility smoke tests.

### Phase 2 (in progress)

- ✅ Added scripted compatibility tests for:
  - fixture-driven golden stream replay (ANSI/OSC/CSI)
  - cursor save/restore (`CSI s`/`CSI u`)
  - line insert/delete (`CSI L`/`CSI M`)
  - region scroll (`CSI r`)
  - bracketed paste mode (`CSI ?2004 h/l`)
  - OSC 8 hyperlinks (including BEL terminator), truecolor, alternate screen, rapid clear stress
  - grapheme cluster / ZWJ unicode rendering checks
  - fragmented ESC/CSI sequence delivery checks
  - sustained high-volume UTF-8+ANSI burst tail-integrity checks
  - auth version/token-shape/binary-preauth fail-closed checks
- ⏭️ Next in Phase 2:
  - Add long-run metrics retention and external dashboard wiring for failure budget SLO tracking.

### Phase 3 (advanced)

- Optional extension support (feature flags): OSC 52 clipboard, richer OSC metadata.
- Long-session endurance test (multi-hour output + reconnect cycles).
- Differential tests against a reference terminal parser.

## Exit Criteria for “Mature Terminal Baseline”

- No regressions in matrix tests for 30 consecutive CI runs.
- All P0/P1 compatibility scenarios covered by deterministic tests.
- Backpressure and auth metrics remain within thresholds in stress runs.

## Failure Budget Checks

- Nominal baseline (no stress):
  - `MAX_DROPPED_CHUNKS_TOTAL=0 MAX_WS_BACKPRESSURE_EVENTS_TOTAL=0 MIN_RECONNECT_SUCCESS_RATE_PERCENT=100 ./scripts/terminal_failure_budget_check.sh`
- Stress baseline (expect backpressure, bounded pause p95):
  - `MIN_WS_BACKPRESSURE_EVENTS_TOTAL=1 MAX_PAUSE_DURATION_P95_MS=5000 MIN_RECONNECT_SUCCESS_RATE_PERCENT=90 ./scripts/terminal_failure_budget_check.sh`
- The check script consumes `vibe-ctl debug` metrics and fails fast on threshold violations.
