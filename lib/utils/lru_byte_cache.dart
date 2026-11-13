import 'dart:collection';

/// Least-recently-used cache bounded by entry count and total payload bytes.
class LruByteCache<K, V> {
  LruByteCache({
    required this.maxEntries,
    required this.maxBytes,
    required this.sizeOf,
    this.pressureThreshold = 0.8,
  }) : assert(maxEntries > 0),
       assert(maxBytes > 0);

  final int maxEntries;
  final int maxBytes;
  final int Function(V value) sizeOf;
  final double pressureThreshold;

  final LinkedHashMap<K, V> _entries = LinkedHashMap<K, V>();
  int _bytes = 0;

  int get length => _entries.length;
  int get currentBytes => _bytes;
  bool get isEmpty => _entries.isEmpty;
  Iterable<K> get keys => _entries.keys;
  Iterable<MapEntry<K, V>> get entries => _entries.entries;

  /// Returns [key] and promotes it to most-recently used.
  V? get(K key) {
    final value = _entries.remove(key);
    if (value == null) return null;
    _entries[key] = value;
    return value;
  }

  /// Returns [key] without changing recency.
  V? peek(K key) => _entries[key];

  bool containsKey(K key) => _entries.containsKey(key);

  /// Inserts [value], replacing any previous entry for [key], then evicts
  /// oldest items until both bounds hold. Values larger than [maxBytes] are
  /// dropped.
  void put(K key, V value) {
    remove(key);
    final size = sizeOf(value);
    if (size > maxBytes) return;
    _entries[key] = value;
    _bytes += size;
    evictToBounds();
  }

  V? remove(K key) {
    final removed = _entries.remove(key);
    if (removed != null) _bytes -= sizeOf(removed);
    return removed;
  }

  void removeWhere(bool Function(K key, V value) test) {
    final doomed = <K>[];
    for (final entry in _entries.entries) {
      if (test(entry.key, entry.value)) doomed.add(entry.key);
    }
    for (final key in doomed) {
      remove(key);
    }
  }

  /// Evicts until count and bytes sit at or below [maxEntries] / [maxBytes].
  void evictToBounds() {
    while (_entries.isNotEmpty &&
        (_entries.length > maxEntries || _bytes > maxBytes)) {
      remove(_entries.keys.first);
    }
  }

  /// Evicts preferred items first, then oldest, down to 75% of the caps.
  void evictUnderPressure({bool Function(K key, V value)? prefer}) {
    final targetBytes = (maxBytes * 0.75).round();
    final targetCount = (maxEntries * 0.75).round();
    if (prefer != null) {
      final preferred = <K>[];
      for (final entry in _entries.entries) {
        if (prefer(entry.key, entry.value)) preferred.add(entry.key);
      }
      for (final key in preferred) {
        if (_bytes <= targetBytes && _entries.length <= targetCount) return;
        remove(key);
      }
    }
    while (_entries.isNotEmpty &&
        (_bytes > targetBytes || _entries.length > targetCount)) {
      remove(_entries.keys.first);
    }
  }

  bool get isUnderPressure =>
      _entries.length > (maxEntries * pressureThreshold) ||
      _bytes > (maxBytes * pressureThreshold);

  void clear() {
    _entries.clear();
    _bytes = 0;
  }
}
