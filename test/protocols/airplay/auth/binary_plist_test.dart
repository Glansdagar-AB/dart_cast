import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/binary_plist.dart';
import 'package:test/test.dart';

void main() {
  group('BinaryPlistEncoder', () {
    test('output starts with bplist00 magic', () {
      final result = BinaryPlistEncoder.encode({'key': 'value'});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
    });

    test('encodes string values', () {
      final result = BinaryPlistEncoder.encode({'name': 'hello'});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // Verify the bytes contain the string "hello" and "name"
      final asString = String.fromCharCodes(result);
      expect(asString, contains('hello'));
      expect(asString, contains('name'));
    });

    test('encodes integer values', () {
      final result = BinaryPlistEncoder.encode({'count': 42});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // The integer 42 should be encoded as 0x10 0x2A (1-byte int)
      expect(result.contains(42), isTrue);
    });

    test('encodes boolean values', () {
      final result =
          BinaryPlistEncoder.encode({'enabled': true, 'disabled': false});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // true = 0x09, false = 0x08
      expect(result.contains(0x09), isTrue);
      expect(result.contains(0x08), isTrue);
    });

    test('encodes double values', () {
      final result = BinaryPlistEncoder.encode({'pi': 3.14});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // 0x23 = float64 marker
      expect(result.contains(0x23), isTrue);
    });

    test('encodes mixed-type dict', () {
      final result = BinaryPlistEncoder.encode({
        'name': 'test',
        'count': 7,
        'ratio': 0.5,
        'active': true,
      });
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // Verify trailer is 32 bytes at the end
      expect(result.length >= 40, isTrue); // 8 header + 32 trailer minimum
    });

    test('trailer has correct structure', () {
      final result = BinaryPlistEncoder.encode({'a': 1});
      final trailerStart = result.length - 32;
      final trailer = ByteData.sublistView(result, trailerStart);

      // Bytes 0-5: unused (zero)
      for (int i = 0; i < 6; i++) {
        expect(trailer.getUint8(i), equals(0),
            reason: 'trailer byte $i should be 0');
      }

      // Byte 6: offset int size (should be >= 1)
      final offsetSize = trailer.getUint8(6);
      expect(offsetSize, greaterThanOrEqualTo(1));

      // Byte 7: object ref size (should be >= 1)
      final objectRefSize = trailer.getUint8(7);
      expect(objectRefSize, greaterThanOrEqualTo(1));

      // Bytes 8-15: number of objects (big-endian uint64)
      final numObjectsHi = trailer.getUint32(8, Endian.big);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      final numObjects = (numObjectsHi << 32) | numObjectsLo;
      // {'a': 1} => dict + 'a' + 1 = 3 objects
      expect(numObjects, equals(3));

      // Bytes 16-23: top object index (should be 0)
      final topHi = trailer.getUint32(16, Endian.big);
      final topLo = trailer.getUint32(20, Endian.big);
      expect(topHi, equals(0));
      expect(topLo, equals(0));

      // Bytes 24-31: offset table offset (should be after header + objects)
      final offsetTableOffsetHi = trailer.getUint32(24, Endian.big);
      final offsetTableOffsetLo = trailer.getUint32(28, Endian.big);
      final offsetTableOffset =
          (offsetTableOffsetHi << 32) | offsetTableOffsetLo;
      expect(offsetTableOffset, greaterThan(8)); // After bplist00 header
      expect(offsetTableOffset, lessThan(result.length - 32)); // Before trailer
    });

    test('encodes SETUP body used in RTSP', () {
      final result = BinaryPlistEncoder.encode({
        'deviceID': 'AA:BB:CC:DD:EE:FF',
        'sessionUUID': '12345678-1234-1234-1234-123456789ABC',
        'timingPort': 0,
        'timingProtocol': 'NTP',
        'isMultiSelectAirPlay': true,
        'groupContainsGroupLeader': false,
        'macAddress': 'AA:BB:CC:DD:EE:FF',
        'model': 'iPhone14,3',
        'name': 'dart_cast',
        'osBuildVersion': '20F66',
        'osName': 'iPhone OS',
        'osVersion': '16.5',
        'sourceVersion': '690.7.1',
      });

      // Verify magic
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Verify it contains expected strings
      final asString = String.fromCharCodes(result);
      expect(asString, contains('deviceID'));
      expect(asString, contains('AA:BB:CC:DD:EE:FF'));
      expect(asString, contains('NTP'));
      expect(asString, contains('dart_cast'));
    });

    test('encodes /play body used in AirPlay', () {
      final result = BinaryPlistEncoder.encode({
        'Content-Location': 'http://example.com/video.m3u8',
        'Start-Position-Seconds': 0.0,
        'uuid': 'abcdef01-2345-6789-abcd-ef0123456789',
        'streamType': 1,
        'mediaType': 'file',
        'volume': 1.0,
        'rate': 1.0,
      });

      // Verify magic
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Verify it contains expected strings
      final asString = String.fromCharCodes(result);
      expect(asString, contains('Content-Location'));
      expect(asString, contains('http://example.com/video.m3u8'));
      expect(asString, contains('mediaType'));
      expect(asString, contains('file'));
    });

    test('encodes large integers correctly', () {
      final result = BinaryPlistEncoder.encode({'big': 100000});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // 100000 > 0xFFFF so needs 4-byte int (marker 0x12)
      expect(result.contains(0x12), isTrue);
    });

    test('encodes zero integer', () {
      final result = BinaryPlistEncoder.encode({'zero': 0});
      expect(result.sublist(0, 8), equals(ascii.encode('bplist00')));
      // 0 fits in 1 byte, marker 0x10
      expect(result.contains(0x10), isTrue);
    });

    test('encodes empty dict', () {
      final result = BinaryPlistEncoder.encode({});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Just 1 object (the empty dict)
      final trailer = ByteData.sublistView(result, result.length - 32);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      expect(numObjectsLo, equals(1));
    });

    test('encodes nested dict', () {
      final result = BinaryPlistEncoder.encode({
        'outer': <String, dynamic>{'inner': 'value'},
      });
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      final asString = String.fromCharCodes(result);
      expect(asString, contains('outer'));
      expect(asString, contains('inner'));
      expect(asString, contains('value'));
    });

    test('encodes unicode strings', () {
      final result = BinaryPlistEncoder.encode({'emoji': '\u00e9\u00e8'});
      expect(ascii.decode(result.sublist(0, 8)), equals('bplist00'));
      // Unicode strings use 0x6N marker
      // Check that we have a 0x62 byte (unicode string, length 2)
      expect(result.contains(0x62), isTrue);
    });

    test('offset table has correct number of entries', () {
      final dict = {'a': 'b', 'c': 1};
      final result = BinaryPlistEncoder.encode(dict);

      final trailer = ByteData.sublistView(result, result.length - 32);
      final offsetSize = trailer.getUint8(6);
      final numObjectsLo = trailer.getUint32(12, Endian.big);
      final offsetTableOffsetLo = trailer.getUint32(28, Endian.big);

      // Offset table should have numObjects entries of offsetSize bytes each
      final expectedOffsetTableSize = numObjectsLo * offsetSize;
      final actualOffsetTableSize =
          result.length - 32 - offsetTableOffsetLo;
      expect(actualOffsetTableSize, equals(expectedOffsetTableSize));
    });
  });
}
