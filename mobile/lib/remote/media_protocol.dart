import 'dart:typed_data';

enum VideoCodec {
  rawRgba(0),
  h264(1),
  h265(2),
  av1(3);

  const VideoCodec(this.id);
  final int id;

  static VideoCodec? fromId(int id) {
    for (final codec in VideoCodec.values) {
      if (codec.id == id) return codec;
    }
    return null;
  }
}

class VideoFrameHeader {
  static const int size = 2 + 1 + 1 + 4 + 8 + 1 + 2 + 2 + 2 + 2 + 2 + 2 + 4;

  VideoFrameHeader({
    required this.version,
    required this.flags,
    required this.seq,
    required this.timestampMs,
    required this.codec,
    required this.width,
    required this.height,
    required this.roiX,
    required this.roiY,
    required this.roiW,
    required this.roiH,
    required this.payloadLen,
  });

  final int version;
  final int flags;
  final int seq;
  final int timestampMs;
  final VideoCodec codec;
  final int width;
  final int height;
  final int roiX;
  final int roiY;
  final int roiW;
  final int roiH;
  final int payloadLen;

  bool get isKeyframe => (flags & 0x01) != 0;
  bool get hasRoi => (flags & 0x02) != 0;
  bool get isZlib => (flags & 0x04) != 0;

  static VideoFrameHeader? tryParse(Uint8List bytes) {
    if (bytes.length < size) return null;
    final data = ByteData.sublistView(bytes);
    if (data.getUint8(0) != 0x56 || data.getUint8(1) != 0x32) {
      return null;
    }
    final version = data.getUint8(2);
    final flags = data.getUint8(3);
    final seq = data.getUint32(4, Endian.big);
    final ts = data.getUint64(8, Endian.big);
    final codec = VideoCodec.fromId(data.getUint8(16));
    if (codec == null) return null;
    final width = data.getUint16(17, Endian.big);
    final height = data.getUint16(19, Endian.big);
    final roiX = data.getUint16(21, Endian.big);
    final roiY = data.getUint16(23, Endian.big);
    final roiW = data.getUint16(25, Endian.big);
    final roiH = data.getUint16(27, Endian.big);
    final payloadLen = data.getUint32(29, Endian.big);
    return VideoFrameHeader(
      version: version,
      flags: flags,
      seq: seq,
      timestampMs: ts,
      codec: codec,
      width: width,
      height: height,
      roiX: roiX,
      roiY: roiY,
      roiW: roiW,
      roiH: roiH,
      payloadLen: payloadLen,
    );
  }
}
