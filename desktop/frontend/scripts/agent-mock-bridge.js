(() => {
  if (window.__TAURI__?.core?.invoke || window.__TAURI__?.invoke || window.__TAURI_INTERNALS__?.invoke) {
    return;
  }

  const search = new URLSearchParams(window.location.search);
  const explicitMock = search.get("mock") === "1" || search.get("mock_bridge") === "1";
  const devHost = ["localhost", "127.0.0.1"].includes(window.location.hostname);
  const fileProtocol = window.location.protocol === "file:";
  if (!explicitMock && !devHost && !fileProtocol) {
    return;
  }

  const nowTs = () => Math.floor(Date.now() / 1000);
  const randomToken = (len = 64) => {
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
    let value = "";
    for (let i = 0; i < len; i += 1) {
      value += alphabet[Math.floor(Math.random() * alphabet.length)];
    }
    return value;
  };

  const state = {
    session: null,
    connected_at: null,
    pending: {
      token: "mock-pending",
      requested_at: nowTs(),
      expires_at: nowTs() + 180,
      source: "Mock phone",
      client_id: "mock-client-1",
      client_name: "Mock iPhone",
    },
    requires_approval: true,
    tunnel_url: null,
    tunnel_error: null,
    device_id: "mock-desktop",
    auth_token: randomToken(64),
    auth_tokens: [],
    wifi_ssid: "MockWiFi",
    location_permission: "authorized",
    bundle_id: "com.vibeinspect.agent.mock",
    bundle_path: "/mock/path/VibeInspect.app",
    location_usage_key: true,
    local_ips: ["192.168.1.120"],
    frp_url: "",
    listen_port: 58888,
    roi_quic_port: 5000,
    paired_devices: [
      {
        id: "mock-client-1",
        name: "Mock iPhone",
        paired_at: nowTs() - 400,
        last_seen_at: nowTs() - 10,
        source: "LAN",
        disabled: false,
        blocked_until: null,
      },
    ],
    connected_devices: [
      {
        id: "mock-client-1",
        name: "Mock iPhone",
        paired_at: nowTs() - 400,
        last_seen_at: nowTs() - 10,
        source: "LAN",
        disabled: false,
        blocked_until: null,
      },
    ],
    terminal_update_available:
      search.get("mock_terminal_update") === "1" || search.get("mock_update") === "1",
    terminal_update_message: null,
    terminal_running_version: "0.8.0",
    terminal_bundled_version: "0.9.0",
    terminalSessions: {
      "mock-session-1": {
        id: "mock-session-1",
        label: "Mock shell",
        status: "running",
        created_at: nowTs() - 80,
        last_activity: nowTs() - 2,
        seq: 2,
        next_expected_seq: 3,
        output: [
          { seq: 1, ts: nowTs() - 75, data: "$ echo hello from mock\nhello from mock\n" },
          { seq: 2, ts: nowTs() - 30, data: "$ uname -a\nDarwin mock-host 24.0.0\n" },
        ],
        rows: 32,
        cols: 120,
      },
    },
  };

  if (state.terminal_update_available) {
    state.terminal_update_message =
      "Mock mode: a newer terminald is available. Restart terminal service to apply.";
  }

  const listTerminalSessions = () =>
    Object.values(state.terminalSessions)
      .sort((left, right) => (right.last_activity || 0) - (left.last_activity || 0))
      .map((session) => ({
        id: session.id,
        label: session.label,
        status: session.status,
        created_at: session.created_at,
        last_activity: session.last_activity,
        exit_code: session.exit_code ?? null,
        closed_reason: session.closed_reason ?? null,
        last_output: session.output.length ? session.output[session.output.length - 1].data : "",
      }));

  const statusResponse = () => ({
    session: state.session,
    connected_at: state.connected_at,
    pending: state.pending,
    requires_approval: state.requires_approval,
    local_urls: [
      `http://${state.local_ips[0]}:${state.listen_port}`,
      `http://127.0.0.1:${state.listen_port}`,
    ],
    tunnel_url: state.tunnel_url,
    tunnel_error: state.tunnel_error,
    device_id: state.device_id,
    auth_token: state.auth_token,
    auth_tokens: state.auth_tokens,
    wifi_ssid: state.wifi_ssid,
    location_permission: state.location_permission,
    bundle_id: state.bundle_id,
    bundle_path: state.bundle_path,
    location_usage_key: state.location_usage_key,
    local_ips: state.local_ips,
    frp_url: state.frp_url,
    transports: [],
    listen_port: state.listen_port,
    roi_quic_port: state.roi_quic_port,
    paired_devices: state.paired_devices,
    active_devices: state.connected_devices,
    connected_devices: state.connected_devices,
    terminal_sessions: listTerminalSessions(),
    terminal_error_code: null,
    terminal_error_message: null,
    terminal_update_available: state.terminal_update_available,
    terminal_update_message: state.terminal_update_message,
    terminal_running_version: state.terminal_running_version,
    terminal_bundled_version: state.terminal_bundled_version,
  });

  const terminalPayload = (action, session, output = []) => ({
    type: "terminal",
    action,
    session_id: session.id,
    status: session.status,
    seq: session.seq,
    next_expected_seq: session.next_expected_seq,
    output,
    first_seq: output.length > 0 ? output[0].seq : session.seq,
    truncated: false,
    snapshot: session.output.length ? session.output.map((entry) => entry.data).join("") : null,
    exit_code: session.exit_code ?? null,
    closed_reason: session.closed_reason ?? null,
    last_activity: session.last_activity,
    label: session.label,
    notification_seq: 0,
    notifications: [],
  });

  const decodeBase64 = (value) => {
    if (!value) return "";
    try {
      const bin = window.atob(value);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i += 1) {
        bytes[i] = bin.charCodeAt(i);
      }
      return new TextDecoder().decode(bytes);
    } catch (_) {
      return "";
    }
  };

  const makeError = (code, message) => ({ status: "error", error: { code, message } });

  const handleTerminalAction = (payload = {}) => {
    const action = payload.action;
    const sessionId = payload.session_id;
    let session = sessionId ? state.terminalSessions[sessionId] : null;

    if (action === "restart_daemon" || action === "restart_terminald") {
      state.terminal_update_available = false;
      state.terminal_update_message = null;
      state.terminal_running_version = state.terminal_bundled_version;
      return { status: "ok", payload: { type: "terminal", action: "restart_daemon", status: "restarted" } };
    }

    if (action === "start") {
      const id = `mock-session-${Date.now()}`;
      session = {
        id,
        label: payload.label || "Mock shell",
        status: "running",
        created_at: nowTs(),
        last_activity: nowTs(),
        seq: 0,
        next_expected_seq: 1,
        output: [],
        rows: Number.isFinite(payload.rows) ? payload.rows : 32,
        cols: Number.isFinite(payload.cols) ? payload.cols : 120,
      };
      state.terminalSessions[id] = session;
      return { status: "ok", payload: terminalPayload("start", session) };
    }

    if (!session) {
      return makeError("session_not_found", "Mock terminal session not found.");
    }

    if (action === "rename") {
      session.label = payload.label || session.label;
      session.last_activity = nowTs();
      return { status: "ok", payload: terminalPayload("rename", session) };
    }

    if (action === "keepalive") {
      session.last_activity = nowTs();
      return { status: "ok", payload: terminalPayload("keepalive", session) };
    }

    if (action === "resize") {
      session.rows = Number.isFinite(payload.rows) ? payload.rows : session.rows;
      session.cols = Number.isFinite(payload.cols) ? payload.cols : session.cols;
      session.last_activity = nowTs();
      return { status: "ok", payload: terminalPayload("resize", session) };
    }

    if (action === "input") {
      const text = decodeBase64(payload.input_b64) || "\n";
      session.seq += 1;
      session.next_expected_seq = session.seq + 1;
      session.last_activity = nowTs();
      const entry = {
        seq: session.seq,
        ts: nowTs(),
        data: `$ ${text.replace(/\n+$/g, "")}\nmock: command executed\n`,
      };
      session.output.push(entry);
      return { status: "ok", payload: terminalPayload("input", session) };
    }

    if (action === "poll") {
      const since = Number.isFinite(payload.since) ? payload.since : 0;
      const output = session.output.filter((entry) => entry.seq > since);
      session.last_activity = nowTs();
      return { status: "ok", payload: terminalPayload("poll", session, output) };
    }

    if (action === "status") {
      return { status: "ok", payload: terminalPayload("status", session) };
    }

    if (action === "stop" || action === "kill") {
      session.status = action === "kill" ? "killed" : "exited";
      session.closed_reason = action === "kill" ? "Killed from mock UI." : "Disconnected from mock UI.";
      session.exit_code = null;
      session.last_activity = nowTs();
      return {
        status: "ok",
        payload: {
          ...terminalPayload("stop", session),
          status: session.status,
          closed_reason: session.closed_reason,
          snapshot: session.output.map((entry) => entry.data).join(""),
        },
      };
    }

    if (action === "delete") {
      delete state.terminalSessions[session.id];
      return {
        status: "ok",
        payload: {
          type: "terminal",
          action: "delete",
          session_id: session.id,
          status: "deleted",
        },
      };
    }

    return makeError("unsupported_action", `Unsupported mock terminal action: ${action}`);
  };

  const invoke = async (command, args = {}) => {
    await new Promise((resolve) => setTimeout(resolve, 80));

    if (command === "request_location_permission") {
      state.location_permission = "authorized";
      return { granted: true };
    }

    if (command === "open_location_settings") {
      return { opened: true };
    }

    if (command === "create_pairing_session") {
      const token = randomToken(8);
      const secret = randomToken(12);
      const expires = nowTs() + 180;
      state.session = {
        protocol_version: "1.1",
        token,
        secret,
        nonce: randomToken(16),
        expires_at: expires,
      };
      return {
        token,
        secret,
        qr_payload: JSON.stringify({ token, secret }),
        qr_svg:
          '<svg xmlns="http://www.w3.org/2000/svg" width="180" height="180"><rect width="180" height="180" fill="#0f172a"/><text x="18" y="92" fill="#bae6fd" font-size="14">Mock QR</text></svg>',
        expires_at: expires,
        device_id: state.device_id,
        auth_token: state.auth_token,
        wifi_ssid: state.wifi_ssid,
        local_ips: state.local_ips,
        local_urls: [`http://127.0.0.1:${state.listen_port}`],
        tunnel_url: state.tunnel_url,
        tunnel_error: state.tunnel_error,
        frp_url: state.frp_url,
        listen_port: state.listen_port,
      };
    }

    if (command === "get_pairing_status") {
      return statusResponse();
    }

    if (command === "set_pairing_requires_approval") {
      state.requires_approval = !!args.requires_approval;
      return statusResponse();
    }

    if (command === "approve_pairing_request") {
      state.pending = null;
      state.connected_at = nowTs();
      return { status: "connected" };
    }

    if (command === "deny_pairing_request") {
      state.pending = null;
      state.connected_at = null;
      return statusResponse();
    }

    if (command === "reset_auth_token") {
      state.auth_token = randomToken(64);
      return { device_id: state.device_id, auth_token: state.auth_token };
    }

    if (command === "set_frp_url") {
      state.frp_url = (args.url || "").trim();
      return statusResponse();
    }

    if (command === "set_listen_port") {
      state.listen_port = Number(args.port) || state.listen_port;
      return statusResponse();
    }

    if (command === "set_roi_quic_port") {
      state.roi_quic_port = Number(args.port) || state.roi_quic_port;
      return statusResponse();
    }

    if (command === "create_auth_token") {
      const record = {
        token: randomToken(64),
        label: args.label || "Manual token",
        created_at: nowTs(),
        revoked_at: null,
        client_id: null,
        is_primary: state.auth_tokens.length === 0,
      };
      state.auth_tokens.unshift(record);
      return record;
    }

    if (command === "add_auth_token") {
      const token = (args.token || "").trim();
      if (!token) throw { code: "invalid_token", message: "Token cannot be empty." };
      if (token.length !== 64) {
        throw { code: "invalid_token_length", message: "Token must be 64 characters." };
      }
      state.auth_tokens.unshift({
        token,
        label: args.label || null,
        created_at: nowTs(),
        revoked_at: null,
        client_id: null,
        is_primary: state.auth_tokens.length === 0,
      });
      return { ok: true };
    }

    if (command === "set_primary_auth_token") {
      const token = (args.token || "").trim();
      state.auth_tokens = state.auth_tokens.map((record) => ({
        ...record,
        is_primary: record.token === token,
      }));
      return statusResponse();
    }

    if (command === "revoke_auth_token") {
      const token = (args.token || "").trim();
      state.auth_tokens = state.auth_tokens.map((record) =>
        record.token === token ? { ...record, revoked_at: nowTs(), is_primary: false } : record
      );
      return statusResponse();
    }

    if (command === "rename_client") {
      const id = args.client_id;
      const name = (args.name || "").trim();
      state.paired_devices = state.paired_devices.map((device) =>
        device.id === id ? { ...device, name } : device
      );
      state.connected_devices = state.connected_devices.map((device) =>
        device.id === id ? { ...device, name } : device
      );
      return statusResponse();
    }

    if (command === "set_client_blocked") {
      const id = args.client_id;
      const blocked = !!args.blocked;
      state.paired_devices = state.paired_devices.map((device) =>
        device.id === id ? { ...device, disabled: blocked } : device
      );
      return statusResponse();
    }

    if (command === "kick_client") {
      const id = args.client_id;
      state.connected_devices = state.connected_devices.filter((device) => device.id !== id);
      return statusResponse();
    }

    if (command === "forget_client") {
      const id = args.client_id;
      state.paired_devices = state.paired_devices.filter((device) => device.id !== id);
      state.connected_devices = state.connected_devices.filter((device) => device.id !== id);
      return statusResponse();
    }

    if (command === "handle_agent_command") {
      const request = args.request || {};
      if (request.command !== "terminal") {
        return { status: "error", error: { code: "unsupported_command", message: "Unsupported mock command." } };
      }
      return handleTerminalAction(request.payload || {});
    }

    throw { code: "unsupported_command", message: `Mock bridge does not implement: ${command}` };
  };

  window.__TAURI__ = {
    core: { invoke },
    invoke,
  };

  window.__AGENT_UI__ = window.__AGENT_UI__ || {};
  window.__AGENT_UI__.mockBridgeEnabled = true;
})();
