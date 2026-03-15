import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/hap_credentials.dart';
import 'package:test/test.dart';

void main() {
  group('HapCredentials', () {
    late HapCredentials credentials;

    setUp(() {
      credentials = HapCredentials(
        clientPrivateKey: Uint8List.fromList(List.generate(64, (i) => i)),
        clientPublicKey: Uint8List.fromList(List.generate(32, (i) => i + 100)),
        clientId: 'test-client-id',
        devicePublicKey: Uint8List.fromList(List.generate(32, (i) => i + 200)),
        deviceId: 'test-device-id',
      );
    });

    group('toJson / fromJson', () {
      test('roundtrip preserves all fields', () {
        final json = credentials.toJson();
        final restored = HapCredentials.fromJson(json);

        expect(restored.clientPrivateKey, equals(credentials.clientPrivateKey));
        expect(restored.clientPublicKey, equals(credentials.clientPublicKey));
        expect(restored.clientId, equals('test-client-id'));
        expect(restored.devicePublicKey, equals(credentials.devicePublicKey));
        expect(restored.deviceId, equals('test-device-id'));
      });

      test('toJson produces hex strings', () {
        final json = credentials.toJson();
        expect(json['clientId'], equals('test-client-id'));
        expect(json['deviceId'], equals('test-device-id'));
        // Hex encoded keys
        expect(json['clientPublicKey'], isA<String>());
        expect(json['clientPrivateKey'], isA<String>());
        expect(json['devicePublicKey'], isA<String>());
      });
    });

    group('serialize / deserialize', () {
      test('roundtrip preserves all fields', () {
        final serialized = credentials.serialize();
        final restored = HapCredentials.deserialize(serialized);

        expect(restored.clientPrivateKey, equals(credentials.clientPrivateKey));
        expect(restored.clientPublicKey, equals(credentials.clientPublicKey));
        expect(restored.clientId, equals('test-client-id'));
        expect(restored.devicePublicKey, equals(credentials.devicePublicKey));
        expect(restored.deviceId, equals('test-device-id'));
      });

      test('serialized format uses pipes', () {
        final serialized = credentials.serialize();
        final parts = serialized.split('|');
        expect(parts.length, equals(5));
      });

      test('deserialize throws on invalid format', () {
        expect(
          () => HapCredentials.deserialize('only|two|parts'),
          throwsFormatException,
        );
      });
    });

    group('toString', () {
      test('includes identifiers', () {
        final str = credentials.toString();
        expect(str, contains('test-client-id'));
        expect(str, contains('test-device-id'));
      });
    });
  });
}
