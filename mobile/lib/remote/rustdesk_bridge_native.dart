import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

const bool _kDirectOnly = bool.fromEnvironment(
  'DIRECT_ONLY',
  defaultValue: true,
);

class RustdeskBridge {
  RustdeskBridge._();

  static final RustdeskBridge instance = RustdeskBridge._();

  static const _defaultServerName = 'vibe-inspect';

  bool _loaded = false;
  bool _initialized = false;
  late DynamicLibrary _lib;

  late final int Function(Pointer<Utf8>, Pointer<Utf8>) _mainInit;
  void Function(int)? _setDirectOnly;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
  _sessionAdd;
  late final int Function(Pointer<Utf8>) _sessionStartNoUi;
  late final void Function(Pointer<Utf8>) _sessionClose;
  late final int Function(
    Pointer<Utf8>,
    int,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _quicConnect;
  late final void Function() _quicDisconnect;
  late final int Function(Pointer<Utf8>, int, Pointer<Uint32>, Pointer<Uint32>)
  _sessionGetDisplaySize;
  late final void Function(Pointer<Utf8>, int, int, int) _sessionSetSize;
  late final int Function(Pointer<Utf8>, int) _sessionGetRgbaSize;
  late final Pointer<Uint8> Function(Pointer<Utf8>, int) _sessionGetRgba;
  late final void Function(Pointer<Utf8>, int) _sessionNextRgba;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>) _sessionSendMouse;
  late final int Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    int,
    int,
    int,
    int,
    int,
    int,
  )
  _sessionInputKey;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>) _sessionInputString;
  late final int Function(Pointer<Utf8>, int) _sessionSwitchDisplay;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>) _sessionLogin;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, int) _sessionBootstrap;
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, int)
  _sessionSetToggleOption;
  late final int Function(Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>)
  _sessionGetCursorPosition;
  late final Pointer<Int32> _cursorXPtr;
  late final Pointer<Int32> _cursorYPtr;

  void ensureLoaded() {
    if (_loaded || kIsWeb) {
      return;
    }
    _lib = _openLibrary();
    _setDirectOnly = _lookupSetDirectOnly();
    _mainInit = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('rustdesk_main_init');
    _sessionAdd = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
        >('rustdesk_session_add');
    _sessionStartNoUi = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>),
          int Function(Pointer<Utf8>)
        >('rustdesk_session_start_no_ui');
    _sessionClose = _lib
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('rustdesk_session_close');
    _quicConnect = _lib
        .lookupFunction<
          Int32 Function(
            Pointer<Utf8>,
            Uint16,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          int Function(
            Pointer<Utf8>,
            int,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('rustdesk_quic_connect');
    _quicDisconnect = _lib.lookupFunction<Void Function(), void Function()>(
      'rustdesk_quic_disconnect',
    );
    _sessionGetDisplaySize = _lib
        .lookupFunction<
          Int32 Function(
            Pointer<Utf8>,
            IntPtr,
            Pointer<Uint32>,
            Pointer<Uint32>,
          ),
          int Function(Pointer<Utf8>, int, Pointer<Uint32>, Pointer<Uint32>)
        >('rustdesk_session_get_display_size');
    _sessionSetSize = _lib
        .lookupFunction<
          Void Function(Pointer<Utf8>, IntPtr, Uint32, Uint32),
          void Function(Pointer<Utf8>, int, int, int)
        >('rustdesk_session_set_size');
    _sessionGetRgbaSize = _lib
        .lookupFunction<
          IntPtr Function(Pointer<Utf8>, IntPtr),
          int Function(Pointer<Utf8>, int)
        >('rustdesk_session_get_rgba_size');
    _sessionGetRgba = _lib
        .lookupFunction<
          Pointer<Uint8> Function(Pointer<Utf8>, IntPtr),
          Pointer<Uint8> Function(Pointer<Utf8>, int)
        >('session_get_rgba');
    _sessionNextRgba = _lib
        .lookupFunction<
          Void Function(Pointer<Utf8>, IntPtr),
          void Function(Pointer<Utf8>, int)
        >('rustdesk_session_next_rgba');
    _sessionSendMouse = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('rustdesk_session_send_mouse');
    _sessionInputKey = _lib
        .lookupFunction<
          Int32 Function(
            Pointer<Utf8>,
            Pointer<Utf8>,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
            Int32,
          ),
          int Function(
            Pointer<Utf8>,
            Pointer<Utf8>,
            int,
            int,
            int,
            int,
            int,
            int,
          )
        >('rustdesk_session_input_key');
    _sessionInputString = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('rustdesk_session_input_string');
    _sessionSwitchDisplay = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)
        >('rustdesk_session_switch_display');
    _sessionLogin = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
          int Function(Pointer<Utf8>, Pointer<Utf8>)
        >('rustdesk_session_login');
    _sessionBootstrap = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, Pointer<Utf8>, int)
        >('rustdesk_session_bootstrap');
    _sessionSetToggleOption = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, Pointer<Utf8>, int)
        >('rustdesk_session_set_toggle_option');
    _sessionGetCursorPosition = _lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>),
          int Function(Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>)
        >('rustdesk_session_get_cursor_position');
    _cursorXPtr = malloc.allocate<Int32>(sizeOf<Int32>());
    _cursorYPtr = malloc.allocate<Int32>(sizeOf<Int32>());
    _loaded = true;
  }

  void ensureInitialized() {
    ensureLoaded();
    if (_initialized || kIsWeb) {
      return;
    }
    final appDir = Directory.systemTemp.path;
    final appDirPtr = appDir.toNativeUtf8();
    final configPtr = ''.toNativeUtf8();
    try {
      _setDirectOnly?.call(_kDirectOnly ? 1 : 0);
      final result = _mainInit(appDirPtr, configPtr);
      if (result != 0) {
        String message;
        switch (result) {
          case -2:
            message = 'RustDesk build missing hardware decode support.';
            break;
          case -3:
            message = 'No hardware H264/H265 decoder available on this device.';
            break;
          default:
            message = 'RustDesk init failed (code=$result).';
        }
        throw StateError(message);
      }
      _initialized = true;
    } finally {
      malloc.free(appDirPtr);
      malloc.free(configPtr);
    }
  }

  bool connectQuic({
    required String host,
    required int port,
    required String remoteSessionId,
    required String token,
    String serverName = _defaultServerName,
    String? authToken,
    String? clientId,
    String? clientName,
  }) {
    ensureInitialized();
    if (kIsWeb) {
      return false;
    }
    final hostPtr = host.toNativeUtf8();
    final serverPtr = serverName.toNativeUtf8();
    final sessionPtr = remoteSessionId.toNativeUtf8();
    final tokenPtr = token.toNativeUtf8();
    final authPtr = _nullableUtf8(authToken);
    final clientIdPtr = _nullableUtf8(clientId);
    final clientNamePtr = _nullableUtf8(clientName);
    try {
      final result = _quicConnect(
        hostPtr,
        port,
        serverPtr,
        sessionPtr,
        tokenPtr,
        authPtr ?? nullptr,
        clientIdPtr ?? nullptr,
        clientNamePtr ?? nullptr,
      );
      return result == 0;
    } finally {
      malloc.free(hostPtr);
      malloc.free(serverPtr);
      malloc.free(sessionPtr);
      malloc.free(tokenPtr);
      if (authPtr != null) {
        malloc.free(authPtr);
      }
      if (clientIdPtr != null) {
        malloc.free(clientIdPtr);
      }
      if (clientNamePtr != null) {
        malloc.free(clientNamePtr);
      }
    }
  }

  void disconnectQuic() {
    if (!_loaded || kIsWeb) {
      return;
    }
    _quicDisconnect();
  }

  bool setToggleOption(String sessionId, String name, bool enabled) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return false;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    final namePtr = name.toNativeUtf8();
    try {
      final result = _sessionSetToggleOption(
        sessionPtr,
        namePtr,
        enabled ? 1 : 0,
      );
      return result == 0;
    } finally {
      malloc.free(sessionPtr);
      malloc.free(namePtr);
    }
  }

  Offset? getCursorPosition(String sessionId) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return null;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      final result = _sessionGetCursorPosition(
        sessionPtr,
        _cursorXPtr,
        _cursorYPtr,
      );
      if (result != 1) {
        return null;
      }
      return Offset(_cursorXPtr.value.toDouble(), _cursorYPtr.value.toDouble());
    } finally {
      malloc.free(sessionPtr);
    }
  }

  void sessionInputKey(
    String sessionId, {
    required String name,
    bool down = false,
    bool press = true,
    bool alt = false,
    bool ctrl = false,
    bool shift = false,
    bool command = false,
  }) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    final namePtr = name.toNativeUtf8();
    try {
      _sessionInputKey(
        sessionPtr,
        namePtr,
        down ? 1 : 0,
        press ? 1 : 0,
        alt ? 1 : 0,
        ctrl ? 1 : 0,
        shift ? 1 : 0,
        command ? 1 : 0,
      );
    } finally {
      malloc.free(sessionPtr);
      malloc.free(namePtr);
    }
  }

  void sessionInputString(String sessionId, String value) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    try {
      _sessionInputString(sessionPtr, valuePtr);
    } finally {
      malloc.free(sessionPtr);
      malloc.free(valuePtr);
    }
  }

  bool sessionAdd({
    required String sessionId,
    required String peerId,
    required String password,
  }) {
    ensureInitialized();
    final sessionPtr = sessionId.toNativeUtf8();
    final peerPtr = peerId.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();
    try {
      return _sessionAdd(sessionPtr, peerPtr, passwordPtr) == 0;
    } finally {
      malloc.free(sessionPtr);
      malloc.free(peerPtr);
      malloc.free(passwordPtr);
    }
  }

  bool sessionStart(String sessionId) {
    ensureInitialized();
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      return _sessionStartNoUi(sessionPtr) == 0;
    } finally {
      malloc.free(sessionPtr);
    }
  }

  bool sessionSwitchDisplay(String sessionId, int display) {
    ensureInitialized();
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      return _sessionSwitchDisplay(sessionPtr, display) == 0;
    } finally {
      malloc.free(sessionPtr);
    }
  }

  bool sessionLogin(String sessionId, String password) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return false;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();
    try {
      return _sessionLogin(sessionPtr, passwordPtr) == 0;
    } finally {
      malloc.free(sessionPtr);
      malloc.free(passwordPtr);
    }
  }

  bool sessionBootstrap(String sessionId, String password, int display) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return false;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    final passwordPtr = password.toNativeUtf8();
    try {
      return _sessionBootstrap(sessionPtr, passwordPtr, display) == 0;
    } finally {
      malloc.free(sessionPtr);
      malloc.free(passwordPtr);
    }
  }

  void sessionClose(String sessionId) {
    if (!_loaded || kIsWeb) {
      return;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      _sessionClose(sessionPtr);
    } finally {
      malloc.free(sessionPtr);
    }
  }

  Size? getDisplaySize(String sessionId, int display) {
    if (!_loaded || kIsWeb) {
      return null;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    final widthPtr = calloc<Uint32>();
    final heightPtr = calloc<Uint32>();
    try {
      final result = _sessionGetDisplaySize(
        sessionPtr,
        display,
        widthPtr,
        heightPtr,
      );
      if (result != 0) {
        return null;
      }
      return Size(widthPtr.value.toDouble(), heightPtr.value.toDouble());
    } finally {
      malloc.free(sessionPtr);
      calloc.free(widthPtr);
      calloc.free(heightPtr);
    }
  }

  void setDisplaySize(String sessionId, int display, Size size) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      _sessionSetSize(
        sessionPtr,
        display,
        size.width.round(),
        size.height.round(),
      );
    } finally {
      malloc.free(sessionPtr);
    }
  }

  int getRgbaSize(String sessionId, int display) {
    if (!_loaded || kIsWeb) {
      return 0;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      return _sessionGetRgbaSize(sessionPtr, display);
    } finally {
      malloc.free(sessionPtr);
    }
  }

  Uint8List? copyRgba(String sessionId, int display) {
    if (!_loaded || kIsWeb) {
      return null;
    }
    final size = getRgbaSize(sessionId, display);
    if (size <= 0) {
      return null;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    try {
      final ptr = _sessionGetRgba(sessionPtr, display);
      if (ptr == nullptr) {
        return null;
      }
      final bytes = ptr.asTypedList(size);
      final copy = Uint8List.fromList(bytes);
      _sessionNextRgba(sessionPtr, display);
      return copy;
    } finally {
      malloc.free(sessionPtr);
    }
  }

  bool sendMouse(String sessionId, Map<String, dynamic> payload) {
    ensureLoaded();
    if (!_loaded || kIsWeb) {
      return false;
    }
    final sessionPtr = sessionId.toNativeUtf8();
    final msgPtr = jsonEncode(payload).toNativeUtf8();
    try {
      return _sessionSendMouse(sessionPtr, msgPtr) == 0;
    } finally {
      malloc.free(sessionPtr);
      malloc.free(msgPtr);
    }
  }

  void Function(int)? _lookupSetDirectOnly() {
    try {
      return _lib.lookupFunction<Void Function(Int32), void Function(int)>(
        'rustdesk_set_direct_only',
      );
    } catch (_) {
      return null;
    }
  }

  Pointer<Utf8>? _nullableUtf8(String? value) {
    if (value == null || value.isEmpty) {
      return null;
    }
    return value.toNativeUtf8();
  }

  DynamicLibrary _openLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('librustdesk.so');
    }
    return DynamicLibrary.process();
  }
}
