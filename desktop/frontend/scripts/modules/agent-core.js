      const resolveInvoke = () =>
        window.__TAURI__?.core?.invoke ??
        window.__TAURI__?.invoke ??
        window.__TAURI_INTERNALS__?.invoke ??
        null;
      let invoke = resolveInvoke();
      const shellEl = document.querySelector(".shell");
      const bridgeAlertEl = document.getElementById("bridgeAlert");
      const locationAlertEl = document.getElementById("locationAlert");
      const requestLocationPermissionBtn = document.getElementById(
        "requestLocationPermission"
      );
      const openLocationSettingsBtn = document.getElementById(
        "openLocationSettings"
      );
      const statusEl = document.getElementById("status");
      const toastHostEl = document.getElementById("toastHost");
      const topRestartTerminalBtn = document.getElementById("topRestartTerminal");
      const qrEl = document.getElementById("qr");
      const qrEmptyEl = document.getElementById("qrEmpty");
      const qrEmptyTitleEl = document.getElementById("qrEmptyTitle");
      const qrEmptyMessageEl = document.getElementById("qrEmptyMessage");
      const tokenEl = document.getElementById("token");
      const secretEl = document.getElementById("secret");
      const expiresEl = document.getElementById("expires");
      const payloadEl = document.getElementById("payload");
      const localUrlsEl = document.getElementById("localUrls");
      const localIpsEl = document.getElementById("localIps");
      const wifiSsidEl = document.getElementById("wifiSsid");
      const locationPermissionEl = document.getElementById(
        "locationPermission"
      );
      const bundleIdEl = document.getElementById("bundleId");
      const bundlePathEl = document.getElementById("bundlePath");
      const locationUsageKeyEl = document.getElementById("locationUsageKey");
      const tunnelUrlEl = document.getElementById("tunnelUrl");
      const frpUrlEl = document.getElementById("frpUrl");
      const tunnelErrorEl = document.getElementById("tunnelError");
      const approvalToggle = document.getElementById("requireApproval");
      const approvalCard = document.getElementById("approvalCard");
      const pendingMetaEl = document.getElementById("pendingMeta");
      const approveBtn = document.getElementById("approvePairing");
      const denyBtn = document.getElementById("denyPairing");
      const pairedDevicesEl = document.getElementById("pairedDevices");
      const activeDevicesEl = document.getElementById("activeDevices");
      const terminalSessionsEl = document.getElementById("terminalSessions");
      const refreshTerminalSessionsBtn = document.getElementById("refreshTerminalSessions");
      const terminalDetailTitleEl = document.getElementById("terminalDetailTitle");
      const terminalDetailMetaEl = document.getElementById("terminalDetailMeta");
      const terminalDetailStatusEl = document.getElementById("terminalDetailStatus");
      const terminalRestartPromptEl = document.getElementById("terminalRestartPrompt");
      const terminalRestartMessageEl = document.getElementById("terminalRestartMessage");
      const terminalRestartLaterBtn = document.getElementById("terminalRestartLater");
      const terminalRestartNowBtn = document.getElementById("terminalRestartNow");
      const terminalOutputEl = document.getElementById("terminalOutput");
      const terminalInputEl = document.getElementById("terminalInput");
      const terminalSendBtn = document.getElementById("terminalSend");
      const terminalStopBtn = document.getElementById("terminalStop");
      const terminalDeleteBtn = document.getElementById("terminalDelete");
      const terminalEnterSendsEl = document.getElementById("terminalEnterSends");
      const terminalAutoScrollEl = document.getElementById("terminalAutoScroll");
      const terminalNoWrapEl = document.getElementById("terminalNoWrap");
      const terminalCopyOutputBtn = document.getElementById("terminalCopyOutput");
      const terminalClearOutputBtn = document.getElementById("terminalClearOutput");
      const terminalOutputMetaEl = document.getElementById("terminalOutputMeta");
      const terminalColsInput = document.getElementById("terminalCols");
      const terminalRowsInput = document.getElementById("terminalRows");
      const terminalFitBtn = document.getElementById("terminalFit");
      const terminalResizeBtn = document.getElementById("terminalResize");
      const generateBtn = document.getElementById("generate");
      const copyBtn = document.getElementById("copyPayload");
      const authTokenEl = document.getElementById("authToken");
      const deviceIdEl = document.getElementById("deviceId");
      const connectionModeEl = document.getElementById("connectionMode");
      const frpStatusEl = document.getElementById("frpStatus");
      const pairedCountEl = document.getElementById("pairedCount");
      const activeCountEl = document.getElementById("activeCount");
      const lastActiveEl = document.getElementById("lastActive");
      const copyAuthTokenBtn = document.getElementById("copyAuthToken");
      const toggleAuthTokenBtn = document.getElementById("toggleAuthToken");
      const copyDeviceIdBtn = document.getElementById("copyDeviceId");
      const resetAuthTokenBtn = document.getElementById("resetAuthToken");
      const tokenListEl = document.getElementById("tokenList");
      const generateTokenBtn = document.getElementById("generateLongToken");
      const addTokenBtn = document.getElementById("addTokenBtn");
      const customTokenInput = document.getElementById("customTokenInput");
      const customTokenLabelInput = document.getElementById("customTokenLabel");
      const frpUrlInput = document.getElementById("frpUrlInput");
      const saveFrpUrlBtn = document.getElementById("saveFrpUrl");
      const listenPortInput = document.getElementById("listenPortInput");
      const saveListenPortBtn = document.getElementById("saveListenPort");
      const roiQuicPortInput = document.getElementById("roiQuicPortInput");
      const saveRoiQuicPortBtn = document.getElementById("saveRoiQuicPort");
      const imageUploadDropzoneEl = document.getElementById("imageUploadDropzone");
      const imageUploadInputEl = document.getElementById("imageUploadInput");
      const imageUploadBrowseBtn = document.getElementById("imageUploadBrowse");
      const imageUploadClearBtn = document.getElementById("imageUploadClear");
      const imageUploadMetaEl = document.getElementById("imageUploadMeta");
      const imageUploadErrorEl = document.getElementById("imageUploadError");
      const imageUploadListEl = document.getElementById("imageUploadList");

      const viewTabs = document.querySelectorAll(".view-tabs .tab");
      const overviewView = document.getElementById("overviewView");
      const settingsView = document.getElementById("settingsView");

      let session = null;
      let syncingToggle = false;
      let bridgeAvailable = false;
      let authTokenRaw = null;
      let authTokenVisible = false;
      let locationPermissionState = null;
      let bundleIdValue = null;
      let activeTerminalSessionId = null;
      let terminalSessionInfo = null;
      let terminalOutputText = "";
      let terminalNextSeq = 0;
      let terminalPollTimer = null;
      let terminalPollInFlight = false;
      let terminalSessionsById = {};
      const terminalAdvancedExpanded = new Set();
      let terminalAutoScroll = true;
      let terminalNoWrap = false;
      let terminalImeComposing = false;
      let terminalImeLastCompositionEndedAt = 0;
      let terminalRestartRequired = false;
      let terminalRestartPromptDismissed = false;
      let terminalRestartUpdateFingerprint = "";
      let statusPinnedUntil = 0;
      const actionConfirmDeadlines = new Map();
      const TERMINAL_RESTART_REQUIRED_MESSAGE =
        "Terminal compatibility mismatch detected. Restart terminal service to continue.";
      const TERMINAL_RESTART_AVAILABLE_MESSAGE =
        "A newer terminald is bundled with PC agent. Restart terminal service to upgrade.";
      let terminalRestartPromptMessage = TERMINAL_RESTART_AVAILABLE_MESSAGE;
      const TERMINAL_IME_ENTER_GRACE_MS = 120;
      const STATUS_OPERATION_HOLD_MS = 2600;
      const ACTION_CONFIRM_WINDOW_MS = 4200;
      const TERMINAL_ACTION_TIMEOUT_MS = 12000;
      const ANSI_CSI_REGEX = /\u001B\[[0-?]*[ -/]*[@-~]/g;
      const ANSI_OSC_REGEX = /\u001B\][^\u0007\u001B]*(?:\u0007|\u001B\\)/g;
      const ANSI_8BIT_CSI_REGEX = /\u009B[0-?]*[ -/]*[@-~]/g;
      const TERMINAL_CONTROL_REGEX = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g;
      const IMAGE_UPLOAD_MAX_FILES = 8;
      const IMAGE_UPLOAD_MAX_BYTES = 10 * 1024 * 1024;
      const IMAGE_UPLOAD_ALLOWED_MIME = new Set([
        "image/png",
        "image/jpeg",
        "image/webp",
        "image/gif",
      ]);
      const IMAGE_UPLOAD_ALLOWED_EXTENSIONS = new Set([
        "png",
        "jpg",
        "jpeg",
        "webp",
        "gif",
      ]);
      const imageUploads = [];
      let imageUploadDragDepth = 0;
      let imageUploadSeq = 0;

      function sanitizeTerminalText(text) {
        if (!text) return "";
        const value = String(text);
        const stripped = value
          .replace(ANSI_OSC_REGEX, "")
          .replace(ANSI_CSI_REGEX, "")
          .replace(ANSI_8BIT_CSI_REGEX, "");
        const normalized = stripped.replace(/\r\n/g, "\n").replace(/\r/g, "\n");
        return normalized.replace(TERMINAL_CONTROL_REGEX, "");
      }

      function normalizeTerminalStatus(status) {
        if (typeof status !== "string") return "unknown";
        const normalized = status.trim().toLowerCase();
        return normalized || "unknown";
      }

      function isTerminalRunningStatus(status) {
        return normalizeTerminalStatus(status) === "running";
      }

      function updateTerminalOutputMeta() {
        if (!terminalOutputMetaEl) return;
        const chars = terminalOutputText.length;
        const lines = terminalOutputText ? terminalOutputText.split("\n").length : 0;
        terminalOutputMetaEl.textContent = `${chars} chars · ${lines} lines`;
      }

      function applyTerminalOutputOptions() {
        if (!terminalOutputEl) return;
        terminalOutputEl.classList.toggle("nowrap", terminalNoWrap);
      }

      function isTerminalImeComposing(event) {
        if (!event) return false;
        if (event.isComposing) return true;
        if (typeof event.key === "string" && event.key.toLowerCase() === "process") {
          return true;
        }
        if (typeof event.keyCode === "number" && event.keyCode === 229) {
          return true;
        }
        return terminalImeComposing;
      }

      function isTerminalImeCommitEnter(event) {
        if (!event || event.key !== "Enter") return false;
        if (isTerminalImeComposing(event)) return true;
        if (terminalImeLastCompositionEndedAt <= 0) return false;
        return Date.now() - terminalImeLastCompositionEndedAt < TERMINAL_IME_ENTER_GRACE_MS;
      }

      function encodeTerminalInputBytes(value) {
        if (!value) return null;
        if (typeof TextEncoder === "function") {
          return new TextEncoder().encode(value);
        }
        const encoded = unescape(encodeURIComponent(value));
        const bytes = new Uint8Array(encoded.length);
        for (let index = 0; index < encoded.length; index += 1) {
          bytes[index] = encoded.charCodeAt(index);
        }
        return bytes;
      }

      function bytesToBase64(bytes) {
        if (!bytes || !bytes.length) return "";
        const chunk = 0x8000;
        let binary = "";
        for (let index = 0; index < bytes.length; index += chunk) {
          const slice = bytes.subarray(index, Math.min(bytes.length, index + chunk));
          binary += String.fromCharCode(...slice);
        }
        return btoa(binary);
      }

      function formatUploadSize(bytes) {
        const value = Number.isFinite(bytes) ? Math.max(0, bytes) : 0;
        if (value < 1024) return `${value} B`;
        if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
        return `${(value / (1024 * 1024)).toFixed(2)} MB`;
      }

      function extractFileExtension(fileName) {
        if (typeof fileName !== "string") return "";
        const normalized = fileName.trim().toLowerCase();
        if (!normalized.includes(".")) return "";
        const extension = normalized.split(".").pop();
        return extension || "";
      }

      function normalizeUploadName(rawName) {
        if (typeof rawName !== "string") return "image";
        const trimmed = rawName.trim();
        return trimmed || "image";
      }

      function isAcceptedImageFile(file) {
        const mime = typeof file?.type === "string" ? file.type.trim().toLowerCase() : "";
        if (mime && IMAGE_UPLOAD_ALLOWED_MIME.has(mime)) {
          return true;
        }
        const extension = extractFileExtension(file?.name);
        return IMAGE_UPLOAD_ALLOWED_EXTENSIONS.has(extension);
      }

      function validateImageFile(file) {
        if (!(file instanceof File)) {
          return "Unsupported file payload.";
        }
        if (!isAcceptedImageFile(file)) {
          return "Only PNG, JPEG, WEBP, or GIF files are allowed.";
        }
        if (!Number.isFinite(file.size) || file.size <= 0) {
          return "File is empty.";
        }
        if (file.size > IMAGE_UPLOAD_MAX_BYTES) {
          return `Each file must be ${formatUploadSize(IMAGE_UPLOAD_MAX_BYTES)} or smaller.`;
        }
        return null;
      }

      function getImageUploadSignature(file) {
        const name = normalizeUploadName(file?.name).toLowerCase();
        const size = Number.isFinite(file?.size) ? file.size : 0;
        const modified = Number.isFinite(file?.lastModified) ? file.lastModified : 0;
        return `${name}|${size}|${modified}`;
      }

      function hasFilesInDataTransfer(dataTransfer) {
        const types = Array.from(dataTransfer?.types || []);
        return types.includes("Files");
      }

      function setImageUploadDragActive(active) {
        if (!imageUploadDropzoneEl) return;
        imageUploadDropzoneEl.classList.toggle("drag-active", !!active);
      }

      function resetImageUploadDragState() {
        imageUploadDragDepth = 0;
        setImageUploadDragActive(false);
      }

      function setImageUploadError(message) {
        if (!imageUploadErrorEl) return;
        const text = typeof message === "string" ? message.trim() : "";
        if (text) {
          imageUploadErrorEl.textContent = text;
          imageUploadErrorEl.classList.remove("hidden");
        } else {
          imageUploadErrorEl.textContent = "";
          imageUploadErrorEl.classList.add("hidden");
        }
      }

      function releaseImageUploadRecord(record) {
        if (!record?.previewUrl) return;
        if (typeof URL !== "undefined" && typeof URL.revokeObjectURL === "function") {
          URL.revokeObjectURL(record.previewUrl);
        }
      }

      function syncImageUploadInteractivity() {
        const atCapacity = imageUploads.length >= IMAGE_UPLOAD_MAX_FILES;
        const canInteract = bridgeAvailable && !atCapacity;

        if (imageUploadInputEl) {
          imageUploadInputEl.disabled = !canInteract;
        }

        if (imageUploadBrowseBtn) {
          imageUploadBrowseBtn.disabled = !canInteract;
          imageUploadBrowseBtn.classList.toggle("button-disabled", !canInteract);
        }

        if (imageUploadClearBtn) {
          const disableClear = !bridgeAvailable || imageUploads.length === 0;
          imageUploadClearBtn.disabled = disableClear;
          imageUploadClearBtn.classList.toggle("button-disabled", disableClear);
        }

        if (imageUploadDropzoneEl) {
          imageUploadDropzoneEl.classList.toggle("disabled", !canInteract);
          imageUploadDropzoneEl.setAttribute("aria-disabled", String(!canInteract));
        }

        if (imageUploadMetaEl) {
          imageUploadMetaEl.textContent = `${imageUploads.length} / ${IMAGE_UPLOAD_MAX_FILES} selected`;
        }

        if (!canInteract) {
          setImageUploadDragActive(false);
        }
      }

      function notifyImageUploadStateChanged() {
        syncImageUploadInteractivity();
        if (typeof renderImageUploadState === "function") {
          renderImageUploadState();
        }
      }

      function addImageUploadFiles(rawFiles) {
        const files = Array.from(rawFiles || []).filter(Boolean);
        if (files.length === 0) {
          return;
        }

        const slotsLeft = Math.max(0, IMAGE_UPLOAD_MAX_FILES - imageUploads.length);
        if (slotsLeft <= 0) {
          setImageUploadError(`You can upload up to ${IMAGE_UPLOAD_MAX_FILES} images at once.`);
          notifyImageUploadStateChanged();
          return;
        }

        const existingSignatures = new Set(imageUploads.map((item) => item.signature));
        const pendingSignatures = new Set();
        const accepted = [];
        const issues = [];

        for (const file of files) {
          if (accepted.length >= slotsLeft) {
            issues.push(`Only ${slotsLeft} more image${slotsLeft === 1 ? "" : "s"} can be added.`);
            break;
          }

          const validationError = validateImageFile(file);
          if (validationError) {
            issues.push(`${normalizeUploadName(file?.name)}: ${validationError}`);
            continue;
          }

          const signature = getImageUploadSignature(file);
          if (existingSignatures.has(signature) || pendingSignatures.has(signature)) {
            issues.push(`${normalizeUploadName(file.name)} is already selected.`);
            continue;
          }
          pendingSignatures.add(signature);

          const previewUrl =
            typeof URL !== "undefined" && typeof URL.createObjectURL === "function"
              ? URL.createObjectURL(file)
              : "";
          accepted.push({
            id: `upload-${Date.now()}-${++imageUploadSeq}`,
            name: normalizeUploadName(file.name),
            size: Number.isFinite(file.size) ? file.size : 0,
            type: typeof file.type === "string" ? file.type : "",
            signature,
            previewUrl,
            addedAt: Date.now(),
          });
        }

        if (accepted.length > 0) {
          imageUploads.push(...accepted);
          setImageUploadError(issues.length > 0 ? issues[0] : null);
        } else {
          setImageUploadError(issues[0] || "No valid images were selected.");
        }

        notifyImageUploadStateChanged();
      }

      function removeImageUploadById(uploadId) {
        if (!uploadId) return;
        const index = imageUploads.findIndex((item) => item.id === uploadId);
        if (index < 0) return;
        const [removed] = imageUploads.splice(index, 1);
        releaseImageUploadRecord(removed);
        if (imageUploads.length === 0) {
          setImageUploadError(null);
        }
        notifyImageUploadStateChanged();
      }

      function clearImageUploads() {
        imageUploads.splice(0).forEach((record) => {
          releaseImageUploadRecord(record);
        });
        setImageUploadError(null);
        notifyImageUploadStateChanged();
      }

      window.addEventListener("beforeunload", () => {
        imageUploads.forEach((record) => {
          releaseImageUploadRecord(record);
        });
      });

      function ensureInvoke() {
        if (!invoke) {
          invoke = resolveInvoke();
          if (!invoke) {
            setBridgeState(false);
            setStatus("Desktop bridge not available.", "error", { force: true });
            return null;
          }
          setBridgeState(true);
        }
        return invoke;
      }

      function setStatus(message, tone = "ok", options = {}) {
        if (!statusEl) return false;
        const now = Date.now();
        const force = options.force === true;
        const holdMs = Number.isFinite(options.holdMs)
          ? Math.max(0, options.holdMs)
          : 0;
        if (!force && now < statusPinnedUntil) {
          return false;
        }
        statusEl.textContent = message;
        statusEl.classList.toggle("error", tone === "error");
        statusEl.classList.toggle("notice", tone === "notice");
        if (holdMs > 0) {
          statusPinnedUntil = now + holdMs;
        } else if (force) {
          statusPinnedUntil = 0;
        }
        return true;
      }

      function setOperationStatus(message, tone = "notice", holdMs = STATUS_OPERATION_HOLD_MS) {
        setStatus(message, tone, { force: true, holdMs });
        pushToast(message, tone, holdMs);
      }

      function pushToast(message, tone = "notice", holdMs = STATUS_OPERATION_HOLD_MS) {
        if (!toastHostEl || !message) return;
        const toast = document.createElement("div");
        toast.className = `toast ${tone === "error" ? "error" : "notice"}`;
        toast.textContent = message;
        toastHostEl.appendChild(toast);
        requestAnimationFrame(() => {
          toast.classList.add("show");
        });
        const ttl = Number.isFinite(holdMs) ? Math.max(1200, Math.min(holdMs, 7000)) : 2600;
        window.setTimeout(() => {
          toast.classList.remove("show");
          window.setTimeout(() => {
            if (toast.parentElement === toastHostEl) {
              toastHostEl.removeChild(toast);
            }
          }, 220);
        }, ttl);
      }

      function requireActionConfirmation(actionKey, message, holdMs = ACTION_CONFIRM_WINDOW_MS) {
        const now = Date.now();
        const expiresAt = actionConfirmDeadlines.get(actionKey) || 0;
        if (expiresAt > now) {
          actionConfirmDeadlines.delete(actionKey);
          return true;
        }
        actionConfirmDeadlines.set(actionKey, now + holdMs);
        setOperationStatus(message, "notice", holdMs);
        return false;
      }

      const FRIENDLY_ERROR_MESSAGES = {
        invalid_token: "Invalid token. Check the token and try again.",
        invalid_token_length: "Token must be 64 characters.",
        invalid_token_format: "Token must use only letters and numbers.",
        token_expired: "Token expired. Generate a new token.",
        token_mismatch: "Pairing token mismatch. Generate a new token and retry.",
        secret_mismatch: "Pairing token mismatch. Generate a new token and retry.",
        nonce_mismatch: "Pairing token mismatch. Generate a new token and retry.",
        missing_nonce: "Pairing nonce missing. Regenerate QR and retry.",
        unsupported_protocol: "Client protocol unsupported. Please update the app.",
        missing_token: "Pairing token is missing. Generate a new token.",
        approval_pending: "Waiting for desktop approval.",
        requires_approval: "Waiting for desktop approval.",
        approval_timeout: "Approval timed out. Generate a new token and retry.",
        invalid_port: "Port must be between 1 and 65535.",
        listen_port_busy: "Listen port is already in use. Choose another port.",
        roi_quic_port_busy: "ROI QUIC port is already in use. Choose another port.",
        roi_quic_port_unavailable: "ROI QUIC port is unavailable. Choose another port.",
        roi_quic_port_conflict: "ROI QUIC port is already in use. Choose another port.",
        local_server_unavailable: "Desktop agent is offline. Start it and try again.",
        connection_failed: "Unable to reach the desktop agent. Check your connection.",
        http_error: "Desktop agent returned an error response.",
        invalid_payload: "Request payload invalid. Try again.",
        invalid_response: "Desktop agent returned an invalid response.",
        api_request_failed: "API request failed. Check the target endpoint.",
        session_not_found: "Terminal session not found. Refresh sessions and try again.",
        missing_session: "Select a terminal session first.",
        missing_input: "Enter a command before sending.",
        missing_size: "Terminal size was missing. Try again.",
        write_failed: "Failed to send input to the terminal.",
        resize_failed: "Failed to resize the terminal.",
        pty_error: "Terminal backend unavailable. Restart the desktop agent.",
        spawn_error: "Terminal backend unavailable. Restart the desktop agent.",
        version_mismatch: TERMINAL_RESTART_REQUIRED_MESSAGE,
        invalid_name: "Device name cannot be empty.",
        identity_error: "Device update failed. Try again.",
      };

      function normalizeError(error) {
        if (!error) return { message: null, code: null, requestId: null, raw: error };
        if (typeof error === "string") {
          return { message: error, code: null, requestId: null, raw: error };
        }
        const nested = error.error || {};
        const message =
          error.message || nested.message || (typeof nested === "string" ? nested : null);
        const code = error.code || nested.code || null;
        const requestId =
          error.request_id ||
          error.requestId ||
          nested.request_id ||
          nested.requestId ||
          null;
        return { message, code, requestId, raw: error };
      }

      function resolveFriendlyMessage(info, fallback) {
        const code = info.code ? info.code.toString().trim().toLowerCase() : "";
        const friendly = code ? FRIENDLY_ERROR_MESSAGES[code] : null;
        const message = friendly || info.message || fallback;
        return { message, code: code || null };
      }

      function formatStatusText(message, code) {
        if (!message) return code ? `Error (code: ${code})` : "Error";
        if (code) return `${message} (code: ${code})`;
        return message;
      }

      function logErrorDetails(context, info, extra = {}) {
        const payload = {
          context,
          code: info.code || null,
          message: info.message || null,
          requestId: info.requestId || null,
          ...extra,
        };
        console.error("[agent-error]", payload, info.raw);
      }

      function setStatusFromError(fallback, error, context = "status", extra = {}) {
        const info = normalizeError(error);
        const resolved = resolveFriendlyMessage(info, fallback);
        const text = formatStatusText(resolved.message, resolved.code);
        setStatus(text, "error", {
          force: true,
          holdMs: STATUS_OPERATION_HOLD_MS,
        });
        pushToast(text, "error", STATUS_OPERATION_HOLD_MS);
        logErrorDetails(context, info, extra);
        return resolved;
      }

      window.__AGENT_UI__ = window.__AGENT_UI__ || {};
      window.__AGENT_UI__.notify = setOperationStatus;

      async function runButtonAction(button, action, options = {}) {
        if (!button) return;
        if (button.dataset.inFlight === "1" || button.disabled) {
          return;
        }
        const originalText = button.textContent;
        const wasDisabled = button.disabled;
        const busyLabel =
          typeof options.busyLabel === "string" && options.busyLabel.trim().length
            ? options.busyLabel.trim()
            : `${originalText}…`;

        button.dataset.inFlight = "1";
        button.disabled = true;
        button.classList.add("button-disabled");
        if (busyLabel) {
          button.textContent = busyLabel;
        }

        try {
          await action();
        } catch (error) {
          if (typeof options.onError === "function") {
            try {
              await options.onError(error);
            } catch (nestedError) {
              setStatusFromError(
                options.errorMessage || "Action failed.",
                nestedError,
                options.errorContext || "ui_action"
              );
            }
          } else {
            setStatusFromError(
              options.errorMessage || "Action failed.",
              error,
              options.errorContext || "ui_action"
            );
          }
        } finally {
          delete button.dataset.inFlight;
          if (button.isConnected) {
            button.textContent = originalText;
            if (!bridgeAvailable) {
              button.disabled = true;
              button.classList.add("button-disabled");
            } else {
              button.disabled = wasDisabled;
              button.classList.toggle("button-disabled", wasDisabled);
            }
          }
        }
      }

      function parsePortValue(raw) {
        const value = (raw || "").trim();
        if (!/^\d+$/.test(value)) {
          return null;
        }
        const port = Number.parseInt(value, 10);
        if (!Number.isFinite(port) || port < 1 || port > 65535) {
          return null;
        }
        return port;
      }

      function setControlsEnabled(enabled) {
        const controls = [
          generateBtn,
          copyBtn,
          approveBtn,
          denyBtn,
          copyAuthTokenBtn,
          toggleAuthTokenBtn,
          resetAuthTokenBtn,
          generateTokenBtn,
          addTokenBtn,
          saveFrpUrlBtn,
          saveListenPortBtn,
          saveRoiQuicPortBtn,
          requestLocationPermissionBtn,
          openLocationSettingsBtn,
          refreshTerminalSessionsBtn,
          terminalSendBtn,
          terminalStopBtn,
          terminalDeleteBtn,
          terminalRestartNowBtn,
          terminalRestartLaterBtn,
          topRestartTerminalBtn,
          terminalFitBtn,
          terminalResizeBtn,
          imageUploadBrowseBtn,
          imageUploadClearBtn,
        ];
        controls.forEach((btn) => {
          if (!btn) return;
          const shouldEnable = enabled && !(btn === copyBtn && !session);
          btn.disabled = !shouldEnable;
          btn.classList.toggle("button-disabled", !shouldEnable);
        });
        const inputs = [
          customTokenInput,
          customTokenLabelInput,
          frpUrlInput,
          listenPortInput,
          roiQuicPortInput,
          approvalToggle,
          terminalInputEl,
          terminalColsInput,
          terminalRowsInput,
          imageUploadInputEl,
        ];
        inputs.forEach((input) => {
          if (!input) return;
          input.disabled = !enabled;
        });
        syncImageUploadInteractivity();
      }

      function setBridgeState(available) {
        bridgeAvailable = !!available;
        if (!shellEl) return;
        shellEl.classList.toggle("app-disabled", !available);
        bridgeAlertEl?.classList.toggle("hidden", available);
        statusEl?.classList.toggle("hidden", !available);
        if (available) {
          setStatus("Waiting for mobile confirmation.", "ok", { force: true });
        } else {
          setStatus(
            "Desktop bridge not available. Agent controls are disabled.",
            "error",
            { force: true },
          );
        }
        setControlsEnabled(available);
        setTerminalStopEnabled(
          available && isTerminalRunningStatus(terminalSessionInfo?.status)
        );
        syncTerminalRestartPromptVisibility();
      }

      function maskToken(token) {
        if (!token) return "--";
        if (token.length <= 8) return "****";
        return `${token.slice(0, 4)}....${token.slice(-4)}`;
      }

      function setAuthToken(token) {
        authTokenRaw = token || null;
        updateAuthTokenDisplay();
      }

      function updateAuthTokenDisplay() {
        if (!authTokenEl) return;
        if (!authTokenRaw) {
          authTokenEl.textContent = "--";
          if (copyAuthTokenBtn) copyAuthTokenBtn.disabled = true;
          if (toggleAuthTokenBtn) toggleAuthTokenBtn.disabled = true;
          return;
        }
        if (copyAuthTokenBtn) copyAuthTokenBtn.disabled = false;
        if (toggleAuthTokenBtn) toggleAuthTokenBtn.disabled = false;
        if (authTokenVisible) {
          authTokenEl.textContent = authTokenRaw;
          if (toggleAuthTokenBtn) toggleAuthTokenBtn.textContent = "Hide token";
        } else {
          authTokenEl.textContent = maskToken(authTokenRaw);
          if (toggleAuthTokenBtn) toggleAuthTokenBtn.textContent = "Show token";
        }
      }

      async function copyText(text, message) {
        if (!text) return;
        try {
          await navigator.clipboard.writeText(text);
          setOperationStatus(message, "notice");
        } catch (error) {
          setStatusFromError("Clipboard unavailable.", error, "copy_text");
        }
      }

      function formatDateTime(ts) {
        if (!ts) return "--";
        return new Date(ts * 1000).toLocaleString();
      }

      function formatExpiry(expiresAt) {
        if (!expiresAt || expiresAt === 0) return "Active";
        const remaining = expiresAt * 1000 - Date.now();
        if (remaining <= 0) return "Expired";
        const minutes = Math.floor(remaining / 60000);
        const seconds = Math.floor((remaining % 60000) / 1000);
        if (minutes > 0) {
          return `${minutes}m ${seconds}s`;
        }
        return `${seconds}s`;
      }

      function renderSession(data) {
        session = data;
        if (tokenEl) tokenEl.textContent = data.token;
        if (secretEl) secretEl.textContent = data.secret;
        if (payloadEl) payloadEl.textContent = data.qr_payload;
        if (qrEl) {
          qrEl.innerHTML = data.qr_svg;
          qrEl.classList.add("loaded");
        }
        if (qrEmptyEl) qrEmptyEl.classList.remove("active");
        if (copyBtn) {
          copyBtn.disabled = false;
          copyBtn.classList.remove("button-disabled");
        }
        if (expiresEl) expiresEl.textContent = formatExpiry(data.expires_at);
        if (deviceIdEl) deviceIdEl.textContent = data.device_id || "--";
        setAuthToken(data.auth_token);
        renderWifiSsid(data.wifi_ssid);
        renderLocalIps(data.local_ips);
        renderListenPort(data.listen_port);
        updateConnectionMode(data);
      }

      function clearQrDisplay(message) {
        session = null;
        if (qrEl) {
          qrEl.classList.remove("loaded");
          qrEl.innerHTML = "";
        }
        if (qrEmptyEl) qrEmptyEl.classList.add("active");
        if (qrEmptyTitleEl) {
          qrEmptyTitleEl.textContent =
            message && message.toLowerCase().includes("expired")
              ? "QR expired"
              : "No active QR";
        }
        if (qrEmptyMessageEl) {
          qrEmptyMessageEl.textContent =
            message || 'Click "New handshake" to generate a 3-minute QR.';
        }
        if (copyBtn) {
          copyBtn.disabled = true;
          copyBtn.classList.add("button-disabled");
        }
        if (tokenEl) tokenEl.textContent = "--";
        if (secretEl) secretEl.textContent = "--";
        if (expiresEl) expiresEl.textContent = "--";
        if (payloadEl) payloadEl.textContent = "--";
      }

      function renderLocalUrls(urls) {
        if (!localUrlsEl) return;
        localUrlsEl.innerHTML = "";
        if (!urls || urls.length === 0) {
          const fallback = document.createElement("span");
          fallback.className = "url-pill";
          fallback.textContent = "--";
          localUrlsEl.appendChild(fallback);
          return;
        }
        urls.forEach((url) => {
          const pill = document.createElement("span");
          pill.className = "url-pill";
          pill.textContent = url;
          localUrlsEl.appendChild(pill);
        });
      }

      function renderLocalIps(ips) {
        if (!localIpsEl) return;
        localIpsEl.innerHTML = "";
        if (!ips || ips.length === 0) {
          const fallback = document.createElement("span");
          fallback.className = "url-pill";
          fallback.textContent = "--";
          localIpsEl.appendChild(fallback);
          return;
        }
        ips.forEach((ip) => {
          const pill = document.createElement("span");
          pill.className = "url-pill";
          pill.textContent = ip;
          localIpsEl.appendChild(pill);
        });
      }

      function renderWifiSsid(ssid) {
        if (!wifiSsidEl) return;
        wifiSsidEl.textContent = ssid && ssid.trim().length ? ssid : "--";
      }

      function renderLocationPermission(permission) {
        if (!locationAlertEl) return;
        locationPermissionState =
          typeof permission === "string" && permission.trim().length
            ? permission.trim().toLowerCase()
            : null;
        if (locationPermissionEl) {
          locationPermissionEl.textContent = locationPermissionState
            ? formatLocationPermission(locationPermissionState)
            : "--";
        }
        const authorized =
          !locationPermissionState ||
          locationPermissionState === "authorized" ||
          locationPermissionState === "granted";
        if (authorized) {
          locationAlertEl.classList.add("hidden");
          requestLocationPermissionBtn?.classList.add("hidden");
          openLocationSettingsBtn?.classList.add("hidden");
          return;
        }

        locationAlertEl.classList.remove("hidden");
        const metaEl = locationAlertEl.querySelector(".meta");
        if (metaEl) {
          if (locationPermissionState === "disabled") {
            metaEl.textContent = "Location services are disabled. Enable location services first.";
          } else if (locationPermissionState === "restricted") {
            metaEl.textContent = "Location services are restricted. Check system restrictions or parental controls.";
          } else if (locationPermissionState === "not_determined") {
            if (!bundleIdValue) {
              metaEl.textContent =
                "The app was not launched from the .app bundle, so macOS will not show the permission prompt.";
            } else {
              metaEl.textContent = "Click Request permission, then allow location access in the system prompt.";
            }
          } else if (locationPermissionState === "denied") {
            metaEl.textContent =
              "Click Open settings, then allow location access for Vibe Inspect Agent.";
          } else {
            metaEl.textContent = "Check your location permission settings.";
          }
        }

        const shouldShowRequest = locationPermissionState === "not_determined";
        const shouldShowSettings =
          locationPermissionState === "denied" ||
          locationPermissionState === "restricted" ||
          locationPermissionState === "disabled";

        if (requestLocationPermissionBtn) {
          requestLocationPermissionBtn.classList.toggle("hidden", !shouldShowRequest);
          const requestDisabled = !shouldShowRequest || !bundleIdValue || !bridgeAvailable;
          requestLocationPermissionBtn.disabled = requestDisabled;
          requestLocationPermissionBtn.classList.toggle("button-disabled", requestDisabled);
          requestLocationPermissionBtn.title =
            shouldShowRequest && !bundleIdValue
              ? "Not launched from .app bundle, so permission prompt is unavailable."
              : "";
        }

        if (openLocationSettingsBtn) {
          openLocationSettingsBtn.classList.toggle(
            "hidden",
            !(shouldShowSettings || !shouldShowRequest)
          );
          const settingsDisabled = !bridgeAvailable;
          openLocationSettingsBtn.disabled = settingsDisabled;
          openLocationSettingsBtn.classList.toggle("button-disabled", settingsDisabled);
          openLocationSettingsBtn.title = "";
        }
      }

      function formatLocationPermission(permission) {
        switch (permission) {
          case "authorized":
          case "granted":
            return "Authorized";
          case "not_determined":
            return "Not requested";
          case "denied":
            return "Denied";
          case "restricted":
            return "Restricted";
          case "disabled":
            return "Disabled";
          default:
            return permission || "Unknown";
        }
      }

      function renderBundleDiagnostics(data) {
        bundleIdValue = data?.bundle_id || null;
        if (bundleIdEl) {
          bundleIdEl.textContent = bundleIdValue || "--";
        }
        if (bundlePathEl) {
          bundlePathEl.textContent = data?.bundle_path || "--";
        }
        if (locationUsageKeyEl) {
          if (data?.location_usage_key === true) {
            locationUsageKeyEl.textContent = "Configured";
          } else if (data?.location_usage_key === false) {
            locationUsageKeyEl.textContent = "Missing";
          } else {
            locationUsageKeyEl.textContent = "--";
          }
        }
      }

      function renderTunnel(tunnelUrl, tunnelError) {
        if (tunnelUrlEl) tunnelUrlEl.textContent = tunnelUrl || "--";
        if (!tunnelErrorEl) return;
        if (tunnelError) {
          tunnelErrorEl.style.display = "block";
          tunnelErrorEl.textContent = tunnelError;
        } else {
          tunnelErrorEl.style.display = "none";
          tunnelErrorEl.textContent = "";
        }
      }

      function renderFrpUrl(url) {
        if (!frpUrlEl) return;
        frpUrlEl.textContent = url && url.trim().length ? url : "--";
        if (frpUrlInput && document.activeElement !== frpUrlInput) {
          frpUrlInput.value = url || "";
        }
      }

      function renderListenPort(port) {
        if (!listenPortInput) return;
        const value = port ? String(port) : "";
        if (document.activeElement !== listenPortInput) {
          listenPortInput.value = value;
        }
      }

      function renderRoiQuicPort(port) {
        if (!roiQuicPortInput) return;
        const value = port ? String(port) : "";
        if (document.activeElement !== roiQuicPortInput) {
          roiQuicPortInput.value = value;
        }
      }

      function formatTime(ts) {
        if (!ts) return "--";
        return new Date(ts * 1000).toLocaleTimeString();
      }

      function updateConnectionMode(data) {
        let mode = "Offline";
        if (data?.local_urls?.length) {
          mode = "LAN";
        } else if (data?.tunnel_url) {
          mode = "Tunnel";
        }
        if (connectionModeEl) connectionModeEl.textContent = mode;
        if (frpStatusEl) {
          frpStatusEl.textContent = data?.frp_url || "Not configured";
        }
      }

      function updateCounts(data) {
        const paired = data?.paired_devices || [];
        const connected = data?.connected_devices || data?.active_devices || [];
        if (pairedCountEl) pairedCountEl.textContent = paired.length;
        if (activeCountEl) activeCountEl.textContent = connected.length;
        const lastActiveTs =
          connected[0]?.last_seen_at || paired[0]?.last_seen_at || null;
        if (lastActiveEl) lastActiveEl.textContent = formatDateTime(lastActiveTs);
      }

      function buildRequestId() {
        if (crypto?.randomUUID) return crypto.randomUUID();
        return `req-${Date.now()}-${Math.floor(Math.random() * 100000)}`;
      }

      function withTimeout(promise, timeoutMs, code, message) {
        let timer = null;
        return new Promise((resolve, reject) => {
          timer = window.setTimeout(() => {
            const error = new Error(message || "Operation timed out.");
            error.code = code || "timeout";
            reject(error);
          }, timeoutMs);
          Promise.resolve(promise)
            .then(resolve)
            .catch(reject)
            .finally(() => {
              if (timer) {
                window.clearTimeout(timer);
                timer = null;
              }
            });
        });
      }

      async function applyPairingAction(commandName, payload, message) {
        const invokeFn = ensureInvoke();
        if (!invokeFn) return;
        try {
          const response = await invokeFn(commandName, payload);
          if (response) {
            renderStatus(response);
          }
          if (message) setOperationStatus(message, "notice");
        } catch (error) {
          setStatusFromError("Action failed.", error, "pairing_action", {
            command: commandName,
          });
        }
      }

      async function sendTerminalAction(action, sessionId, extra = {}) {
        const invokeFn = ensureInvoke();
        if (!invokeFn) return null;
        const request = {
          request_id: buildRequestId(),
          command: "terminal",
          payload: {
            action,
            session_id: sessionId,
            ...extra,
          },
        };
        try {
          const response = await withTimeout(
            invokeFn("handle_agent_command", { request }),
            TERMINAL_ACTION_TIMEOUT_MS,
            "terminal_action_timeout",
            `Terminal action timed out: ${action}`
          );
          if (response?.status === "error") {
            const info = normalizeError(response?.error);
            const resolved = resolveFriendlyMessage(info, "Terminal action failed.");
            setStatus(formatStatusText(resolved.message, resolved.code), "error", {
              force: true,
              holdMs: STATUS_OPERATION_HOLD_MS,
            });
            logErrorDetails("terminal_action", info, {
              requestId: request.request_id,
              command: "terminal",
              action,
            });
            if (resolved.code === "version_mismatch" && action !== "restart_daemon" && action !== "restart_terminald") {
              showTerminalRestartPrompt(
                resolved.message ||
                  TERMINAL_RESTART_REQUIRED_MESSAGE
              );
              setTerminalDetailStatus(
                "Terminal service update required. Restart when you are ready.",
                "error"
              );
              setTerminalInputEnabled(false);
              setTerminalStopEnabled(false);
              stopTerminalPolling();
            }
            return null;
          }
          if (action === "restart_daemon" || action === "restart_terminald") {
            hideTerminalRestartPrompt({ resolved: true });
          }
          return response?.payload || null;
        } catch (error) {
          if (error?.code === "terminal_action_timeout") {
            const message = `Terminal ${action} request timed out. Please retry.`;
            setOperationStatus(message, "error", 3600);
            setTerminalDetailStatus(message, "error");
            return null;
          }
          const resolved = setStatusFromError("Terminal action failed.", error, "terminal_action", {
            requestId: request.request_id,
            command: "terminal",
          });
          if (
            resolved.code === "version_mismatch" &&
            action !== "restart_daemon" &&
            action !== "restart_terminald"
          ) {
            showTerminalRestartPrompt(
              resolved.message ||
                TERMINAL_RESTART_REQUIRED_MESSAGE
            );
            setTerminalDetailStatus(
              "Terminal service update required. Restart when you are ready.",
              "error"
            );
            setTerminalInputEnabled(false);
            setTerminalStopEnabled(false);
            stopTerminalPolling();
          }
          return null;
        }
      }

      function createActionButton(label, className, onClick) {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = className;
        btn.textContent = label;
        let inFlight = false;
        btn.addEventListener("click", async (event) => {
          if (inFlight || btn.disabled) return;
          inFlight = true;
          const originalText = btn.textContent;
          btn.disabled = true;
          btn.classList.add("button-disabled");
          btn.textContent = `${label}…`;
          try {
            await onClick(event);
          } catch (error) {
            setStatusFromError("Action failed. Please retry.", error, "list_action");
          } finally {
            inFlight = false;
            if (btn.isConnected) {
              btn.disabled = false;
              btn.classList.remove("button-disabled");
              btn.textContent = originalText;
            }
          }
        });
        return btn;
      }

      function createTag(label, className) {
        const tag = document.createElement("span");
        tag.className = className ? `tag ${className}` : "tag";
        tag.textContent = label;
        return tag;
      }

      const DEFAULT_TERMINAL_COLS = 120;
      const DEFAULT_TERMINAL_ROWS = 32;
      const TERMINAL_OUTPUT_LIMIT = 24000;

      function titleCase(value) {
        if (!value) return "";
        return value.charAt(0).toUpperCase() + value.slice(1);
      }

      function renderTerminalHeader() {
        if (!terminalDetailTitleEl || !terminalDetailMetaEl) return;
        if (!terminalSessionInfo) {
          terminalDetailTitleEl.textContent = "Terminal console";
          terminalDetailMetaEl.textContent = "Select a session to stream output.";
          return;
        }
        const label =
          terminalSessionInfo.label || terminalSessionInfo.id || "Terminal console";
        terminalDetailTitleEl.textContent = label;
        const parts = [];
        if (terminalSessionInfo.status) {
          parts.push(titleCase(terminalSessionInfo.status));
        }
        if (terminalSessionInfo.last_activity) {
          parts.push(`last ${formatTime(terminalSessionInfo.last_activity)}`);
        }
        if (terminalSessionInfo.created_at) {
          parts.push(`started ${formatTime(terminalSessionInfo.created_at)}`);
        }
        if (terminalSessionInfo.id) {
          parts.push(`id ${terminalSessionInfo.id}`);
        }
        terminalDetailMetaEl.textContent =
          parts.length > 0 ? parts.join(" · ") : "Terminal session";
      }

      function setTerminalDetailStatus(message, tone = "error") {
        if (!terminalDetailStatusEl) return;
        if (!message) {
          terminalDetailStatusEl.textContent = "";
          terminalDetailStatusEl.classList.add("hidden");
          terminalDetailStatusEl.classList.remove("notice");
          return;
        }
        terminalDetailStatusEl.textContent = message;
        terminalDetailStatusEl.classList.remove("hidden");
        terminalDetailStatusEl.classList.toggle("notice", tone === "notice");
      }

      function syncTerminalRestartPromptVisibility() {
        const visible = terminalRestartRequired && !terminalRestartPromptDismissed;
        if (terminalRestartMessageEl) {
          terminalRestartMessageEl.textContent = terminalRestartPromptMessage;
        }
        if (terminalRestartPromptEl) {
          terminalRestartPromptEl.classList.toggle("hidden", !visible);
        }
        if (topRestartTerminalBtn) {
          const topVisible = bridgeAvailable && visible;
          topRestartTerminalBtn.classList.toggle("hidden", !topVisible);
          topRestartTerminalBtn.classList.toggle("button-disabled", !topVisible);
          topRestartTerminalBtn.disabled = !topVisible;
          if (topVisible) {
            topRestartTerminalBtn.textContent = "Restart terminal";
            topRestartTerminalBtn.title = terminalRestartPromptMessage;
          }
        }
      }

      function showTerminalRestartPrompt(message) {
        terminalRestartRequired = true;
        terminalRestartPromptDismissed = false;
        const text = (message || "").trim();
        if (text) {
          terminalRestartPromptMessage = text;
        }
        syncTerminalRestartPromptVisibility();
      }

      function hideTerminalRestartPrompt(options = {}) {
        if (options.resolved === true) {
          terminalRestartRequired = false;
          terminalRestartPromptDismissed = false;
          terminalRestartUpdateFingerprint = "";
        } else if (options.dismissed === true) {
          terminalRestartPromptDismissed = true;
        }
        syncTerminalRestartPromptVisibility();
      }

      function setTerminalRestartActionBusy(busy) {
        if (terminalRestartNowBtn) {
          terminalRestartNowBtn.disabled = busy;
          terminalRestartNowBtn.classList.toggle("button-disabled", busy);
          terminalRestartNowBtn.textContent = busy ? "Restarting…" : "Restart now";
        }
        if (terminalRestartLaterBtn) {
          terminalRestartLaterBtn.disabled = busy;
          terminalRestartLaterBtn.classList.toggle("button-disabled", busy);
        }
        if (topRestartTerminalBtn) {
          topRestartTerminalBtn.disabled = busy;
          topRestartTerminalBtn.classList.toggle("button-disabled", busy);
          topRestartTerminalBtn.textContent = busy ? "Restarting…" : "Restart terminal";
        }
      }

      async function requestTerminalDaemonRestart() {
        setTerminalRestartActionBusy(true);
        setOperationStatus("Restarting terminal service…", "notice", 3600);
        setTerminalDetailStatus("Restarting terminal service…", "notice");
        const payload = await sendTerminalAction("restart_daemon", null);
        setTerminalRestartActionBusy(false);
        if (!payload) {
          setTerminalDetailStatus(
            "Restart failed. Please retry and check terminald status.",
            "error"
          );
          return;
        }
        await refreshStatus();
        if (terminalRestartRequired) {
          setOperationStatus(
            "Restart command sent, but terminal service is still outdated. Please retry or check terminald process.",
            "error"
          );
          setTerminalDetailStatus(
            "Restart attempted, but old terminal service is still running.",
            "error"
          );
          return;
        }
        hideTerminalRestartPrompt({ resolved: true });
        setOperationStatus("Terminal service restarted. Reopen a session if needed.", "notice");
        setTerminalDetailStatus(
          "Terminal service restarted. You can continue using terminal sessions.",
          "notice"
        );
      }

      function setTerminalInputEnabled(enabled) {
        const writerEnabled = !!enabled;
        if (terminalInputEl) terminalInputEl.disabled = !writerEnabled;
        if (terminalSendBtn) {
          terminalSendBtn.disabled = !writerEnabled;
          terminalSendBtn.classList.toggle("button-disabled", !writerEnabled);
        }
        if (terminalColsInput) terminalColsInput.disabled = !writerEnabled;
        if (terminalRowsInput) terminalRowsInput.disabled = !writerEnabled;
        if (terminalFitBtn) {
          terminalFitBtn.disabled = !writerEnabled;
          terminalFitBtn.classList.toggle("button-disabled", !writerEnabled);
        }
        if (terminalResizeBtn) {
          terminalResizeBtn.disabled = !writerEnabled;
          terminalResizeBtn.classList.toggle("button-disabled", !writerEnabled);
        }
        if (terminalEnterSendsEl) terminalEnterSendsEl.disabled = !writerEnabled;

        if (terminalCopyOutputBtn) {
          terminalCopyOutputBtn.disabled = false;
          terminalCopyOutputBtn.classList.remove("button-disabled");
        }
        if (terminalClearOutputBtn) {
          terminalClearOutputBtn.disabled = false;
          terminalClearOutputBtn.classList.remove("button-disabled");
        }
        if (terminalAutoScrollEl) terminalAutoScrollEl.disabled = false;
        if (terminalNoWrapEl) terminalNoWrapEl.disabled = false;
      }

      function setTerminalStopEnabled(enabled) {
        if (!terminalStopBtn) return;

        const syncDeleteButton = (show, title = "") => {
          if (!terminalDeleteBtn) return;
          terminalDeleteBtn.classList.toggle("hidden", !show);
          terminalDeleteBtn.disabled = !show;
          terminalDeleteBtn.classList.toggle("button-disabled", !show);
          terminalDeleteBtn.title = title;
        };

        if (!bridgeAvailable) {
          terminalStopBtn.disabled = true;
          terminalStopBtn.classList.add("button-disabled");
          terminalStopBtn.title = "Terminal controls are unavailable while desktop bridge is disconnected.";
          syncDeleteButton(false, "Terminal controls are unavailable while desktop bridge is disconnected.");
          return;
        }
        const status = normalizeTerminalStatus(terminalSessionInfo?.status);
        const running = isTerminalRunningStatus(status);
        const hasSession = !!activeTerminalSessionId;
        const activeSession = hasSession
          ? terminalSessionsById[activeTerminalSessionId]
          : null;
        const shouldEnable = !!enabled && !!activeSession && running;
        terminalStopBtn.disabled = !shouldEnable;
        terminalStopBtn.classList.toggle("button-disabled", !shouldEnable);

        const canDeleteSession = !!activeSession && status !== "unknown" && !running;
        syncDeleteButton(
          canDeleteSession,
          canDeleteSession ? "" : "Select an ended terminal session first."
        );

        if (shouldEnable) {
          terminalStopBtn.title = "";
          return;
        }
        if (!hasSession) {
          terminalStopBtn.title = "Select a running terminal session first.";
          return;
        }
        if (!activeSession) {
          terminalStopBtn.title = "Session no longer exists. Refresh sessions.";
          return;
        }
        terminalStopBtn.title =
          status !== "unknown" && status !== "running"
            ? `Session ${status} is already ended.`
            : "Select a running terminal session first.";
      }

      function renderTerminalOutput() {
        if (!terminalOutputEl) return;
        if (!activeTerminalSessionId) {
          terminalOutputEl.textContent = "Select a terminal session to stream output.";
          updateTerminalOutputMeta();
          return;
        }
        terminalOutputEl.textContent =
          terminalOutputText || "Waiting for output...";
        if (terminalAutoScroll) {
          terminalOutputEl.scrollTop = terminalOutputEl.scrollHeight;
        }
        updateTerminalOutputMeta();
      }

      function appendTerminalOutput(text) {
        if (!text) return;
        const sanitized = sanitizeTerminalText(text);
        if (!sanitized) return;
        terminalOutputText += sanitized;
        if (terminalOutputText.length > TERMINAL_OUTPUT_LIMIT) {
          terminalOutputText = terminalOutputText.slice(-TERMINAL_OUTPUT_LIMIT);
        }
        updateTerminalOutputMeta();
      }

      function applyTerminalPayload(payload, options = {}) {
        if (!payload) return;
        if (!terminalSessionInfo) {
          terminalSessionInfo = { id: activeTerminalSessionId };
        }
        if (payload.label && payload.label.trim().length) {
          terminalSessionInfo.label = payload.label.trim();
        }
        if (payload.status !== undefined && payload.status !== null) {
          terminalSessionInfo.status = normalizeTerminalStatus(payload.status);
        }
        if (payload.last_activity) {
          terminalSessionInfo.last_activity = payload.last_activity;
        }
        renderTerminalHeader();
        const hasSnapshot =
          payload.snapshot !== undefined && payload.snapshot !== null;
        if (hasSnapshot && (options.forceReset || payload.truncated)) {
          terminalOutputText = sanitizeTerminalText(payload.snapshot);
        } else if (options.forceReset && !hasSnapshot) {
          terminalOutputText = "";
        }
        const output = Array.isArray(payload.output) ? payload.output : [];
        output.forEach((chunk) => {
          if (chunk?.data) {
            appendTerminalOutput(chunk.data);
          }
        });
        const nextSeq = Number(payload.next_seq);
        if (Number.isFinite(nextSeq)) {
          terminalNextSeq = nextSeq;
        }
        renderTerminalOutput();
        const status = normalizeTerminalStatus(payload.status ?? terminalSessionInfo?.status);
        if (!isTerminalRunningStatus(status)) {
          setTerminalDetailStatus(`Session ${status}. Input disabled.`, "error");
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return;
        }
        setTerminalDetailStatus("");
        setTerminalInputEnabled(true);
        setTerminalStopEnabled(true);
      }

      function stopTerminalPolling() {
        if (terminalPollTimer) {
          clearInterval(terminalPollTimer);
          terminalPollTimer = null;
        }
        terminalPollInFlight = false;
      }

      async function pollTerminalOutput() {
        if (!activeTerminalSessionId || terminalPollInFlight) return;
        terminalPollInFlight = true;
        const since = Math.max(0, Number(terminalNextSeq) - 1);
        const payload = await sendTerminalAction("poll", activeTerminalSessionId, {
          since,
          limit: 200,
        });
        terminalPollInFlight = false;
        if (!payload) {
          setTerminalDetailStatus(
            "Terminal session unavailable. Input disabled.",
            "error"
          );
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return;
        }
        applyTerminalPayload(payload);
      }

      async function fetchTerminalStatus(sessionId) {
        const payload = await sendTerminalAction("status", sessionId);
        if (!payload) {
          setTerminalDetailStatus(
            "Terminal session unavailable. Input disabled.",
            "error"
          );
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return false;
        }
        applyTerminalPayload(payload, { forceReset: true });
        return true;
      }

      function startTerminalPolling() {
        stopTerminalPolling();
        if (!activeTerminalSessionId) return;
        terminalPollTimer = setInterval(pollTerminalOutput, 1000);
      }

      function resetTerminalDetail() {
        activeTerminalSessionId = null;
        terminalSessionInfo = null;
        terminalOutputText = "";
        terminalNextSeq = 0;
        stopTerminalPolling();
        renderTerminalHeader();
        setTerminalDetailStatus("");
        renderTerminalOutput();
        setTerminalInputEnabled(false);
        setTerminalStopEnabled(false);
        if (terminalColsInput) terminalColsInput.value = String(DEFAULT_TERMINAL_COLS);
        if (terminalRowsInput) terminalRowsInput.value = String(DEFAULT_TERMINAL_ROWS);
        updateTerminalOutputMeta();
      }

      async function openTerminalSession(session) {
        if (!session || !session.id) return;
        activeTerminalSessionId = session.id;
        terminalSessionInfo = {
          id: session.id,
          label: session.label || session.id,
          status: normalizeTerminalStatus(session.status),
          created_at: session.created_at,
          last_activity: session.last_activity,
        };
        terminalOutputText = "";
        terminalNextSeq = 0;
        stopTerminalPolling();
        setTerminalInputEnabled(false);
        setTerminalStopEnabled(false);
        renderTerminalHeader();
        setTerminalDetailStatus("Loading session log…", "notice");
        renderTerminalOutput();
        if (terminalColsInput && !terminalColsInput.value) {
          terminalColsInput.value = String(DEFAULT_TERMINAL_COLS);
        }
        if (terminalRowsInput && !terminalRowsInput.value) {
          terminalRowsInput.value = String(DEFAULT_TERMINAL_ROWS);
        }

        const ok = await fetchTerminalStatus(session.id);
        if (!ok) {
          return;
        }

        const isRunning = isTerminalRunningStatus(terminalSessionInfo?.status);
        if (isRunning) {
          setTerminalInputEnabled(true);
          setTerminalStopEnabled(true);
          startTerminalPolling();
          terminalInputEl?.focus();
        } else {
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
        }
      }


      function syncActiveTerminalSession() {
        if (!activeTerminalSessionId) {
          resetTerminalDetail();
          return;
        }
        const session = terminalSessionsById[activeTerminalSessionId];
        if (!session) {
          setTerminalDetailStatus(
            "Session ended or missing. Input disabled.",
            "error"
          );
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return;
        }
        const status = normalizeTerminalStatus(session.status);
        terminalSessionInfo = {
          ...terminalSessionInfo,
          id: session.id,
          label: session.label || session.id,
          status,
          created_at: session.created_at,
          last_activity: session.last_activity,
        };
        renderTerminalHeader();
        if (!isTerminalRunningStatus(status)) {
          setTerminalDetailStatus(`Session ${status}. Input disabled.`, "error");
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return;
        }
        setTerminalDetailStatus("");
        setTerminalInputEnabled(true);
        setTerminalStopEnabled(true);
        if (!terminalPollTimer) {
          startTerminalPolling();
        }
      }

      function computeTerminalGrid() {
        if (!terminalOutputEl) {
          return { cols: DEFAULT_TERMINAL_COLS, rows: DEFAULT_TERMINAL_ROWS };
        }
        const probe = document.createElement("span");
        probe.className = "terminal-measure";
        probe.textContent = "M";
        terminalOutputEl.appendChild(probe);
        const rect = probe.getBoundingClientRect();
        probe.remove();
        const charWidth = rect.width || 8;
        const charHeight = rect.height || 16;
        const styles = getComputedStyle(terminalOutputEl);
        const paddingX =
          parseFloat(styles.paddingLeft) + parseFloat(styles.paddingRight);
        const paddingY =
          parseFloat(styles.paddingTop) + parseFloat(styles.paddingBottom);
        const width = terminalOutputEl.clientWidth - paddingX;
        const height = terminalOutputEl.clientHeight - paddingY;
        const cols = Math.max(20, Math.floor(width / charWidth));
        const rows = Math.max(4, Math.floor(height / charHeight));
        return { cols, rows };
      }
