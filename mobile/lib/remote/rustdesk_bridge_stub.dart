import 'dart:typed_data';
import 'dart:ui';

class RustdeskBridge {
  RustdeskBridge._();

  static final RustdeskBridge instance = RustdeskBridge._();

  void ensureLoaded() {}

  void ensureInitialized() {}

  bool connectQuic({
    required String host,
    required int port,
    required String remoteSessionId,
    required String token,
    String serverName = 'vibe-inspect',
    String? authToken,
    String? clientId,
    String? clientName,
  }) {
    return false;
  }

  void disconnectQuic() {}

  bool setToggleOption(String sessionId, String name, bool enabled) {
    return false;
  }

  Offset? getCursorPosition(String sessionId) {
    return null;
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
  }) {}

  void sessionInputString(String sessionId, String value) {}

  bool sessionAdd({
    required String sessionId,
    required String peerId,
    required String password,
  }) {
    return false;
  }

  bool sessionStart(String sessionId) {
    return false;
  }

  bool sessionSwitchDisplay(String sessionId, int display) {
    return false;
  }

  bool sessionLogin(String sessionId, String password) {
    return false;
  }

  bool sessionBootstrap(String sessionId, String password, int display) {
    return false;
  }

  void sessionClose(String sessionId) {}

  Size? getDisplaySize(String sessionId, int display) {
    return null;
  }

  void setDisplaySize(String sessionId, int display, Size size) {}

  int getRgbaSize(String sessionId, int display) {
    return 0;
  }

  Uint8List? copyRgba(String sessionId, int display) {
    return null;
  }

  bool sendMouse(String sessionId, Map<String, dynamic> payload) {
    return false;
  }
}
