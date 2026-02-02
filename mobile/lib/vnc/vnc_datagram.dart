import 'dart:collection';
import 'dart:typed_data';

const int vncDatagramHeaderSize = 22;
const String vncDatagramMagic = 'VQC1';
const int vncDatagramVersion = 1;

const int vncChannelVideoDelta = 1;
const int vncChannelVideoKeyframe = 2;
const int vncChannelRoiTile = 3;

const int vncFlagKeyframe = 1 << 0;
const int vncFlagCompressed = 1 << 1;
const int vncFlagHasFec = 1 << 2;

const int vncCodecRfb = 0;
const int vncCodecZlib = 1;
const int vncCodecTight = 2;
const int vncCodecH264 = 3;
const int vncCodecH265 = 4;
const int vncCodecAv1 = 5;

class VncDatagramChunk {
  VncDatagramChunk({
    required this.version,
    required this.channel,
    required this.flags,
    required this.codec,
    required this.seq,
    required this.frameId,
    required this.chunkIndex,
    required this.chunkCount,
    required this.payload,
  });

  final int version;
  final int channel;
  final int flags;
  final int codec;
  final int seq;
  final int frameId;
  final int chunkIndex;
  final int chunkCount;
  final Uint8List payload;
}

VncDatagramChunk? decodeVncDatagram(Uint8List data) {
  if (data.length < vncDatagramHeaderSize) {
    return null;
  }
  final magic = String.fromCharCodes(data.sublist(0, 4));
  if (magic != vncDatagramMagic) {
    return null;
  }
  final view = ByteData.sublistView(data);
  final version = data[4];
  final channel = data[5];
  final flags = data[6];
  final codec = data[7];
  final seq = view.getUint32(8, Endian.little);
  final frameId = view.getUint32(12, Endian.little);
  final chunkIndex = view.getUint16(16, Endian.little);
  final chunkCount = view.getUint16(18, Endian.little);
  final payloadLen = view.getUint16(20, Endian.little);
  if (chunkCount == 0 || payloadLen == 0 || payloadLen > data.length - vncDatagramHeaderSize) {
    return null;
  }
  final payload = Uint8List.sublistView(
    data,
    vncDatagramHeaderSize,
    vncDatagramHeaderSize + payloadLen,
  );
  return VncDatagramChunk(
    version: version,
    channel: channel,
    flags: flags,
    codec: codec,
    seq: seq,
    frameId: frameId,
    chunkIndex: chunkIndex,
    chunkCount: chunkCount,
    payload: payload,
  );
}

class VncDatagramAssembler {
  VncDatagramAssembler({this.maxFrames = 64});

  final int maxFrames;
  final Map<String, _VncChunkBuffer> _buffers = <String, _VncChunkBuffer>{};
  final Queue<String> _order = Queue<String>();

  Uint8List? addDatagram(Uint8List datagram) {
    final chunk = decodeVncDatagram(datagram);
    if (chunk == null || chunk.version != vncDatagramVersion) {
      return null;
    }
    if (chunk.chunkCount <= 1) {
      return Uint8List.fromList(chunk.payload);
    }
    final key = '${chunk.seq}:${chunk.frameId}:${chunk.channel}';
    final buffer = _buffers.putIfAbsent(
      key,
      () {
        _order.addLast(key);
        _evictIfNeeded();
        return _VncChunkBuffer(chunk.chunkCount);
      },
    );
    buffer.add(chunk.chunkIndex, chunk.payload);
    if (!buffer.complete) {
      return null;
    }
    _buffers.remove(key);
    _order.remove(key);
    return buffer.merge();
  }

  void _evictIfNeeded() {
    while (_order.length > maxFrames) {
      final key = _order.removeFirst();
      _buffers.remove(key);
    }
  }
}

class _VncChunkBuffer {
  _VncChunkBuffer(this.expectedCount) : _chunks = List<Uint8List?>.filled(expectedCount, null);

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
