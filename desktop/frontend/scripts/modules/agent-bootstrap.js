      async function refreshStatus(options = {}) {
        const silent = options.silent === true;
        const invokeFn = ensureInvoke();
        if (!invokeFn) return;
        try {
          const status = await invokeFn("get_pairing_status");
          renderStatus(status);
        } catch (error) {
          if (silent) {
            const info = normalizeError(error);
            logErrorDetails("refresh_status", info, { silent: true });
          } else {
            setStatusFromError("Failed to refresh desktop status.", error, "refresh_status");
          }
        }
      }

      async function createSession() {
        const invokeFn = ensureInvoke();
        if (!invokeFn) return;
        setOperationStatus("Generating pairing token...", "notice", 3200);
        const data = await invokeFn("create_pairing_session");
        renderSession(data);
        renderLocalUrls(data.local_urls || []);
        renderLocalIps(data.local_ips || []);
        renderTunnel(data.tunnel_url, data.tunnel_error);
        renderFrpUrl(data.frp_url);
        setOperationStatus("Waiting for mobile confirmation.", "notice");
      }

      function bindPairingActions() {
        if (copyBtn) {
          copyBtn.addEventListener("click", async () => {
            if (!session) return;
            await copyText(session.qr_payload, "QR payload copied to clipboard.");
          });
        }

        if (generateBtn) {
          generateBtn.addEventListener("click", () =>
            runButtonAction(generateBtn, createSession, {
              busyLabel: "Generating…",
              errorMessage: "Failed to generate pairing token.",
              errorContext: "create_pairing_session",
            })
          );
        }
      }

      function bindIdentityActions() {
        if (copyAuthTokenBtn) {
          copyAuthTokenBtn.addEventListener("click", async () => {
            await copyText(authTokenRaw, "Login token copied.");
          });
        }

        if (toggleAuthTokenBtn) {
          toggleAuthTokenBtn.addEventListener("click", () => {
            authTokenVisible = !authTokenVisible;
            updateAuthTokenDisplay();
          });
        }

        if (copyDeviceIdBtn) {
          copyDeviceIdBtn.addEventListener("click", async () => {
            await copyText(deviceIdEl.textContent, "Device ID copied.");
          });
        }

        if (resetAuthTokenBtn) {
          resetAuthTokenBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            if (
              !requireActionConfirmation(
                "reset_auth_token",
                "Click Rotate again within 4s to confirm login token reset."
              )
            ) {
              return;
            }
            await runButtonAction(
              resetAuthTokenBtn,
              async () => {
                const response = await invokeFn("reset_auth_token");
                if (response?.device_id && deviceIdEl) {
                  deviceIdEl.textContent = response.device_id;
                }
                setAuthToken(response?.auth_token);
                await refreshStatus();
                setOperationStatus("Login token rotated.", "notice");
              },
              {
                busyLabel: "Rotating…",
                errorMessage: "Failed to reset login token.",
                errorContext: "reset_auth_token",
              }
            );
          });
        }
      }

      function bindTokenActions() {
        if (generateTokenBtn) {
          generateTokenBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            await runButtonAction(
              generateTokenBtn,
              async () => {
                await invokeFn("create_auth_token", { label: "Manual token" });
                await refreshStatus();
                setOperationStatus("Token generated.", "notice");
              },
              {
                busyLabel: "Generating…",
                errorMessage: "Failed to generate token.",
                errorContext: "create_auth_token",
              }
            );
          });
        }

        if (addTokenBtn) {
          addTokenBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            const token = customTokenInput?.value?.trim() || "";
            const label = customTokenLabelInput?.value?.trim() || undefined;
            if (!token) {
              setOperationStatus("Token cannot be empty.", "error");
              return;
            }
            if (token.length !== 64) {
              setOperationStatus("Token must be 64 characters.", "error");
              return;
            }
            await runButtonAction(
              addTokenBtn,
              async () => {
                await invokeFn("add_auth_token", { token, label });
                if (customTokenInput) customTokenInput.value = "";
                if (customTokenLabelInput) customTokenLabelInput.value = "";
                await refreshStatus();
                setOperationStatus("Token added.", "notice");
              },
              {
                busyLabel: "Adding…",
                errorMessage: "Failed to add token.",
                errorContext: "add_auth_token",
              }
            );
          });
        }
      }

      function bindSettingsActions() {
        if (openLocationSettingsBtn) {
          openLocationSettingsBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            await runButtonAction(
              openLocationSettingsBtn,
              async () => {
                await invokeFn("open_location_settings");
                locationSettingsOpened = true;
                setOperationStatus("Location settings opened.", "notice");
              },
              {
                busyLabel: "Opening…",
                errorMessage: "Failed to open location settings.",
                errorContext: "open_location_settings",
              }
            );
          });
        }

        if (saveFrpUrlBtn) {
          saveFrpUrlBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            const url = frpUrlInput?.value?.trim() || "";
            await runButtonAction(
              saveFrpUrlBtn,
              async () => {
                const status = await invokeFn("set_frp_url", { url });
                renderStatus(status);
                setOperationStatus("FRP URL updated.", "notice");
              },
              {
                busyLabel: "Saving…",
                errorMessage: "Failed to update FRP URL.",
                errorContext: "set_frp_url",
                onError: async (error) => {
                  setStatusFromError("Failed to update FRP URL.", error, "set_frp_url");
                  await refreshStatus({ silent: true });
                },
              }
            );
          });
        }

        if (saveListenPortBtn) {
          saveListenPortBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            const port = parsePortValue(listenPortInput?.value);
            if (port == null) {
              setOperationStatus("Port must be between 1 and 65535.", "error");
              return;
            }
            await runButtonAction(
              saveListenPortBtn,
              async () => {
                const status = await invokeFn("set_listen_port", { port });
                renderStatus(status);
                setOperationStatus("Listen port updated.", "notice");
              },
              {
                busyLabel: "Saving…",
                errorMessage: "Failed to update listen port.",
                errorContext: "set_listen_port",
                onError: async (error) => {
                  setStatusFromError("Failed to update listen port.", error, "set_listen_port");
                  await refreshStatus({ silent: true });
                },
              }
            );
          });
        }

        if (saveRoiQuicPortBtn) {
          saveRoiQuicPortBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            const port = parsePortValue(roiQuicPortInput?.value);
            if (port == null) {
              setOperationStatus("Port must be between 1 and 65535.", "error");
              return;
            }
            await runButtonAction(
              saveRoiQuicPortBtn,
              async () => {
                const status = await invokeFn("set_roi_quic_port", { port });
                renderStatus(status);
                setOperationStatus("ROI QUIC port updated.", "notice");
              },
              {
                busyLabel: "Saving…",
                errorMessage: "Failed to update ROI QUIC port.",
                errorContext: "set_roi_quic_port",
                onError: async (error) => {
                  setStatusFromError(
                    "Failed to update ROI QUIC port.",
                    error,
                    "set_roi_quic_port"
                  );
                  await refreshStatus({ silent: true });
                },
              }
            );
          });
        }
      }

      function bindTerminalInputActions() {
        if (terminalSendBtn) {
          terminalSendBtn.addEventListener("click", sendActiveTerminalInput);
        }

        if (!terminalInputEl) return;

        terminalInputEl.addEventListener("compositionstart", () => {
          terminalImeComposing = true;
        });
        terminalInputEl.addEventListener("compositionupdate", () => {
          terminalImeComposing = true;
        });
        terminalInputEl.addEventListener("compositionend", () => {
          terminalImeComposing = false;
          terminalImeLastCompositionEndedAt = Date.now();
        });
        terminalInputEl.addEventListener("blur", () => {
          terminalImeComposing = false;
          terminalImeLastCompositionEndedAt = 0;
        });
        terminalInputEl.addEventListener("keydown", (event) => {
          if (isTerminalImeCommitEnter(event)) {
            return;
          }
          const enterSends = terminalEnterSendsEl?.checked !== false;
          if (event.key === "Enter" && enterSends && !event.shiftKey) {
            event.preventDefault();
            sendActiveTerminalInput();
          }
        });
      }

      function bindTerminalUtilityActions() {
        if (terminalEnterSendsEl) {
          terminalEnterSendsEl.checked = true;
        }

        if (terminalAutoScrollEl) {
          terminalAutoScrollEl.checked = true;
          terminalAutoScrollEl.addEventListener("change", () => {
            terminalAutoScroll = terminalAutoScrollEl.checked;
            if (terminalAutoScroll) {
              renderTerminalOutput();
            }
          });
        }

        if (terminalNoWrapEl) {
          terminalNoWrapEl.checked = false;
          terminalNoWrapEl.addEventListener("change", () => {
            terminalNoWrap = terminalNoWrapEl.checked;
            applyTerminalOutputOptions();
            renderTerminalOutput();
          });
        }

        if (terminalCopyOutputBtn) {
          terminalCopyOutputBtn.addEventListener("click", async () => {
            const text = terminalOutputText || "";
            if (!text.trim()) {
              setTerminalDetailStatus("No terminal output to copy.", "notice");
              return;
            }
            try {
              await navigator.clipboard.writeText(text);
              setTerminalDetailStatus("Terminal output copied.", "notice");
            } catch (error) {
              setTerminalDetailStatus("Copy failed. Use manual selection.", "error");
            }
          });
        }

        if (terminalClearOutputBtn) {
          terminalClearOutputBtn.addEventListener("click", () => {
            terminalOutputText = "";
            renderTerminalOutput();
            setTerminalDetailStatus("Screen cleared.", "notice");
          });
        }
      }

      function bindTerminalActionButtons() {
        if (terminalResizeBtn) {
          terminalResizeBtn.addEventListener("click", () =>
            runButtonAction(terminalResizeBtn, sendActiveTerminalResize, {
              busyLabel: "Resizing…",
              errorMessage: "Failed to resize terminal.",
              errorContext: "terminal_resize",
            })
          );
        }

        if (terminalFitBtn) {
          terminalFitBtn.addEventListener("click", () =>
            runButtonAction(terminalFitBtn, fitTerminalToPanel, {
              busyLabel: "Fitting…",
              errorMessage: "Failed to fit terminal to panel.",
              errorContext: "terminal_fit",
            })
          );
        }

        if (terminalStopBtn) {
          terminalStopBtn.addEventListener("click", () =>
            runButtonAction(terminalStopBtn, stopActiveTerminalSession, {
              busyLabel: "Disconnecting…",
              errorMessage: "Failed to disconnect terminal session.",
              errorContext: "terminal_stop",
            })
          );
        }

        if (terminalRestartNowBtn) {
          terminalRestartNowBtn.addEventListener("click", requestTerminalDaemonRestart);
        }

        if (topRestartTerminalBtn) {
          topRestartTerminalBtn.addEventListener("click", requestTerminalDaemonRestart);
        }

        if (terminalRestartLaterBtn) {
          terminalRestartLaterBtn.addEventListener("click", () => {
            hideTerminalRestartPrompt({ dismissed: true });
            setTerminalDetailStatus("", "notice");
          });
        }
      }

      function bindApprovalActions() {
        if (approvalToggle) {
          approvalToggle.addEventListener("change", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn || syncingToggle || approvalToggle.disabled) return;
            const checked = approvalToggle.checked;
            const previous = !checked;
            approvalToggle.disabled = true;
            try {
              const status = await invokeFn("set_pairing_requires_approval", {
                requires_approval: checked,
              });
              renderStatus(status);
              setOperationStatus(
                checked
                  ? "Desktop approval is now required."
                  : "Desktop approval requirement disabled.",
                "notice"
              );
            } catch (error) {
              approvalToggle.checked = previous;
              setStatusFromError(
                "Failed to update approval requirement.",
                error,
                "set_pairing_requires_approval"
              );
              await refreshStatus({ silent: true });
            } finally {
              approvalToggle.disabled = !bridgeAvailable;
            }
          });
        }

        if (approveBtn) {
          approveBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            await runButtonAction(
              approveBtn,
              async () => {
                const response = await invokeFn("approve_pairing_request");
                await refreshStatus({ silent: true });
                if (response?.status === "connected") {
                  setOperationStatus("Paired and connected.", "notice");
                } else {
                  setOperationStatus("Pairing request approved.", "notice");
                }
              },
              {
                busyLabel: "Approving…",
                errorMessage: "Failed to approve pairing request.",
                errorContext: "approve_pairing_request",
              }
            );
          });
        }

        if (denyBtn) {
          denyBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            await runButtonAction(
              denyBtn,
              async () => {
                const status = await invokeFn("deny_pairing_request");
                renderStatus(status);
                setOperationStatus("Pairing request denied.", "notice");
              },
              {
                busyLabel: "Denying…",
                errorMessage: "Failed to deny pairing request.",
                errorContext: "deny_pairing_request",
              }
            );
          });
        }
      }

      function bindViewTabs() {
        viewTabs.forEach((tab) => {
          tab.addEventListener("click", () => {
            viewTabs.forEach((btn) => btn.classList.remove("active"));
            tab.classList.add("active");
            const view = tab.dataset.view;
            if (view === "settings") {
              overviewView?.classList.add("hidden");
              settingsView?.classList.remove("hidden");
            } else {
              settingsView?.classList.add("hidden");
              overviewView?.classList.remove("hidden");
            }
          });
        });
      }

      function startSessionExpiryTicker() {
        setInterval(() => {
          if (session && expiresEl) {
            expiresEl.textContent = formatExpiry(session.expires_at);
            if (session.expires_at * 1000 <= Date.now()) {
              clearQrDisplay('QR expired. Click "New handshake" to generate a new one.');
              setStatus('Token expired. Click "New handshake" to generate a new token.', "error");
            }
          }
        }, 1000);
      }

      function startStatusPolling() {
        setInterval(() => {
          refreshStatus({ silent: true });
        }, 2000);
      }

      function initializeApp() {
        bindPairingActions();
        bindIdentityActions();
        bindTokenActions();
        bindSettingsActions();
        bindTerminalInputActions();
        bindTerminalUtilityActions();
        bindTerminalActionButtons();
        bindApprovalActions();
        bindViewTabs();

        applyTerminalOutputOptions();
        updateTerminalOutputMeta();
        updateAuthTokenDisplay();
        clearQrDisplay('Click "New handshake" to generate a 3-minute QR.');
        setBridgeState(!!invoke);
        resetTerminalDetail();

        const invokeFn = ensureInvoke();
        invokeFn?.("request_location_permission").catch((error) => {
          const info = normalizeError(error);
          logErrorDetails("request_location_permission", info, { silent: true });
        });

        refreshStatus({ silent: true });
        startSessionExpiryTicker();
        startStatusPolling();
      }

      initializeApp();
