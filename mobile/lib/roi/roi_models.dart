import 'dart:typed_data';

class RoiSessionInfo {
  RoiSessionInfo({
    required this.sessionId,
    required this.token,
    required this.quicPort,
    required this.framebufferWidth,
    required this.framebufferHeight,
    required this.screenWidth,
    required this.screenHeight,
    required this.issuedAt,
  });

  final String sessionId;
  final String token;
  final int quicPort;
  final int framebufferWidth;
  final int framebufferHeight;
  final int screenWidth;
  final int screenHeight;
  final int issuedAt;

  factory RoiSessionInfo.fromPayload(Map<String, dynamic> payload) {
    final sessionId = payload['session_id']?.toString() ?? '';
    final token = payload['token']?.toString() ?? '';
    final quicPort = int.tryParse(payload['quic_port']?.toString() ?? '') ?? 0;
    final framebufferWidth =
        int.tryParse(payload['framebuffer_width']?.toString() ?? '') ?? 0;
    final framebufferHeight =
        int.tryParse(payload['framebuffer_height']?.toString() ?? '') ?? 0;
    final screenWidth =
        int.tryParse(payload['screen_width']?.toString() ?? '') ?? 0;
    final screenHeight =
        int.tryParse(payload['screen_height']?.toString() ?? '') ?? 0;
    final issuedAt =
        int.tryParse(payload['issued_at']?.toString() ?? '') ?? 0;
    if (sessionId.isEmpty || token.isEmpty || quicPort <= 0) {
      throw const FormatException('ROI session response missing fields.');
    }
    return RoiSessionInfo(
      sessionId: sessionId,
      token: token,
      quicPort: quicPort,
      framebufferWidth: framebufferWidth,
      framebufferHeight: framebufferHeight,
      screenWidth: screenWidth,
      screenHeight: screenHeight,
      issuedAt: issuedAt,
    );
  }
}

class RoiTileKey {
  const RoiTileKey({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.scaleLevel,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final int scaleLevel;

  @override
  bool operator ==(Object other) {
    return other is RoiTileKey &&
        other.x == x &&
        other.y == y &&
        other.width == width &&
        other.height == height &&
        other.scaleLevel == scaleLevel;
  }

  @override
  int get hashCode => Object.hash(x, y, width, height, scaleLevel);
}

class RoiTilePayload {
  RoiTilePayload({
    required this.key,
    required this.frameId,
    required this.codec,
    required this.pixelWidth,
    required this.pixelHeight,
    required this.pixels,
  });

  final RoiTileKey key;
  final int frameId;
  final int codec;
  final int pixelWidth;
  final int pixelHeight;
  final Uint8List pixels;
}
