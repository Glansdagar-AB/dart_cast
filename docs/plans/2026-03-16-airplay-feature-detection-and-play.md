# AirPlay Feature Detection + V1/V2 `/play` Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add AirPlay feature flag detection and implement correct V1/V2 `/play` format negotiation so video URL casting works on devices that support it and fails gracefully on devices that don't.

**Architecture:** New `AirPlayFeatures` class parses mDNS feature bitmask. New `AirPlayMediaController` extracts media logic from `HapSession`. Play method tries V1 binary plist → V1 text/parameters → V2 binary plist with RTSP, stopping at first success. `AirPlaySession` delegates to controller and checks features before attempting `/play`.

**Tech Stack:** Dart, dart_cast package, ChaCha20-Poly1305 (cryptography package), binary plist encoder

**Spec:** `docs/specs/2026-03-16-airplay-feature-detection-and-play-design.md`

---

## File Structure

### New Files
- `lib/src/protocols/airplay/airplay_features.dart` — Feature bitmask parser with named getters
- `lib/src/protocols/airplay/airplay_media_controller.dart` — Media protocol logic (V1/V2 `/play`, control commands)
- `test/protocols/airplay/airplay_features_test.dart` — Feature parsing tests
- `test/protocols/airplay/airplay_media_controller_test.dart` — Media controller tests
- `docs/PROTOCOL_REFERENCES.md` — Protocol source attribution
- `docs/FUTURE_WORK.md` — Screen mirroring and RAOP audio documentation

### Modified Files
- `lib/src/protocols/airplay/auth/hap_session.dart` — Remove media methods (play/stop/scrub/rate/getPlaybackInfo/getServerInfo), keep encryption + RTSP
- `lib/src/protocols/airplay/airplay_session.dart` — Use AirPlayMediaController, add feature detection
- `lib/src/protocols/airplay/airplay_discovery_provider.dart` — Log parsed features
- `lib/src/core/cast_exceptions.dart` — Add `UnsupportedFeatureException`
- `lib/dart_cast.dart` — Export new files
- `test/protocols/airplay/auth/hap_session_test.dart` — Remove media method tests (moved to controller tests)
- `README.md` — AirPlay capabilities section
- `CHANGELOG.md` — Release notes

---

## Chunk 1: AirPlayFeatures (Feature Detection)

### Task 1: AirPlayFeatures class with TDD

**Files:**
- Create: `lib/src/protocols/airplay/airplay_features.dart`
- Create: `test/protocols/airplay/airplay_features_test.dart`

- [ ] **Step 1: Write failing tests for feature parsing**

```dart
// test/protocols/airplay/airplay_features_test.dart
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
        // "0x5A7FFFF7,0x1E" => lower=0x5A7FFFF7, upper=0x1E
        // combined = (0x1E << 32) | 0x5A7FFFF7
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
        // bit 49 = 0x2000000000000 => upper half = 0x20000, lower = 0x0
        final f = AirPlayFeatures.parse('0x0,0x20000');
        expect(f.supportsVideoV2, isTrue);
        expect(f.supportsVideo, isTrue);
      });

      test('supportsVideo true if either V1 or V2', () {
        final neither = AirPlayFeatures.parse('0x0');
        expect(neither.supportsVideo, isFalse);
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
        // bit 46 = 0x400000000000 => upper=0x4000, lower=0x0
        final f46 = AirPlayFeatures.parse('0x0,0x4000');
        expect(f46.requiresHapPairing, isTrue);

        // bit 48 = 0x1000000000000 => upper=0x10000, lower=0x0
        final f48 = AirPlayFeatures.parse('0x0,0x10000');
        expect(f48.requiresHapPairing, isTrue);
      });

      test('isV2Protocol checks bit 38 or 48', () {
        // bit 38 = 0x4000000000 => upper=0x40, lower=0x0
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
        // Apple TV 4K: video V1+V2, audio, screen, HLS, HAP
        final f = AirPlayFeatures.parse('0x5A7FFFF7,0x1E');
        expect(f.supportsVideoV1, isTrue);
        expect(f.supportsAudio, isTrue);
        expect(f.supportsScreen, isTrue);
        expect(f.supportsHLS, isTrue);
      });

      test('device with only audio and mirroring (no video URL cast)', () {
        // Simulates Google TV / some third-party receivers: bit 7 + bit 9
        final f = AirPlayFeatures.parse('0x280');
        expect(f.supportsVideo, isFalse);
        expect(f.supportsAudio, isTrue);
        expect(f.supportsScreen, isTrue);
      });

      test('device with HAP pairing required', () {
        // bit 48 = 0x1000000000000 => upper=0x10000
        final f = AirPlayFeatures.parse('0x280,0x10000');
        expect(f.requiresHapPairing, isTrue);
        expect(f.isV2Protocol, isTrue);
      });
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test test/protocols/airplay/airplay_features_test.dart`
Expected: Compilation error — `AirPlayFeatures` class doesn't exist

- [ ] **Step 3: Implement AirPlayFeatures**

```dart
// lib/src/protocols/airplay/airplay_features.dart

/// Parses and provides named access to AirPlay feature flags.
///
/// The features bitmask is advertised via mDNS TXT records under the
/// `features` or `ft` key. It can be a single hex value (`"0x5A7FFFF7"`)
/// or two comma-separated halves (`"0x5A7FFFF7,0x1E"`) where the first
/// part is the lower 32 bits and the second is the upper 32 bits.
///
/// Reference: https://emanuelecozzi.net/docs/airplay2/features/
class AirPlayFeatures {
  final int rawValue;

  const AirPlayFeatures(this.rawValue);

  /// Parses a features string from mDNS TXT records.
  ///
  /// Handles formats: "0x5A7FFFF7", "0x5A7FFFF7,0x1E", "0x0", "", malformed.
  factory AirPlayFeatures.parse(String features) {
    if (features.isEmpty) return const AirPlayFeatures(0);

    try {
      final parts = features.split(',');
      final lower = _parseHex(parts[0].trim());
      final upper = parts.length > 1 ? _parseHex(parts[1].trim()) : 0;
      return AirPlayFeatures((upper << 32) | lower);
    } catch (_) {
      return const AirPlayFeatures(0);
    }
  }

  static int _parseHex(String s) {
    final cleaned = s.replaceFirst(RegExp(r'^0[xX]'), '');
    if (cleaned.isEmpty) return 0;
    return int.parse(cleaned, radix: 16);
  }

  bool _hasBit(int bit) => (rawValue >> bit) & 1 == 1;

  // Video URL cast
  bool get supportsVideoV1 => _hasBit(0);
  bool get supportsVideoV2 => _hasBit(49);
  bool get supportsVideo => supportsVideoV1 || supportsVideoV2;

  // Other capabilities
  bool get supportsPhoto => _hasBit(1);
  bool get supportsHLS => _hasBit(4);
  bool get supportsScreen => _hasBit(7);
  bool get supportsAudio => _hasBit(9);

  // Authentication
  bool get requiresHapPairing => _hasBit(46) || _hasBit(48);
  bool get isV2Protocol => _hasBit(38) || _hasBit(48);

  @override
  String toString() =>
      'AirPlayFeatures(0x${rawValue.toRadixString(16)}, '
      'video=$supportsVideo, audio=$supportsAudio, '
      'screen=$supportsScreen, hap=$requiresHapPairing)';
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test test/protocols/airplay/airplay_features_test.dart -r expanded`
Expected: All tests pass

- [ ] **Step 5: Run full test suite**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test`
Expected: All existing tests still pass

- [ ] **Step 6: Commit**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add lib/src/protocols/airplay/airplay_features.dart test/protocols/airplay/airplay_features_test.dart
git commit -m "feat: add AirPlayFeatures class for mDNS feature bitmask parsing"
```

### Task 2: Wire feature detection into discovery

**Files:**
- Modify: `lib/src/protocols/airplay/airplay_discovery_provider.dart:39-48`
- Modify: `lib/dart_cast.dart`

- [ ] **Step 1: Update discovery provider to log parsed features**

In `airplay_discovery_provider.dart`, replace the raw features logging (line 44-48) with parsed `AirPlayFeatures`:

```dart
// Replace lines 44-48 with:
final featuresStr = info.txtRecords['features'] ?? info.txtRecords['ft'] ?? '';
final features = AirPlayFeatures.parse(featuresStr);
final device = info.toAirplayDevice();
if (!_devices.containsKey(device.id)) {
  CastLogger.info(
      'AirPlay: found "${device.name}" at ${device.address.address}:${device.port} $features');
```

Add import at top: `import 'airplay_features.dart';`

- [ ] **Step 2: Export AirPlayFeatures from barrel**

In `lib/dart_cast.dart`, add:
```dart
export 'src/protocols/airplay/airplay_features.dart';
```

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add lib/src/protocols/airplay/airplay_discovery_provider.dart lib/dart_cast.dart
git commit -m "feat: log parsed AirPlay features during discovery"
```

### Task 3: Add UnsupportedFeatureException and PlaybackException

**Files:**
- Modify: `lib/src/core/cast_exceptions.dart` (insert between NeedsPairingException and ProtocolException)

- [ ] **Step 1: Add exception classes**

Add after `NeedsPairingException` (line 51) in `cast_exceptions.dart`:

```dart
/// Thrown when a device does not support the requested feature.
///
/// For example, attempting video URL cast on a device that only supports
/// screen mirroring. The caller can use this to suggest an alternative
/// protocol (e.g., Chromecast or DLNA).
class UnsupportedFeatureException extends CastException {
  UnsupportedFeatureException(super.message);
}

/// Thrown when playback fails after trying all available formats.
///
/// Contains the last HTTP status code received from the device.
class PlaybackException extends CastException {
  final int? statusCode;
  PlaybackException(super.message, {this.statusCode});
}
```

- [ ] **Step 2: Run full test suite**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add lib/src/core/cast_exceptions.dart
git commit -m "feat: add UnsupportedFeatureException and PlaybackException"
```

---

## Chunk 2: AirPlayMediaController (V1/V2 /play)

### Task 4: Extract media methods from HapSession into AirPlayMediaController

**Files:**
- Create: `lib/src/protocols/airplay/airplay_media_controller.dart`
- Create: `test/protocols/airplay/airplay_media_controller_test.dart`
- Modify: `lib/src/protocols/airplay/auth/hap_session.dart:874-990` (remove media methods)
- Modify: `lib/dart_cast.dart`

- [ ] **Step 1: Write failing tests for AirPlayMediaController.playV1**

```dart
// test/protocols/airplay/airplay_media_controller_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_features.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_media_controller.dart';
import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:test/test.dart';

/// Creates a server + client HapSession pair with matching keys.
Future<({ServerSocket server, HapSession client})> createEncryptedPair() async {
  final key = Uint8List(32);
  for (int i = 0; i < 32; i++) key[i] = i;
  final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final sock = await Socket.connect('127.0.0.1', srv.port);
  final client = HapSession(
    socket: sock,
    outputKey: Uint8List.fromList(key),
    inputKey: Uint8List.fromList(key),
    host: '127.0.0.1',
    port: srv.port,
    sessionId: 'test-media-session',
  );
  return (server: srv, client: client);
}

HapSession serverSession(Socket sock, int port) {
  final key = Uint8List(32);
  for (int i = 0; i < 32; i++) key[i] = i;
  return HapSession(
    socket: sock,
    outputKey: Uint8List.fromList(key),
    inputKey: Uint8List.fromList(key),
    host: '127.0.0.1',
    port: port,
  );
}

void main() {
  group('AirPlayMediaController', () {
    group('playV1', () {
      test('sends binary plist with Content-Location and Start-Position', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1'); // bit 0 = video V1
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        String? receivedRequest;
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            final data = await srv.readDecryptedData();
            receivedRequest = utf8.decode(data, allowMalformed: true);
            final resp = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
            final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(enc);
            await sock.flush();
          } catch (_) {}
        });

        await controller.playV1('http://example.com/video.m3u8', 0.0);

        expect(receivedRequest, contains('POST /play HTTP/1.1'));
        expect(receivedRequest, contains('Content-Type: application/x-apple-binary-plist'));
        expect(receivedRequest, contains('User-Agent: MediaControl/1.0'));
        // Body should contain the URL as binary plist
        expect(receivedRequest, contains('example.com/video.m3u8'));

        await controller.dispose();
        await pair.server.close();
      });

      test('does not call setupRtspSession', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1');
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        final receivedRequests = <String>[];
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            while (true) {
              final data = await srv.readDecryptedData();
              receivedRequests.add(utf8.decode(data, allowMalformed: true));
              final resp = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
              final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
              sock.add(enc);
              await sock.flush();
            }
          } catch (_) {}
        });

        await controller.playV1('http://example.com/video.m3u8', 0.0);

        // Should only have 1 request (/play), no SETUP or RECORD
        expect(receivedRequests.length, equals(1));
        expect(receivedRequests[0], contains('POST /play'));
        expect(receivedRequests[0], isNot(contains('SETUP')));

        await controller.dispose();
        await pair.server.close();
      });
    });

    group('playV1Text', () {
      test('sends text/parameters with Content-Location and Start-Position', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1');
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        String? receivedRequest;
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            final data = await srv.readDecryptedData();
            receivedRequest = utf8.decode(data, allowMalformed: true);
            final resp = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
            final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(enc);
            await sock.flush();
          } catch (_) {}
        });

        await controller.playV1Text('http://example.com/video.m3u8', 0.0);

        expect(receivedRequest, contains('POST /play HTTP/1.1'));
        expect(receivedRequest, contains('Content-Type: text/parameters'));
        expect(receivedRequest, contains('Content-Location: http://example.com/video.m3u8'));
        expect(receivedRequest, contains('Start-Position: 0'));

        await controller.dispose();
        await pair.server.close();
      });
    });

    group('playV2', () {
      test('sends binary plist with extended fields and AirPlay/550.10 User-Agent', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x0,0x20000'); // bit 49 = V2
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        final receivedRequests = <String>[];
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            while (true) {
              final data = await srv.readDecryptedData();
              receivedRequests.add(utf8.decode(data, allowMalformed: true));
              // Respond 200 to all requests (SETUP, feedback, RECORD, /play)
              final cseqMatch = RegExp(r'CSeq:\s*(\d+)').firstMatch(utf8.decode(data, allowMalformed: true));
              final cseq = cseqMatch?.group(1) ?? '1';
              final resp = 'RTSP/1.0 200 OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
              final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
              sock.add(enc);
              await sock.flush();
            }
          } catch (_) {}
        });

        await controller.playV2('http://example.com/video.m3u8', 0.0);

        // Should have SETUP + feedback + RECORD + /play = 4+ requests
        expect(receivedRequests.length, greaterThanOrEqualTo(4));
        // Last request should be /play with V2 headers
        final playReq = receivedRequests.last;
        expect(playReq, contains('POST /play'));
        expect(playReq, contains('User-Agent: AirPlay/550.10'));
        expect(playReq, contains('application/x-apple-binary-plist'));
        // Should NOT have CSeq/DACP-ID (those are RTSP-only)
        expect(playReq, isNot(contains('CSeq:')));

        await controller.dispose();
        await pair.server.close();
      });
    });

    group('play auto-selection', () {
      test('throws UnsupportedFeatureException when no video bits', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x200'); // audio only
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        expect(
          () => controller.play('http://example.com/video.m3u8'),
          throwsA(isA<UnsupportedFeatureException>()),
        );

        await controller.dispose();
        await pair.server.close();
      });

      test('V1 plist 404 falls back to V1 text, then V2', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1'); // V1 video
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        int requestCount = 0;
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            while (true) {
              final data = await srv.readDecryptedData();
              requestCount++;
              final reqStr = utf8.decode(data, allowMalformed: true);
              // First two /play attempts return 404, third returns 200
              final statusCode = requestCount <= 2 ? 404 : 200;
              String resp;
              if (reqStr.contains('RTSP/1.0')) {
                final cseqMatch = RegExp(r'CSeq:\s*(\d+)').firstMatch(reqStr);
                final cseq = cseqMatch?.group(1) ?? '1';
                resp = 'RTSP/1.0 $statusCode OK\r\nCSeq: $cseq\r\nContent-Length: 0\r\n\r\n';
              } else {
                resp = 'HTTP/1.1 $statusCode OK\r\nContent-Length: 0\r\n\r\n';
              }
              final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
              sock.add(enc);
              await sock.flush();
            }
          } catch (_) {}
        });

        // play() should try V1 plist (404), V1 text (404), then V2 setup flow
        await controller.play('http://example.com/video.m3u8');

        // At minimum: V1 plist + V1 text + SETUP + feedback + RECORD + V2 /play
        expect(requestCount, greaterThanOrEqualTo(3));

        await controller.dispose();
        await pair.server.close();
      });
    });

    group('getPlaybackInfo', () {
      test('sends GET /playback-info and returns PlaybackInfo', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1');
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            final data = await srv.readDecryptedData();
            final reqStr = utf8.decode(data, allowMalformed: true);
            expect(reqStr, contains('GET /playback-info'));
            // Return a minimal playback-info XML plist
            final body = '<?xml version="1.0" encoding="UTF-8"?>'
                '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
                '<plist version="1.0"><dict>'
                '<key>duration</key><real>120.0</real>'
                '<key>position</key><real>30.5</real>'
                '<key>rate</key><real>1.0</real>'
                '<key>readyToPlay</key><true/>'
                '</dict></plist>';
            final resp = 'HTTP/1.1 200 OK\r\nContent-Type: text/x-apple-plist+xml\r\nContent-Length: ${body.length}\r\n\r\n$body';
            final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(enc);
            await sock.flush();
          } catch (_) {}
        });

        final info = await controller.getPlaybackInfo();
        expect(info.duration, closeTo(120.0, 0.1));
        expect(info.position, closeTo(30.5, 0.1));
        expect(info.rate, equals(1.0));

        await controller.dispose();
        await pair.server.close();
      });
    });

    group('control commands', () {
      test('pause sends POST /rate?value=0', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1');
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        String? receivedRequest;
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            final data = await srv.readDecryptedData();
            receivedRequest = utf8.decode(data, allowMalformed: true);
            final resp = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
            final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(enc);
            await sock.flush();
          } catch (_) {}
        });

        await controller.pause();

        expect(receivedRequest, contains('POST /rate?value=0'));

        await controller.dispose();
        await pair.server.close();
      });

      test('resume sends POST /rate?value=1', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1');
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        String? receivedRequest;
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            final data = await srv.readDecryptedData();
            receivedRequest = utf8.decode(data, allowMalformed: true);
            final resp = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
            final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(enc);
            await sock.flush();
          } catch (_) {}
        });

        await controller.resume();

        expect(receivedRequest, contains('POST /rate?value=1'));

        await controller.dispose();
        await pair.server.close();
      });

      test('seek sends POST /scrub?position=N', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1');
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        String? receivedRequest;
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            final data = await srv.readDecryptedData();
            receivedRequest = utf8.decode(data, allowMalformed: true);
            final resp = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
            final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(enc);
            await sock.flush();
          } catch (_) {}
        });

        await controller.seek(42.5);

        expect(receivedRequest, contains('POST /scrub?position=42.5'));

        await controller.dispose();
        await pair.server.close();
      });

      test('stop sends POST /stop', () async {
        final pair = await createEncryptedPair();
        final features = AirPlayFeatures.parse('0x1');
        final controller = AirPlayMediaController(
          session: pair.client,
          features: features,
        );

        String? receivedRequest;
        pair.server.listen((sock) async {
          final srv = serverSession(sock, pair.server.port);
          try {
            final data = await srv.readDecryptedData();
            receivedRequest = utf8.decode(data, allowMalformed: true);
            final resp = 'HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n';
            final enc = await srv.encrypt(Uint8List.fromList(utf8.encode(resp)));
            sock.add(enc);
            await sock.flush();
          } catch (_) {}
        });

        await controller.stop();

        expect(receivedRequest, contains('POST /stop'));

        await controller.dispose();
        await pair.server.close();
      });
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test test/protocols/airplay/airplay_media_controller_test.dart`
Expected: Compilation error — `AirPlayMediaController` doesn't exist

- [ ] **Step 3: Implement AirPlayMediaController**

Create `lib/src/protocols/airplay/airplay_media_controller.dart` with:
- Constructor taking `HapSession` and `AirPlayFeatures`
- `playV1(url, startPosition)` — sends binary plist with `MediaControl/1.0`, `Content-Location`, `Start-Position`, `X-Apple-Session-ID` in body
- `playV1Text(url, startPosition)` — sends `text/parameters` with `Content-Location: <url>\nStart-Position: <pos>\n`
- `playV2(url, startPosition)` — calls `session.setupRtspSession()` first, then sends binary plist with `AirPlay/550.10`, extended fields
- `play(url, {startPosition})` — checks `features.supportsVideo`, tries V1 plist → V1 text → V2, throws `UnsupportedFeatureException` or `PlaybackException`
- `pause()` — `POST /rate?value=0`
- `resume()` — `POST /rate?value=1`
- `seek(seconds)` — `POST /scrub?position=<seconds>`
- `stop()` — `POST /stop`, resets RTSP state
- `getPlaybackInfo()` — `GET /playback-info`, returns `PlaybackInfo`
- `dispose()` — stops feedback loop

All HTTP commands use `session.sendRequest()` (HTTP/1.1). All playback control commands use `sendRequest`, not `sendRtspRequest`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test test/protocols/airplay/airplay_media_controller_test.dart -r expanded`
Expected: All tests pass

- [ ] **Step 5: Run full test suite**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test`
Expected: All tests pass (HapSession still has its old methods — we haven't removed them yet)

- [ ] **Step 6: Export and commit**

Add to `lib/dart_cast.dart`:
```dart
export 'src/protocols/airplay/airplay_media_controller.dart';
```

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add lib/src/protocols/airplay/airplay_media_controller.dart test/protocols/airplay/airplay_media_controller_test.dart lib/dart_cast.dart
git commit -m "feat: add AirPlayMediaController with V1/V2 /play and control commands"
```

### Task 5: Remove media methods from HapSession

**Files:**
- Modify: `lib/src/protocols/airplay/auth/hap_session.dart` (lines 866-998: remove play, scrub, rate, stop, getPlaybackInfo, getServerInfo, _checkResponse)
- Modify: `test/protocols/airplay/auth/hap_session_test.dart` (update tests that reference removed methods)

TDD order: update tests first, then remove methods.

- [ ] **Step 1: Update tests that reference removed methods**

In `hap_session_test.dart`, the "stop resets session state" test group (lines 933-1078) calls `clientSession.stop()` which sends a `POST /stop` request and resets state. After refactoring, `HapSession` will only have `resetRtspSession()` (local state reset, no network request). Update:

- Rename test group to "resetRtspSession resets session state"
- Replace `clientSession.stop()` with `clientSession.resetRtspSession()`
- Remove the request count assertion for the `/stop` POST (line 1069: `expect(requestCount, equals(4))` becomes `expect(requestCount, equals(3))` since no `/stop` is sent)
- Update the re-setup count accordingly (line 1073: stays `equals(6)` since 3 original + 3 re-setup)

- [ ] **Step 2: Remove media methods from HapSession**

Delete from `hap_session.dart`:
- The comment `// -- AirPlay media command convenience methods --` (line 866)
- `play()` method (line 874-934)
- `scrub()` method (line 937-944)
- `rate()` method (line 947-954)
- `stop()` method (line 960-970)
- `getPlaybackInfo()` method (line 973-980)
- `getServerInfo()` method (line 983-990)
- `_checkResponse()` helper
- Remove the `PlistCodec` and `BinaryPlistEncoder` imports if they become unused

Add a new public method:
```dart
/// Resets the RTSP session state so a new SETUP + RECORD can be performed.
///
/// Does NOT send any network request — only resets local state.
void resetRtspSession() {
  _stopFeedbackLoop();
  _sessionId = _generateUuid();
  _rtspSessionSetUp = false;
  _cseq = 0;
}
```

Keep: `sendRequest()`, `sendRtspRequest()`, `setupRtspSession()`, `encrypt()`, `decrypt()`, event channel, feedback loop, `close()`.

- [ ] **Step 3: Run full test suite**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add lib/src/protocols/airplay/auth/hap_session.dart test/protocols/airplay/auth/hap_session_test.dart
git commit -m "refactor: remove media methods from HapSession, add resetRtspSession()"
```

### Task 6: Update AirPlaySession to use AirPlayMediaController

**Files:**
- Modify: `lib/src/protocols/airplay/airplay_session.dart`

- [ ] **Step 1: Add AirPlayMediaController and features to AirPlaySession**

Replace the dual-path pattern (`_hapSession != null` checks in every method) with a single `_mediaController` field.

Key changes:
- Add `AirPlayMediaController? _mediaController` field
- In `_handleAuthRequired()`, after creating `_hapSession`, create `_mediaController = AirPlayMediaController(session: _hapSession!, features: _parseFeatures())`
- Add `_parseFeatures()` helper that reads `device.metadata['features']` or `device.metadata['ft']` and returns `AirPlayFeatures.parse()`
- `loadMedia()` — delegates to `_mediaController!.play()`, catches `UnsupportedFeatureException`
- `play()` — delegates to `_mediaController!.resume()`
- `pause()` — delegates to `_mediaController!.pause()`
- `stop()` — delegates to `_mediaController!.stop()`
- `seek()` — delegates to `_mediaController!.seek()`
- For non-authenticated devices (no HAP), keep using `_client` with V1 text/parameters format directly
- `_pollPlaybackInfo()` — delegates to `_mediaController!.getPlaybackInfo()` or `_client!.getPlaybackInfo()`

- [ ] **Step 2: Run full test suite**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test`
Expected: All tests pass

- [ ] **Step 3: Run analyzer**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart analyze lib/`
Expected: No errors

- [ ] **Step 4: Commit**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add lib/src/protocols/airplay/airplay_session.dart
git commit -m "refactor: use AirPlayMediaController in AirPlaySession with feature detection"
```

---

## Chunk 3: Documentation and Release Prep

### Task 7: Create protocol references and future work docs

**Files:**
- Create: `docs/PROTOCOL_REFERENCES.md`
- Create: `docs/FUTURE_WORK.md`

- [ ] **Step 1: Write PROTOCOL_REFERENCES.md**

```markdown
# Protocol References

Sources used to implement the AirPlay, Chromecast, and DLNA protocols.

## AirPlay

- [Unofficial AirPlay Protocol Specification](https://nto.github.io/AirPlay.html) — Original AirPlay 1 spec (video, audio, photo)
- [OpenAirPlay Spec](https://openairplay.github.io/airplay-spec/) — Community-maintained AirPlay spec
- [AirPlay 2 Internals — Features](https://emanuelecozzi.net/docs/airplay2/features/) — Feature bitmask reference
- [AirPlay 2 Internals — RTSP](https://emanuelecozzi.net/docs/airplay2/rtsp/) — RTSP audio streaming protocol
- [pyatv](https://github.com/postlund/pyatv) — Python Apple TV client library (SRP, HAP, RTSP reference implementation)
- [watson/airplay-protocol](https://github.com/watson/airplay-protocol) — Node.js AirPlay 1 client (V1 text/parameters format)
- [openairplay/airplay2-receiver](https://github.com/openairplay/airplay2-receiver) — Python AirPlay 2 receiver (audio only, no /play)
- [openairplay/ap2-sender](https://github.com/openairplay/ap2-sender) — Objective-C AirPlay 2 sender reference
- [UxPlay](https://github.com/FDH2/UxPlay) — Open-source AirPlay receiver with mirroring + HLS video support
- [pyatv Issue #1518](https://github.com/postlund/pyatv/issues/1518) — /play 404 on non-Apple devices (feature flag analysis)
- [pyatv Issue #2204](https://github.com/postlund/pyatv/issues/2204) — Force AirPlay V1/V2 version selection
```

- [ ] **Step 2: Write FUTURE_WORK.md**

Document sub-project 3 (video-as-mirroring) and RAOP audio streaming architecture, required components, estimated effort.

- [ ] **Step 3: Commit**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add docs/PROTOCOL_REFERENCES.md docs/FUTURE_WORK.md
git commit -m "docs: add protocol references and future work documentation"
```

### Task 8: Update README and CHANGELOG

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add AirPlay capabilities section to README**

Add after the existing content an "AirPlay Capabilities" section explaining:
- Feature flag detection from mDNS
- Three AirPlay modes (video URL cast, audio streaming, screen mirroring)
- Which are currently supported (video URL cast with V1/V2 auto-negotiation)
- Limitations: devices without feature bit 0/49 don't support video URL cast

- [ ] **Step 2: Update CHANGELOG**

Add entry for the new version describing:
- AirPlay feature flag detection via mDNS
- V1 and V2 `/play` format auto-negotiation
- `AirPlayMediaController` for media protocol logic
- `UnsupportedFeatureException` for graceful fallback
- Breaking: `HapSession` media methods moved to `AirPlayMediaController`

- [ ] **Step 3: Run analyzer and formatter**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
dart analyze lib/ test/
dart format lib/ test/
```

- [ ] **Step 4: Run full test suite one final time**

Run: `cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && dart test`
Expected: All tests pass

- [ ] **Step 5: Commit**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git add README.md CHANGELOG.md
git commit -m "docs: add AirPlay capabilities to README, update CHANGELOG"
```

- [ ] **Step 6: Push all commits**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast && git push origin main
```
