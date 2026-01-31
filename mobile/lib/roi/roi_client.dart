import 'dart:async';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'roi_models.dart';
import 'roi_protocol.dart';

abstract class RoiClient {
  Stream<RoiTilePayload> get tiles;

  Future<void> connect(RoiSessionInfo sessionInfo);

  Future<void> disconnect();

  Future<void> requestRoi({
    required double centerX,
    required double centerY,
    required double zoom,
    required double viewportWidth,
    required double viewportHeight,
    required double prefetchRadius,
  });
}

class RoiClientConfig {
  const RoiClientConfig({
    required this.maxTileSize,
    required this.maxDatagramSize,
  });

  final int maxTileSize;
  final int maxDatagramSize;
}

class RoiNoopClient implements RoiClient {
  @override
  Stream<RoiTilePayload> get tiles => const Stream<RoiTilePayload>.empty();

  @override
  Future<void> connect(RoiSessionInfo sessionInfo) async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> requestRoi({
    required double centerX,
    required double centerY,
    required double zoom,
    required double viewportWidth,
    required double viewportHeight,
    required double prefetchRadius,
  }) async {}
}

class RoiTileAssembler {
  final Map<String, _RoiChunkBuffer> _buffers = <String, _RoiChunkBuffer>{};

  RoiTilePayload? addDatagram(Uint8List datagram) {
    final chunk = decodeRoiDatagram(datagram);
    if (chunk == null) {
      return null;
    }
    if (chunk.chunkCount <= 1) {
      return _buildPayload(chunk, chunk.payload);
    }
    final key = '${chunk.frameId}:${chunk.logicalX}:${chunk.logicalY}';
    final buffer = _buffers.putIfAbsent(
      key,
      () => _RoiChunkBuffer(chunk.chunkCount),
    );
    buffer.add(chunk.chunkIndex, chunk.payload);
    if (!buffer.complete) {
      return null;
    }
    _buffers.remove(key);
    final merged = buffer.merge();
    return _buildPayload(chunk, merged);
  }

  RoiTilePayload _buildPayload(RoiTileChunk chunk, Uint8List payload) {
    Uint8List pixels = payload;
    if (chunk.codec == 1) {
      final decoded = ZLibDecoder().decodeBytes(payload);
      pixels = Uint8List.fromList(decoded);
    }
    final key = RoiTileKey(
      x: chunk.logicalX,
      y: chunk.logicalY,
      width: chunk.logicalW,
      height: chunk.logicalH,
      scaleLevel: chunk.scaleLevel,
    );
    return RoiTilePayload(
      key: key,
      frameId: chunk.frameId,
      codec: chunk.codec,
      pixelWidth: chunk.pixelW,
      pixelHeight: chunk.pixelH,
      pixels: pixels,
    );
  }
}

class _RoiChunkBuffer {
  _RoiChunkBuffer(this.expectedCount) : _chunks = List<Uint8List?>.filled(expectedCount, null);

  final int expectedCount;
  final List<Uint8List?> _chunks;

  bool get complete => _chunks.every((chunk) => chunk != null);

  void add(int index, Uint8List payload) {
    if (index < 0 || index >= expectedCount) {
      return;
    }
    _chunks[index] ??= payload;
  }

  Uint8List merge() {
    final total = _chunks.fold<int>(0, (sum, item) => sum + (item?.length ?? 0));
    final merged = Uint8List(total);
    var offset = 0;
    for (final chunk in _chunks) {
      if (chunk == null) {
        continue;
      }
      merged.setRange(offset, offset + chunk.length, chunk);
      offset += chunk.length;
    }
    return merged;
  }
}
