import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class VncFrame {
  const VncFrame({
    required this.width,
    required this.height,
    required this.pixels,
    required this.format,
  });

  final int width;
  final int height;
  final Uint8List pixels;
  final ui.PixelFormat format;
}

class VncRfbClient {
  VncRfbClient({
    required this.uri,
    required this.onFrame,
    required this.onError,
    this.preferredEncodings,
  });

  final Uri uri;
  final void Function(VncFrame frame) onFrame;
  final void Function(String message) onError;
  final List<int>? preferredEncodings;

  WebSocketChannel? _channel;
  final List<int> _buffer = [];
  Completer<void>? _waiter;
  bool _handshakeComplete = false;
  bool _closed = false;
  int _width = 0;
  int _height = 0;
  int _bytesPerPixel = 4;
  int _depth = 24;
  bool _bigEndian = false;
  bool _trueColour = true;
  int _redMax = 255;
  int _greenMax = 255;
  int _blueMax = 255;
  int _redShift = 16;
  int _greenShift = 8;
  int _blueShift = 0;
  int _cpixelSize = 3;
  bool _cpixel24A = true;
  ui.PixelFormat _format = ui.PixelFormat.bgra8888;
  Uint8List _framebuffer = Uint8List(0);
  List<int> _preferredEncodings = const [];

  static const int _encodingRaw = 0;
  static const int _encodingCopyRect = 1;
  static const int _encodingZlib = 6;
  static const int _encodingTight = 7;
  static const int _encodingZrle = 16;
  static const int _zrleTileSize = 64;

  Future<void> connect() async {
    if (preferredEncodings != null) {
      _preferredEncodings = List<int>.from(preferredEncodings!);
    }
    _channel = WebSocketChannel.connect(uri);
    _channel!.stream.listen(
      _handleMessage,
      onError: (Object error) {
        _closed = true;
        onError('VNC socket error: $error');
      },
      onDone: () {
        _closed = true;
        onError('VNC socket closed.');
      },
    );
    try {
      await _handshake();
      _handshakeComplete = true;
      _sendSetEncodings();
      _sendFramebufferUpdateRequest(incremental: false);
    } catch (error) {
      onError(error.toString());
      rethrow;
    }
  }

  void close() {
    _closed = true;
    _channel?.sink.close();
  }

  void setEncodings(List<int> encodings) {
    _preferredEncodings = List<int>.from(encodings);
    if (_handshakeComplete && !_closed) {
      _sendSetEncodings();
    }
  }

  void requestFullFrame() {
    if (_handshakeComplete && !_closed) {
      _sendFramebufferUpdateRequest(incremental: false);
    }
  }

  void sendPointer({required int x, required int y, required int mask}) {
    final payload = Uint8List(6);
    payload[0] = 5;
    payload[1] = mask & 0xff;
    payload[2] = (x >> 8) & 0xff;
    payload[3] = x & 0xff;
    payload[4] = (y >> 8) & 0xff;
    payload[5] = y & 0xff;
    _sendBinary(payload);
  }

  void sendKey({required bool down, required int keysym}) {
    final payload = Uint8List(8);
    payload[0] = 4;
    payload[1] = down ? 1 : 0;
    payload[4] = (keysym >> 24) & 0xff;
    payload[5] = (keysym >> 16) & 0xff;
    payload[6] = (keysym >> 8) & 0xff;
    payload[7] = keysym & 0xff;
    _sendBinary(payload);
  }

  void sendScroll({required int x, required int y, required int delta}) {
    final mask = delta < 0 ? 0x20 : 0x10;
    sendPointer(x: x, y: y, mask: mask);
    sendPointer(x: x, y: y, mask: 0);
  }

  void sendText(String text) {
    for (final rune in text.runes) {
      sendKey(down: true, keysym: rune);
      sendKey(down: false, keysym: rune);
    }
  }

  void _handleMessage(dynamic message) {
    if (_closed) {
      return;
    }
    if (message is String) {
      final bytes = message.codeUnits;
      _buffer.addAll(bytes);
    } else if (message is List<int>) {
      _buffer.addAll(message);
    }
    _waiter?.complete();
    _waiter = null;
    if (_handshakeComplete) {
      _processServerMessages();
    }
  }

  Future<void> _handshake() async {
    final version = await _readExact(12);
    final versionText = String.fromCharCodes(version);
    if (!versionText.startsWith('RFB')) {
      throw Exception('Invalid VNC server response.');
    }
    _sendBinary(Uint8List.fromList(version));

    final securityCountBytes = await _readExact(1);
    final securityCount = securityCountBytes[0];
    if (securityCount == 0) {
      final reasonLengthBytes = await _readExact(4);
      final reasonLength = (reasonLengthBytes[0] << 24) |
          (reasonLengthBytes[1] << 16) |
          (reasonLengthBytes[2] << 8) |
          reasonLengthBytes[3];
      if (reasonLength > 0) {
        await _readExact(reasonLength);
      }
      throw Exception('VNC server does not support security types.');
    }
    final securityTypes = await _readExact(securityCount);
    if (!securityTypes.contains(1)) {
      throw Exception('VNC server does not support no-auth mode.');
    }
    _sendBinary(Uint8List.fromList([1]));

    final securityResult = await _readExact(4);
    if (securityResult.any((value) => value != 0)) {
      throw Exception('VNC security negotiation failed.');
    }

    _sendBinary(Uint8List.fromList([1]));

    final serverInit = await _readExact(24);
    _width = (serverInit[0] << 8) | serverInit[1];
    _height = (serverInit[2] << 8) | serverInit[3];
    final bitsPerPixel = serverInit[4];
    _depth = serverInit[5];
    _bigEndian = serverInit[6] != 0;
    _trueColour = serverInit[7] != 0;
    _redMax = (serverInit[8] << 8) | serverInit[9];
    _greenMax = (serverInit[10] << 8) | serverInit[11];
    _blueMax = (serverInit[12] << 8) | serverInit[13];
    _redShift = serverInit[14];
    _greenShift = serverInit[15];
    _blueShift = serverInit[16];
    _bytesPerPixel = bitsPerPixel ~/ 8;
    _cpixelSize = _bytesPerPixel;
    _cpixel24A = true;
    if (_trueColour && bitsPerPixel == 32 && _depth <= 24) {
      final rgbLower =
          ((_redMax << _redShift) < (1 << 24)) &&
              ((_greenMax << _greenShift) < (1 << 24)) &&
              ((_blueMax << _blueShift) < (1 << 24));
      final rgbUpper =
          _redShift > 7 && _greenShift > 7 && _blueShift > 7;
      if (rgbLower || rgbUpper) {
        _cpixelSize = 3;
        _cpixel24A = (rgbLower && !_bigEndian) || (rgbUpper && _bigEndian);
      }
    }
    _format = ui.PixelFormat.bgra8888;
    final totalBytes = _width * _height * _bytesPerPixel;
    if (totalBytes <= 0) {
      throw Exception('Invalid VNC framebuffer size.');
    }
    _framebuffer = Uint8List(totalBytes);
    final nameLength = (serverInit[20] << 24) |
        (serverInit[21] << 16) |
        (serverInit[22] << 8) |
        serverInit[23];
    if (nameLength > 0) {
      await _readExact(nameLength);
    }
  }

  void _processServerMessages() {
    while (true) {
      if (_buffer.isEmpty) {
        return;
      }
      final messageType = _buffer[0];
      if (messageType != 0) {
        _buffer.removeAt(0);
        continue;
      }
      if (_buffer.length < 4) {
        return;
      }
      final rectCount = (_buffer[2] << 8) | _buffer[3];
      var offset = 4;
      var updated = false;
      var hasAsyncUpdate = false;
      for (var rect = 0; rect < rectCount; rect += 1) {
        if (_buffer.length < offset + 12) {
          return;
        }
        final x = (_buffer[offset] << 8) | _buffer[offset + 1];
        final y = (_buffer[offset + 2] << 8) | _buffer[offset + 3];
        final width = (_buffer[offset + 4] << 8) | _buffer[offset + 5];
        final height = (_buffer[offset + 6] << 8) | _buffer[offset + 7];
        final encoding = _decodeEncoding(
          (_buffer[offset + 8] << 24) |
              (_buffer[offset + 9] << 16) |
              (_buffer[offset + 10] << 8) |
              _buffer[offset + 11],
        );
        offset += 12;
        if (!_validateRect(x, y, width, height)) {
          onError('Invalid VNC rectangle received.');
          close();
          return;
        }
        Uint8List rectPixels;
        if (encoding == _encodingCopyRect) {
          if (_buffer.length < offset + 4) {
            return;
          }
          final srcX = (_buffer[offset] << 8) | _buffer[offset + 1];
          final srcY = (_buffer[offset + 2] << 8) | _buffer[offset + 3];
          offset += 4;
          if (!_validateRect(srcX, srcY, width, height)) {
            onError('Invalid VNC CopyRect source.');
            close();
            return;
          }
          _copyRect(srcX, srcY, x, y, width, height);
          updated = true;
          continue;
        } else if (encoding == _encodingZrle) {
          if (_buffer.length < offset + 4) {
            return;
          }
          final dataLength = (_buffer[offset] << 24) |
              (_buffer[offset + 1] << 16) |
              (_buffer[offset + 2] << 8) |
              _buffer[offset + 3];
          if (dataLength < 0 || _buffer.length < offset + 4 + dataLength) {
            return;
          }
          final compressed =
              _buffer.sublist(offset + 4, offset + 4 + dataLength);
          Uint8List decoded;
          try {
            decoded = Uint8List.fromList(
              ZLibDecoder().decodeBytes(compressed),
            );
          } catch (error) {
            onError('VNC ZRLE decode failed: $error');
            close();
            return;
          }
          offset += 4 + dataLength;
          Uint8List rectPixels;
          try {
            rectPixels = _decodeZrleRect(
              decoded,
              width,
              height,
            );
          } catch (error) {
            onError('VNC ZRLE parse failed: $error');
            close();
            return;
          }
          _blitRect(rectPixels, x, y, width, height);
          updated = true;
          continue;
        } else if (encoding == _encodingTight) {
          final nextOffset = _tryDecodeTightRect(
            offset,
            x,
            y,
            width,
            height,
          );
          if (nextOffset == null) {
            return;
          }
          offset = nextOffset.nextOffset;
          updated = true;
          if (nextOffset.asyncFrame) {
            hasAsyncUpdate = true;
          }
          continue;
        }
        final bytesNeeded = width * height * _bytesPerPixel;
        if (bytesNeeded <= 0) {
          onError('Invalid VNC rectangle size.');
          close();
          return;
        }
        if (encoding == _encodingRaw) {
          if (_buffer.length < offset + bytesNeeded) {
            return;
          }
          rectPixels = Uint8List.fromList(
            _buffer.sublist(offset, offset + bytesNeeded),
          );
          offset += bytesNeeded;
        } else if (encoding == _encodingZlib) {
          if (_buffer.length < offset + 4) {
            return;
          }
          final dataLength = (_buffer[offset] << 24) |
              (_buffer[offset + 1] << 16) |
              (_buffer[offset + 2] << 8) |
              _buffer[offset + 3];
          if (dataLength < 0 || _buffer.length < offset + 4 + dataLength) {
            return;
          }
          final compressed =
              _buffer.sublist(offset + 4, offset + 4 + dataLength);
          try {
            final decoded = ZLibDecoder().decodeBytes(compressed);
            if (decoded.length < bytesNeeded) {
              onError('VNC zlib frame truncated.');
              close();
              return;
            }
            rectPixels = Uint8List.fromList(decoded);
          } catch (error) {
            onError('VNC zlib decode failed: $error');
            close();
            return;
          }
          offset += 4 + dataLength;
        } else {
          onError('Unsupported VNC encoding: $encoding');
          close();
          return;
        }
        _blitRect(rectPixels, x, y, width, height);
        updated = true;
      }
      _buffer.removeRange(0, offset);
      if (updated && !hasAsyncUpdate) {
        onFrame(
          VncFrame(
            width: _width,
            height: _height,
            pixels: Uint8List.fromList(_framebuffer),
            format: _format,
          ),
        );
      }
      _sendFramebufferUpdateRequest(incremental: true);
    }
  }

  int _decodeEncoding(int value) {
    if (value & 0x80000000 != 0) {
      return value - 0x100000000;
    }
    return value;
  }

  bool _validateRect(int x, int y, int width, int height) {
    if (x < 0 || y < 0 || width <= 0 || height <= 0) {
      return false;
    }
    if (x + width > _width || y + height > _height) {
      return false;
    }
    final bytesNeeded = width * height * _bytesPerPixel;
    if (bytesNeeded <= 0 || bytesNeeded > _framebuffer.length) {
      return false;
    }
    return true;
  }

  void _blitRect(Uint8List rectPixels, int x, int y, int width, int height) {
    final sourceStride = width * _bytesPerPixel;
    for (var row = 0; row < height; row += 1) {
      final srcStart = row * sourceStride;
      final dstStart = ((y + row) * _width + x) * _bytesPerPixel;
      _framebuffer.setRange(
        dstStart,
        dstStart + sourceStride,
        rectPixels,
        srcStart,
      );
    }
  }

  void _copyRect(int srcX, int srcY, int dstX, int dstY, int width, int height) {
    final rowStride = width * _bytesPerPixel;
    for (var row = 0; row < height; row += 1) {
      final srcStart = ((srcY + row) * _width + srcX) * _bytesPerPixel;
      final dstStart = ((dstY + row) * _width + dstX) * _bytesPerPixel;
      final slice = _framebuffer.sublist(srcStart, srcStart + rowStride);
      _framebuffer.setRange(dstStart, dstStart + rowStride, slice);
    }
  }

  _TightDecodeResult? _tryDecodeTightRect(
    int offset,
    int x,
    int y,
    int width,
    int height,
  ) {
    var cursor = offset;
    if (_buffer.length < cursor + 1) {
      return null;
    }
    final control = _buffer[cursor++];
    final compressionType = control >> 4;
    final hasExplicitFilter = (control & 0x40) != 0;

    if (compressionType == 0x08) {
      if (_buffer.length < cursor + _cpixelSize) {
        return null;
      }
      final packed = _readPackedCpixelFromBuffer(cursor);
      cursor += _cpixelSize;
      final rectPixels = Uint8List(width * height * _bytesPerPixel);
      for (var row = 0; row < height; row += 1) {
        var outIndex = row * width * _bytesPerPixel;
        for (var col = 0; col < width; col += 1) {
          _writePackedPixel(rectPixels, outIndex, packed);
          outIndex += _bytesPerPixel;
        }
      }
      _blitRect(rectPixels, x, y, width, height);
      return _TightDecodeResult(cursor, false);
    }

    if (compressionType == 0x09) {
      final lengthResult = _readCompactLength(cursor);
      if (lengthResult == null) {
        return null;
      }
      cursor = lengthResult.nextOffset;
      if (_buffer.length < cursor + lengthResult.length) {
        return null;
      }
      final jpegData = Uint8List.fromList(
        _buffer.sublist(cursor, cursor + lengthResult.length),
      );
      cursor += lengthResult.length;
      _decodeTightJpegRect(jpegData, x, y, width, height);
      return _TightDecodeResult(cursor, true);
    }

    if (compressionType > 0x07) {
      onError('Unsupported Tight compression type: $compressionType');
      close();
      return _TightDecodeResult(cursor, false);
    }

    var filterId = 0;
    if (hasExplicitFilter) {
      if (_buffer.length < cursor + 1) {
        return null;
      }
      filterId = _buffer[cursor++];
    }

    List<int>? palette;
    var expectedLen = 0;
    var monoBitmap = false;
    if (hasExplicitFilter && filterId == 1) {
      if (_buffer.length < cursor + 1) {
        return null;
      }
      final paletteSize = _buffer[cursor++] + 1;
      final paletteBytes = paletteSize * _cpixelSize;
      if (_buffer.length < cursor + paletteBytes) {
        return null;
      }
      final paletteRaw =
          Uint8List.fromList(_buffer.sublist(cursor, cursor + paletteBytes));
      cursor += paletteBytes;
      palette = List<int>.filled(paletteSize, 0);
      var palOffset = 0;
      for (var i = 0; i < paletteSize; i += 1) {
        palette[i] = _readPackedCpixel(paletteRaw, palOffset);
        palOffset += _cpixelSize;
      }
      if (paletteSize == 2) {
        final bytesPerRow = (width + 7) >> 3;
        expectedLen = bytesPerRow * height;
        monoBitmap = true;
      } else {
        expectedLen = width * height;
      }
    } else if (hasExplicitFilter && filterId != 0) {
      onError('Unsupported Tight filter: $filterId');
      close();
      return _TightDecodeResult(cursor, false);
    } else {
      expectedLen = width * height * _cpixelSize;
    }

    Uint8List payload;
    if (expectedLen < 12) {
      if (_buffer.length < cursor + expectedLen) {
        return null;
      }
      payload = Uint8List.fromList(_buffer.sublist(cursor, cursor + expectedLen));
      cursor += expectedLen;
    } else {
      final lengthResult = _readCompactLength(cursor);
      if (lengthResult == null) {
        return null;
      }
      cursor = lengthResult.nextOffset;
      if (_buffer.length < cursor + lengthResult.length) {
        return null;
      }
      final rawData = Uint8List.fromList(
        _buffer.sublist(cursor, cursor + lengthResult.length),
      );
      cursor += lengthResult.length;
      try {
        payload = Uint8List.fromList(ZLibDecoder().decodeBytes(rawData));
      } catch (error) {
        if (rawData.length == expectedLen) {
          payload = rawData;
        } else {
          onError('VNC Tight zlib decode failed: $error');
          close();
          return _TightDecodeResult(cursor, false);
        }
      }
    }

    if (payload.length < expectedLen) {
      onError('VNC Tight payload truncated.');
      close();
      return _TightDecodeResult(cursor, false);
    }

    final rectPixels = Uint8List(width * height * _bytesPerPixel);
    if (palette != null) {
      if (monoBitmap) {
        final bytesPerRow = (width + 7) >> 3;
        for (var row = 0; row < height; row += 1) {
          final rowStart = row * bytesPerRow;
          for (var col = 0; col < width; col += 1) {
            final byte = payload[rowStart + (col >> 3)];
            final bit = (byte >> (7 - (col & 7))) & 0x01;
            final packed = palette[bit];
            final outIndex =
                ((row * width) + col) * _bytesPerPixel;
            _writePackedPixel(rectPixels, outIndex, packed);
          }
        }
      } else {
        final totalPixels = width * height;
        for (var i = 0; i < totalPixels; i += 1) {
          final index = payload[i];
          final paletteIndex =
              index < palette.length ? index : 0;
          final packed = palette[paletteIndex];
          final outIndex = i * _bytesPerPixel;
          _writePackedPixel(rectPixels, outIndex, packed);
        }
      }
    } else {
      final totalPixels = width * height;
      var srcOffset = 0;
      for (var i = 0; i < totalPixels; i += 1) {
        final packed = _readPackedCpixel(payload, srcOffset);
        _writePackedPixel(rectPixels, i * _bytesPerPixel, packed);
        srcOffset += _cpixelSize;
      }
    }

      _blitRect(rectPixels, x, y, width, height);
    return _TightDecodeResult(cursor, false);
  }

  _CompactLength? _readCompactLength(int offset) {
    var cursor = offset;
    var result = 0;
    var shift = 0;
    for (var i = 0; i < 3; i += 1) {
      if (_buffer.length <= cursor) {
        return null;
      }
      final byte = _buffer[cursor++];
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        return _CompactLength(result, cursor);
      }
      shift += 7;
    }
    return _CompactLength(result, cursor);
  }

  int _readPackedCpixelFromBuffer(int offset) {
    if (_cpixelSize == 4) {
      if (_bigEndian) {
        final a = _buffer[offset];
        final r = _buffer[offset + 1];
        final g = _buffer[offset + 2];
        final b = _buffer[offset + 3];
        return (a << 24) | (r << 16) | (g << 8) | b;
      }
      final b = _buffer[offset];
      final g = _buffer[offset + 1];
      final r = _buffer[offset + 2];
      final a = _buffer[offset + 3];
      return (a << 24) | (r << 16) | (g << 8) | b;
    }
    if (_bigEndian) {
      final r = _buffer[offset];
      final g = _buffer[offset + 1];
      final b = _buffer[offset + 2];
      return (0xff << 24) | (r << 16) | (g << 8) | b;
    }
    if (_cpixel24A) {
      final b = _buffer[offset];
      final g = _buffer[offset + 1];
      final r = _buffer[offset + 2];
      return (0xff << 24) | (r << 16) | (g << 8) | b;
    }
    final b = _buffer[offset];
    final g = _buffer[offset + 1];
    final r = _buffer[offset + 2];
    return (0xff << 24) | (r << 16) | (g << 8) | b;
  }

  void _decodeTightJpegRect(
    Uint8List jpegData,
    int x,
    int y,
    int width,
    int height,
  ) {
    if (_closed) {
      return;
    }
    ui.decodeImageFromList(jpegData, (image) async {
      if (_closed) {
        image.dispose();
        return;
      }
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (byteData == null) {
        image.dispose();
        return;
      }
      final rgba = byteData.buffer.asUint8List();
      final rectPixels = Uint8List(width * height * _bytesPerPixel);
      var src = 0;
      var dst = 0;
      final totalPixels = width * height;
      for (var i = 0; i < totalPixels; i += 1) {
        final r = rgba[src];
        final g = rgba[src + 1];
        final b = rgba[src + 2];
        final a = rgba[src + 3];
        rectPixels[dst] = b;
        rectPixels[dst + 1] = g;
        rectPixels[dst + 2] = r;
        rectPixels[dst + 3] = a;
        src += 4;
        dst += 4;
      }
      _blitRect(rectPixels, x, y, width, height);
      onFrame(
        VncFrame(
          width: _width,
          height: _height,
          pixels: Uint8List.fromList(_framebuffer),
          format: _format,
        ),
      );
      image.dispose();
    });
  }

  Uint8List _decodeZrleRect(Uint8List data, int width, int height) {
    final bytesPerPixel = _bytesPerPixel;
    final output = Uint8List(width * height * bytesPerPixel);
    var offset = 0;
    for (var tileY = 0; tileY < height; tileY += _zrleTileSize) {
      final remainingH = height - tileY;
      final tileH = remainingH < _zrleTileSize ? remainingH : _zrleTileSize;
      for (var tileX = 0; tileX < width; tileX += _zrleTileSize) {
        final remainingW = width - tileX;
        final tileW = remainingW < _zrleTileSize ? remainingW : _zrleTileSize;
        if (offset >= data.length) {
          throw Exception('ZRLE data truncated.');
        }
        final sub = data[offset++];
        if (sub == 0) {
          final tilePixels = tileW * tileH;
          for (var i = 0; i < tilePixels; i += 1) {
            if (offset + _cpixelSize > data.length) {
              throw Exception('ZRLE raw tile truncated.');
            }
            final packed = _readPackedCpixel(data, offset);
            offset += _cpixelSize;
            final localX = i % tileW;
            final localY = i ~/ tileW;
            final outIndex =
                ((tileY + localY) * width + tileX + localX) * bytesPerPixel;
            _writePackedPixel(output, outIndex, packed);
          }
          continue;
        }
        if (sub == 1) {
          if (offset + _cpixelSize > data.length) {
            throw Exception('ZRLE solid tile truncated.');
          }
          final packed = _readPackedCpixel(data, offset);
          offset += _cpixelSize;
          for (var y = 0; y < tileH; y += 1) {
            var outIndex = ((tileY + y) * width + tileX) * bytesPerPixel;
            for (var x = 0; x < tileW; x += 1) {
              _writePackedPixel(output, outIndex, packed);
              outIndex += bytesPerPixel;
            }
          }
          continue;
        }
        if (sub >= 2 && sub <= 16) {
          final paletteSize = sub;
          final palette = List<int>.filled(paletteSize, 0);
          for (var i = 0; i < paletteSize; i += 1) {
            if (offset + _cpixelSize > data.length) {
              throw Exception('ZRLE palette truncated.');
            }
            palette[i] = _readPackedCpixel(data, offset);
            offset += _cpixelSize;
          }
          final bitsPerPixel = paletteSize == 2
              ? 1
              : paletteSize <= 4
                  ? 2
                  : 4;
          final bytesPerRow = ((tileW * bitsPerPixel) + 7) >> 3;
          final mask = (1 << bitsPerPixel) - 1;
          for (var row = 0; row < tileH; row += 1) {
            if (offset + bytesPerRow > data.length) {
              throw Exception('ZRLE palette row truncated.');
            }
            final rowStart = offset;
            var bitPos = 0;
            for (var col = 0; col < tileW; col += 1) {
              final byteIndex = rowStart + (bitPos >> 3);
              final shift = 8 - bitsPerPixel - (bitPos & 7);
              final index = (data[byteIndex] >> shift) & mask;
              final packed = palette[index];
              final outIndex =
                  ((tileY + row) * width + tileX + col) * bytesPerPixel;
              _writePackedPixel(output, outIndex, packed);
              bitPos += bitsPerPixel;
            }
            offset += bytesPerRow;
          }
          continue;
        }
        if (sub == 128) {
          final totalPixels = tileW * tileH;
          var pos = 0;
          while (pos < totalPixels) {
            if (offset + _cpixelSize > data.length) {
              throw Exception('ZRLE RLE tile truncated.');
            }
            final packed = _readPackedCpixel(data, offset);
            offset += _cpixelSize;
            var run = 1;
            while (true) {
              if (offset >= data.length) {
                throw Exception('ZRLE RLE length truncated.');
              }
              final len = data[offset++];
              run += len;
              if (len < 255) {
                break;
              }
            }
            for (var i = 0; i < run && pos < totalPixels; i += 1) {
              final localX = pos % tileW;
              final localY = pos ~/ tileW;
              final outIndex =
                  ((tileY + localY) * width + tileX + localX) * bytesPerPixel;
              _writePackedPixel(output, outIndex, packed);
              pos += 1;
            }
          }
          continue;
        }
        if (sub >= 129) {
          final paletteSize = sub & 0x7f;
          final palette = List<int>.filled(paletteSize, 0);
          for (var i = 0; i < paletteSize; i += 1) {
            if (offset + _cpixelSize > data.length) {
              throw Exception('ZRLE RLE palette truncated.');
            }
            palette[i] = _readPackedCpixel(data, offset);
            offset += _cpixelSize;
          }
          final totalPixels = tileW * tileH;
          var pos = 0;
          while (pos < totalPixels) {
            if (offset >= data.length) {
              throw Exception('ZRLE palette data truncated.');
            }
            final header = data[offset++];
            var index = header & 0x7f;
            var run = 1;
            if (header & 0x80 != 0) {
              while (true) {
                if (offset >= data.length) {
                  throw Exception('ZRLE palette run truncated.');
                }
                final len = data[offset++];
                run += len;
                if (len < 255) {
                  break;
                }
              }
            }
            final packed = palette[index];
            for (var i = 0; i < run && pos < totalPixels; i += 1) {
              final localX = pos % tileW;
              final localY = pos ~/ tileW;
              final outIndex =
                  ((tileY + localY) * width + tileX + localX) * bytesPerPixel;
              _writePackedPixel(output, outIndex, packed);
              pos += 1;
            }
          }
          continue;
        }
        throw Exception('ZRLE unsupported subencoding: $sub');
      }
    }
    return output;
  }

  int _readPackedCpixel(Uint8List data, int offset) {
    if (_cpixelSize == 4) {
      if (_bigEndian) {
        final a = data[offset];
        final r = data[offset + 1];
        final g = data[offset + 2];
        final b = data[offset + 3];
        return (a << 24) | (r << 16) | (g << 8) | b;
      }
      final b = data[offset];
      final g = data[offset + 1];
      final r = data[offset + 2];
      final a = data[offset + 3];
      return (a << 24) | (r << 16) | (g << 8) | b;
    }
    if (_bigEndian) {
      final r = data[offset];
      final g = data[offset + 1];
      final b = data[offset + 2];
      return (0xff << 24) | (r << 16) | (g << 8) | b;
    }
    if (_cpixel24A) {
      final b = data[offset];
      final g = data[offset + 1];
      final r = data[offset + 2];
      return (0xff << 24) | (r << 16) | (g << 8) | b;
    }
    final b = data[offset];
    final g = data[offset + 1];
    final r = data[offset + 2];
    return (0xff << 24) | (r << 16) | (g << 8) | b;
  }

  void _writePackedPixel(Uint8List buffer, int index, int packed) {
    buffer[index] = packed & 0xff;
    buffer[index + 1] = (packed >> 8) & 0xff;
    buffer[index + 2] = (packed >> 16) & 0xff;
    buffer[index + 3] = (packed >> 24) & 0xff;
  }

  Future<List<int>> _readExact(int length) async {
    while (_buffer.length < length) {
      if (_closed) {
        throw Exception('VNC connection closed.');
      }
      _waiter = Completer<void>();
      await _waiter!.future;
    }
    final data = _buffer.sublist(0, length);
    _buffer.removeRange(0, length);
    return data;
  }

  void _sendSetEncodings() {
    final encodings = _preferredEncodings.isNotEmpty
        ? _preferredEncodings
        : [
            _encodingZrle,
            _encodingTight,
            _encodingZlib,
            _encodingCopyRect,
            _encodingRaw
          ];
    final payload = Uint8List(4 + encodings.length * 4);
    payload[0] = 2;
    payload[2] = (encodings.length >> 8) & 0xff;
    payload[3] = encodings.length & 0xff;
    var offset = 4;
    for (final encoding in encodings) {
      payload[offset] = (encoding >> 24) & 0xff;
      payload[offset + 1] = (encoding >> 16) & 0xff;
      payload[offset + 2] = (encoding >> 8) & 0xff;
      payload[offset + 3] = encoding & 0xff;
      offset += 4;
    }
    _sendBinary(payload);
  }

  void _sendFramebufferUpdateRequest({required bool incremental}) {
    final payload = Uint8List(10);
    payload[0] = 3;
    payload[1] = incremental ? 1 : 0;
    payload[6] = (_width >> 8) & 0xff;
    payload[7] = _width & 0xff;
    payload[8] = (_height >> 8) & 0xff;
    payload[9] = _height & 0xff;
    _sendBinary(payload);
  }

  void _sendBinary(Uint8List payload) {
    if (_closed) {
      return;
    }
    _channel?.sink.add(payload);
  }
}

class _CompactLength {
  const _CompactLength(this.length, this.nextOffset);

  final int length;
  final int nextOffset;
}

class _TightDecodeResult {
  const _TightDecodeResult(this.nextOffset, this.asyncFrame);

  final int nextOffset;
  final bool asyncFrame;
}
