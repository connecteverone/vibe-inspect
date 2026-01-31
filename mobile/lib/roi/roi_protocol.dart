import 'dart:typed_data';

const int roiDatagramHeaderSize = 28;
const String roiDatagramMagic = 'ROI1';

class RoiTileChunk {
  RoiTileChunk({
    required this.frameId,
    required this.logicalX,
    required this.logicalY,
    required this.logicalW,
    required this.logicalH,
    required this.pixelW,
    required this.pixelH,
    required this.scaleLevel,
    required this.codec,
    required this.chunkIndex,
    required this.chunkCount,
    required this.payload,
  });

  final int frameId;
  final int logicalX;
  final int logicalY;
  final int logicalW;
  final int logicalH;
  final int pixelW;
  final int pixelH;
  final int scaleLevel;
  final int codec;
  final int chunkIndex;
  final int chunkCount;
  final Uint8List payload;
}

RoiTileChunk? decodeRoiDatagram(Uint8List data) {
  if (data.length < roiDatagramHeaderSize) {
    return null;
  }
  final magic = String.fromCharCodes(data.sublist(0, 4));
  if (magic != roiDatagramMagic) {
    return null;
  }
  final view = ByteData.sublistView(data);
  final frameId = view.getUint32(4, Endian.little);
  final logicalX = view.getUint16(8, Endian.little);
  final logicalY = view.getUint16(10, Endian.little);
  final logicalW = view.getUint16(12, Endian.little);
  final logicalH = view.getUint16(14, Endian.little);
  final pixelW = view.getUint16(16, Endian.little);
  final pixelH = view.getUint16(18, Endian.little);
  final scaleLevel = data[20];
  final codec = data[21];
  final chunkIndex = view.getUint16(22, Endian.little);
  final chunkCount = view.getUint16(24, Endian.little);
  final payloadLen = view.getUint16(26, Endian.little);
  if (roiDatagramHeaderSize + payloadLen > data.length) {
    return null;
  }
  final payload = Uint8List.sublistView(
    data,
    roiDatagramHeaderSize,
    roiDatagramHeaderSize + payloadLen,
  );
  return RoiTileChunk(
    frameId: frameId,
    logicalX: logicalX,
    logicalY: logicalY,
    logicalW: logicalW,
    logicalH: logicalH,
    pixelW: pixelW,
    pixelH: pixelH,
    scaleLevel: scaleLevel,
    codec: codec,
    chunkIndex: chunkIndex,
    chunkCount: chunkCount,
    payload: payload,
  );
}
