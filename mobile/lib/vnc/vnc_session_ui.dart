part of '../main.dart';

extension _VncSessionUi on _VncSessionScreenState {
  Future<void> _showKeyboardInput() async {
    if (!mounted) {
      return;
    }
    if (_vncClient == null || _connectionError != null || _isConnecting) {
      return;
    }
    final controller = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Send keystrokes',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 3,
                minLines: 1,
                textInputAction: TextInputAction.send,
                decoration: const InputDecoration(
                  hintText: 'Type and send to the remote session',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) {
                  final trimmed = value.trim();
                  if (trimmed.isNotEmpty) {
                    _vncClient?.sendText(trimmed);
                  }
                  Navigator.of(context).maybePop();
                },
              ),
              const SizedBox(height: 12),
              Text(
                'Special keys',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _VncSpecialKeyButton(
                    label: 'Enter',
                    onPressed: () => _sendKeyPress(0xff0d),
                  ),
                  _VncSpecialKeyButton(
                    label: 'Backspace',
                    onPressed: () => _sendKeyPress(0xff08),
                  ),
                  _VncSpecialKeyButton(
                    label: 'Delete',
                    onPressed: () => _sendKeyPress(0xffff),
                  ),
                  _VncSpecialKeyButton(
                    label: 'Ctrl',
                    onPressed: () => _sendKeyPress(0xffe3),
                  ),
                  _VncSpecialKeyButton(
                    label: 'Cmd',
                    onPressed: () => _sendKeyPress(0xffe7),
                  ),
                  _VncSpecialKeyButton(
                    label: 'Opt',
                    onPressed: () => _sendKeyPress(0xffe9),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () {
                      final trimmed = controller.text.trim();
                      if (trimmed.isNotEmpty) {
                        _vncClient?.sendText(trimmed);
                      }
                      Navigator.of(context).maybePop();
                    },
                    child: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _handleSwipeUpdate(DragUpdateDetails details) {
    _swipeDistance += details.delta.dy;
  }

  void _handleSwipeEnd(DragEndDetails details) {
    if (_swipeDistance > _swipeThreshold) {
      Navigator.of(context).maybePop();
    }
    _swipeDistance = 0;
  }

  Future<void> _setFullscreen(bool value) async {
    if (!mounted || _isFullscreen == value) {
      return;
    }
    _clearPointerState();
    _updateState(() {
      _isFullscreen = value;
      _autoSizedOnce = false;
      if (value) {
        _directInputBackup = _directInputEnabled;
        _directInputEnabled = false;
      } else if (_directInputBackup != null) {
        _directInputEnabled = _directInputBackup ?? false;
        _directInputBackup = null;
      }
    });
    if (value) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _scheduleLayoutRecalibration();
    _requestStreamRefresh(resetAutoResize: true);
  }

  void _requestStreamRefresh({bool resetAutoResize = false}) {
    if (resetAutoResize) {
      _autoSizedOnce = false;
    }
    if (_pendingFullFrameRequest) {
      return;
    }
    _pendingFullFrameRequest = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pendingFullFrameRequest = false;
      if (!mounted || _isDisposed) {
        return;
      }
      _maybeAutoResizeStream();
      _vncClient?.requestFullFrame();
    });
  }

  void _scheduleLayoutRecalibration() {
    _pendingLayoutRecalibration = true;
    _layoutRecalibrationTimer?.cancel();
    _layoutRecalibrationTimer = Timer(const Duration(milliseconds: 420), () {
      if (!mounted || _isDisposed) {
        return;
      }
      if (!_pendingLayoutRecalibration) {
        return;
      }
      _pendingLayoutRecalibration = false;
      _performLayoutRecalibration();
    });
  }

  void _maybeHandleLayoutChange(Size viewSize, bool isLandscape) {
    if (_lastLayoutSize == Size.zero) {
      _lastLayoutSize = viewSize;
      _lastLayoutLandscape = isLandscape;
      _lastLayoutFullscreen = _isFullscreen;
      return;
    }
    final sizeDelta = (viewSize.width - _lastLayoutSize.width).abs() +
        (viewSize.height - _lastLayoutSize.height).abs();
    final landscapeChanged =
        _lastLayoutLandscape != null && _lastLayoutLandscape != isLandscape;
    final fullscreenChanged = _lastLayoutFullscreen != _isFullscreen;
    if (sizeDelta <= 6 && !landscapeChanged && !fullscreenChanged) {
      return;
    }
    if (landscapeChanged || fullscreenChanged) {
      _schedulePointerReset();
    }
    _lastLayoutSize = viewSize;
    _lastLayoutLandscape = isLandscape;
    _lastLayoutFullscreen = _isFullscreen;
    _scheduleLayoutRecalibration();
  }

  void _performLayoutRecalibration() {
    if (_connectionError != null || _isConnecting || _vncClient == null) {
      return;
    }
    if (_directInputEnabled) {
      return;
    }
    if (_isAutoCalibrating) {
      return;
    }
    final now = DateTime.now();
    if (_lastRecalibrationAt != null) {
      final elapsed = now.difference(_lastRecalibrationAt!);
      if (elapsed.inMilliseconds < 1500) {
        _pendingLayoutRecalibration = true;
        _layoutRecalibrationTimer?.cancel();
        _layoutRecalibrationTimer = Timer(
          Duration(milliseconds: 1500 - elapsed.inMilliseconds),
          () {
            if (!mounted || _isDisposed) {
              return;
            }
            if (_pendingLayoutRecalibration) {
              _pendingLayoutRecalibration = false;
              _performLayoutRecalibration();
            }
          },
        );
        return;
      }
    }
    _lastRecalibrationAt = now;
    _updateState(() {
      _trackpadMoreAnchor = _trackpadMoreAnchorDefault;
      _trackpadMoreRepositioning = false;
      _cameraCenter = _applyInputCalibration(_pointerPosition);
    });
    _sendPointerEvent();
  }

  void _startAutoCalibration() {
    final margin = (_frameSize.shortestSide * 0.12).clamp(24.0, 96.0);
    final targets = [
      Offset(margin, margin),
      Offset(_frameSize.width - margin, margin),
      Offset(_frameSize.width - margin, _frameSize.height - margin),
      Offset(margin, _frameSize.height - margin),
    ];
    _updateState(() {
      _calibrationBackupScaleX = _inputScaleX;
      _calibrationBackupScaleY = _inputScaleY;
      _calibrationBackupOffsetX = _inputOffsetX;
      _calibrationBackupOffsetY = _inputOffsetY;
      _inputScaleX = 1;
      _inputScaleY = 1;
      _inputOffsetX = 0;
      _inputOffsetY = 0;
      _calibrationNormalized = true;
      _calibrationAspectRatio = _currentAspectRatio();
      _cameraCenter = _applyInputCalibration(_pointerPosition);
      _isAutoCalibrating = true;
      _calibrationStep = 0;
      _calibrationTargets = targets;
      _calibrationSamples.clear();
    });
    _sendPointerEvent();
  }

  void _cancelAutoCalibration() {
    if (!mounted) {
      return;
    }
    _updateState(() {
      _isAutoCalibrating = false;
      _calibrationStep = 0;
      _calibrationTargets = const [];
      _calibrationSamples.clear();
      if (_calibrationBackupScaleX != null &&
          _calibrationBackupScaleY != null &&
          _calibrationBackupOffsetX != null &&
          _calibrationBackupOffsetY != null) {
        _inputScaleX = _calibrationBackupScaleX!;
        _inputScaleY = _calibrationBackupScaleY!;
        _inputOffsetX = _calibrationBackupOffsetX!;
        _inputOffsetY = _calibrationBackupOffsetY!;
      }
      _cameraCenter = _applyInputCalibration(_pointerPosition);
      _calibrationBackupScaleX = null;
      _calibrationBackupScaleY = null;
      _calibrationBackupOffsetX = null;
      _calibrationBackupOffsetY = null;
    });
    _sendPointerEvent();
  }

  void _captureCalibrationPoint() {
    if (!_isAutoCalibrating || _calibrationTargets.isEmpty) {
      return;
    }
    _calibrationSamples.add(_pointerPosition);
    if (_calibrationSamples.length < _calibrationTargets.length) {
      _updateState(() {
        _calibrationStep =
            (_calibrationStep + 1).clamp(0, _calibrationTargets.length - 1);
      });
      return;
    }
    if (_calibrationSamples.length >= 2) {
      final result = _solveLinearCalibration(
        _calibrationSamples,
        _calibrationTargets,
      );
      final scaleX = result.scaleX;
      final scaleY = result.scaleY;
      final offsetX = result.offsetX;
      final offsetY = result.offsetY;
      _updateState(() {
        _inputScaleX = scaleX;
        _inputScaleY = scaleY;
        _inputOffsetX = offsetX;
        _inputOffsetY = offsetY;
        _calibrationNormalized = true;
        _calibrationAspectRatio = _currentAspectRatio();
        _cameraCenter = _applyInputCalibration(_pointerPosition);
        _calibrationBackupScaleX = null;
        _calibrationBackupScaleY = null;
        _calibrationBackupOffsetX = null;
        _calibrationBackupOffsetY = null;
      });
      unawaited(_persistCalibration());
    }
    _cancelAutoCalibration();
  }

  void _updateTrackpadMoreAnchorByDelta(Offset delta, Size areaSize) {
    final width = areaSize.width -
        _trackpadMoreButtonWidth -
        _trackpadMoreButtonMargin * 2;
    final height = areaSize.height -
        _trackpadMoreButtonHeight -
        _trackpadMoreButtonMargin * 2;
    if (width <= 0 || height <= 0) {
      return;
    }
    final nextDx =
        (_trackpadMoreAnchor.dx * width + delta.dx).clamp(0.0, width);
    final nextDy =
        (_trackpadMoreAnchor.dy * height + delta.dy).clamp(0.0, height);
    _updateState(() {
      _trackpadMoreAnchor = Offset(nextDx / width, nextDy / height);
    });
  }

  Future<void> _openTrackpadMoreSheet({required bool isInteractive}) async {
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: false,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              void updateDebugVisibility(bool value) {
                _updateState(() {
                  _debugPanelVisible = value;
                });
                unawaited(_persistDebugPanelPreference(value));
                setSheetState(() {});
              }

              return Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 42,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '更多操作',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF0F172A),
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '键盘输入、调试视图与校准操作。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF64748B),
                          ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.keyboard),
                      title: const Text('Keyboard input'),
                      subtitle: const Text('Send text to the remote session'),
                      enabled: isInteractive,
                      onTap: isInteractive
                          ? () {
                              Navigator.of(context).maybePop();
                              Future.microtask(_showKeyboardInput);
                            }
                          : null,
                    ),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Debug view'),
                      subtitle: Text(
                        _debugPanelVisible ? 'Visible' : 'Hidden',
                      ),
                      value: _debugPanelVisible,
                      onChanged: updateDebugVisibility,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.copy),
                      title: const Text('导出日志'),
                      subtitle: const Text('复制当前设备日志'),
                      onTap: () {
                        Navigator.of(context).maybePop();
                        Future.microtask(_copyAgentLogs);
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('清空日志'),
                      onTap: () {
                        Navigator.of(context).maybePop();
                        Future.microtask(_clearAgentLogs);
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.center_focus_strong),
                      title: const Text('Recalibrate cursor'),
                      subtitle: const Text('Recenter pointer alignment'),
                      enabled: isInteractive,
                      onTap: isInteractive
                          ? () {
                              Navigator.of(context).maybePop();
                              _performLayoutRecalibration();
                            }
                          : null,
                    ),
                    const Divider(height: 16),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.center_focus_strong),
                      title: const Text('输入校准'),
                      subtitle: const Text('打开校准面板'),
                      enabled: isInteractive,
                      onTap: isInteractive
                          ? () {
                              Navigator.of(context).maybePop();
                              _openCalibrationSheet(isInteractive: true);
                            }
                          : null,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.auto_fix_high),
                      title: const Text('自动校准（四点）'),
                      enabled: isInteractive,
                      onTap: isInteractive
                          ? () {
                              Navigator.of(context).maybePop();
                              _startAutoCalibration();
                            }
                          : null,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.tune),
                      title: Text(
                        _trackpadMoreRepositioning ? '完成定位按钮' : '拖动定位按钮',
                      ),
                      onTap: () {
                        Navigator.of(context).maybePop();
                        _updateState(() {
                          _trackpadMoreRepositioning =
                              !_trackpadMoreRepositioning;
                        });
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.refresh),
                      title: const Text('重置按钮位置'),
                      onTap: () {
                        Navigator.of(context).maybePop();
                        _updateState(() {
                          _trackpadMoreAnchor = _trackpadMoreAnchorDefault;
                          _trackpadMoreRepositioning = false;
                        });
                      },
                    ),
                    const SizedBox(height: 4),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTrackpadMoreButton({
    required Size areaSize,
    required bool isInteractive,
  }) {
    final theme = Theme.of(context);
    final width = areaSize.width -
        _trackpadMoreButtonWidth -
        _trackpadMoreButtonMargin * 2;
    final height = areaSize.height -
        _trackpadMoreButtonHeight -
        _trackpadMoreButtonMargin * 2;
    final safeWidth = width <= 0 ? 0.0 : width;
    final safeHeight = height <= 0 ? 0.0 : height;
    final anchor = _trackpadMoreAnchor;
    final left =
        _trackpadMoreButtonMargin + safeWidth * anchor.dx.clamp(0.0, 1.0);
    final top =
        _trackpadMoreButtonMargin + safeHeight * anchor.dy.clamp(0.0, 1.0);
    final isDragging = _trackpadMoreRepositioning;
    final label = isDragging ? 'Move' : 'More';
    return Positioned(
      left: left,
      top: top,
      child: GestureDetector(
        onPanUpdate: isDragging
            ? (details) => _updateTrackpadMoreAnchorByDelta(
                  details.delta,
                  areaSize,
                )
            : null,
        onTap: () => _openTrackpadMoreSheet(isInteractive: isInteractive),
        onLongPress: () {
          _updateState(() {
            _trackpadMoreRepositioning = !_trackpadMoreRepositioning;
          });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: _trackpadMoreButtonWidth,
          height: _trackpadMoreButtonHeight,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isDragging
                ? const Color(0xFFF59E0B)
                : Colors.black.withAlpha(140),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDragging
                  ? const Color(0xFFFBBF24)
                  : Colors.white.withAlpha(40),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(60),
                blurRadius: 10,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isDragging ? Icons.open_with_rounded : Icons.more_horiz,
                color: Colors.white,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  _CalibrationResult _solveLinearCalibration(
    List<Offset> samples,
    List<Offset> targets,
  ) {
    final count = samples.length.clamp(2, targets.length);
    final width = _frameSize.width <= 0 ? 1.0 : _frameSize.width;
    final height = _frameSize.height <= 0 ? 1.0 : _frameSize.height;
    double sumSX = 0;
    double sumSY = 0;
    double sumTX = 0;
    double sumTY = 0;
    for (var i = 0; i < count; i += 1) {
      sumSX += samples[i].dx / width;
      sumSY += samples[i].dy / height;
      sumTX += targets[i].dx / width;
      sumTY += targets[i].dy / height;
    }
    final meanSX = sumSX / count;
    final meanSY = sumSY / count;
    final meanTX = sumTX / count;
    final meanTY = sumTY / count;

    double varSX = 0;
    double varSY = 0;
    double covX = 0;
    double covY = 0;
    for (var i = 0; i < count; i += 1) {
      final dx = samples[i].dx / width - meanSX;
      final dy = samples[i].dy / height - meanSY;
      varSX += dx * dx;
      varSY += dy * dy;
      covX += dx * (targets[i].dx / width - meanTX);
      covY += dy * (targets[i].dy / height - meanTY);
    }

    var scaleX = varSX.abs() < 0.0001 ? 1.0 : covX / varSX;
    var scaleY = varSY.abs() < 0.0001 ? 1.0 : covY / varSY;
    if (scaleX.isNaN || scaleX.isInfinite) {
      scaleX = 1;
    }
    if (scaleY.isNaN || scaleY.isInfinite) {
      scaleY = 1;
    }
    scaleX = scaleX.clamp(0.5, 2.0);
    scaleY = scaleY.clamp(0.5, 2.0);

    var offsetX = meanTX - scaleX * meanSX;
    var offsetY = meanTY - scaleY * meanSY;
    offsetX = offsetX.clamp(-0.5, 0.5);
    offsetY = offsetY.clamp(-0.5, 0.5);

    return _CalibrationResult(
      scaleX: scaleX,
      scaleY: scaleY,
      offsetX: offsetX,
      offsetY: offsetY,
    );
  }

  Widget _buildVncCanvas({
    required ThemeData theme,
    required bool isInteractive,
    required bool isLandscape,
    required EdgeInsets safePadding,
    required Size screenSize,
    bool isFullscreen = false,
    bool expandToFit = false,
    bool showControls = true,
  }) {
    final canvas = LayoutBuilder(
      builder: (context, constraints) {
        _devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
        final viewSize = Size(
          constraints.maxWidth,
          constraints.maxHeight,
        );
        _maybeHandleLayoutChange(viewSize, isLandscape);
        final previousViewSize = _lastViewSize;
        _lastViewSize = viewSize;
        if (_roiSession != null && _roiLastRequestAt == null) {
          _scheduleRoiRequest();
        }
        final viewDelta = (viewSize.width - previousViewSize.width).abs() +
            (viewSize.height - previousViewSize.height).abs();
        if (isInteractive && viewDelta > 6) {
          _autoSizedOnce = false;
          _requestStreamRefresh();
        }
        if (isInteractive) {
          _maybeAutoResizeStream();
        }
        final pointerScreen = _pointerToScreen(viewSize);
        final targetScreen =
            _isAutoCalibrating && _calibrationTargets.isNotEmpty
                ? _frameToScreen(
                    _calibrationTargets[_calibrationStep
                        .clamp(0, _calibrationTargets.length - 1)],
                    viewSize,
                  )
                : null;
        final translation = _calculateTranslation(viewSize);
        final scale = _baseScale(viewSize) * _zoom;
        final cursorImage = _cursorImage;
        final cursorSize = _cursorSize;
        final cursorHotspot = _cursorHotspot;
        final roiRenderer = _roiRenderer;
        final roiImages = _roiImages;
        final roiRevision = _roiRevision;
        final hasFrame = _frameImage != null;
        final filterQuality = (isFullscreen && isLandscape)
            ? FilterQuality.none
            : (_zoom > 1.01 ? FilterQuality.none : FilterQuality.medium);
        return ClipRRect(
          borderRadius: BorderRadius.circular(isFullscreen ? 0 : 18),
          child: Stack(
            children: [
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFF0B1120),
                        Color(0xFF1E293B),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              ),
              if (hasFrame)
                Positioned.fill(
                  child: OverflowBox(
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    alignment: Alignment.topLeft,
                    child: Transform(
                      alignment: Alignment.topLeft,
                      transform: Matrix4.identity()
                        ..translateByDouble(
                          translation.dx,
                          translation.dy,
                          0,
                          1,
                        )
                        ..scaleByDouble(scale, scale, 1, 1),
                      child: SizedBox(
                        width: _frameSize.width,
                        height: _frameSize.height,
                      child: RawImage(
                        image: _frameImage,
                        fit: BoxFit.fill,
                        filterQuality: filterQuality,
                      ),
                    ),
                  ),
                ),
                ),
              if (hasFrame &&
                  _zoom > _roiZoomThreshold &&
                  roiRenderer != null &&
                  roiImages.isNotEmpty)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _RoiTilePainter(
                      tiles: roiImages,
                      renderer: roiRenderer,
                      translation: translation,
                      scale: scale,
                      revision: roiRevision,
                    ),
                  ),
                ),
              if (!hasFrame)
                Center(
                  child: Text(
                    'Waiting for frames...',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (isInteractive && _directInputEnabled)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (details) {
                      final framePos =
                          _screenToFrame(details.localPosition, viewSize);
                      _setPointerPosition(_removeInputCalibration(framePos));
                    },
                    onPanStart: (details) {
                      _directDragActive = true;
                      final framePos =
                          _screenToFrame(details.localPosition, viewSize);
                      _setPointerPosition(_removeInputCalibration(framePos));
                    },
                    onPanUpdate: (details) {
                      if (!_directDragActive) {
                        return;
                      }
                      final framePos =
                          _screenToFrame(details.localPosition, viewSize);
                      _setPointerPosition(_removeInputCalibration(framePos));
                    },
                    onPanEnd: (_) {
                      if (!_directDragActive) {
                        return;
                      }
                      _directDragActive = false;
                    },
                    onPanCancel: () {
                      if (!_directDragActive) {
                        return;
                      }
                      _directDragActive = false;
                    },
                  ),
                ),
              if (showControls && !isLandscape)
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: _VncShortcutOverlay(
                    enabled: isInteractive,
                    onEsc: () => _sendKeyPress(0xff1b),
                    onCmd: () => _sendKeyPress(0xffe7),
                    onTab: () => _sendKeyPress(0xff09),
                    onCtrl: () => _sendKeyPress(0xffe3),
                    onKeyboard: _showKeyboardInput,
                  ),
                ),
              if (showControls && (isLandscape || isFullscreen))
                Positioned(
                  right: 12 + safePadding.right,
                  bottom: 12 + safePadding.bottom,
                  child: Tooltip(
                    message: 'Controls',
                    child: FloatingActionButton.small(
                      heroTag: 'vncControlsFab-${widget.session.id}',
                      onPressed: () => _openLandscapeControls(
                        isInteractive: isInteractive,
                      ),
                      backgroundColor: isInteractive
                          ? Colors.black.withAlpha(170)
                          : Colors.black.withAlpha(100),
                      foregroundColor: Colors.white,
                      child: Icon(
                        _controlsSheetOpen ? Icons.close : Icons.tune,
                      ),
                    ),
                  ),
                ),
              if (showControls)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _VncOverlayIconButton(
                    icon: _isFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    label: _isFullscreen ? 'Exit' : 'Full',
                    onPressed: () => _setFullscreen(!_isFullscreen),
                  ),
                ),
              if (showControls)
                Positioned(
                  right: 12,
                  top: 12,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _VncStatsBadge(
                        latencyMs: _streamLatencyMs,
                        fps: _streamFps,
                      ),
                      const SizedBox(height: 6),
                      _VncZoomBadge(value: _zoom),
                    ],
                  ),
                ),
              if (!isInteractive)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withAlpha(80),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _connectionError != null
                                  ? 'Stream unavailable'
                                  : 'Connecting...',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (_connectionError != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                _connectionError!,
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: Colors.white70,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (isFullscreen) ...[
                                const SizedBox(height: 12),
                                FilledButton.icon(
                                  onPressed: _isConnecting ? null : _startStream,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('Retry stream'),
                                ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (_isAutoCalibrating && targetScreen != null)
                Positioned(
                  left: targetScreen.dx - 18,
                  top: targetScreen.dy - 18,
                  child: const _CalibrationTarget(),
                ),
              if (_isAutoCalibrating)
                Positioned(
                  left: 12,
                  right: 12,
                  top: 56,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(160),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withAlpha(40)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '自动校准 ${_calibrationStep + 1}/${_calibrationTargets.length}',
                          style: theme.textTheme.bodyMedium?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '依次对准四个角标记，然后点“记录当前点”。',
                          style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            TextButton(
                              onPressed: _cancelAutoCalibration,
                              style: TextButton.styleFrom(
                                foregroundColor: Colors.white70,
                              ),
                              child: const Text('取消'),
                            ),
                            const Spacer(),
                            FilledButton(
                              onPressed: _captureCalibrationPoint,
                              child: Text(
                                _calibrationStep + 1 >=
                                        _calibrationTargets.length
                                    ? '完成'
                                    : '记录当前点',
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (_debugPanelVisible)
                Positioned(
                  left: 12 + safePadding.left,
                  bottom: 12 + safePadding.bottom,
                  child: _buildVncDebugPanel(theme: theme),
                ),
              if (cursorImage != null &&
                  scale > 0 &&
                  cursorSize.width > 0 &&
                  cursorSize.height > 0)
                Positioned(
                  left: pointerScreen.dx - cursorHotspot.dx * scale,
                  top: pointerScreen.dy - cursorHotspot.dy * scale,
                  child: IgnorePointer(
                    child: SizedBox(
                      width: cursorSize.width * scale,
                      height: cursorSize.height * scale,
                      child: RawImage(
                        image: cursorImage,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.none,
                      ),
                    ),
                  ),
                ),
              if (isInteractive && (_showLocalCursor || _isAutoCalibrating))
                Positioned(
                  left: pointerScreen.dx - 10,
                  top: pointerScreen.dy - 10,
                  child: _VncPointer(
                    isClicking: _showClickPulse,
                    isFocusing: _showFocusPulse,
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (expandToFit) {
      return SizedBox.expand(child: canvas);
    }
    return AspectRatio(
      aspectRatio: _viewAspectRatio(screenSize),
      child: canvas,
    );
  }

  Widget _buildVncDebugPanel({required ThemeData theme}) {
    final vncStatus = _connectionError != null
        ? '错误'
        : _isConnecting
            ? '连接中'
            : '已连接';
    final vncSessionId = _lastVncSessionInfo?.sessionId ?? '-';
    final frameLabel = _frameSize.width <= 0 || _frameSize.height <= 0
        ? '-'
        : '${_frameSize.width.toInt()}x${_frameSize.height.toInt()}';
    final viewLabel = _lastViewSize.width <= 0 || _lastViewSize.height <= 0
        ? '-'
        : '${_lastViewSize.width.toInt()}x${_lastViewSize.height.toInt()}';
    final fpsLabel = _streamFps > 0 ? _streamFps.toStringAsFixed(1) : '-';
    final latencyLabel = _streamLatencyMs?.toString() ?? '-';
    final encodingLabel = _encodingPreference.name;
    final roiStatus = _roiStatusLabel();
    final roiHost = _roiHost ?? '-';
    final roiPortValue = _roiSession?.quicPort ?? 0;
    final roiPortLabel = roiPortValue > 0 ? roiPortValue.toString() : '未知';
    final roiLastTileLabel = _formatSince(_roiLastTileAt);
    final roiLastRequestLabel = _formatSince(_roiLastRequestAt);
    final roiTileLabel = _roiTileCount == 0
        ? '-'
        : '${_roiTileCount} (${_formatBytes(_roiTileBytes)})';
    final roiCacheLabel = _roiImages.isEmpty ? '-' : '${_roiImages.length}';
    final roiErrorLabel =
        _roiLastError == null || _roiLastError!.isEmpty ? '-' : _roiLastError!;

    const panelWidth = 300.0;
    final background = Colors.black.withAlpha(165);
    final borderColor = Colors.white.withAlpha(50);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: Colors.white70,
      fontWeight: FontWeight.w600,
    );
    final valueStyle = theme.textTheme.bodySmall?.copyWith(
      color: Colors.white,
      fontWeight: FontWeight.w600,
    );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      child: _debugPanelOpen
          ? ConstrainedBox(
              key: const ValueKey('debug-open'),
              constraints: const BoxConstraints(maxWidth: panelWidth),
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'VNC 调试',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () {
                            _updateState(() {
                              _debugPanelOpen = false;
                            });
                          },
                          icon: const Icon(
                            Icons.expand_more,
                            color: Colors.white70,
                          ),
                          tooltip: 'Collapse',
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                            minWidth: 28,
                            minHeight: 28,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _VncDebugRow(
                      label: 'VNC 状态',
                      value: vncStatus,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'VNC 会话',
                      value: vncSessionId,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '帧尺寸',
                      value: frameLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '视图尺寸',
                      value: viewLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '缩放',
                      value: _zoom.toStringAsFixed(2),
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'FPS/延迟',
                      value: '$fpsLabel fps / ${latencyLabel}ms',
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: '编码',
                      value: encodingLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    const SizedBox(height: 6),
                    Divider(color: Colors.white.withAlpha(30), height: 12),
                    _VncDebugRow(
                      label: 'ROI 状态',
                      value: roiStatus,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI Host',
                      value: roiHost,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 端口',
                      value: roiPortLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 最近帧',
                      value: roiLastTileLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 最近请求',
                      value: roiLastRequestLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI Tiles',
                      value: roiTileLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 缓存',
                      value: roiCacheLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                    _VncDebugRow(
                      label: 'ROI 错误',
                      value: roiErrorLabel,
                      labelStyle: labelStyle,
                      valueStyle: valueStyle,
                    ),
                  ],
                ),
              ),
            )
          : GestureDetector(
              key: const ValueKey('debug-closed'),
              onTap: () {
                _updateState(() {
                  _debugPanelOpen = true;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: background,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: borderColor),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.bug_report,
                      size: 14,
                      color: Colors.white70,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '调试',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'VNC:$vncStatus',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'ROI:$roiStatus',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 6),
                    const Icon(
                      Icons.expand_more,
                      size: 14,
                      color: Colors.white70,
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildFullscreenInputPanel({
    required bool isInteractive,
    required bool isLandscape,
  }) {
    final trackpadEnabled = isInteractive && !_directInputEnabled;
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final zoomOpacity = isLandscape ? 0.38 : 1.0;
        final trackpadOpacity = isLandscape ? 0.18 : 1.0;
        final zoomWidth = isLandscape ? 48.0 : 60.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Opacity(
              opacity: zoomOpacity,
              child: SizedBox(
                width: zoomWidth,
                child: _VncZoomBar(
                  value: _zoom,
                  min: _zoomMin,
                  max: _zoomMax,
                  enabled: isInteractive,
                  glassStyle: isLandscape,
                  onValueChanged: _updateZoomValue,
                  onValueCommitted: _commitZoomValue,
                  onReset: _resetZoom,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Opacity(
                opacity: trackpadOpacity,
                child: LayoutBuilder(
                  builder: (context, _) {
                    final surface = _VncTrackpadSurface(
                      enabled: trackpadEnabled,
                      glassStyle: isLandscape,
                      height: height,
                      showLabel: !isLandscape,
                      disabledMessage:
                          _directInputEnabled ? 'Direct touch enabled' : null,
                      onDoubleTapDown:
                          trackpadEnabled ? _handleTrackpadDoubleTapDown : null,
                      onDoubleTap: trackpadEnabled ? _handleTrackpadDoubleTap : null,
                      onPointerDown: _handleTrackpadPointerDown,
                      onPointerMove: _handleTrackpadPointerMove,
                      onPointerHover: _handleTrackpadPointerHover,
                      onPointerUp: _handleTrackpadPointerUp,
                      onPointerCancel: _handleTrackpadPointerCancel,
                      onPointerSignal: _handleTrackpadPointerSignal,
                      onPointerPanZoomUpdate: _handleTrackpadPanZoomUpdate,
                    );
                    final trackpadColumn = Column(
                      children: [
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, surfaceConstraints) {
                              final trackpadSize = Size(
                                surfaceConstraints.maxWidth,
                                surfaceConstraints.maxHeight,
                              );
                              _updateTrackpadSize(
                                trackpadSize,
                                source: isLandscape
                                    ? 'fullscreen_landscape'
                                    : 'fullscreen_portrait',
                              );
                              if (isLandscape) {
                                return surface;
                              }
                              return Stack(
                                children: [
                                  Positioned.fill(child: surface),
                                  _buildTrackpadMoreButton(
                                    areaSize: trackpadSize,
                                    isInteractive: isInteractive,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildTrackpadClickBar(
                          enabled: trackpadEnabled,
                          glassStyle: isLandscape,
                        ),
                      ],
                    );
                    return trackpadColumn;
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFullscreenPortrait({
    required ThemeData theme,
    required bool isInteractive,
    required EdgeInsets safePadding,
    required Size screenSize,
  }) {
    final safeWidth = screenSize.width - safePadding.left - safePadding.right;
    final safeHeight = screenSize.height - safePadding.top - safePadding.bottom;
    final aspect = _frameSize.height == 0
        ? 1.0
        : _frameSize.width / _frameSize.height;
    final minControlsHeight = 240.0;
    final maxViewHeight = safeHeight - minControlsHeight;
    final rawViewHeight =
        aspect <= 0 ? safeHeight * 0.6 : safeWidth / aspect;
    final viewHeight = maxViewHeight > 0
        ? (rawViewHeight <= maxViewHeight ? rawViewHeight : maxViewHeight)
        : safeHeight * 0.6;
    return Column(
      children: [
        Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: safeWidth,
                height: viewHeight,
                child: _buildVncCanvas(
                  theme: theme,
                  isInteractive: isInteractive,
                  isLandscape: false,
                  safePadding: EdgeInsets.zero,
                  screenSize: screenSize,
                  isFullscreen: true,
                  expandToFit: true,
                  showControls: false,
                ),
              ),
            ),
            Positioned(
              left: 12,
              top: 12,
              child: _VncOverlayIconButton(
                icon: Icons.fullscreen_exit,
                label: 'Exit',
                onPressed: () => _setFullscreen(false),
              ),
            ),
            Positioned(
              right: 12,
              top: 12,
              child: _VncOverlayIconButton(
                icon: Icons.keyboard,
                label: 'Kbd',
                onPressed: _showKeyboardInput,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: _buildFullscreenInputPanel(
              isInteractive: isInteractive,
              isLandscape: false,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFullscreenLandscape({
    required ThemeData theme,
    required bool isInteractive,
    required EdgeInsets safePadding,
    required Size screenSize,
  }) {
    final trackpadEnabled = isInteractive && !_directInputEnabled;
    final overlayOpacity = isInteractive ? 0.8 : 0.5;
    return LayoutBuilder(
      builder: (context, constraints) {
        final areaSize = Size(constraints.maxWidth, constraints.maxHeight);
        final zoomHeight =
            (constraints.maxHeight - 140).clamp(220.0, 360.0);
        _updateTrackpadSize(
          areaSize,
          source: 'fullscreen_landscape_overlay',
        );
        return Stack(
          children: [
            Positioned.fill(
              child: _buildVncCanvas(
                theme: theme,
                isInteractive: isInteractive,
                isLandscape: true,
                safePadding: EdgeInsets.zero,
                screenSize: screenSize,
                isFullscreen: true,
                expandToFit: true,
                showControls: false,
              ),
            ),
            if (trackpadEnabled)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: trackpadEnabled ? (_) {} : null,
                  onPanUpdate: trackpadEnabled ? (_) {} : null,
                  onDoubleTapDown:
                      trackpadEnabled ? _handleTrackpadDoubleTapDown : null,
                  onDoubleTap:
                      trackpadEnabled ? _handleTrackpadDoubleTap : null,
                  onSecondaryTap: () => _sendClick(2),
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _handleTrackpadPointerDown,
                    onPointerMove: _handleTrackpadPointerMove,
                    onPointerHover: _handleTrackpadPointerHover,
                    onPointerUp: _handleTrackpadPointerUp,
                    onPointerCancel: _handleTrackpadPointerCancel,
                    onPointerSignal: _handleTrackpadPointerSignal,
                    onPointerPanZoomUpdate: _handleTrackpadPanZoomUpdate,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            Positioned(
              left: 12 + safePadding.left,
              top: 12 + safePadding.top,
              child: _VncOverlayIconButton(
                icon: Icons.fullscreen_exit,
                label: 'Exit',
                onPressed: () => _setFullscreen(false),
              ),
            ),
            Positioned(
              right: 12 + safePadding.right,
              top: 12 + safePadding.top,
              child: _VncOverlayIconButton(
                icon: Icons.keyboard,
                label: 'Kbd',
                onPressed: _showKeyboardInput,
              ),
            ),
            _buildTrackpadMoreButton(
              areaSize: areaSize,
              isInteractive: isInteractive,
            ),
            Positioned(
              left: 12 + safePadding.left,
              top: 60 + safePadding.top,
              child: Opacity(
                opacity: overlayOpacity,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withAlpha(120),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white.withAlpha(60)),
                  ),
                  child: SizedBox(
                    width: 52,
                    height: zoomHeight,
                    child: _VncZoomBar(
                      value: _zoom,
                      min: _zoomMin,
                      max: _zoomMax,
                      enabled: isInteractive,
                      glassStyle: true,
                      onValueChanged: _updateZoomValue,
                      onValueCommitted: _commitZoomValue,
                      onReset: _resetZoom,
                    ),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16 + safePadding.left,
                    right: 16 + safePadding.right,
                    bottom: 12 + safePadding.bottom,
                  ),
                  child: Opacity(
                    opacity: overlayOpacity,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 240),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.black.withAlpha(110),
                          borderRadius: BorderRadius.circular(12),
                          border:
                              Border.all(color: Colors.white.withAlpha(60)),
                        ),
                        child: _buildTrackpadClickBar(
                          enabled: trackpadEnabled,
                          glassStyle: true,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTrackpadControls({
    required bool isInteractive,
    bool showCalibrationAction = true,
    bool glassStyle = false,
  }) {
    final trackpadEnabled = isInteractive && !_directInputEnabled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '输入模式',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 6),
        ToggleButtons(
          isSelected: [_directInputEnabled == false, _directInputEnabled == true],
          onPressed: isInteractive
              ? (index) {
                  _updateState(() {
                    _directInputEnabled = index == 1;
                  });
                }
              : null,
          borderRadius: BorderRadius.circular(12),
          constraints: const BoxConstraints(minWidth: 96, minHeight: 36),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('触控板'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('直接触摸'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_directInputEnabled)
          Text(
            '提示：直接在 VNC 画面上滑动移动光标（不触发点击）。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF94A3B8),
                ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          height: 200,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 52,
                child: _VncZoomBar(
                  value: _zoom,
                  min: _zoomMin,
                  max: _zoomMax,
                  enabled: isInteractive,
                  glassStyle: glassStyle,
                  onValueChanged: _updateZoomValue,
                  onValueCommitted: _commitZoomValue,
                  onReset: _resetZoom,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, surfaceConstraints) {
                          final trackpadSize = Size(
                            surfaceConstraints.maxWidth,
                            surfaceConstraints.maxHeight,
                          );
                          _updateTrackpadSize(
                            trackpadSize,
                            source: glassStyle ? 'trackpad_glass' : 'trackpad',
                          );
                          return _VncTrackpadSurface(
                            enabled: trackpadEnabled,
                            glassStyle: glassStyle,
                            disabledMessage: _directInputEnabled
                                ? 'Direct touch enabled'
                                : null,
                            onDoubleTapDown: trackpadEnabled
                                ? _handleTrackpadDoubleTapDown
                                : null,
                            onDoubleTap:
                                trackpadEnabled ? _handleTrackpadDoubleTap : null,
                            onPointerDown: _handleTrackpadPointerDown,
                            onPointerMove: _handleTrackpadPointerMove,
                            onPointerHover: _handleTrackpadPointerHover,
                            onPointerUp: _handleTrackpadPointerUp,
                            onPointerCancel: _handleTrackpadPointerCancel,
                            onPointerSignal: _handleTrackpadPointerSignal,
                            onPointerPanZoomUpdate: _handleTrackpadPanZoomUpdate,
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                    _buildTrackpadClickBar(
                      enabled: trackpadEnabled,
                      glassStyle: glassStyle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _buildGestureHints(glassStyle: glassStyle),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          title: const Text('显示调试面板'),
          subtitle: Text(_debugPanelVisible ? '可见' : '隐藏'),
          value: _debugPanelVisible,
          onChanged: isInteractive
              ? (value) {
                  _updateState(() {
                    _debugPanelVisible = value;
                  });
                  unawaited(_persistDebugPanelPreference(value));
                }
              : null,
        ),
        const SizedBox(height: 6),
        SwitchListTile.adaptive(
          title: const Text('显示本地光标'),
          subtitle: const Text('关闭后仅移动远端光标'),
          value: _showLocalCursor,
          onChanged: isInteractive
              ? (value) {
                  _updateState(() {
                    _showLocalCursor = value;
                  });
                  unawaited(_persistLocalCursorPreference(value));
                }
              : null,
        ),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _copyAgentLogs,
              icon: const Icon(Icons.copy),
              label: const Text('复制日志'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _clearAgentLogs,
              child: const Text('清空日志'),
            ),
          ],
        ),
        if (kDebugMode) ...[
          const SizedBox(height: 8),
          SwitchListTile.adaptive(
            title: const Text('光标调试日志'),
            subtitle: const Text('记录光标轨迹/坐标，便于排查偏移'),
            value: _cursorDebugEnabled,
            onChanged: isInteractive
                ? (value) {
                    _updateState(() {
                      _cursorDebugEnabled = value;
                    });
                    if (!value) {
                      _clearCursorDebugLog();
                    } else {
                      _logCursorDebug('debug_enabled', {
                        'enabled': true,
                      }, force: true);
                    }
                  }
                : null,
          ),
          if (_cursorDebugEnabled)
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _copyCursorDebugLog,
                  icon: const Icon(Icons.copy),
                  label: Text('复制日志 (${_cursorDebugLog.length})'),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    _updateState(() {
                      _clearCursorDebugLog();
                    });
                  },
                  child: const Text('清空'),
                ),
              ],
            ),
        ],
        const SizedBox(height: 12),
        Text(
          '视图模式',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: glassStyle ? Colors.white70 : const Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 6),
        ToggleButtons(
          isSelected: [
            _viewMode == VncViewMode.fit,
            _viewMode == VncViewMode.fill,
            _viewMode == VncViewMode.original,
          ],
          onPressed: isInteractive
              ? (index) {
                  _updateState(() {
                    _viewMode = VncViewMode.values[index];
                    _autoSizedOnce = false;
                  });
                  if (_cursorDebugEnabled) {
                    _logCursorDebug(
                      'view_mode',
                      {'mode': _viewMode.name},
                      force: true,
                    );
                  }
                  _requestStreamRefresh(resetAutoResize: true);
                }
              : null,
          borderRadius: BorderRadius.circular(12),
          constraints: const BoxConstraints(minWidth: 84, minHeight: 36),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('适配'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('填满'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('原始'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Theme(
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
          ),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            title: Text(
              '高级选项',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: glassStyle ? Colors.white70 : const Color(0xFF64748B),
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '编码与质量 / 压缩',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: glassStyle ? Colors.white54 : const Color(0xFF94A3B8),
                  ),
            ),
            children: [
              const SizedBox(height: 6),
              Text(
                '编码与质量',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          glassStyle ? Colors.white70 : const Color(0xFF64748B),
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 6),
              SwitchListTile.adaptive(
                title: const Text('低延迟模式'),
                subtitle: const Text('优先响应，可能降低画质'),
                value: _lowLatencyEnabled,
                onChanged: isInteractive ? _setLowLatencyMode : null,
              ),
              SwitchListTile.adaptive(
                title: const Text('高性能模式'),
                subtitle: Text('空闲时也保持高帧率（${_highPerfIntervalMs}ms）'),
                value: _highPerfEnabled,
                onChanged: isInteractive ? _setHighPerfMode : null,
              ),
              if (_highPerfEnabled)
                _CalibrationSlider(
                  label: '高性能采样间隔 (${_highPerfIntervalMs}ms，越小越快)',
                  value: _highPerfIntervalMs.toDouble(),
                  min: 5,
                  max: 10,
                  divisions: 5,
                  enabled: isInteractive,
                  labelColor: glassStyle ? Colors.white70 : null,
                  onChanged: (value) {
                    _updateState(() {
                      _highPerfIntervalMs = value.round().clamp(5, 10);
                    });
                  },
                  onChangeEnd: (value) {
                    if (!isInteractive || !_highPerfEnabled) {
                      return;
                    }
                    final next = value.round().clamp(5, 10);
                    if (next != _highPerfIntervalMs) {
                      _updateState(() {
                        _highPerfIntervalMs = next;
                      });
                    }
                    unawaited(_startStream(preserveExisting: true));
                  },
                ),
              SwitchListTile.adaptive(
                title: const Text('省流模式'),
                subtitle: const Text('空闲时降低同步频率'),
                value: _dataSaverEnabled,
                onChanged: isInteractive ? _setDataSaverMode : null,
              ),
              SwitchListTile.adaptive(
                title: const Text('16-bit 色深'),
                subtitle: const Text('减少带宽，颜色更少'),
                value: _colorDepth == VncColorDepth.depth16,
                onChanged: isInteractive
                    ? (value) {
                        _updateState(() {
                          _colorDepth = value
                              ? VncColorDepth.depth16
                              : VncColorDepth.full;
                          if (value) {
                            _tightJpegEnabled = false;
                            _encodingPreference = VncEncodingPreference.zlib;
                          }
                        });
                        _applyEncodingPreferences();
                        _applyPixelFormatPreference();
                        _requestStreamRefresh(resetAutoResize: true);
                      }
                    : null,
              ),
              DropdownButtonFormField<VncEncodingPreference>(
                value: _encodingPreference,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(
                    value: VncEncodingPreference.zrle,
                    child: Text('ZRLE（默认）'),
                  ),
                  DropdownMenuItem(
                    value: VncEncodingPreference.tight,
                    child: Text('Tight（可调压缩）'),
                  ),
                  DropdownMenuItem(
                    value: VncEncodingPreference.zlib,
                    child: Text('Zlib（兼容）'),
                  ),
                  DropdownMenuItem(
                    value: VncEncodingPreference.raw,
                    child: Text('Raw（无压缩）'),
                  ),
                ],
                onChanged: isInteractive && !_lowLatencyEnabled
                    ? (value) {
                        if (value == null) {
                          return;
                        }
                        _updateState(() {
                          _encodingPreference = value;
                        });
                        _applyEncodingPreferences();
                      }
                    : null,
              ),
              const SizedBox(height: 8),
              _CalibrationSlider(
                label: '压缩级别 (${_tightCompressionLevel})',
                value: _tightCompressionLevel.toDouble(),
                min: 0,
                max: 9,
                enabled: isInteractive && !_lowLatencyEnabled,
                labelColor: glassStyle ? Colors.white70 : null,
                onChanged: (value) {
                  _updateState(() {
                    _tightCompressionLevel = value.round().clamp(0, 9);
                  });
                  _applyEncodingPreferences();
                },
              ),
              if (_encodingPreference == VncEncodingPreference.tight) ...[
                SwitchListTile.adaptive(
                  title: const Text('JPEG 低带宽'),
                  subtitle: const Text('开启后画质会有损'),
                  value: _tightJpegEnabled,
                  onChanged: isInteractive
                      ? (value) {
                          _updateState(() {
                            _tightJpegEnabled = value;
                          });
                          _applyEncodingPreferences();
                        }
                      : null,
                ),
                if (_tightJpegEnabled)
                  _CalibrationSlider(
                    label: 'JPEG 质量 (${_tightQualityLevel})',
                    value: _tightQualityLevel.toDouble(),
                    min: 0,
                    max: 9,
                    enabled: isInteractive,
                    labelColor: glassStyle ? Colors.white70 : null,
                    onChanged: (value) {
                      _updateState(() {
                        _tightQualityLevel = value.round().clamp(0, 9);
                      });
                      _applyEncodingPreferences();
                    },
                  ),
              ],
            ],
          ),
        ),
        if (showCalibrationAction) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () =>
                  _openCalibrationSheet(isInteractive: isInteractive),
              icon: const Icon(Icons.tune),
              label: const Text('校准触控坐标'),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed:
                  isInteractive ? () => unawaited(_resetCalibration()) : null,
              icon: const Icon(Icons.restart_alt),
              label: const Text('重置校准'),
            ),
          ),
          if (_availableDisplays.length > 1) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _openDisplayPicker,
                icon: const Icon(Icons.monitor),
                label: const Text('选择显示器'),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildGestureHints({bool glassStyle = false}) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _VncGestureHint(
          icon: Icons.open_with,
          label: 'Move',
          glassStyle: glassStyle,
        ),
        _VncGestureHint(
          icon: Icons.ads_click,
          label: 'Double tap = Left click',
          glassStyle: glassStyle,
        ),
        _VncGestureHint(
          icon: Icons.mouse,
          label: 'Use buttons to click',
          glassStyle: glassStyle,
        ),
        _VncGestureHint(
          icon: Icons.track_changes,
          label: 'System 2/3-finger gestures',
          glassStyle: glassStyle,
        ),
      ],
    );
  }

  Widget _buildTrackpadClickBar({
    required bool enabled,
    bool glassStyle = false,
  }) {
    final borderColor =
        glassStyle ? Colors.white.withAlpha(60) : const Color(0xFFE2E8F0);
    final background =
        glassStyle ? Colors.white.withAlpha(18) : Colors.white;
    final textColor = glassStyle ? Colors.white : const Color(0xFF0F172A);
    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
        boxShadow: glassStyle
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withAlpha(12),
                  blurRadius: 10,
                  offset: const Offset(0, 6),
                ),
              ],
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              onTap: enabled ? () {} : null,
              onTapDown: enabled ? (_) => _holdButton(1) : null,
              onTapUp: enabled ? (_) => _releaseButton(1) : null,
              onTapCancel: enabled ? () => _releaseButton(1) : null,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(12),
              ),
              child: Center(
                child: Text(
                  '左键',
                  style: TextStyle(
                    color: enabled ? textColor : textColor.withAlpha(120),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          Container(width: 1, color: borderColor),
          Expanded(
            child: InkWell(
              onTap: enabled ? () {} : null,
              onTapDown: enabled ? (_) => _holdButton(2) : null,
              onTapUp: enabled ? (_) => _releaseButton(2) : null,
              onTapCancel: enabled ? () => _releaseButton(2) : null,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(12),
              ),
              child: Center(
                child: Text(
                  '右键',
                  style: TextStyle(
                    color: enabled ? textColor : textColor.withAlpha(120),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openLandscapeControls({required bool isInteractive}) async {
    if (_controlsSheetOpen) {
      return;
    }
    if (!mounted) {
      return;
    }
    _updateState(() {
      _controlsSheetOpen = true;
    });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              0,
              16,
              16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                child: Container(
                  color: Colors.black.withAlpha(140),
                  child: SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: Container(
                              width: 42,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.white.withAlpha(160),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Text(
                                'Controls',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                              ),
                              const Spacer(),
                              if (_isFullscreen)
                                TextButton.icon(
                                  onPressed: () => _setFullscreen(false),
                                  icon: const Icon(Icons.fullscreen_exit),
                                  label: const Text('Exit'),
                                  style: TextButton.styleFrom(
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              IconButton(
                                onPressed: () => Navigator.of(context).maybePop(),
                                icon: const Icon(Icons.close, color: Colors.white),
                                tooltip: 'Close',
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _VncControlAction(
                                icon: Icons.keyboard,
                                label: 'Keyboard',
                                onPressed:
                                    isInteractive ? _showKeyboardInput : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.close,
                                label: 'Esc',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xff1b)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.keyboard_command_key,
                                label: 'Cmd',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xffe7)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.keyboard_tab,
                                label: 'Tab',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xff09)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.keyboard_control_key,
                                label: 'Ctrl',
                                onPressed: isInteractive
                                    ? () => _sendKeyPress(0xffe3)
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.zoom_out_map,
                                label: 'Reset zoom',
                                onPressed: isInteractive ? _resetZoom : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.monitor,
                                label: '显示器',
                                onPressed: _availableDisplays.length > 1
                                    ? _openDisplayPicker
                                    : null,
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.tune,
                                label: '校准',
                                onPressed: () => _openCalibrationSheet(
                                  isInteractive: isInteractive,
                                ),
                                glassStyle: true,
                              ),
                              _VncControlAction(
                                icon: Icons.restart_alt,
                                label: '重置校准',
                                onPressed: () =>
                                    unawaited(_resetCalibration()),
                                glassStyle: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          _buildTrackpadControls(
                            isInteractive: isInteractive,
                            showCalibrationAction: false,
                            glassStyle: true,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    if (!mounted) {
      return;
    }
    _updateState(() {
      _controlsSheetOpen = false;
    });
  }

  Future<void> _openCalibrationSheet({required bool isInteractive}) async {
    if (!mounted) {
      return;
    }
    const maxOffsetNorm = 0.2;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              void updateState(VoidCallback fn) {
                if (mounted) {
                  _updateState(() {
                    fn();
                    _calibrationNormalized = true;
                    _calibrationAspectRatio = _currentAspectRatio();
                    _cameraCenter = _applyInputCalibration(_pointerPosition);
                  });
                  setSheetState(() {});
                  _scheduleCalibrationSave();
                  _sendPointerEvent();
                }
              }

              return SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    20,
                    12,
                    20,
                    16 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 42,
                          height: 4,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE2E8F0),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '输入校准',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: const Color(0xFF0F172A),
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '调节缩放与偏移，让触摸板光标与远端光标对齐。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: const Color(0xFF64748B),
                            ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: isInteractive
                            ? () {
                                Navigator.of(context).maybePop();
                                _startAutoCalibration();
                              }
                            : null,
                        icon: const Icon(Icons.auto_fix_high),
                        label: const Text('自动校准（四点）'),
                      ),
                      const SizedBox(height: 16),
                      _CalibrationSlider(
                        label: 'X 缩放',
                        value: _inputScaleX,
                        min: 0.7,
                        max: 1.3,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputScaleX = value),
                      ),
                      _CalibrationSlider(
                        label: 'Y 缩放',
                        value: _inputScaleY,
                        min: 0.7,
                        max: 1.3,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputScaleY = value),
                      ),
                      _CalibrationSlider(
                        label:
                            'X 偏移 (${(_inputOffsetX * _frameSize.width).round()}px)',
                        value: _inputOffsetX,
                        min: -maxOffsetNorm,
                        max: maxOffsetNorm,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputOffsetX = value),
                      ),
                      _CalibrationSlider(
                        label:
                            'Y 偏移 (${(_inputOffsetY * _frameSize.height).round()}px)',
                        value: _inputOffsetY,
                        min: -maxOffsetNorm,
                        max: maxOffsetNorm,
                        enabled: isInteractive,
                        onChanged: (value) =>
                            updateState(() => _inputOffsetY = value),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('完成'),
                          ),
                          const Spacer(),
                          OutlinedButton.icon(
                            onPressed: isInteractive
                                ? () {
                                    _resetCalibration();
                                    setSheetState(() {});
                                  }
                                : null,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重置'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _openDisplayPicker() async {
    if (!mounted) {
      return;
    }
    if (_availableDisplays.isEmpty) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '选择显示器',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: const Color(0xFF0F172A),
                      ),
                ),
                const SizedBox(height: 12),
                ..._availableDisplays.map((display) {
                  final isSelected = _selectedDisplayIndex == display.index;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(display.label),
                    trailing:
                        isSelected ? const Icon(Icons.check) : const SizedBox(),
                    onTap: () async {
                      _updateState(() {
                        _selectedDisplayIndex = display.index;
                      });
                      final navigator = Navigator.of(context);
                      await _persistDisplaySelection(display.index);
                      await _loadCalibration();
                      if (!mounted) {
                        return;
                      }
                      navigator.maybePop();
                      unawaited(_startStream());
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

}
