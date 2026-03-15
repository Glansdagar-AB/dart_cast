import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/tlv8.dart';
import 'package:test/test.dart';

void main() {
  group('Tlv8', () {
    group('encode()', () {
      test('encodes empty value', () {
        final result = Tlv8.encode([(0x06, <int>[])]);
        expect(result, equals(Uint8List.fromList([0x06, 0x00])));
      });

      test('encodes single byte value', () {
        final result = Tlv8.encode([(0x06, [0x01])]);
        expect(result, equals(Uint8List.fromList([0x06, 0x01, 0x01])));
      });

      test('encodes multiple tags', () {
        final result = Tlv8.encode([
          (0x00, [0x00]),
          (0x06, [0x01]),
        ]);
        expect(
          result,
          equals(Uint8List.fromList([
            0x00, 0x01, 0x00, // Method = PairSetup
            0x06, 0x01, 0x01, // SeqNo = 1
          ])),
        );
      });

      test('splits values longer than 255 bytes', () {
        final longValue = List<int>.generate(300, (i) => i % 256);
        final result = Tlv8.encode([(0x03, longValue)]);

        // First chunk: tag=0x03, length=255, 255 bytes
        expect(result[0], equals(0x03));
        expect(result[1], equals(255));
        expect(result.sublist(2, 2 + 255), equals(longValue.sublist(0, 255)));

        // Second chunk: tag=0x03, length=45, 45 bytes
        expect(result[257], equals(0x03));
        expect(result[258], equals(45));
        expect(result.sublist(259, 259 + 45), equals(longValue.sublist(255)));

        expect(result.length, equals(2 + 255 + 2 + 45));
      });

      test('splits values exactly 255 bytes without extra chunk', () {
        final value = List<int>.generate(255, (i) => i % 256);
        final result = Tlv8.encode([(0x03, value)]);

        expect(result.length, equals(2 + 255));
        expect(result[0], equals(0x03));
        expect(result[1], equals(255));
      });

      test('splits values of 510 bytes into two 255-byte chunks', () {
        final value = List<int>.generate(510, (i) => i % 256);
        final result = Tlv8.encode([(0x03, value)]);

        expect(result.length, equals(2 + 255 + 2 + 255));
      });

      test('splits values of 511 bytes into two 255 + one 1 byte chunks', () {
        final value = List<int>.generate(511, (i) => i % 256);
        final result = Tlv8.encode([(0x03, value)]);

        expect(result.length, equals(2 + 255 + 2 + 255 + 2 + 1));
      });
    });

    group('decode()', () {
      test('decodes empty data', () {
        final result = Tlv8.decode([]);
        expect(result, isEmpty);
      });

      test('decodes single tag with empty value', () {
        final result = Tlv8.decode([0x06, 0x00]);
        expect(result, equals({0x06: <int>[]}));
      });

      test('decodes single tag with value', () {
        final result = Tlv8.decode([0x06, 0x01, 0x03]);
        expect(result, equals({0x06: [0x03]}));
      });

      test('decodes multiple tags', () {
        final result = Tlv8.decode([
          0x00, 0x01, 0x00, // Method
          0x06, 0x01, 0x01, // SeqNo
        ]);
        expect(result, equals({0x00: [0x00], 0x06: [0x01]}));
      });

      test('concatenates consecutive entries with same tag', () {
        final result = Tlv8.decode([
          0x03, 0x02, 0xAA, 0xBB, // PublicKey part 1
          0x03, 0x03, 0xCC, 0xDD, 0xEE, // PublicKey part 2
        ]);
        expect(result, equals({0x03: [0xAA, 0xBB, 0xCC, 0xDD, 0xEE]}));
      });

      test('does not concatenate non-consecutive same tags', () {
        final result = Tlv8.decode([
          0x03, 0x01, 0xAA, // PublicKey
          0x06, 0x01, 0x01, // SeqNo (breaks consecutive)
          0x03, 0x01, 0xBB, // PublicKey again (not consecutive with first)
        ]);
        // The second 0x03 overwrites the first since they're not consecutive
        expect(result[0x03], equals([0xBB]));
        expect(result[0x06], equals([0x01]));
      });

      test('throws on truncated data (missing length byte)', () {
        expect(
          () => Tlv8.decode([0x06]),
          throwsFormatException,
        );
      });

      test('throws on value overflowing data', () {
        expect(
          () => Tlv8.decode([0x06, 0x05, 0x01, 0x02]),
          throwsFormatException,
        );
      });
    });

    group('roundtrip', () {
      test('encode then decode preserves data', () {
        final original = [
          (0x00, [0x00]), // Method = PairSetup
          (0x06, [0x01]), // SeqNo = 1
        ];
        final encoded = Tlv8.encode(original);
        final decoded = Tlv8.decode(encoded);

        expect(decoded[0x00], equals([0x00]));
        expect(decoded[0x06], equals([0x01]));
      });

      test('encode then decode preserves long values', () {
        final longValue = List<int>.generate(384, (i) => i % 256);
        final encoded = Tlv8.encode([(0x03, longValue)]);
        final decoded = Tlv8.decode(encoded);

        expect(decoded[0x03], equals(longValue));
      });

      test('encode then decode handles 16-byte salt', () {
        final salt = List<int>.generate(16, (i) => i + 1);
        final encoded = Tlv8.encode([(Tlv8.tagSalt, salt)]);
        final decoded = Tlv8.decode(encoded);

        expect(decoded[Tlv8.tagSalt], equals(salt));
      });

      test('full pair-setup M1 roundtrip', () {
        final items = [
          (Tlv8.tagMethod, [0x00]), // PairSetup
          (Tlv8.tagSeqNo, [0x01]), // Step 1
        ];
        final encoded = Tlv8.encode(items);
        final decoded = Tlv8.decode(encoded);

        expect(decoded[Tlv8.tagMethod], equals([0x00]));
        expect(decoded[Tlv8.tagSeqNo], equals([0x01]));
      });
    });

    group('encodeMap()', () {
      test('encodes from map', () {
        final result = Tlv8.encodeMap({0x06: [0x01]});
        expect(result, equals(Uint8List.fromList([0x06, 0x01, 0x01])));
      });
    });
  });
}
