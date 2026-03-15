import 'dart:convert';
import 'dart:typed_data';

/// Encodes Dart objects into Apple binary plist format (`bplist00`).
///
/// Supports: [String], [int], [double], [bool], `null`,
/// [Map<String, dynamic>] (dict), and [List] (array).
///
/// The binary plist format consists of:
/// 1. Header: `bplist00` (8 bytes)
/// 2. Object table: serialized objects
/// 3. Offset table: byte offsets to each object
/// 4. Trailer: 32 bytes of metadata
///
/// Reference: Apple's binary plist specification and Python's `plistlib`.
class BinaryPlistEncoder {
  /// Encodes a [Map<String, dynamic>] as Apple binary plist format.
  ///
  /// Returns a [Uint8List] starting with the `bplist00` magic bytes.
  static Uint8List encode(Map<String, dynamic> dict) {
    final encoder = BinaryPlistEncoder._();
    return encoder._encode(dict);
  }

  BinaryPlistEncoder._();

  /// Flattened list of all objects in order of their reference index.
  final List<Object?> _objects = [];

  /// Maps objects to their reference indices to enable deduplication.
  /// Keys are identity-based for non-primitive types.
  final Map<Object, int> _objectRefs = {};

  /// Assigns a reference index to [obj], recursively flattening dicts/lists.
  ///
  /// Returns the reference index for [obj].
  int _flatten(Object? obj) {
    // Booleans, null — use sentinel objects for dedup
    if (obj == null) {
      return _addObject(null);
    }
    if (obj is bool) {
      // Booleans are singletons, safe to use identity
      final existing = _objectRefs[obj];
      if (existing != null) return existing;
      return _addObject(obj);
    }
    if (obj is int) {
      // Small ints could be deduped but for simplicity just add
      return _addObject(obj);
    }
    if (obj is double) {
      return _addObject(obj);
    }
    if (obj is String) {
      return _addObject(obj);
    }
    if (obj is Map<String, dynamic>) {
      // Add the dict object first to get its index, then flatten children.
      final refIndex = _addObject(obj);
      // Flatten all keys and values so they get indices.
      for (final entry in obj.entries) {
        _flatten(entry.key);
        _flatten(entry.value);
      }
      return refIndex;
    }
    if (obj is List) {
      final refIndex = _addObject(obj);
      for (final item in obj) {
        _flatten(item);
      }
      return refIndex;
    }
    throw ArgumentError('Unsupported plist type: ${obj.runtimeType}');
  }

  int _addObject(Object? obj) {
    final index = _objects.length;
    _objects.add(obj);
    if (obj != null) {
      _objectRefs[obj] = index;
    }
    return index;
  }

  Uint8List _encode(Map<String, dynamic> rootDict) {
    // Phase 1: Flatten all objects to get reference indices.
    _objects.clear();
    _objectRefs.clear();
    _flatten(rootDict);

    final numObjects = _objects.length;

    // Determine object ref size (bytes needed to encode a ref index).
    final objectRefSize = _bytesNeeded(numObjects);

    // Phase 2: Serialize each object and record offsets.
    final objectData = BytesBuilder(copy: false);
    final offsets = <int>[];

    // Write header: bplist00
    objectData.add(ascii.encode('bplist00'));

    for (int i = 0; i < numObjects; i++) {
      offsets.add(objectData.length);
      _writeObject(_objects[i], objectData, objectRefSize);
    }

    // Phase 3: Write offset table.
    final offsetTableOffset = objectData.length;
    final offsetSize = _bytesNeeded(offsetTableOffset);

    for (final offset in offsets) {
      objectData.add(_encodeUnsignedInt(offset, offsetSize));
    }

    // Phase 4: Write trailer (32 bytes).
    final trailer = ByteData(32);
    // Bytes 0-5: unused (zero)
    trailer.setUint8(6, offsetSize); // byte 6: offset int size
    trailer.setUint8(7, objectRefSize); // byte 7: object ref size
    // Bytes 8-15: number of objects (big-endian uint64)
    _setUint64BE(trailer, 8, numObjects);
    // Bytes 16-23: top object index (0, big-endian uint64)
    _setUint64BE(trailer, 16, 0);
    // Bytes 24-31: offset table offset (big-endian uint64)
    _setUint64BE(trailer, 24, offsetTableOffset);

    objectData.add(trailer.buffer.asUint8List());

    return Uint8List.fromList(objectData.toBytes());
  }

  /// Serializes a single object into the byte builder.
  void _writeObject(
      Object? obj, BytesBuilder builder, int objectRefSize) {
    if (obj == null) {
      builder.addByte(0x00); // null
      return;
    }
    if (obj is bool) {
      builder.addByte(obj ? 0x09 : 0x08);
      return;
    }
    if (obj is int) {
      _writeInt(obj, builder);
      return;
    }
    if (obj is double) {
      _writeReal(obj, builder);
      return;
    }
    if (obj is String) {
      _writeString(obj, builder);
      return;
    }
    if (obj is Map<String, dynamic>) {
      _writeDict(obj, builder, objectRefSize);
      return;
    }
    if (obj is List) {
      _writeArray(obj, builder, objectRefSize);
      return;
    }
    throw ArgumentError('Unsupported plist type: ${obj.runtimeType}');
  }

  /// Writes an integer object.
  ///
  /// Format: 0x1N where N is log2(byte_count).
  /// Encodes as the smallest power-of-2 byte count that fits.
  void _writeInt(int value, BytesBuilder builder) {
    if (value >= 0 && value < 0x100) {
      builder.addByte(0x10); // 1-byte int
      builder.addByte(value & 0xFF);
    } else if (value >= 0 && value < 0x10000) {
      builder.addByte(0x11); // 2-byte int
      final bd = ByteData(2);
      bd.setUint16(0, value, Endian.big);
      builder.add(bd.buffer.asUint8List());
    } else if (value >= 0 && value < 0x100000000) {
      builder.addByte(0x12); // 4-byte int
      final bd = ByteData(4);
      bd.setUint32(0, value, Endian.big);
      builder.add(bd.buffer.asUint8List());
    } else {
      builder.addByte(0x13); // 8-byte int
      final bd = ByteData(8);
      // Dart int is 64-bit on VM, but ByteData has no setInt64 with big-endian
      // that handles negative values portably. Use two 32-bit writes.
      bd.setUint32(0, (value >> 32) & 0xFFFFFFFF, Endian.big);
      bd.setUint32(4, value & 0xFFFFFFFF, Endian.big);
      builder.add(bd.buffer.asUint8List());
    }
  }

  /// Writes a float64 (real) object.
  ///
  /// Format: 0x23 followed by 8-byte big-endian IEEE 754 double.
  void _writeReal(double value, BytesBuilder builder) {
    builder.addByte(0x23); // 8-byte float
    final bd = ByteData(8);
    bd.setFloat64(0, value, Endian.big);
    builder.add(bd.buffer.asUint8List());
  }

  /// Writes a string object.
  ///
  /// Uses ASCII (0x5N) if the string is pure ASCII, otherwise Unicode (0x6N).
  /// If length >= 15, writes 0xNF followed by an encoded int length.
  void _writeString(String value, BytesBuilder builder) {
    final isAscii = value.codeUnits.every((c) => c < 128);

    if (isAscii) {
      final bytes = ascii.encode(value);
      _writeSizeHeader(0x50, bytes.length, builder);
      builder.add(bytes);
    } else {
      // UTF-16 BE encoding
      final codeUnits = value.codeUnits;
      _writeSizeHeader(0x60, codeUnits.length, builder);
      final bd = ByteData(codeUnits.length * 2);
      for (int i = 0; i < codeUnits.length; i++) {
        bd.setUint16(i * 2, codeUnits[i], Endian.big);
      }
      builder.add(bd.buffer.asUint8List());
    }
  }

  /// Writes a dict object.
  ///
  /// Format: 0xDN (N = count) followed by N key refs then N value refs.
  void _writeDict(
      Map<String, dynamic> dict, BytesBuilder builder, int objectRefSize) {
    _writeSizeHeader(0xD0, dict.length, builder);

    // Write key references first, then value references.
    for (final key in dict.keys) {
      final keyRef = _objectRefs[key]!;
      builder.add(_encodeUnsignedInt(keyRef, objectRefSize));
    }
    for (final value in dict.values) {
      final valueRef = _objectRefs[value]!;
      builder.add(_encodeUnsignedInt(valueRef, objectRefSize));
    }
  }

  /// Writes an array object.
  ///
  /// Format: 0xAN (N = count) followed by N object refs.
  void _writeArray(List list, BytesBuilder builder, int objectRefSize) {
    _writeSizeHeader(0xA0, list.length, builder);

    for (final item in list) {
      final itemRef = _objectRefs[item]!;
      builder.add(_encodeUnsignedInt(itemRef, objectRefSize));
    }
  }

  /// Writes a type+size header byte.
  ///
  /// If [size] < 15, it is packed into the low nibble of the marker byte.
  /// If [size] >= 15, the low nibble is 0xF and the size follows as an int.
  void _writeSizeHeader(int markerHighNibble, int size, BytesBuilder builder) {
    if (size < 15) {
      builder.addByte(markerHighNibble | size);
    } else {
      builder.addByte(markerHighNibble | 0x0F);
      _writeInt(size, builder);
    }
  }

  /// Encodes an unsigned integer into exactly [byteCount] bytes (big-endian).
  static Uint8List _encodeUnsignedInt(int value, int byteCount) {
    final bytes = Uint8List(byteCount);
    for (int i = byteCount - 1; i >= 0; i--) {
      bytes[i] = value & 0xFF;
      value >>= 8;
    }
    return bytes;
  }

  /// Returns the minimum number of bytes needed to represent [value].
  static int _bytesNeeded(int value) {
    if (value <= 0xFF) return 1;
    if (value <= 0xFFFF) return 2;
    if (value <= 0xFFFFFFFF) return 4;
    return 8;
  }

  /// Sets a big-endian uint64 at [offset] in [bd].
  static void _setUint64BE(ByteData bd, int offset, int value) {
    bd.setUint32(offset, (value >> 32) & 0xFFFFFFFF, Endian.big);
    bd.setUint32(offset + 4, value & 0xFFFFFFFF, Endian.big);
  }
}
