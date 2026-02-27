      let refreshStatusRequestSeq = 0;
      let refreshStatusAppliedSeq = 0;
      let refreshStatusActiveCount = 0;

      async function refreshStatus(options = {}) {
        const silent = options.silent === true;
        const skipIfBusy = options.skipIfBusy !== false;
        const invokeFn = ensureInvoke();
        if (!invokeFn) return false;

        if (silent && skipIfBusy && refreshStatusActiveCount > 0) {
          return false;
        }

        const requestSeq = ++refreshStatusRequestSeq;
        refreshStatusActiveCount += 1;
        try {
          const status = await invokeFn("get_pairing_status");
          if (requestSeq < refreshStatusAppliedSeq) {
            return false;
          }
          refreshStatusAppliedSeq = requestSeq;
          renderStatus(status);
          return true;
        } catch (error) {
          if (silent) {
            const info = normalizeError(error);
            logErrorDetails("refresh_status", info, { silent: true });
          } else {
            setStatusFromError("Failed to refresh desktop status.", error, "refresh_status");
          }
          return false;
        } finally {
          refreshStatusActiveCount = Math.max(0, refreshStatusActiveCount - 1);
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
        if (requestLocationPermissionBtn) {
          requestLocationPermissionBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            await runButtonAction(
              requestLocationPermissionBtn,
              async () => {
                await invokeFn("request_location_permission");
                await refreshStatus({ silent: true });
                setOperationStatus("Location permission request sent.", "notice");
              },
              {
                busyLabel: "Requesting…",
                errorMessage: "Failed to request location permission.",
                errorContext: "request_location_permission",
              }
            );
          });
        }

        if (openLocationSettingsBtn) {
          openLocationSettingsBtn.addEventListener("click", async () => {
            const invokeFn = ensureInvoke();
            if (!invokeFn) return;
            await runButtonAction(
              openLocationSettingsBtn,
              async () => {
                await invokeFn("open_location_settings");
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

      function bindImageUploadActions() {
        if (!imageUploadDropzoneEl || !imageUploadInputEl) {
          return;
        }

        const openPicker = () => {
          if (imageUploadInputEl.disabled) return;
          imageUploadInputEl.click();
        };

        if (imageUploadBrowseBtn) {
          imageUploadBrowseBtn.addEventListener("click", () => {
            openPicker();
          });
        }

        imageUploadDropzoneEl.addEventListener("click", (event) => {
          const target = event.target;
          if (target instanceof HTMLElement && target.closest("button")) {
            return;
          }
          openPicker();
        });

        imageUploadDropzoneEl.addEventListener("keydown", (event) => {
          if (event.key !== "Enter" && event.key !== " ") {
            return;
          }
          event.preventDefault();
          openPicker();
        });

        imageUploadInputEl.addEventListener("change", () => {
          addImageUploadFiles(imageUploadInputEl.files);
          imageUploadInputEl.value = "";
        });

        imageUploadDropzoneEl.addEventListener("dragenter", (event) => {
          if (!hasFilesInDataTransfer(event.dataTransfer)) {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          imageUploadDragDepth += 1;
          setImageUploadDragActive(true);
        });

        imageUploadDropzoneEl.addEventListener("dragover", (event) => {
          if (!hasFilesInDataTransfer(event.dataTransfer)) {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          if (event.dataTransfer) {
            event.dataTransfer.dropEffect = imageUploadInputEl.disabled ? "none" : "copy";
          }
        });

        imageUploadDropzoneEl.addEventListener("dragleave", (event) => {
          if (!hasFilesInDataTransfer(event.dataTransfer)) {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          imageUploadDragDepth = Math.max(0, imageUploadDragDepth - 1);
          if (imageUploadDragDepth === 0) {
            setImageUploadDragActive(false);
          }
        });

        imageUploadDropzoneEl.addEventListener("drop", (event) => {
          if (!hasFilesInDataTransfer(event.dataTransfer)) {
            return;
          }
          event.preventDefault();
          event.stopPropagation();
          resetImageUploadDragState();
          if (imageUploadInputEl.disabled) {
            return;
          }
          addImageUploadFiles(event.dataTransfer.files);
        });

        if (imageUploadClearBtn) {
          imageUploadClearBtn.addEventListener("click", () => {
            clearImageUploads();
            setOperationStatus("Image selection cleared.", "notice", 1800);
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
        if (refreshTerminalSessionsBtn) {
          refreshTerminalSessionsBtn.addEventListener("click", () =>
            runButtonAction(refreshTerminalSessionsBtn, async () => {
              const ok = await refreshStatus({ silent: false, skipIfBusy: false });
              if (ok) {
                setOperationStatus("Terminal sessions refreshed.", "notice", 1800);
              }
            }, {
              busyLabel: "Refreshing…",
              errorMessage: "Failed to refresh terminal sessions.",
              errorContext: "refresh_terminal_sessions",
            })
          );
        }

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

        if (terminalDeleteBtn) {
          terminalDeleteBtn.addEventListener("click", () =>
            runButtonAction(terminalDeleteBtn, deleteActiveTerminalSession, {
              busyLabel: "Deleting…",
              errorMessage: "Failed to delete terminal session.",
              errorContext: "terminal_delete",
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

      function setActiveView(view) {
        const normalizedView = view === "settings" ? "settings" : "overview";
        viewTabs.forEach((btn) => {
          const isActive = btn.dataset.view === normalizedView;
          btn.classList.toggle("active", isActive);
          btn.setAttribute("aria-selected", String(isActive));
          btn.tabIndex = isActive ? 0 : -1;
        });

        if (normalizedView === "settings") {
          overviewView?.classList.add("hidden");
          overviewView?.setAttribute("aria-hidden", "true");
          settingsView?.classList.remove("hidden");
          settingsView?.setAttribute("aria-hidden", "false");
        } else {
          settingsView?.classList.add("hidden");
          settingsView?.setAttribute("aria-hidden", "true");
          overviewView?.classList.remove("hidden");
          overviewView?.setAttribute("aria-hidden", "false");
        }
      }

      function bindViewTabs() {
        const tabs = Array.from(viewTabs);
        if (tabs.length === 0) return;

        const activateByIndex = (index) => {
          const wrapped = ((index % tabs.length) + tabs.length) % tabs.length;
          const tab = tabs[wrapped];
          if (!tab) return;
          setActiveView(tab.dataset.view);
          tab.focus();
        };

        tabs.forEach((tab, index) => {
          tab.addEventListener("click", () => {
            setActiveView(tab.dataset.view);
          });
          tab.addEventListener("keydown", (event) => {
            if (event.key === "ArrowRight") {
              event.preventDefault();
              activateByIndex(index + 1);
            } else if (event.key === "ArrowLeft") {
              event.preventDefault();
              activateByIndex(index - 1);
            } else if (event.key === "Home") {
              event.preventDefault();
              activateByIndex(0);
            } else if (event.key === "End") {
              event.preventDefault();
              activateByIndex(tabs.length - 1);
            }
          });
        });

        const initialTab = tabs.find((tab) => tab.classList.contains("active")) || tabs[0];
        setActiveView(initialTab.dataset.view);
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
        bindImageUploadActions();
        bindTerminalInputActions();
        bindTerminalUtilityActions();
        bindTerminalActionButtons();
        bindApprovalActions();
        bindViewTabs();

        applyTerminalOutputOptions();
        updateTerminalOutputMeta();
        updateAuthTokenDisplay();
        renderImageUploadState();
        clearQrDisplay('Click "New handshake" to generate a 3-minute QR.');
        setBridgeState(!!invoke);
        resetTerminalDetail();

        refreshStatus({ silent: true });
        startSessionExpiryTicker();
        startStatusPolling();
      }

      initializeApp();
