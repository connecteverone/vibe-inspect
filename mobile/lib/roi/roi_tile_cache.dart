import 'roi_models.dart';

class RoiTileCache {
  RoiTileCache({required this.capacity});

  final int capacity;
  final Map<RoiTileKey, RoiTilePayload> _entries =
      <RoiTileKey, RoiTilePayload>{};

  RoiTilePayload? get(RoiTileKey key) {
    final entry = _entries.remove(key);
    if (entry == null) {
      return null;
    }
    _entries[key] = entry;
    return entry;
  }

  void put(RoiTilePayload payload) {
    _entries.remove(payload.key);
    _entries[payload.key] = payload;
    if (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  void clear() {
    _entries.clear();
  }
}
