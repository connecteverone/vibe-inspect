      function renderDeviceList(container, devices, emptyLabel, options = {}) {
        const { showActions = false, activeLabel = false, pairedTag = false } = options;
        container.innerHTML = "";
        if (!devices || devices.length === 0) {
          const item = document.createElement("div");
          item.className = "device-item";
          item.textContent = emptyLabel;
          container.appendChild(item);
          return;
        }
        devices.forEach((device) => {
          const item = document.createElement("div");
          item.className = "device-item";
          if (device.disabled) {
            item.classList.add("disabled");
          }
          if (activeLabel) {
            item.classList.add("connected");
          }
          const header = document.createElement("div");
          header.className = "device-header";
          const title = document.createElement("div");
          title.className = "device-title";
          const rawName = typeof device.name === "string" ? device.name.trim() : "";
          const rawId = typeof device.id === "string" ? device.id.trim() : "";
          const displayName = rawName || "Unknown";
          title.textContent = rawId ? `${displayName} · ${rawId}` : displayName;
          const tags = document.createElement("div");
          tags.className = "device-tags";
          if (activeLabel) {
            const label = typeof activeLabel === "string" ? activeLabel : "active";
            tags.appendChild(createTag(label, "connected"));
          }
          if (pairedTag && device.paired_at) {
            tags.appendChild(createTag("paired", "paired"));
          }
          if (device.disabled) {
            tags.appendChild(createTag("disabled", "disabled"));
          }
          if (device.blocked_until) {
            tags.appendChild(createTag("blocked", "blocked"));
          }
          header.appendChild(title);
          if (tags.childNodes.length > 0) {
            header.appendChild(tags);
          }
          const meta = document.createElement("div");
          meta.className = "device-meta";
          const parts = [];
          if (device.paired_at) {
            parts.push(`paired ${formatTime(device.paired_at)}`);
          }
          if (device.last_seen_at) {
            parts.push(`seen ${formatTime(device.last_seen_at)}`);
          }
          if (device.source) {
            parts.push(device.source);
          }
          if (device.blocked_until) {
            parts.push(`blocked until ${formatTime(device.blocked_until)}`);
          }
          meta.textContent = parts.join(" · ");
          item.appendChild(header);
          if (parts.length > 0) {
            item.appendChild(meta);
          }
          if (showActions) {
            const actions = document.createElement("div");
            actions.className = "device-actions";
            const renameBtn = createActionButton("Rename", "secondary mini", async () => {
              const name = window.prompt("Rename device", device.name || "");
              if (name === null) return;
              const trimmed = name.trim();
              if (!trimmed) {
                setOperationStatus("Device name cannot be empty.", "error");
                return;
              }
              await applyPairingAction(
                "rename_client",
                { client_id: device.id, name: trimmed },
                "Device renamed."
              );
            });
            const toggleBtn = createActionButton(
              device.disabled ? "Enable" : "Disable",
              "secondary mini",
              async () => {
                await applyPairingAction(
                  "set_client_blocked",
                  { client_id: device.id, blocked: !device.disabled },
                  device.disabled ? "Device enabled." : "Device disabled."
                );
              }
            );
            const kickBtn = createActionButton("Kick", "secondary mini", async () => {
              if (
                !requireActionConfirmation(
                  `kick_client_${device.id}`,
                  "Click Kick again within 4s to confirm temporary disconnect."
                )
              ) {
                return;
              }
              await applyPairingAction(
                "kick_client",
                { client_id: device.id },
                "Device kicked."
              );
            });
            const forgetBtn = createActionButton("Forget", "danger mini", async () => {
              if (
                !requireActionConfirmation(
                  `forget_client_${device.id}`,
                  "Click Forget again within 4s to remove this device."
                )
              ) {
                return;
              }
              await applyPairingAction(
                "forget_client",
                { client_id: device.id },
                "Device removed."
              );
            });
            actions.appendChild(renameBtn);
            actions.appendChild(toggleBtn);
            actions.appendChild(kickBtn);
            actions.appendChild(forgetBtn);
            item.appendChild(actions);
          }
          container.appendChild(item);
        });
      }

      function renderTerminalSessions(sessions) {
        if (!terminalSessionsEl) return;
        terminalSessionsEl.innerHTML = "";
        terminalSessionsById = {};
        if (!sessions || sessions.length === 0) {
          terminalAdvancedExpanded.clear();
          const item = document.createElement("div");
          item.className = "device-item";
          item.textContent = "No terminal sessions.";
          terminalSessionsEl.appendChild(item);
          syncActiveTerminalSession();
          return;
        }

        const validSessionIds = new Set();
        sessions.forEach((session) => {
          if (session?.id) {
            validSessionIds.add(session.id);
          }
        });
        Array.from(terminalAdvancedExpanded).forEach((sessionId) => {
          if (!validSessionIds.has(sessionId)) {
            terminalAdvancedExpanded.delete(sessionId);
          }
        });

        sessions.forEach((session) => {
          terminalSessionsById[session.id] = session;
          const statusText =
            typeof session.status === "string" && session.status.trim().length
              ? session.status.trim().toLowerCase()
              : "unknown";
          const isRunning = statusText === "running";

          const item = document.createElement("div");
          item.className = "device-item";
          if (session.id === activeTerminalSessionId) {
            item.classList.add("active");
          }

          const header = document.createElement("div");
          header.className = "device-header";
          const title = document.createElement("div");
          title.className = "device-title";
          const rawLabel = typeof session.label === "string" ? session.label.trim() : "";
          const displayLabel = rawLabel || session.id;
          title.textContent = displayLabel;

          const tags = document.createElement("div");
          tags.className = "device-tags";
          tags.appendChild(createTag(statusText, isRunning ? "connected" : "disabled"));
          header.appendChild(title);
          header.appendChild(tags);
          item.appendChild(header);

          const meta = document.createElement("div");
          meta.className = "device-meta";
          const metaParts = [
            `started ${formatTime(session.created_at)}`,
            `last ${formatTime(session.last_activity)}`,
          ];
          if (Number.isFinite(session.exit_code)) {
            metaParts.push(`exit ${session.exit_code}`);
          }
          if (typeof session.closed_reason === "string" && session.closed_reason.trim().length) {
            metaParts.push(session.closed_reason.trim());
          }
          if (rawLabel && session.id) {
            metaParts.push(`id ${session.id}`);
          }
          meta.textContent = metaParts.join(" · ");
          item.appendChild(meta);

          if (session.last_output) {
            const preview = document.createElement("div");
            preview.className = "device-preview";
            preview.textContent = session.last_output;
            item.appendChild(preview);
          }

          const primaryActions = document.createElement("div");
          primaryActions.className = "device-actions terminal-main-actions";
          const advancedActions = document.createElement("div");
          const isAdvancedExpanded = terminalAdvancedExpanded.has(session.id);
          advancedActions.className =
            `device-actions terminal-advanced-actions${isAdvancedExpanded ? "" : " hidden"}`;
          let hasAdvancedActions = false;

          const isActive = session.id === activeTerminalSessionId;
          const openBtn = createActionButton(
            isActive ? "Viewing" : isRunning ? "Open" : "View log",
            isActive ? "secondary mini" : "primary mini",
            async () => {
              if (!isActive) {
                await openTerminalSession(session);
              }
            }
          );
          if (isActive) {
            openBtn.disabled = true;
            openBtn.classList.add("button-disabled");
          }

          const renameBtn = createActionButton("Rename", "secondary mini", async () => {
            const name = window.prompt("Rename terminal session", displayLabel);
            if (name === null) return;
            const trimmed = name.trim();
            if (!trimmed) {
              setOperationStatus("Session name cannot be empty.", "error");
              return;
            }
            if (trimmed.length > 80) {
              setOperationStatus("Session name must be 80 characters or fewer.", "error");
              return;
            }
            const payload = await sendTerminalAction("rename", session.id, {
              label: trimmed,
            });
            if (payload) {
              await refreshStatus();
              setOperationStatus("Terminal session renamed.", "notice");
            }
          });

          primaryActions.appendChild(openBtn);
          primaryActions.appendChild(renameBtn);

          if (isRunning) {
            const keepaliveBtn = createActionButton("Keep alive", "secondary mini", async () => {
              const payload = await sendTerminalAction("keepalive", session.id);
              if (!payload) {
                setOperationStatus("Failed to send keepalive. Check terminal status.", "error");
                return;
              }
              await refreshStatus();
              setOperationStatus("Terminal keepalive sent.", "notice");
            });

            const pollBtn = createActionButton("Poll output", "secondary mini", async () => {
              const payload = await sendTerminalAction("poll", session.id, {
                limit: 20,
              });
              if (!payload) {
                setOperationStatus("Failed to poll terminal output. Check terminal status.", "error");
                return;
              }
              const output = payload?.output || [];
              let text = "";
              if (output.length > 0) {
                const last = output[output.length - 1];
                text = (last?.data || "").trim();
              }
              if (!text && typeof payload?.snapshot === "string") {
                const snapshot = payload.snapshot.trim();
                if (snapshot) {
                  const lines = snapshot.split("\n").filter((line) => line.trim().length > 0);
                  const candidate = lines.length > 0 ? lines[lines.length - 1] : snapshot;
                  text = candidate.length > 220 ? candidate.slice(candidate.length - 220) : candidate;
                }
              }
              if (text) {
                const preview =
                  item.querySelector(".device-preview") || document.createElement("div");
                preview.className = "device-preview";
                preview.textContent = text;
                if (!item.contains(preview)) item.appendChild(preview);
              }
              await refreshStatus();
            });

            const stopBtn = createActionButton("Disconnect", "danger mini", async () => {
              const payload = await sendTerminalAction("stop", session.id);
              if (!payload) {
                setOperationStatus("Failed to disconnect terminal session.", "error");
                return;
              }
              if (activeTerminalSessionId === session.id) {
                resetTerminalDetail();
              }
              await refreshStatus();
              setOperationStatus("Terminal session disconnected.", "notice");
            });

            advancedActions.appendChild(keepaliveBtn);
            advancedActions.appendChild(pollBtn);
            advancedActions.appendChild(stopBtn);
            hasAdvancedActions = true;
          } else {
            const deleteBtn = createActionButton("Delete", "danger mini", async () => {
              if (
                !requireActionConfirmation(
                  `delete_terminal_${session.id}`,
                  "Click Delete again within 4s to remove this terminal session."
                )
              ) {
                return;
              }
              const payload = await sendTerminalAction("delete", session.id);
              if (!payload) {
                setOperationStatus("Failed to delete terminal session.", "error");
                return;
              }
              if (activeTerminalSessionId === session.id) {
                resetTerminalDetail();
              }
              await refreshStatus();
              setOperationStatus("Terminal session deleted.", "notice");
            });
            advancedActions.appendChild(deleteBtn);
            hasAdvancedActions = true;
          }

          if (hasAdvancedActions) {
            const toggleBtn = document.createElement("button");
            toggleBtn.type = "button";
            toggleBtn.className = "secondary mini";
            toggleBtn.textContent = isAdvancedExpanded ? "Less" : "More";
            toggleBtn.setAttribute("aria-expanded", String(isAdvancedExpanded));
            toggleBtn.addEventListener("click", () => {
              const expanded = !advancedActions.classList.contains("hidden");
              advancedActions.classList.toggle("hidden", expanded);
              const nextExpanded = !expanded;
              if (nextExpanded) {
                terminalAdvancedExpanded.add(session.id);
              } else {
                terminalAdvancedExpanded.delete(session.id);
              }
              toggleBtn.textContent = nextExpanded ? "Less" : "More";
              toggleBtn.setAttribute("aria-expanded", String(nextExpanded));
            });
            primaryActions.appendChild(toggleBtn);
          }

          item.appendChild(primaryActions);
          if (hasAdvancedActions) {
            item.appendChild(advancedActions);
          }
          terminalSessionsEl.appendChild(item);
        });
        syncActiveTerminalSession();
      }


      async function sendActiveTerminalInput() {
        const sessionId = activeTerminalSessionId;
        if (!sessionId) {
          setTerminalDetailStatus("Select a session to send input.", "error");
          return;
        }
        const rawValue = terminalInputEl?.value ?? "";
        const value = rawValue.endsWith("\n") ? rawValue : `${rawValue}\n`;
        if (!value.trim()) return;
        const status = normalizeTerminalStatus(terminalSessionInfo?.status);
        if (!isTerminalRunningStatus(status)) {
          setTerminalDetailStatus(
            `Session ${status}. Input disabled.`,
            "error"
          );
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return;
        }
        const bytes = encodeTerminalInputBytes(value);
        if (!bytes || !bytes.length) return;
        const payload = await sendTerminalAction("input", sessionId, {
          input_b64: bytesToBase64(bytes),
        });
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
        if (terminalInputEl) terminalInputEl.value = "";
        applyTerminalPayload(payload);
        await pollTerminalOutput();
        terminalInputEl?.focus();
      }

      async function sendActiveTerminalResize() {
        const sessionId = activeTerminalSessionId;
        if (!sessionId) {
          setTerminalDetailStatus("Select a session to resize.", "error");
          return;
        }
        const status = normalizeTerminalStatus(terminalSessionInfo?.status);
        if (!isTerminalRunningStatus(status)) {
          setTerminalDetailStatus(`Session ${status}. Resize unavailable.`, "error");
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return;
        }
        const cols = Number.parseInt(terminalColsInput?.value ?? "", 10);
        const rows = Number.parseInt(terminalRowsInput?.value ?? "", 10);
        if (!Number.isFinite(cols) || cols < 10 || cols > 400) {
          setTerminalDetailStatus("Cols must be between 10 and 400.", "error");
          return;
        }
        if (!Number.isFinite(rows) || rows < 4 || rows > 200) {
          setTerminalDetailStatus("Rows must be between 4 and 200.", "error");
          return;
        }
        const payload = await sendTerminalAction("resize", sessionId, { cols, rows });
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
        setTerminalDetailStatus("Terminal resized.", "notice");
      }

      async function stopActiveTerminalSession() {
        const sessionId = activeTerminalSessionId;
        if (!sessionId) {
          setTerminalDetailStatus("Select a session to disconnect.", "error");
          setOperationStatus("Select a terminal session first.", "error");
          return;
        }
        const status = normalizeTerminalStatus(terminalSessionInfo?.status);
        if (!isTerminalRunningStatus(status)) {
          setTerminalDetailStatus(`Session ${status} is already ended.`, "notice");
          setTerminalStopEnabled(false);
          setTerminalInputEnabled(false);
          stopTerminalPolling();
          return;
        }
        setTerminalDetailStatus("Disconnecting terminal session…", "notice");
        const payload = await sendTerminalAction("stop", sessionId);
        if (!payload) {
          setTerminalDetailStatus("Failed to disconnect terminal session.", "error");
          return;
        }
        applyTerminalPayload(payload, { forceReset: true });
        await refreshStatus();
        setTerminalDetailStatus("Terminal session disconnected.", "notice");
        setOperationStatus("Terminal session disconnected.", "notice");
      }

      async function deleteActiveTerminalSession() {
        const sessionId = activeTerminalSessionId;
        if (!sessionId) {
          setTerminalDetailStatus("Select a session to delete.", "error");
          setOperationStatus("Select a terminal session first.", "error");
          return;
        }

        const status = normalizeTerminalStatus(terminalSessionInfo?.status);
        if (isTerminalRunningStatus(status)) {
          setTerminalDetailStatus("Disconnect the running session before deleting it.", "notice");
          return;
        }

        if (
          !requireActionConfirmation(
            `delete_terminal_active_${sessionId}`,
            "Click Delete again within 4s to remove this terminal session."
          )
        ) {
          return;
        }

        setTerminalDetailStatus("Deleting terminal session…", "notice");
        const payload = await sendTerminalAction("delete", sessionId);
        if (!payload) {
          setTerminalDetailStatus("Failed to delete terminal session.", "error");
          return;
        }

        resetTerminalDetail();
        await refreshStatus();
        setOperationStatus("Terminal session deleted.", "notice");
      }

      async function fitTerminalToPanel() {
        const grid = computeTerminalGrid();
        if (terminalColsInput) terminalColsInput.value = String(grid.cols);
        if (terminalRowsInput) terminalRowsInput.value = String(grid.rows);
        await sendActiveTerminalResize();
      }

      function renderTokenList(tokens) {
        if (!tokenListEl) return;
        tokenListEl.innerHTML = "";
        if (!tokens || tokens.length === 0) {
          const item = document.createElement("div");
          item.className = "device-item";
          item.textContent = "No tokens yet.";
          tokenListEl.appendChild(item);
          return;
        }
        tokens.forEach((record) => {
          const item = document.createElement("div");
          item.className = "device-item";
          if (record.revoked_at) item.classList.add("disabled");
          const header = document.createElement("div");
          header.className = "device-header";
          const title = document.createElement("div");
          title.className = "device-title";
          title.textContent = record.label || "Access token";
          const tags = document.createElement("div");
          tags.className = "device-tags";
          if (record.is_primary) {
            tags.appendChild(createTag("primary", "paired"));
          }
          if (record.client_id) {
            tags.appendChild(createTag("bound", "connected"));
          }
          if (record.revoked_at) {
            tags.appendChild(createTag("revoked", "disabled"));
          }
          header.appendChild(title);
          if (tags.childNodes.length > 0) {
            header.appendChild(tags);
          }
          item.appendChild(header);
          const meta = document.createElement("div");
          meta.className = "device-meta";
          const parts = [
            `token ${maskToken(record.token)}`,
            `created ${formatDateTime(record.created_at)}`,
          ];
          if (record.client_id) {
            parts.push(`device ${record.client_id}`);
          }
          if (record.revoked_at) {
            parts.push(`revoked ${formatDateTime(record.revoked_at)}`);
          }
          meta.textContent = parts.join(" · ");
          item.appendChild(meta);
          const actions = document.createElement("div");
          actions.className = "device-actions";
          const copyBtn = createActionButton("Copy", "secondary mini", async () => {
            await copyText(record.token, "Token copied.");
          });
          actions.appendChild(copyBtn);
          if (!record.revoked_at) {
            const primaryBtn = createActionButton(
              record.is_primary ? "Primary" : "Set primary",
              "secondary mini",
              async () => {
                if (record.is_primary) return;
                await applyPairingAction(
                  "set_primary_auth_token",
                  { token: record.token, label: record.label },
                  "Primary token updated."
                );
              }
            );
            actions.appendChild(primaryBtn);
            const revokeBtn = createActionButton("Revoke", "danger mini", async () => {
              if (
                !requireActionConfirmation(
                  `revoke_token_${record.token}`,
                  "Click Revoke again within 4s to confirm token revoke."
                )
              ) {
                return;
              }
              await applyPairingAction(
                "revoke_auth_token",
                { token: record.token },
                "Token revoked."
              );
            });
            actions.appendChild(revokeBtn);
          }
          item.appendChild(actions);
          tokenListEl.appendChild(item);
        });
      }

      function renderImageUploadState() {
        if (!imageUploadListEl) return;
        imageUploadListEl.innerHTML = "";

        if (!imageUploads || imageUploads.length === 0) {
          const empty = document.createElement("div");
          empty.className = "device-item";
          empty.textContent = "No images selected.";
          imageUploadListEl.appendChild(empty);
          return;
        }

        imageUploads.forEach((record) => {
          const item = document.createElement("div");
          item.className = "upload-item";

          const thumb = document.createElement("div");
          thumb.className = "upload-thumb";
          if (record.previewUrl) {
            const img = document.createElement("img");
            img.src = record.previewUrl;
            img.alt = record.name || "Uploaded image";
            img.loading = "lazy";
            thumb.appendChild(img);
          } else {
            thumb.classList.add("placeholder");
            thumb.textContent = "Image";
          }

          const meta = document.createElement("div");
          meta.className = "upload-item-meta";
          const name = document.createElement("div");
          name.className = "upload-item-name";
          name.textContent = record.name || "image";
          name.title = name.textContent;

          const detail = document.createElement("div");
          detail.className = "upload-item-detail";
          const mime = record.type && record.type.trim().length ? record.type : "image";
          detail.textContent = `${formatUploadSize(record.size)} · ${mime}`;

          meta.appendChild(name);
          meta.appendChild(detail);

          const removeBtn = document.createElement("button");
          removeBtn.type = "button";
          removeBtn.className = "danger mini";
          removeBtn.textContent = "Remove";
          removeBtn.addEventListener("click", () => {
            removeImageUploadById(record.id);
          });

          item.appendChild(thumb);
          item.appendChild(meta);
          item.appendChild(removeBtn);

          imageUploadListEl.appendChild(item);
        });
      }

      function renderPending(pending) {
        if (pending) {
          approvalCard.classList.remove("hidden");
          const when = new Date(pending.requested_at * 1000).toLocaleTimeString();
          const source = pending.source ? ` from ${pending.source}` : "";
          const name = pending.client_name ? ` (${pending.client_name})` : "";
          const expiry = pending.expires_at ? formatExpiry(pending.expires_at) : null;
          const expiryText = expiry ? ` Approval window: ${expiry}.` : "";
          pendingMetaEl.textContent = `Token ${pending.token}${name} requested ${when}${source}.${expiryText}`;
        } else {
          approvalCard.classList.add("hidden");
          pendingMetaEl.textContent = "No pending requests.";
        }
      }

      function applyTerminalStatusError(data) {
        const code = data?.terminal_error_code
          ? String(data.terminal_error_code).trim().toLowerCase()
          : "";
        const message =
          typeof data?.terminal_error_message === "string" &&
          data.terminal_error_message.trim().length > 0
            ? data.terminal_error_message.trim()
            : null;
        const updateAvailableRaw = data?.terminal_update_available;
        const updateAvailable =
          updateAvailableRaw === true ||
          updateAvailableRaw === 1 ||
          (typeof updateAvailableRaw === "string" &&
            updateAvailableRaw.trim().toLowerCase() === "true");
        const updateMessage =
          typeof data?.terminal_update_message === "string" &&
          data.terminal_update_message.trim().length > 0
            ? data.terminal_update_message.trim()
            : null;
        const hasUpdateSignal = updateAvailable || !!updateMessage;
        const runningVersion =
          typeof data?.terminal_running_version === "string" &&
          data.terminal_running_version.trim().length > 0
            ? data.terminal_running_version.trim()
            : null;
        const bundledVersion =
          typeof data?.terminal_bundled_version === "string" &&
          data.terminal_bundled_version.trim().length > 0
            ? data.terminal_bundled_version.trim()
            : null;

        if (code === "version_mismatch") {
          terminalRestartRequired = true;
          terminalRestartPromptDismissed = false;
          if (message) {
            terminalRestartPromptMessage = message;
          }
          syncTerminalRestartPromptVisibility();
          setTerminalDetailStatus(
            "Terminal service update required. Restart terminal service to continue.",
            "error"
          );
          setTerminalInputEnabled(false);
          setTerminalStopEnabled(false);
          stopTerminalPolling();
          return;
        }

        if (hasUpdateSignal) {
          const restartMessage =
            updateMessage || TERMINAL_RESTART_AVAILABLE_MESSAGE;
          const updateFingerprint = [
            restartMessage,
            runningVersion || "",
            bundledVersion || "",
          ].join("|");
          const updateSignalChanged =
            updateFingerprint !== terminalRestartUpdateFingerprint;
          if (!terminalRestartRequired || updateSignalChanged) {
            terminalRestartPromptDismissed = false;
          }
          terminalRestartUpdateFingerprint = updateFingerprint;
          terminalRestartRequired = true;
          terminalRestartPromptMessage = restartMessage;
          syncTerminalRestartPromptVisibility();
          setStatus(
            restartMessage,
            "notice",
            { force: true }
          );
          if (bundledVersion && runningVersion) {
            setTerminalDetailStatus(
              `Bundled terminald ${bundledVersion} is newer than running ${runningVersion}. Restart when convenient.`,
              "notice"
            );
          } else {
            setTerminalDetailStatus(
              "A newer bundled terminald is available. Restart terminal service when convenient.",
              "notice"
            );
          }
          return;
        }

        if (terminalRestartRequired) {
          hideTerminalRestartPrompt({ resolved: true });
        } else {
          syncTerminalRestartPromptVisibility();
        }
      }

      function renderStatus(data) {
        if (data.session) {
          if (tokenEl) tokenEl.textContent = data.session.token;
          if (secretEl) secretEl.textContent = data.session.secret;
          if (expiresEl) expiresEl.textContent = formatExpiry(data.session.expires_at);
          if (data.session.expires_at && data.session.expires_at * 1000 <= Date.now()) {
            clearQrDisplay('QR expired. Click "New handshake" to generate a new one.');
          }
        }
        if (data.device_id && deviceIdEl) {
          deviceIdEl.textContent = data.device_id;
        }
        if (data.auth_token) {
          setAuthToken(data.auth_token);
        }
        renderWifiSsid(data.wifi_ssid);
        renderBundleDiagnostics(data);
        renderLocationPermission(data.location_permission);
        renderLocalIps(data.local_ips);
        if (data.connected_at) {
          setStatus("Paired and connected.");
        } else if (data.pending) {
          setStatus("Awaiting desktop approval.", "notice");
        } else {
          setStatus("Waiting for mobile confirmation.");
        }
        syncingToggle = true;
        approvalToggle.checked = !!data.requires_approval;
        syncingToggle = false;
        renderLocalUrls(data.local_urls);
        renderTunnel(data.tunnel_url, data.tunnel_error);
        renderFrpUrl(data.frp_url);
        renderListenPort(data.listen_port);
        renderRoiQuicPort(data.roi_quic_port);
        renderPending(data.pending);
        updateConnectionMode(data);
        updateCounts(data);
        renderDeviceList(pairedDevicesEl, data.paired_devices, "No paired devices.", {
          showActions: true,
          pairedTag: true,
        });
        const connectedDevices = data.connected_devices || data.active_devices || [];
        renderDeviceList(activeDevicesEl, connectedDevices, "No connected devices.", {
          activeLabel: "Connected",
        });
        renderTerminalSessions(data.terminal_sessions);
        applyTerminalStatusError(data);
        renderTokenList(data.auth_tokens);
      }
