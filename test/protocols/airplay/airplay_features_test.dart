import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:test/test.dart';

void main() {
  group('AirPlayFeatures', () {
    group('parsing', () {
      test('parses single-part hex string', () {
        final f = AirPlayFeatures.parse('0x5A7FFFF7');
        expect(f.rawValue, equals(0x5A7FFFF7));
      });
      test('parses two-part hex string (lower,upper)', () {
        final f = AirPlayFeatures.parse('0x5A7FFFF7,0x1E');
        expect(f.rawValue, equals((0x1E << 32) | 0x5A7FFFF7));
      });
      test('handles 0x0', () {
        final f = AirPlayFeatures.parse('0x0');
        expect(f.rawValue, equals(0));
        expect(f.supportsVideo, isFalse);
      });
      test('handles empty string', () {
        final f = AirPlayFeatures.parse('');
        expect(f.rawValue, equals(0));
      });
      test('handles malformed input', () {
        final f = AirPlayFeatures.parse('not-hex');
        expect(f.rawValue, equals(0));
      });
      test('case insensitive', () {
        final f1 = AirPlayFeatures.parse('0xAB');
        final f2 = AirPlayFeatures.parse('0xab');
        expect(f1.rawValue, equals(f2.rawValue));
      });
    });
    group('video flags', () {
      test('supportsVideoV1 checks bit 0', () {
        final f = AirPlayFeatures.parse('0x1');
        expect(f.supportsVideoV1, isTrue);
        expect(f.supportsVideo, isTrue);
      });
      test('supportsVideoV2 checks bit 49', () {
        final f = AirPlayFeatures.parse('0x0,0x20000');
        expect(f.supportsVideoV2, isTrue);
        expect(f.supportsVideo, isTrue);
      });
      test('supportsVideo false if neither', () {
        final f = AirPlayFeatures.parse('0x0');
        expect(f.supportsVideo, isFalse);
      });
    });
    group('other flags', () {
      test('supportsAudio checks bit 9', () {
        final f = AirPlayFeatures.parse('0x200');
        expect(f.supportsAudio, isTrue);
      });
      test('supportsScreen checks bit 7', () {
        final f = AirPlayFeatures.parse('0x80');
        expect(f.supportsScreen, isTrue);
      });
      test('supportsHLS checks bit 4', () {
        final f = AirPlayFeatures.parse('0x10');
        expect(f.supportsHLS, isTrue);
      });
      test('requiresHapPairing checks bit 46 or 48', () {
        final f46 = AirPlayFeatures.parse('0x0,0x4000');
        expect(f46.requiresHapPairing, isTrue);
        final f48 = AirPlayFeatures.parse('0x0,0x10000');
        expect(f48.requiresHapPairing, isTrue);
      });
      test('isV2Protocol checks bit 38 or 48', () {
        final f38 = AirPlayFeatures.parse('0x0,0x40');
        expect(f38.isV2Protocol, isTrue);
      });
    });
    group('toString', () {
      test('includes flag summary', () {
        final f = AirPlayFeatures.parse('0x1');
        expect(f.toString(), contains('video=true'));
      });
    });
    group('real-world feature strings', () {
      test('Apple TV 4K typical features', () {
        final f = AirPlayFeatures.parse('0x5A7FFFF7,0x1E');
        expect(f.supportsVideoV1, isTrue);
        expect(f.supportsAudio, isTrue);
        expect(f.supportsScreen, isTrue);
        expect(f.supportsHLS, isTrue);
      });
      test('device with only audio and mirroring', () {
        final f = AirPlayFeatures.parse('0x280');
        expect(f.supportsVideo, isFalse);
        expect(f.supportsAudio, isTrue);
        expect(f.supportsScreen, isTrue);
      });
      test('device with HAP pairing required', () {
        final f = AirPlayFeatures.parse('0x280,0x10000');
        expect(f.requiresHapPairing, isTrue);
        expect(f.isV2Protocol, isTrue);
      });
    });
  });
}
