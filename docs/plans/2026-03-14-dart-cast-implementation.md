# dart_cast Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a pure Dart cross-platform casting package supporting Chromecast (CASTV2), AirPlay, and DLNA with a built-in HTTP proxy for header injection.

**Architecture:** Three-layer design — Core (protocol-agnostic abstractions + media proxy), Protocol (isolated DLNA/Chromecast/AirPlay implementations), Consumer (example app). Each protocol is independently testable via mock servers. A local HTTP proxy transparently handles custom header injection for all protocols.

**Tech Stack:** Dart SDK, `protobuf` (Chromecast), `multicast_dns` (mDNS discovery), `dart:io` (HTTP server, TLS sockets, UDP), `http` (proxy upstream requests)

**Reference docs:**
- Design spec: `docs/design/2026-03-14-dart-cast-package-design.md`
- DLNA protocol: `docs/protocol-references/dlna-upnp-protocol.md`
- Chromecast protocol: `docs/protocol-references/chromecast-castv2-protocol.md`
- AirPlay protocol: `docs/protocol-references/airplay-protocol.md`
- HLS spec: `docs/protocol-references/hls-m3u8-specification.md`

---

## Parallelization Strategy

This plan is designed for **maximum parallel execution via subagents**. Tasks are organized into waves — all tasks within a wave can run as independent subagents simultaneously.

```
Wave 1: [Agent A] Tasks 1-6     — Project setup + core models (sequential, fast)
         ↓
Wave 2: [Agent A] Tasks 7-8     — HLS parser + Media Proxy
         [Agent B] Tasks 9-10    — SSDP parsing + DLNA device XML
         [Agent C] Tasks 14-15   — Protobuf setup + CASTV2 channel
         [Agent D] Tasks 19-19b  — Plist parser + mDNS helper
         ↓
Wave 3: [Agent A] Tasks 11-12   — DLNA SOAP controller + session
         [Agent B] Tasks 16-17   — Chromecast channels + session
         [Agent C] Tasks 20-21   — AirPlay client + session
         ↓
Wave 4: [Agent A] Task 13       — DLNA integration test
         [Agent B] Task 18       — Chromecast integration test
         [Agent C] Task 22       — AirPlay integration test
         ↓
Wave 5: [Agent A] Tasks 23-26   — Discovery manager + CastService + exports
         ↓
Wave 6: [Agent A] Task 27       — Example app
         [Agent B] Task 28       — README/docs
         ↓
Wave 7: [Agent A] Task 29       — Final verification
         ↓
Wave 8: [Agent A] Tasks 30-35   — anime_here integration (separate repo)
```

**Key insight:** All 3 protocols (DLNA, Chromecast, AirPlay) are fully independent and can be built simultaneously in Waves 2-4. This is the biggest time savings.

---

## Chunk 1: Project Setup + Core Models

### Task 1: Initialize Dart Package

**Files:**
- Create: `pubspec.yaml`
- Create: `lib/dart_cast.dart`
- Create: `lib/src/core/cast_device.dart`
- Create: `lib/src/core/cast_media.dart`
- Create: `lib/src/core/cast_exceptions.dart`
- Create: `lib/src/utils/logger.dart`
- Create: `analysis_options.yaml`
- Create: `.gitignore`

- [ ] **Step 1: Create pubspec.yaml**

```yaml
name: dart_cast
description: A pure Dart cross-platform casting package supporting Chromecast, AirPlay, and DLNA.
version: 0.1.0
repository: https://github.com/abdelaziz-mahdy/dart_cast

environment:
  sdk: ^3.0.0

dependencies:
  http: ^1.2.0
  multicast_dns: ^0.3.2+6
  protobuf: ^3.1.0

dev_dependencies:
  test: ^1.25.0
  lints: ^5.0.0
```

- [ ] **Step 2: Create analysis_options.yaml**

```yaml
include: package:lints/recommended.yaml
```

- [ ] **Step 3: Create .gitignore**

```
.dart_tool/
.packages
build/
pubspec.lock
.idea/
*.iml
```

- [ ] **Step 4: Create barrel export**

```dart
// lib/dart_cast.dart
library dart_cast;

export 'src/core/cast_device.dart';
export 'src/core/cast_media.dart';
export 'src/core/cast_exceptions.dart';
```

- [ ] **Step 5: Create logger utility**

```dart
// lib/src/utils/logger.dart
typedef LogCallback = void Function(String level, String message);

class CastLogger {
  static LogCallback? onLog;

  static void debug(String message) => onLog?.call('DEBUG', message);
  static void info(String message) => onLog?.call('INFO', message);
  static void warning(String message) => onLog?.call('WARNING', message);
  static void error(String message) => onLog?.call('ERROR', message);
}
```

- [ ] **Step 6: Initialize git repo and run pub get**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
git init
dart pub get
```

- [ ] **Step 7: Commit**

```bash
git add pubspec.yaml analysis_options.yaml .gitignore lib/dart_cast.dart lib/src/utils/logger.dart
git commit -m "chore: initialize dart_cast package with project structure"
```

---

### Task 2: CastDevice Model

**Files:**
- Create: `lib/src/core/cast_device.dart`
- Create: `test/core/cast_device_test.dart`

- [ ] **Step 1: Write failing tests for CastDevice**

```dart
// test/core/cast_device_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('CastDevice', () {
    test('creates with required fields', () {
      final device = CastDevice(
        id: 'test-id',
        name: 'Living Room TV',
        protocol: CastProtocol.chromecast,
        address: InternetAddress('192.168.1.100'),
        port: 8009,
      );
      expect(device.id, 'test-id');
      expect(device.name, 'Living Room TV');
      expect(device.protocol, CastProtocol.chromecast);
      expect(device.port, 8009);
    });

    test('serializes to JSON', () {
      final device = CastDevice(
        id: 'test-id',
        name: 'TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.50'),
        port: 49152,
        metadata: {'manufacturer': 'Samsung'},
      );
      final json = device.toJson();
      expect(json['id'], 'test-id');
      expect(json['name'], 'TV');
      expect(json['protocol'], 'dlna');
      expect(json['address'], '192.168.1.50');
      expect(json['port'], 49152);
      expect(json['metadata']['manufacturer'], 'Samsung');
    });

    test('deserializes from JSON', () {
      final json = {
        'id': 'test-id',
        'name': 'TV',
        'protocol': 'chromecast',
        'address': '192.168.1.100',
        'port': 8009,
        'metadata': {'model': 'Chromecast Ultra'},
      };
      final device = CastDevice.fromJson(json);
      expect(device.id, 'test-id');
      expect(device.protocol, CastProtocol.chromecast);
      expect(device.address.address, '192.168.1.100');
      expect(device.metadata['model'], 'Chromecast Ultra');
    });

    test('roundtrip serialization', () {
      final original = CastDevice(
        id: 'abc',
        name: 'My TV',
        protocol: CastProtocol.airplay,
        address: InternetAddress('10.0.0.5'),
        port: 7000,
        metadata: {'deviceid': 'AA:BB:CC:DD:EE:FF'},
      );
      final restored = CastDevice.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.protocol, original.protocol);
      expect(restored.address.address, original.address.address);
      expect(restored.port, original.port);
      expect(restored.metadata, original.metadata);
    });

    test('equality by id', () {
      final a = CastDevice(
        id: 'same-id', name: 'A',
        protocol: CastProtocol.dlna,
        address: InternetAddress('1.1.1.1'), port: 80,
      );
      final b = CastDevice(
        id: 'same-id', name: 'B',
        protocol: CastProtocol.dlna,
        address: InternetAddress('2.2.2.2'), port: 90,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
dart test test/core/cast_device_test.dart
```
Expected: FAIL — classes don't exist yet

- [ ] **Step 3: Implement CastDevice**

```dart
// lib/src/core/cast_device.dart
import 'dart:io';

enum CastProtocol { chromecast, airplay, dlna }

class CastDevice {
  final String id;
  final String name;
  final CastProtocol protocol;
  final InternetAddress address;
  final int port;
  final Map<String, String> metadata;

  CastDevice({
    required this.id,
    required this.name,
    required this.protocol,
    required this.address,
    required this.port,
    this.metadata = const {},
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'address': address.address,
    'port': port,
    'metadata': metadata,
  };

  factory CastDevice.fromJson(Map<String, dynamic> json) => CastDevice(
    id: json['id'] as String,
    name: json['name'] as String,
    protocol: CastProtocol.values.byName(json['protocol'] as String),
    address: InternetAddress(json['address'] as String),
    port: json['port'] as int,
    metadata: Map<String, String>.from(json['metadata'] as Map? ?? {}),
  );

  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CastDevice($name, $protocol, ${address.address}:$port)';
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/core/cast_device_test.dart
```
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/cast_device.dart test/core/cast_device_test.dart
git commit -m "feat: add CastDevice model with JSON serialization"
```

---

### Task 3: CastMedia and CastSubtitle Models

**Files:**
- Create: `lib/src/core/cast_media.dart`
- Create: `test/core/cast_media_test.dart`

- [ ] **Step 1: Write failing tests for CastMedia**

```dart
// test/core/cast_media_test.dart
import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('CastMedia', () {
    test('creates with required fields', () {
      final media = CastMedia(
        url: 'https://example.com/stream.m3u8',
        type: CastMediaType.hls,
      );
      expect(media.url, 'https://example.com/stream.m3u8');
      expect(media.type, CastMediaType.hls);
      expect(media.httpHeaders, isEmpty);
      expect(media.subtitles, isEmpty);
      expect(media.startPosition, isNull);
    });

    test('creates with all fields', () {
      final media = CastMedia(
        url: 'https://example.com/video.mp4',
        type: CastMediaType.mp4,
        httpHeaders: {'Referer': 'https://megacloud.blog/'},
        title: 'One Piece Episode 1100',
        imageUrl: 'https://example.com/poster.jpg',
        startPosition: Duration(seconds: 120),
        subtitles: [
          CastSubtitle(
            url: 'https://example.com/subs.vtt',
            label: 'English',
            language: 'en',
            format: 'vtt',
          ),
        ],
      );
      expect(media.title, 'One Piece Episode 1100');
      expect(media.httpHeaders['Referer'], 'https://megacloud.blog/');
      expect(media.startPosition, Duration(seconds: 120));
      expect(media.subtitles, hasLength(1));
      expect(media.subtitles.first.label, 'English');
    });

    test('CastMediaType values', () {
      expect(CastMediaType.values, hasLength(3));
      expect(CastMediaType.hls.name, 'hls');
      expect(CastMediaType.mp4.name, 'mp4');
      expect(CastMediaType.mpegTs.name, 'mpegTs');
    });
  });

  group('CastSubtitle', () {
    test('creates with all fields', () {
      final sub = CastSubtitle(
        url: 'https://example.com/subs_en.vtt',
        label: 'English',
        language: 'en',
        format: 'vtt',
      );
      expect(sub.url, 'https://example.com/subs_en.vtt');
      expect(sub.label, 'English');
      expect(sub.language, 'en');
      expect(sub.format, 'vtt');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
dart test test/core/cast_media_test.dart
```

- [ ] **Step 3: Implement CastMedia**

```dart
// lib/src/core/cast_media.dart
enum CastMediaType { hls, mp4, mpegTs }

class CastMedia {
  final String url;
  final Map<String, String> httpHeaders;
  final String? title;
  final String? imageUrl;
  final Duration? startPosition;
  final List<CastSubtitle> subtitles;
  final CastMediaType type;

  const CastMedia({
    required this.url,
    required this.type,
    this.httpHeaders = const {},
    this.title,
    this.imageUrl,
    this.startPosition,
    this.subtitles = const [],
  });
}

class CastSubtitle {
  final String url;
  final String label;
  final String language;
  final String format;

  const CastSubtitle({
    required this.url,
    required this.label,
    required this.language,
    required this.format,
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/core/cast_media_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/cast_media.dart test/core/cast_media_test.dart
git commit -m "feat: add CastMedia and CastSubtitle models"
```

---

### Task 4: Exception Hierarchy

**Files:**
- Create: `lib/src/core/cast_exceptions.dart`
- Create: `test/core/cast_exceptions_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
// test/core/cast_exceptions_test.dart
import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('CastException', () {
    test('CastException has message and optional cause', () {
      final ex = CastException('something failed', cause: FormatException('bad'));
      expect(ex.message, 'something failed');
      expect(ex.cause, isA<FormatException>());
      expect(ex.toString(), contains('something failed'));
    });

    test('DeviceUnreachableException is a CastException', () {
      final ex = DeviceUnreachableException('device offline');
      expect(ex, isA<CastException>());
      expect(ex.message, 'device offline');
    });

    test('ConnectionLostException is a CastException', () {
      final ex = ConnectionLostException('network changed');
      expect(ex, isA<CastException>());
    });

    test('MediaLoadFailedException is a CastException', () {
      final ex = MediaLoadFailedException('unsupported format');
      expect(ex, isA<CastException>());
    });

    test('ProxyUpstreamException is a CastException', () {
      final ex = ProxyUpstreamException('403 forbidden');
      expect(ex, isA<CastException>());
    });

    test('DiscoveryException is a CastException', () {
      final ex = DiscoveryException('permissions denied');
      expect(ex, isA<CastException>());
    });

    test('ProtocolException includes protocol', () {
      final ex = ProtocolException('SOAP parse error', protocol: CastProtocol.dlna);
      expect(ex, isA<CastException>());
      expect(ex.protocol, CastProtocol.dlna);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement exceptions**

```dart
// lib/src/core/cast_exceptions.dart
import 'cast_device.dart';

class CastException implements Exception {
  final String message;
  final Object? cause;

  const CastException(this.message, {this.cause});

  @override
  String toString() => 'CastException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

class DeviceUnreachableException extends CastException {
  const DeviceUnreachableException(super.message, {super.cause});
}

class ConnectionLostException extends CastException {
  const ConnectionLostException(super.message, {super.cause});
}

class MediaLoadFailedException extends CastException {
  const MediaLoadFailedException(super.message, {super.cause});
}

class ProxyUpstreamException extends CastException {
  const ProxyUpstreamException(super.message, {super.cause});
}

class DiscoveryException extends CastException {
  const DiscoveryException(super.message, {super.cause});
}

class ProtocolException extends CastException {
  final CastProtocol protocol;
  const ProtocolException(super.message, {required this.protocol, super.cause});
}
```

- [ ] **Step 4: Update barrel export**

```dart
// lib/dart_cast.dart — add export
export 'src/core/cast_exceptions.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
dart test test/core/cast_exceptions_test.dart
```

- [ ] **Step 6: Commit**

```bash
git add lib/src/core/cast_exceptions.dart test/core/cast_exceptions_test.dart lib/dart_cast.dart
git commit -m "feat: add CastException hierarchy"
```

---

### Task 5: Session State Machine

**Files:**
- Create: `lib/src/core/cast_session.dart`
- Create: `test/core/cast_session_test.dart`

- [ ] **Step 1: Write failing tests for state machine**

```dart
// test/core/cast_session_test.dart
import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('CastSessionState', () {
    test('has all expected values', () {
      expect(CastSessionState.values, containsAll([
        CastSessionState.connecting,
        CastSessionState.connected,
        CastSessionState.loading,
        CastSessionState.playing,
        CastSessionState.paused,
        CastSessionState.buffering,
        CastSessionState.idle,
        CastSessionState.disconnected,
      ]));
    });
  });

  group('SessionStateMachine', () {
    late SessionStateMachine machine;

    setUp(() {
      machine = SessionStateMachine();
    });

    test('starts in disconnected state', () {
      expect(machine.state, CastSessionState.disconnected);
    });

    test('transitions disconnected -> connecting', () {
      expect(machine.canTransitionTo(CastSessionState.connecting), isTrue);
      machine.transitionTo(CastSessionState.connecting);
      expect(machine.state, CastSessionState.connecting);
    });

    test('transitions connecting -> connected', () {
      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);
      expect(machine.state, CastSessionState.connected);
    });

    test('transitions connected -> loading', () {
      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);
      machine.transitionTo(CastSessionState.loading);
      expect(machine.state, CastSessionState.loading);
    });

    test('transitions loading -> playing', () {
      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);
      machine.transitionTo(CastSessionState.loading);
      machine.transitionTo(CastSessionState.playing);
      expect(machine.state, CastSessionState.playing);
    });

    test('transitions playing -> paused -> playing', () {
      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);
      machine.transitionTo(CastSessionState.loading);
      machine.transitionTo(CastSessionState.playing);
      machine.transitionTo(CastSessionState.paused);
      expect(machine.state, CastSessionState.paused);
      machine.transitionTo(CastSessionState.playing);
      expect(machine.state, CastSessionState.playing);
    });

    test('transitions playing -> buffering -> playing', () {
      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);
      machine.transitionTo(CastSessionState.loading);
      machine.transitionTo(CastSessionState.playing);
      machine.transitionTo(CastSessionState.buffering);
      expect(machine.state, CastSessionState.buffering);
      machine.transitionTo(CastSessionState.playing);
      expect(machine.state, CastSessionState.playing);
    });

    test('transitions playing -> idle (stop or media ended)', () {
      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);
      machine.transitionTo(CastSessionState.loading);
      machine.transitionTo(CastSessionState.playing);
      machine.transitionTo(CastSessionState.idle);
      expect(machine.state, CastSessionState.idle);
    });

    test('transitions idle -> loading (next episode)', () {
      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);
      machine.transitionTo(CastSessionState.loading);
      machine.transitionTo(CastSessionState.playing);
      machine.transitionTo(CastSessionState.idle);
      machine.transitionTo(CastSessionState.loading);
      expect(machine.state, CastSessionState.loading);
    });

    test('any state -> disconnected is always valid', () {
      for (final state in CastSessionState.values) {
        final m = SessionStateMachine();
        if (state != CastSessionState.disconnected) {
          // Force state for testing
          m.forceState(state);
        }
        expect(m.canTransitionTo(CastSessionState.disconnected), isTrue);
      }
    });

    test('emits state changes on stream', () async {
      final states = <CastSessionState>[];
      machine.stateStream.listen(states.add);

      machine.transitionTo(CastSessionState.connecting);
      machine.transitionTo(CastSessionState.connected);

      await Future.delayed(Duration(milliseconds: 10));
      expect(states, [CastSessionState.connecting, CastSessionState.connected]);
    });

    test('rejects invalid transitions', () {
      // Can't go from disconnected to playing directly
      expect(machine.canTransitionTo(CastSessionState.playing), isFalse);
      expect(
        () => machine.transitionTo(CastSessionState.playing),
        throwsA(isA<StateError>()),
      );
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement SessionStateMachine**

```dart
// lib/src/core/cast_session.dart
import 'dart:async';

enum CastSessionState {
  connecting, connected, loading, playing, paused, buffering, idle, disconnected
}

/// Defines valid state transitions per the design spec.
class SessionStateMachine {
  CastSessionState _state = CastSessionState.disconnected;
  final _controller = StreamController<CastSessionState>.broadcast();

  static final Map<CastSessionState, Set<CastSessionState>> _validTransitions = {
    CastSessionState.disconnected: {CastSessionState.connecting},
    CastSessionState.connecting: {CastSessionState.connected, CastSessionState.disconnected},
    CastSessionState.connected: {CastSessionState.loading, CastSessionState.disconnected},
    CastSessionState.loading: {CastSessionState.playing, CastSessionState.disconnected},
    CastSessionState.playing: {
      CastSessionState.paused,
      CastSessionState.buffering,
      CastSessionState.idle,
      CastSessionState.disconnected,
    },
    CastSessionState.paused: {
      CastSessionState.playing,
      CastSessionState.idle,
      CastSessionState.disconnected,
    },
    CastSessionState.buffering: {CastSessionState.playing, CastSessionState.disconnected},
    CastSessionState.idle: {CastSessionState.loading, CastSessionState.disconnected},
  };

  CastSessionState get state => _state;
  Stream<CastSessionState> get stateStream => _controller.stream;

  bool canTransitionTo(CastSessionState newState) {
    if (newState == CastSessionState.disconnected) return true;
    return _validTransitions[_state]?.contains(newState) ?? false;
  }

  void transitionTo(CastSessionState newState) {
    if (!canTransitionTo(newState)) {
      throw StateError('Invalid transition: $_state -> $newState');
    }
    _state = newState;
    _controller.add(newState);
  }

  /// For testing only — force a state without validation.
  void forceState(CastSessionState state) {
    _state = state;
  }

  void dispose() {
    _controller.close();
  }
}
```

- [ ] **Step 4: Update barrel export**

```dart
// lib/dart_cast.dart — add export
export 'src/core/cast_session.dart';
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
dart test test/core/cast_session_test.dart
```

- [ ] **Step 6: Commit**

```bash
git add lib/src/core/cast_session.dart test/core/cast_session_test.dart lib/dart_cast.dart
git commit -m "feat: add SessionStateMachine with validated state transitions"
```

---

### Task 5b: Abstract CastSession Interface

**Files:**
- Modify: `lib/src/core/cast_session.dart`
- Create: `test/core/cast_session_interface_test.dart`

- [ ] **Step 1: Write failing tests for abstract interface**

```dart
// test/core/cast_session_interface_test.dart
import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

// Minimal concrete implementation for testing the interface
class _TestSession extends CastSession {
  _TestSession(super.device);

  @override
  Future<void> loadMedia(CastMedia media) async {
    stateMachine.transitionTo(CastSessionState.loading);
    stateMachine.transitionTo(CastSessionState.playing);
  }

  @override
  Future<void> play() async => stateMachine.transitionTo(CastSessionState.playing);

  @override
  Future<void> pause() async => stateMachine.transitionTo(CastSessionState.paused);

  @override
  Future<void> stop() async => stateMachine.transitionTo(CastSessionState.idle);

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {}

  @override
  Future<void> disconnect() async {
    stateMachine.transitionTo(CastSessionState.disconnected);
  }
}

void main() {
  group('CastSession abstract interface', () {
    late _TestSession session;
    late CastDevice device;

    setUp(() {
      device = CastDevice(
        id: 'test', name: 'Test TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.1'), port: 8080,
      );
      session = _TestSession(device);
    });

    test('exposes device', () {
      expect(session.device.id, 'test');
    });

    test('exposes state via stateMachine', () {
      expect(session.state, CastSessionState.disconnected);
    });

    test('provides stateStream', () {
      expect(session.stateStream, isA<Stream<CastSessionState>>());
    });

    test('provides positionStream', () {
      expect(session.positionStream, isA<Stream<Duration>>());
    });

    test('provides durationStream', () {
      expect(session.durationStream, isA<Stream<Duration>>());
    });

    test('provides volumeStream', () {
      expect(session.volumeStream, isA<Stream<double>>());
    });

    test('position and duration default to zero', () {
      expect(session.position, Duration.zero);
      expect(session.duration, Duration.zero);
    });

    test('loadMedia transitions through states', () async {
      session.stateMachine.transitionTo(CastSessionState.connecting);
      session.stateMachine.transitionTo(CastSessionState.connected);
      final media = CastMedia(url: 'http://test.com/v.mp4', type: CastMediaType.mp4);
      await session.loadMedia(media);
      expect(session.state, CastSessionState.playing);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Add abstract CastSession class to cast_session.dart**

```dart
// Add to lib/src/core/cast_session.dart after SessionStateMachine

/// Abstract base class for protocol-specific casting sessions.
/// DlnaSession, ChromecastSession, and AirPlaySession extend this.
abstract class CastSession {
  final CastDevice device;
  final SessionStateMachine stateMachine = SessionStateMachine();

  final StreamController<Duration> _positionController = StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController = StreamController<Duration>.broadcast();
  final StreamController<double> _volumeController = StreamController<double>.broadcast();

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  CastSession(this.device);

  CastSessionState get state => stateMachine.state;
  Stream<CastSessionState> get stateStream => stateMachine.stateStream;

  Duration get position => _position;
  Stream<Duration> get positionStream => _positionController.stream;

  Duration get duration => _duration;
  Stream<Duration> get durationStream => _durationController.stream;

  Stream<double> get volumeStream => _volumeController.stream;

  /// Update position (called by subclasses from polling/push updates).
  void updatePosition(Duration pos) {
    _position = pos;
    _positionController.add(pos);
  }

  /// Update duration (called by subclasses).
  void updateDuration(Duration dur) {
    _duration = dur;
    _durationController.add(dur);
  }

  /// Update volume (called by subclasses).
  void updateVolume(double vol) {
    _volumeController.add(vol);
  }

  Future<void> loadMedia(CastMedia media);
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(double volume);
  Future<void> setSubtitle(CastSubtitle? subtitle);
  Future<void> disconnect();

  void dispose() {
    stateMachine.dispose();
    _positionController.close();
    _durationController.close();
    _volumeController.close();
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/core/cast_session_interface_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/cast_session.dart test/core/cast_session_interface_test.dart
git commit -m "feat: add abstract CastSession base class with streams and state"
```

---

### Task 6: Network Utilities

**Files:**
- Create: `lib/src/utils/network_utils.dart`
- Create: `test/utils/network_utils_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
// test/utils/network_utils_test.dart
import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_cast/src/utils/network_utils.dart';

void main() {
  group('NetworkUtils', () {
    test('getLocalIpAddress returns non-loopback IPv4', () async {
      final ip = await NetworkUtils.getLocalIpAddress();
      // On CI or machines without network, may return null
      if (ip != null) {
        expect(ip.type, InternetAddressType.IPv4);
        expect(ip.address, isNot('127.0.0.1'));
      }
    });

    test('findAvailablePort returns a usable port', () async {
      final port = await NetworkUtils.findAvailablePort();
      expect(port, greaterThan(0));
      expect(port, lessThan(65536));
      // Verify it's actually available by binding
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      await server.close();
    });

    test('formatDuration converts to HH:MM:SS', () {
      expect(NetworkUtils.formatDuration(Duration(hours: 1, minutes: 30, seconds: 45)), '01:30:45');
      expect(NetworkUtils.formatDuration(Duration(seconds: 0)), '00:00:00');
      expect(NetworkUtils.formatDuration(Duration(seconds: 61)), '00:01:01');
    });

    test('parseDuration converts from HH:MM:SS', () {
      expect(NetworkUtils.parseDuration('01:30:45'), Duration(hours: 1, minutes: 30, seconds: 45));
      expect(NetworkUtils.parseDuration('00:00:00'), Duration.zero);
      expect(NetworkUtils.parseDuration('00:01:01'), Duration(seconds: 61));
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement NetworkUtils**

```dart
// lib/src/utils/network_utils.dart
import 'dart:io';

class NetworkUtils {
  /// Find the local WiFi/Ethernet IP address for proxy binding.
  static Future<InternetAddress?> getLocalIpAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final interface_ in interfaces) {
      for (final addr in interface_.addresses) {
        if (!addr.isLoopback && !addr.isLinkLocal) {
          return addr;
        }
      }
    }
    return null;
  }

  /// Find an available port by binding to port 0 (OS assigns one).
  static Future<int> findAvailablePort() async {
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    final port = server.port;
    await server.close();
    return port;
  }

  /// Format Duration as HH:MM:SS (for DLNA SOAP).
  static String formatDuration(Duration d) {
    final hours = d.inHours.toString().padLeft(2, '0');
    final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  /// Parse HH:MM:SS string to Duration.
  static Duration parseDuration(String s) {
    final parts = s.split(':');
    if (parts.length != 3) throw FormatException('Invalid duration format: $s');
    return Duration(
      hours: int.parse(parts[0]),
      minutes: int.parse(parts[1]),
      seconds: int.parse(parts[2]),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/utils/network_utils_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/utils/network_utils.dart test/utils/network_utils_test.dart
git commit -m "feat: add NetworkUtils for IP detection, port finding, duration formatting"
```

---

## Chunk 2: Media Proxy Server

### Task 7: HLS Playlist Parser

**Ref:** `docs/protocol-references/hls-m3u8-specification.md` — Section 6 (Tags with URIs), Section 9 (Proxy Strategy)

**Files:**
- Create: `lib/src/core/hls_parser.dart`
- Create: `test/core/hls_parser_test.dart`

- [ ] **Step 1: Write failing tests for HLS parsing and URL rewriting**

```dart
// test/core/hls_parser_test.dart
import 'package:test/test.dart';
import 'package:dart_cast/src/core/hls_parser.dart';

void main() {
  group('HlsParser', () {
    group('isMasterPlaylist', () {
      test('detects master playlist', () {
        const content = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1280000\nlow.m3u8';
        expect(HlsParser.isMasterPlaylist(content), isTrue);
      });

      test('detects media playlist', () {
        const content = '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:9.0,\nseg0.ts';
        expect(HlsParser.isMasterPlaylist(content), isFalse);
      });
    });

    group('resolveUrl', () {
      test('absolute URL unchanged', () {
        expect(
          HlsParser.resolveUrl('https://cdn.example.com/video.ts', 'https://other.com/master.m3u8'),
          'https://cdn.example.com/video.ts',
        );
      });

      test('relative URL resolved against base', () {
        expect(
          HlsParser.resolveUrl('low/prog.m3u8', 'https://cdn.example.com/streams/master.m3u8'),
          'https://cdn.example.com/streams/low/prog.m3u8',
        );
      });

      test('absolute path resolved against base', () {
        expect(
          HlsParser.resolveUrl('/absolute/prog.m3u8', 'https://cdn.example.com/streams/master.m3u8'),
          'https://cdn.example.com/absolute/prog.m3u8',
        );
      });
    });

    group('rewritePlaylist', () {
      test('rewrites master playlist variant URIs', () {
        const content = '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360\n'
            'low/prog.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720\n'
            'mid/prog.m3u8\n';

        final result = HlsParser.rewritePlaylist(
          content: content,
          baseUrl: 'https://cdn.example.com/streams/master.m3u8',
          proxyBaseUrl: 'http://192.168.1.5:8234',
          token: 'abc123',
        );

        expect(result, contains('http://192.168.1.5:8234/proxy/abc123/'));
        expect(result, isNot(contains('low/prog.m3u8')));
        expect(result, isNot(contains('mid/prog.m3u8')));
      });

      test('rewrites media playlist segment URIs', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            'segment0.ts\n'
            '#EXTINF:9.009,\n'
            'segment1.ts\n'
            '#EXT-X-ENDLIST\n';

        final result = HlsParser.rewritePlaylist(
          content: content,
          baseUrl: 'https://cdn.example.com/streams/low/prog.m3u8',
          proxyBaseUrl: 'http://192.168.1.5:8234',
          token: 'abc123',
        );

        expect(result, contains('http://192.168.1.5:8234/proxy/abc123/'));
        expect(result, isNot(contains('segment0.ts\n')));
      });

      test('rewrites EXT-X-KEY URI attribute', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="https://example.com/key.bin",IV=0x01\n'
            '#EXTINF:9.0,\n'
            'seg0.ts\n';

        final result = HlsParser.rewritePlaylist(
          content: content,
          baseUrl: 'https://cdn.example.com/prog.m3u8',
          proxyBaseUrl: 'http://192.168.1.5:8234',
          token: 'abc123',
        );

        expect(result, contains('URI="http://192.168.1.5:8234/proxy/abc123/'));
        expect(result, isNot(contains('URI="https://example.com/key.bin"')));
      });

      test('rewrites EXT-X-MAP URI attribute', () {
        const content = '#EXTM3U\n'
            '#EXT-X-MAP:URI="init.mp4"\n'
            '#EXTINF:9.0,\n'
            'seg0.m4s\n';

        final result = HlsParser.rewritePlaylist(
          content: content,
          baseUrl: 'https://cdn.example.com/prog.m3u8',
          proxyBaseUrl: 'http://192.168.1.5:8234',
          token: 'abc123',
        );

        expect(result, contains('URI="http://192.168.1.5:8234/proxy/abc123/'));
      });

      test('rewrites EXT-X-MEDIA URI attribute', () {
        const content = '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",URI="subs/en.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1280000,SUBTITLES="subs"\n'
            'video.m3u8\n';

        final result = HlsParser.rewritePlaylist(
          content: content,
          baseUrl: 'https://cdn.example.com/master.m3u8',
          proxyBaseUrl: 'http://192.168.1.5:8234',
          token: 'abc123',
        );

        expect(result, contains('URI="http://192.168.1.5:8234/proxy/abc123/'));
      });

      test('preserves non-URI lines', () {
        const content = '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.0,\n'
            'seg.ts\n'
            '#EXT-X-ENDLIST\n';

        final result = HlsParser.rewritePlaylist(
          content: content,
          baseUrl: 'https://cdn.example.com/prog.m3u8',
          proxyBaseUrl: 'http://192.168.1.5:8234',
          token: 'abc123',
        );

        expect(result, contains('#EXT-X-VERSION:3'));
        expect(result, contains('#EXT-X-TARGETDURATION:10'));
        expect(result, contains('#EXT-X-ENDLIST'));
      });
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement HlsParser**

```dart
// lib/src/core/hls_parser.dart

/// Parses and rewrites HLS m3u8 playlists for proxy URL injection.
/// Ref: docs/protocol-references/hls-m3u8-specification.md
class HlsParser {
  /// Tags where the URI is on the NEXT line.
  static const _nextLineUriTags = ['#EXT-X-STREAM-INF:', '#EXTINF:'];

  /// Regex to match URI="..." in tag attributes.
  static final _uriAttributeRegex = RegExp(r'URI="([^"]*)"');

  /// Tags that have URI="..." attributes.
  static const _uriAttributeTags = [
    '#EXT-X-MEDIA:',
    '#EXT-X-I-FRAME-STREAM-INF:',
    '#EXT-X-KEY:',
    '#EXT-X-MAP:',
    '#EXT-X-SESSION-KEY:',
    '#EXT-X-SESSION-DATA:',
  ];

  static bool isMasterPlaylist(String content) {
    return content.contains('#EXT-X-STREAM-INF:') ||
           content.contains('#EXT-X-I-FRAME-STREAM-INF:');
  }

  /// Resolve a potentially relative URL against a base URL.
  static String resolveUrl(String url, String baseUrl) {
    final uri = Uri.parse(url);
    if (uri.hasScheme) return url;
    final base = Uri.parse(baseUrl);
    return base.resolve(url).toString();
  }

  /// Rewrite all URLs in an HLS playlist to go through the proxy.
  static String rewritePlaylist({
    required String content,
    required String baseUrl,
    required String proxyBaseUrl,
    required String token,
  }) {
    final lines = content.split('\n');
    final result = <String>[];
    var nextLineIsUri = false;

    for (final line in lines) {
      if (nextLineIsUri && line.isNotEmpty && !line.startsWith('#')) {
        // This line is a URI (segment or variant playlist)
        final absoluteUrl = resolveUrl(line.trim(), baseUrl);
        final proxyUrl = _buildProxyUrl(proxyBaseUrl, token, absoluteUrl);
        result.add(proxyUrl);
        nextLineIsUri = false;
        continue;
      }

      nextLineIsUri = false;

      // Check if this tag means the next line is a URI
      for (final tag in _nextLineUriTags) {
        if (line.startsWith(tag)) {
          nextLineIsUri = true;
          break;
        }
      }

      // Check if this line has URI="..." attributes
      var processedLine = line;
      for (final tag in _uriAttributeTags) {
        if (line.startsWith(tag)) {
          processedLine = _rewriteUriAttribute(line, baseUrl, proxyBaseUrl, token);
          break;
        }
      }

      result.add(processedLine);
    }

    return result.join('\n');
  }

  static String _rewriteUriAttribute(
    String line, String baseUrl, String proxyBaseUrl, String token,
  ) {
    return line.replaceAllMapped(_uriAttributeRegex, (match) {
      final originalUrl = match.group(1)!;
      final absoluteUrl = resolveUrl(originalUrl, baseUrl);
      final proxyUrl = _buildProxyUrl(proxyBaseUrl, token, absoluteUrl);
      return 'URI="$proxyUrl"';
    });
  }

  static String _buildProxyUrl(String proxyBaseUrl, String token, String originalUrl) {
    final encoded = Uri.encodeComponent(originalUrl);
    return '$proxyBaseUrl/proxy/$token/$encoded';
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/core/hls_parser_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/hls_parser.dart test/core/hls_parser_test.dart
git commit -m "feat: add HLS playlist parser with URL rewriting for proxy"
```

---

### Task 8: Media Proxy Server

**Ref:** Design spec — Media Proxy Server section

**Files:**
- Create: `lib/src/core/media_proxy.dart`
- Create: `test/core/media_proxy_test.dart`

- [ ] **Step 1: Write failing tests for MediaProxy**

```dart
// test/core/media_proxy_test.dart
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:dart_cast/src/core/media_proxy.dart';

void main() {
  group('MediaProxy', () {
    late MediaProxy proxy;
    late HttpServer upstreamServer;

    setUp(() async {
      // Create a mock upstream server
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamServer.listen((request) {
        if (request.uri.path == '/video.mp4') {
          // Check that headers were forwarded
          final referer = request.headers.value('Referer');
          if (referer == 'https://megacloud.blog/') {
            request.response
              ..headers.contentType = ContentType('video', 'mp4')
              ..add([0x00, 0x01, 0x02, 0x03]) // fake video data
              ..close();
          } else {
            request.response
              ..statusCode = HttpStatus.forbidden
              ..close();
          }
        } else if (request.uri.path == '/master.m3u8') {
          request.response
            ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
            ..write('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1280000\nlow.m3u8\n')
            ..close();
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
        }
      });

      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      await upstreamServer.close(force: true);
    });

    test('starts and provides a base URL', () {
      expect(proxy.baseUrl, isNotEmpty);
      expect(proxy.baseUrl, startsWith('http://'));
    });

    test('proxies requests with correct headers', () async {
      final upstreamUrl = 'http://localhost:${upstreamServer.port}/video.mp4';
      final headers = {'Referer': 'https://megacloud.blog/'};
      final proxyUrl = proxy.registerMedia(upstreamUrl, headers);

      final response = await http.get(Uri.parse(proxyUrl));
      expect(response.statusCode, 200);
      expect(response.bodyBytes, [0x00, 0x01, 0x02, 0x03]);
    });

    test('returns 403 when upstream requires headers and proxy does not send them', () async {
      final upstreamUrl = 'http://localhost:${upstreamServer.port}/video.mp4';
      // Register without required headers
      final proxyUrl = proxy.registerMedia(upstreamUrl, {});

      final response = await http.get(Uri.parse(proxyUrl));
      expect(response.statusCode, 403);
    });

    test('rewrites HLS playlist URLs through proxy', () async {
      final upstreamUrl = 'http://localhost:${upstreamServer.port}/master.m3u8';
      final proxyUrl = proxy.registerMedia(upstreamUrl, {});

      final response = await http.get(Uri.parse(proxyUrl));
      expect(response.statusCode, 200);
      final body = response.body;
      // The variant URL should be rewritten to go through the proxy
      expect(body, contains('/proxy/'));
      expect(body, isNot(contains('low.m3u8\n')));
    });

    test('serves local files', () async {
      // Create a temp file
      final tempDir = await Directory.systemTemp.createTemp('dart_cast_test');
      final tempFile = File('${tempDir.path}/test.mp4');
      await tempFile.writeAsBytes([0xDE, 0xAD, 0xBE, 0xEF]);

      final proxyUrl = proxy.registerFile(tempFile.path);
      final response = await http.get(Uri.parse(proxyUrl));

      expect(response.statusCode, 200);
      expect(response.bodyBytes, [0xDE, 0xAD, 0xBE, 0xEF]);

      await tempDir.delete(recursive: true);
    });

    test('returns 404 for unknown tokens', () async {
      final response = await http.get(
        Uri.parse('${proxy.baseUrl}/proxy/nonexistent/http%3A%2F%2Fexample.com'),
      );
      expect(response.statusCode, 404);
    });

    test('cleans up old routes on new registration', () async {
      final url1 = proxy.registerMedia('http://example.com/a.mp4', {});
      proxy.cleanupPreviousMedia();
      final url2 = proxy.registerMedia('http://example.com/b.mp4', {});

      // Old route should be cleaned up
      final response1 = await http.get(Uri.parse(url1));
      expect(response1.statusCode, 404);

      // New route should work (but upstream will fail since example.com isn't real)
      expect(url2, isNotEmpty);
    });

    test('supports Range requests for local files', () async {
      final tempDir = await Directory.systemTemp.createTemp('dart_cast_range');
      final tempFile = File('${tempDir.path}/test.mp4');
      await tempFile.writeAsBytes(List.generate(100, (i) => i));

      final proxyUrl = proxy.registerFile(tempFile.path);
      final response = await http.get(
        Uri.parse(proxyUrl),
        headers: {'Range': 'bytes=10-19'},
      );

      expect(response.statusCode, 206);
      expect(response.bodyBytes, List.generate(10, (i) => i + 10));

      await tempDir.delete(recursive: true);
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement MediaProxy**

```dart
// lib/src/core/media_proxy.dart
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'hls_parser.dart';
import '../utils/logger.dart';
import '../utils/network_utils.dart';

class _ProxyRoute {
  final String originalUrl;
  final Map<String, String> headers;
  final String? localFilePath;
  final bool isFile;

  _ProxyRoute({
    required this.originalUrl,
    required this.headers,
    this.localFilePath,
    this.isFile = false,
  });
}

class MediaProxy {
  HttpServer? _server;
  String? _baseUrl;
  final _routes = <String, _ProxyRoute>{};
  final _httpClient = http.Client();
  String? _currentToken;
  String? _previousToken;

  String get baseUrl => _baseUrl ?? '';
  bool get isRunning => _server != null;

  Future<void> start({int? port}) async {
    if (_server != null) return;

    final localIp = await NetworkUtils.getLocalIpAddress();
    final bindAddress = localIp ?? InternetAddress.anyIPv4;
    final bindPort = port ?? await NetworkUtils.findAvailablePort();

    _server = await HttpServer.bind(bindAddress, bindPort);
    _baseUrl = 'http://${localIp?.address ?? '127.0.0.1'}:$bindPort';

    CastLogger.info('MediaProxy started at $_baseUrl');
    _server!.listen(_handleRequest);
  }

  /// Register a remote URL to be proxied with headers.
  /// Returns the proxy URL to give to the cast device.
  String registerMedia(String url, Map<String, String> headers) {
    final token = _generateToken();
    _previousToken = _currentToken;
    _currentToken = token;
    _routes[token] = _ProxyRoute(originalUrl: url, headers: headers);
    return '$_baseUrl/proxy/$token/${Uri.encodeComponent(url)}';
  }

  /// Register a local file to be served.
  String registerFile(String filePath) {
    final token = _generateToken();
    _previousToken = _currentToken;
    _currentToken = token;
    _routes[token] = _ProxyRoute(
      originalUrl: filePath,
      headers: {},
      localFilePath: filePath,
      isFile: true,
    );
    return '$_baseUrl/file/$token';
  }

  /// Clean up routes from previous media (called on quality/episode switch).
  void cleanupPreviousMedia() {
    if (_previousToken != null) {
      _routes.remove(_previousToken);
      _previousToken = null;
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;

      if (path.startsWith('/proxy/')) {
        await _handleProxyRequest(request);
      } else if (path.startsWith('/file/')) {
        await _handleFileRequest(request);
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..close();
      }
    } catch (e) {
      CastLogger.error('Proxy error: $e');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..close();
      } catch (_) {}
    }
  }

  Future<void> _handleProxyRequest(HttpRequest request) async {
    // Path format: /proxy/{token}/{encoded_url}
    final segments = request.uri.pathSegments;
    if (segments.length < 3) {
      request.response..statusCode = HttpStatus.badRequest..close();
      return;
    }

    final token = segments[1];
    final route = _routes[token];
    if (route == null) {
      request.response..statusCode = HttpStatus.notFound..close();
      return;
    }

    // Decode the target URL from the path
    final encodedUrl = segments.sublist(2).join('/');
    final targetUrl = Uri.decodeComponent(encodedUrl);

    // Forward request with headers
    final headers = Map<String, String>.from(route.headers);

    // Forward Range header if present
    final rangeHeader = request.headers.value('Range');
    if (rangeHeader != null) {
      headers['Range'] = rangeHeader;
    }

    try {
      final upstreamResponse = await _httpClient.get(
        Uri.parse(targetUrl),
        headers: headers,
      );

      // Check if this is an m3u8 playlist that needs rewriting
      final contentType = upstreamResponse.headers['content-type'] ?? '';
      if (contentType.contains('mpegurl') || targetUrl.endsWith('.m3u8')) {
        final rewritten = HlsParser.rewritePlaylist(
          content: upstreamResponse.body,
          baseUrl: targetUrl,
          proxyBaseUrl: _baseUrl!,
          token: token,
        );
        request.response
          ..statusCode = upstreamResponse.statusCode
          ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
          ..write(rewritten)
          ..close();
      } else {
        request.response
          ..statusCode = upstreamResponse.statusCode;

        // Forward content type
        if (contentType.isNotEmpty) {
          request.response.headers.set('Content-Type', contentType);
        }
        request.response
          ..add(upstreamResponse.bodyBytes)
          ..close();
      }
    } catch (e) {
      CastLogger.error('Upstream error for $targetUrl: $e');
      request.response
        ..statusCode = HttpStatus.badGateway
        ..close();
    }
  }

  Future<void> _handleFileRequest(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length < 2) {
      request.response..statusCode = HttpStatus.badRequest..close();
      return;
    }

    final token = segments[1];
    final route = _routes[token];
    if (route == null || !route.isFile || route.localFilePath == null) {
      request.response..statusCode = HttpStatus.notFound..close();
      return;
    }

    final file = File(route.localFilePath!);
    if (!await file.exists()) {
      request.response..statusCode = HttpStatus.notFound..close();
      return;
    }

    final fileLength = await file.length();
    final rangeHeader = request.headers.value('Range');

    if (rangeHeader != null) {
      // Handle Range request
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        final start = int.parse(match.group(1)!);
        final end = match.group(2)!.isEmpty ? fileLength - 1 : int.parse(match.group(2)!);
        final length = end - start + 1;

        request.response
          ..statusCode = HttpStatus.partialContent
          ..headers.set('Content-Range', 'bytes $start-$end/$fileLength')
          ..headers.contentLength = length;

        final stream = file.openRead(start, end + 1);
        await request.response.addStream(stream);
        await request.response.close();
        return;
      }
    }

    // Serve full file
    final ext = file.path.split('.').last.toLowerCase();
    final mimeType = _getMimeType(ext);
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentLength = fileLength
      ..headers.set('Content-Type', mimeType);

    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  String _getMimeType(String extension) {
    switch (extension) {
      case 'mp4': return 'video/mp4';
      case 'ts': return 'video/mp2t';
      case 'mkv': return 'video/x-matroska';
      case 'm3u8': return 'application/vnd.apple.mpegurl';
      case 'vtt': case 'webvtt': return 'text/vtt';
      case 'srt': return 'application/x-subrip';
      default: return 'application/octet-stream';
    }
  }

  String _generateToken() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _baseUrl = null;
    _routes.clear();
    _httpClient.close();
    CastLogger.info('MediaProxy stopped');
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/core/media_proxy_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/core/media_proxy.dart lib/src/core/hls_parser.dart test/core/media_proxy_test.dart
git commit -m "feat: add MediaProxy with HLS rewriting, header injection, and local file serving"
```

---

## Chunk 3: DLNA Protocol

### Task 9: SSDP Message Parsing

**Ref:** `docs/protocol-references/dlna-upnp-protocol.md` — Section 1 (SSDP Discovery)

**Files:**
- Create: `lib/src/protocols/dlna/ssdp_discovery.dart`
- Create: `test/protocols/dlna/ssdp_discovery_test.dart`

- [ ] **Step 1: Write failing tests for SSDP message formatting and parsing**

```dart
// test/protocols/dlna/ssdp_discovery_test.dart
import 'package:test/test.dart';
import 'package:dart_cast/src/protocols/dlna/ssdp_discovery.dart';

void main() {
  group('SsdpMessage', () {
    test('formats M-SEARCH request', () {
      final request = SsdpMessage.mSearch(
        st: 'urn:schemas-upnp-org:device:MediaRenderer:1',
      );
      expect(request, contains('M-SEARCH * HTTP/1.1'));
      expect(request, contains('HOST: 239.255.255.250:1900'));
      expect(request, contains('ST: urn:schemas-upnp-org:device:MediaRenderer:1'));
      expect(request, contains('MAN: "ssdp:discover"'));
      expect(request, contains('MX: 3'));
    });

    test('parses SSDP response', () {
      const response = 'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: http://192.168.1.100:49152/description.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:device-123::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          '\r\n';

      final parsed = SsdpMessage.parseResponse(response);
      expect(parsed.location, 'http://192.168.1.100:49152/description.xml');
      expect(parsed.usn, 'uuid:device-123::urn:schemas-upnp-org:device:MediaRenderer:1');
      expect(parsed.st, 'urn:schemas-upnp-org:device:MediaRenderer:1');
    });

    test('parses NOTIFY message', () {
      const notify = 'NOTIFY * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'LOCATION: http://192.168.1.50:8080/desc.xml\r\n'
          'NT: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'NTS: ssdp:alive\r\n'
          'USN: uuid:abc\r\n'
          '\r\n';

      final parsed = SsdpMessage.parseResponse(notify);
      expect(parsed.location, 'http://192.168.1.50:8080/desc.xml');
    });

    test('returns null location for invalid response', () {
      const response = 'HTTP/1.1 200 OK\r\nSome-Header: value\r\n\r\n';
      final parsed = SsdpMessage.parseResponse(response);
      expect(parsed.location, isNull);
    });

    test('extracts USN device UUID', () {
      const usn = 'uuid:some-unique-id-123::urn:schemas-upnp-org:device:MediaRenderer:1';
      expect(SsdpMessage.extractUuid(usn), 'uuid:some-unique-id-123');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement SsdpMessage**

```dart
// lib/src/protocols/dlna/ssdp_discovery.dart
import 'dart:async';
import 'dart:io';
import '../../core/cast_device.dart';
import '../../utils/logger.dart';

class SsdpResponse {
  final String? location;
  final String? usn;
  final String? st;
  final Map<String, String> headers;

  SsdpResponse({this.location, this.usn, this.st, this.headers = const {}});
}

class SsdpMessage {
  static const multicastAddress = '239.255.255.250';
  static const multicastPort = 1900;

  static const searchTargets = [
    'urn:schemas-upnp-org:device:MediaRenderer:1',
    'urn:schemas-upnp-org:service:AVTransport:1',
  ];

  static String mSearch({required String st, int mx = 3}) {
    return 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $multicastAddress:$multicastPort\r\n'
        'ST: $st\r\n'
        'MX: $mx\r\n'
        'MAN: "ssdp:discover"\r\n'
        '\r\n';
  }

  static SsdpResponse parseResponse(String data) {
    final headers = <String, String>{};
    final lines = data.split('\r\n');

    for (final line in lines) {
      final colonIndex = line.indexOf(':');
      if (colonIndex > 0) {
        final key = line.substring(0, colonIndex).trim().toUpperCase();
        final value = line.substring(colonIndex + 1).trim();
        headers[key] = value;
      }
    }

    return SsdpResponse(
      location: headers['LOCATION'],
      usn: headers['USN'],
      st: headers['ST'] ?? headers['NT'],
      headers: headers,
    );
  }

  static String? extractUuid(String? usn) {
    if (usn == null) return null;
    final parts = usn.split('::');
    return parts.isNotEmpty ? parts[0] : null;
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/protocols/dlna/ssdp_discovery_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/dlna/ssdp_discovery.dart test/protocols/dlna/ssdp_discovery_test.dart
git commit -m "feat: add SSDP message formatting and parsing for DLNA discovery"
```

---

### Task 10: DLNA Device Description XML Parser

**Ref:** `docs/protocol-references/dlna-upnp-protocol.md` — Section 2 (Device Description XML)

**Files:**
- Create: `lib/src/protocols/dlna/dlna_device.dart`
- Create: `test/protocols/dlna/dlna_device_test.dart`

- [ ] **Step 1: Write failing tests**

```dart
// test/protocols/dlna/dlna_device_test.dart
import 'package:test/test.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_device.dart';

void main() {
  group('DlnaDeviceDescription', () {
    const sampleXml = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://192.168.1.100:49152</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Living Room TV</friendlyName>
    <manufacturer>Samsung</manufacturer>
    <modelName>UE55</modelName>
    <UDN>uuid:some-unique-id</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/RenderingControl/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

    test('parses friendly name', () {
      final desc = DlnaDeviceDescription.parse(sampleXml, 'http://192.168.1.100:49152/description.xml');
      expect(desc.friendlyName, 'Living Room TV');
    });

    test('parses manufacturer', () {
      final desc = DlnaDeviceDescription.parse(sampleXml, 'http://192.168.1.100:49152/description.xml');
      expect(desc.manufacturer, 'Samsung');
    });

    test('parses UDN', () {
      final desc = DlnaDeviceDescription.parse(sampleXml, 'http://192.168.1.100:49152/description.xml');
      expect(desc.udn, 'uuid:some-unique-id');
    });

    test('extracts AVTransport control URL', () {
      final desc = DlnaDeviceDescription.parse(sampleXml, 'http://192.168.1.100:49152/description.xml');
      expect(desc.avTransportControlUrl, 'http://192.168.1.100:49152/AVTransport/control');
    });

    test('extracts RenderingControl control URL', () {
      final desc = DlnaDeviceDescription.parse(sampleXml, 'http://192.168.1.100:49152/description.xml');
      expect(desc.renderingControlUrl, 'http://192.168.1.100:49152/RenderingControl/control');
    });

    test('uses location URL as base when URLBase is absent', () {
      const xmlNoBase = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>TV</friendlyName>
    <UDN>uuid:123</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/ctrl</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
      final desc = DlnaDeviceDescription.parse(xmlNoBase, 'http://10.0.0.1:8080/desc.xml');
      expect(desc.avTransportControlUrl, 'http://10.0.0.1:8080/ctrl');
    });

    test('converts to CastDevice', () {
      final desc = DlnaDeviceDescription.parse(sampleXml, 'http://192.168.1.100:49152/description.xml');
      final device = desc.toCastDevice();
      expect(device.name, 'Living Room TV');
      expect(device.protocol, CastProtocol.dlna);
      expect(device.metadata['manufacturer'], 'Samsung');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement DlnaDeviceDescription** (uses `dart:io`'s XML parsing or simple regex since we want minimal dependencies)

```dart
// lib/src/protocols/dlna/dlna_device.dart
import 'dart:io';
import '../../core/cast_device.dart';

class DlnaDeviceDescription {
  final String friendlyName;
  final String? manufacturer;
  final String? modelName;
  final String udn;
  final String? avTransportControlUrl;
  final String? renderingControlUrl;
  final String baseUrl;

  DlnaDeviceDescription({
    required this.friendlyName,
    this.manufacturer,
    this.modelName,
    required this.udn,
    this.avTransportControlUrl,
    this.renderingControlUrl,
    required this.baseUrl,
  });

  factory DlnaDeviceDescription.parse(String xml, String locationUrl) {
    final friendlyName = _extractElement(xml, 'friendlyName') ?? 'Unknown Device';
    final manufacturer = _extractElement(xml, 'manufacturer');
    final modelName = _extractElement(xml, 'modelName');
    final udn = _extractElement(xml, 'UDN') ?? '';

    // Determine base URL: prefer URLBase, fallback to location origin
    var urlBase = _extractElement(xml, 'URLBase');
    if (urlBase == null || urlBase.isEmpty) {
      final uri = Uri.parse(locationUrl);
      urlBase = '${uri.scheme}://${uri.host}:${uri.port}';
    }
    urlBase = urlBase.endsWith('/') ? urlBase.substring(0, urlBase.length - 1) : urlBase;

    // Extract service control URLs
    String? avTransportUrl;
    String? renderingControlUrl;

    final serviceRegex = RegExp(
      r'<service>(.*?)</service>',
      dotAll: true,
    );

    for (final match in serviceRegex.allMatches(xml)) {
      final serviceXml = match.group(1)!;
      final serviceType = _extractElement(serviceXml, 'serviceType') ?? '';
      final controlUrl = _extractElement(serviceXml, 'controlURL');

      if (controlUrl == null) continue;

      final absoluteUrl = controlUrl.startsWith('http')
          ? controlUrl
          : '$urlBase${controlUrl.startsWith('/') ? '' : '/'}$controlUrl';

      if (serviceType.contains('AVTransport')) {
        avTransportUrl = absoluteUrl;
      } else if (serviceType.contains('RenderingControl')) {
        renderingControlUrl = absoluteUrl;
      }
    }

    return DlnaDeviceDescription(
      friendlyName: friendlyName,
      manufacturer: manufacturer,
      modelName: modelName,
      udn: udn,
      avTransportControlUrl: avTransportUrl,
      renderingControlUrl: renderingControlUrl,
      baseUrl: urlBase,
    );
  }

  CastDevice toCastDevice() {
    final uri = Uri.parse(baseUrl);
    return CastDevice(
      id: udn,
      name: friendlyName,
      protocol: CastProtocol.dlna,
      address: InternetAddress(uri.host),
      port: uri.port,
      metadata: {
        if (manufacturer != null) 'manufacturer': manufacturer!,
        if (modelName != null) 'model': modelName!,
        if (avTransportControlUrl != null) 'avTransportUrl': avTransportControlUrl!,
        if (renderingControlUrl != null) 'renderingControlUrl': renderingControlUrl!,
      },
    );
  }

  static String? _extractElement(String xml, String element) {
    final regex = RegExp('<$element>(.*?)</$element>', dotAll: true);
    return regex.firstMatch(xml)?.group(1)?.trim();
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/protocols/dlna/dlna_device_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/dlna/dlna_device.dart test/protocols/dlna/dlna_device_test.dart
git commit -m "feat: add DLNA device description XML parser"
```

---

### Task 11: DLNA SOAP Controller

**Ref:** `docs/protocol-references/dlna-upnp-protocol.md` — Section 3 (SOAP Actions)

**Files:**
- Create: `lib/src/protocols/dlna/dlna_controller.dart`
- Create: `test/protocols/dlna/dlna_controller_test.dart`

- [ ] **Step 1: Write failing tests for SOAP XML generation and response parsing**

Tests should cover:
- `buildSetAVTransportURI()` generates correct SOAP envelope with DIDL-Lite metadata
- `buildPlay()` / `buildPause()` / `buildStop()` generate correct SOAP envelopes
- `buildSeek()` generates correct envelope with REL_TIME format
- `buildGetPositionInfo()` generates correct envelope
- `parsePositionInfo()` extracts TrackDuration and RelTime from response XML
- `parseTransportInfo()` extracts CurrentTransportState from response XML
- `buildSetVolume()` / `buildGetVolume()` use RenderingControl namespace
- `parseVolume()` extracts CurrentVolume
- `buildDidlMetadata()` generates DIDL-Lite with title, URL, protocolInfo, subtitles (sec:CaptionInfoEx)

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement DlnaController with SOAP XML templates**

The implementation should:
- Have static methods for generating each SOAP action XML
- Have static methods for parsing each SOAP response XML
- Use `urn:schemas-upnp-org:service:AVTransport:1` for playback actions
- Use `urn:schemas-upnp-org:service:RenderingControl:1` for volume actions
- Include DIDL-Lite metadata with `sec:CaptionInfoEx` for subtitles
- Use `http` package to send SOAP requests to the device control URL
- Set `SOAPAction` header correctly for each action

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/dlna/dlna_controller.dart test/protocols/dlna/dlna_controller_test.dart
git commit -m "feat: add DLNA SOAP controller with AVTransport and RenderingControl actions"
```

---

### Task 12: DLNA Session

**Files:**
- Create: `lib/src/protocols/dlna/dlna_session.dart`
- Create: `test/protocols/dlna/dlna_session_test.dart`

- [ ] **Step 1: Write failing tests**

Tests should cover:
- Session wraps DlnaController and manages state machine
- `loadMedia()` calls SetAVTransportURI then Play
- `play()` / `pause()` / `stop()` call correct SOAP actions
- `seek()` converts Duration to HH:MM:SS and calls Seek
- `setVolume()` normalizes 0.0-1.0 to 0-100 and calls SetVolume
- Position polling: starts timer on `loadMedia`, calls GetPositionInfo every ~1s, emits on positionStream
- State transitions: loading→playing on successful load, playing→paused on pause, etc.
- `disconnect()` stops polling timer, calls Stop

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement DlnaSession**

The session should:
- Implement the abstract `CastSession` interface
- Hold a reference to the `DlnaDeviceDescription` for control URLs
- Use `SessionStateMachine` for state management
- Start a periodic timer for position polling
- Use `StreamController` for positionStream, durationStream, volumeStream

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/dlna/dlna_session.dart test/protocols/dlna/dlna_session_test.dart
git commit -m "feat: add DlnaSession with playback control and position polling"
```

---

### Task 13: DLNA Integration Test with Mock Server

**Files:**
- Create: `test/integration/mock_dlna_server.dart`
- Create: `test/integration/dlna_integration_test.dart`

- [ ] **Step 1: Write mock DLNA server**

The mock should:
- Listen on UDP for SSDP M-SEARCH and respond with LOCATION
- Serve device description XML on HTTP
- Accept SOAP actions on the AVTransport control URL
- Track state (STOPPED/PLAYING/PAUSED) and position
- Respond to GetPositionInfo with current position/duration
- Respond to GetTransportInfo with current state

- [ ] **Step 2: Write integration test**

Test full flow: discover → connect → loadMedia → play → seek → getPosition → pause → stop → disconnect

- [ ] **Step 3: Run integration test**

```bash
dart test test/integration/dlna_integration_test.dart
```

- [ ] **Step 4: Commit**

```bash
git add test/integration/mock_dlna_server.dart test/integration/dlna_integration_test.dart
git commit -m "test: add DLNA integration test with mock server"
```

---

## Chunk 4: Chromecast Protocol

### Task 14: Protobuf Setup

**Ref:** `docs/protocol-references/chromecast-castv2-protocol.md` — Section 3 (Protobuf Definition)

**Files:**
- Create: `lib/src/protocols/chromecast/proto/cast_channel.proto`
- Create: `lib/src/protocols/chromecast/proto/cast_channel.pb.dart` (generated)
- Create: `lib/src/protocols/chromecast/proto/cast_channel.pbenum.dart` (generated)
- Create: `lib/src/protocols/chromecast/proto/cast_channel.pbjson.dart` (generated)
- Create: `lib/src/protocols/chromecast/proto/cast_channel.pbserver.dart` (generated)

- [ ] **Step 1: Create .proto file from Chromium source**

- [ ] **Step 2: Generate Dart protobuf files**

```bash
protoc --dart_out=lib/src/protocols/chromecast/proto lib/src/protocols/chromecast/proto/cast_channel.proto
```

- [ ] **Step 3: Commit generated files**

```bash
git add lib/src/protocols/chromecast/proto/
git commit -m "feat: add CASTV2 protobuf definition and generated Dart files"
```

---

### Task 15: CASTV2 Channel (TLS + Protobuf Framing)

**Ref:** `docs/protocol-references/chromecast-castv2-protocol.md` — Section 2 (Framing)

**Files:**
- Create: `lib/src/protocols/chromecast/castv2_channel.dart`
- Create: `test/protocols/chromecast/castv2_channel_test.dart`

- [ ] **Step 1: Write failing tests**

Tests should cover:
- Message framing: 4-byte big-endian length prefix encoding/decoding
- Protobuf CastMessage serialization/deserialization
- Building messages with source_id, destination_id, namespace, payload
- Parsing incoming framed messages from a byte stream

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement CastV2Channel**

The implementation should:
- Connect via `SecureSocket` with `onBadCertificate: (_) => true`
- Write 4-byte BE length + protobuf bytes
- Read 4-byte BE length, then read that many bytes, deserialize
- Provide `send(namespace, destinationId, payload)` method
- Provide `Stream<CastMessage>` for incoming messages
- Handle socket errors and disconnection

- [ ] **Step 4: Run tests to verify they pass**

- [ ] **Step 5: Commit**

```bash
git add lib/src/protocols/chromecast/castv2_channel.dart test/protocols/chromecast/castv2_channel_test.dart
git commit -m "feat: add CASTV2 TLS channel with protobuf message framing"
```

---

### Task 16: Chromecast Receiver and Media Channels

**Ref:** `docs/protocol-references/chromecast-castv2-protocol.md` — Sections 4 and 5

**Files:**
- Create: `lib/src/protocols/chromecast/cast_receiver_channel.dart`
- Create: `lib/src/protocols/chromecast/cast_media_channel.dart`
- Create: `test/protocols/chromecast/cast_receiver_channel_test.dart`
- Create: `test/protocols/chromecast/cast_media_channel_test.dart`

- [ ] **Step 1: Write failing tests for receiver channel**

Tests: CONNECT/CLOSE JSON formation, LAUNCH command, GET_STATUS, RECEIVER_STATUS parsing (extracting transportId, sessionId, volume), heartbeat PING/PONG

- [ ] **Step 2: Write failing tests for media channel**

Tests: LOAD command JSON with MP4/HLS/subtitles, PLAY/PAUSE/STOP/SEEK JSON, SET_VOLUME JSON, MEDIA_STATUS parsing (playerState, currentTime, duration, mediaSessionId), EDIT_TRACKS_INFO for subtitle switching

- [ ] **Step 3: Implement both channels**

- [ ] **Step 4: Run all tests**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: add Chromecast receiver and media channel message handling"
```

---

### Task 17: Chromecast Session

**Files:**
- Create: `lib/src/protocols/chromecast/chromecast_session.dart`
- Create: `test/protocols/chromecast/chromecast_session_test.dart`

- [ ] **Step 1: Write failing tests**

Tests should cover the full session lifecycle:
- Connect → CONNECT to receiver-0 → start heartbeat → LAUNCH CC1AD845 → extract transportId → CONNECT to transportId
- loadMedia → LOAD command with proxy URL and subtitles
- play/pause/stop/seek → correct media channel commands with mediaSessionId
- Position updates from MEDIA_STATUS push messages
- Heartbeat keeps connection alive
- disconnect → CLOSE to transportId → CLOSE to receiver-0

- [ ] **Step 2: Implement ChromecastSession**

- [ ] **Step 3: Run tests**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: add ChromecastSession with full lifecycle management"
```

---

### Task 18: Chromecast Integration Test

**Files:**
- Create: `test/integration/mock_chromecast_server.dart`
- Create: `test/integration/chromecast_integration_test.dart`

- [ ] **Step 1: Write mock Chromecast server**

Mock TLS server at port 8009 that responds to CASTV2 protobuf messages: CONNECT, heartbeat PING/PONG, LAUNCH (returns RECEIVER_STATUS with transportId), LOAD (returns MEDIA_STATUS), PLAY/PAUSE/SEEK/STOP

- [ ] **Step 2: Write integration test** — full flow

- [ ] **Step 3: Run and commit**

```bash
git commit -m "test: add Chromecast integration test with mock CASTV2 server"
```

---

## Chunk 5: AirPlay Protocol

### Task 19: XML Plist Parser

**Ref:** `docs/protocol-references/airplay-protocol.md` — Section 2 (playback-info response)

**Files:**
- Create: `lib/src/protocols/airplay/plist_codec.dart`
- Create: `test/protocols/airplay/plist_codec_test.dart`

- [ ] **Step 1: Write failing tests**

Tests: parse XML plist for duration, position, rate, readyToPlay from /playback-info response. Parse /server-info response for features, model.

- [ ] **Step 2: Implement PlistCodec**

- [ ] **Step 3: Run tests and commit**

```bash
git commit -m "feat: add XML plist parser for AirPlay responses"
```

---

### Task 19b: mDNS Discovery Helper

**Ref:** `docs/protocol-references/chromecast-castv2-protocol.md` — Section 1, `docs/protocol-references/airplay-protocol.md` — Section 1

**Files:**
- Create: `lib/src/utils/mdns_discovery.dart`
- Create: `test/utils/mdns_discovery_test.dart`

This is shared infrastructure for both Chromecast (`_googlecast._tcp.local`) and AirPlay (`_airplay._tcp.local`) discovery.

- [ ] **Step 1: Write failing tests for mDNS helper**

```dart
// test/utils/mdns_discovery_test.dart
import 'package:test/test.dart';
import 'package:dart_cast/src/utils/mdns_discovery.dart';

void main() {
  group('MdnsServiceInfo', () {
    test('parses Chromecast TXT records', () {
      final txtRecords = {
        'fn': 'Living Room TV',
        'md': 'Chromecast Ultra',
        'id': '9472d23123344568',
      };
      final info = MdnsServiceInfo(
        name: 'Living Room TV._googlecast._tcp.local',
        host: '192.168.1.100',
        port: 8009,
        txtRecords: txtRecords,
      );
      expect(info.friendlyName, 'Living Room TV');
      expect(info.deviceId, '9472d23123344568');
      expect(info.model, 'Chromecast Ultra');
    });

    test('parses AirPlay TXT records', () {
      final txtRecords = {
        'deviceid': 'AA:BB:CC:DD:EE:FF',
        'features': '0x5A7FFFF7,0x1E',
        'model': 'AppleTV3,1',
      };
      final info = MdnsServiceInfo(
        name: 'Apple TV._airplay._tcp.local',
        host: '192.168.1.50',
        port: 7000,
        txtRecords: txtRecords,
      );
      expect(info.host, '192.168.1.50');
      expect(info.port, 7000);
    });

    test('detects video support from AirPlay features bitmask', () {
      // Bit 0 (0x01) = video supported
      expect(MdnsServiceInfo.supportsVideo('0x77'), isTrue);   // has bit 0
      expect(MdnsServiceInfo.supportsVideo('0x02'), isFalse);  // no bit 0
      expect(MdnsServiceInfo.supportsVideo('0x5A7FFFF7,0x1E'), isTrue); // two-part format
    });
  });

  group('MdnsDiscovery', () {
    test('Chromecast service type is correct', () {
      expect(MdnsDiscovery.chromecastServiceType, '_googlecast._tcp.local');
    });

    test('AirPlay service type is correct', () {
      expect(MdnsDiscovery.airplayServiceType, '_airplay._tcp.local');
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

- [ ] **Step 3: Implement MdnsDiscovery helper**

```dart
// lib/src/utils/mdns_discovery.dart
import 'dart:io';
import '../core/cast_device.dart';

/// Parsed mDNS service information.
class MdnsServiceInfo {
  final String name;
  final String host;
  final int port;
  final Map<String, String> txtRecords;

  MdnsServiceInfo({
    required this.name,
    required this.host,
    required this.port,
    this.txtRecords = const {},
  });

  /// Get friendly name from TXT records (Chromecast uses 'fn', AirPlay uses service name).
  String get friendlyName => txtRecords['fn'] ?? name.split('.').first;

  /// Get device ID from TXT records.
  String get deviceId => txtRecords['id'] ?? txtRecords['deviceid'] ?? name;

  /// Get model from TXT records.
  String? get model => txtRecords['md'] ?? txtRecords['model'];

  /// Check if AirPlay features bitmask includes video support (bit 0).
  static bool supportsVideo(String features) {
    // Handle two-part format: "0x5A7FFFF7,0x1E"
    final lower = features.split(',').first.trim();
    final value = int.tryParse(lower.replaceFirst('0x', ''), radix: 16) ?? 0;
    return (value & 0x01) != 0;
  }

  CastDevice toChromecastDevice() => CastDevice(
    id: deviceId,
    name: friendlyName,
    protocol: CastProtocol.chromecast,
    address: InternetAddress(host),
    port: port,
    metadata: {
      if (model != null) 'model': model!,
      ...txtRecords,
    },
  );

  CastDevice toAirplayDevice() => CastDevice(
    id: deviceId,
    name: friendlyName,
    protocol: CastProtocol.airplay,
    address: InternetAddress(host),
    port: port,
    metadata: {
      if (model != null) 'model': model!,
      ...txtRecords,
    },
  );
}

/// mDNS discovery wrapper. Uses multicast_dns package by default.
/// On Apple platforms, consumers inject bonsoir-based discovery via DeviceDiscoveryProvider.
class MdnsDiscovery {
  static const chromecastServiceType = '_googlecast._tcp.local';
  static const airplayServiceType = '_airplay._tcp.local';
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dart test test/utils/mdns_discovery_test.dart
```

- [ ] **Step 5: Commit**

```bash
git add lib/src/utils/mdns_discovery.dart test/utils/mdns_discovery_test.dart
git commit -m "feat: add mDNS discovery helper for Chromecast and AirPlay"
```

---

### Task 20: AirPlay Client

**Ref:** `docs/protocol-references/airplay-protocol.md` — Section 2 (HTTP Endpoints)

**Files:**
- Create: `lib/src/protocols/airplay/airplay_client.dart`
- Create: `test/protocols/airplay/airplay_client_test.dart`

- [ ] **Step 1: Write failing tests**

Tests: POST /play body formation (text/parameters with Content-Location and Start-Position), POST /scrub?position=N, POST /rate?value=0|1, POST /stop, GET /playback-info parsing, GET /server-info, X-Apple-Session-ID header

- [ ] **Step 2: Implement AirPlayClient**

- [ ] **Step 3: Run tests and commit**

```bash
git commit -m "feat: add AirPlay HTTP client for video casting control"
```

---

### Task 21: AirPlay Session

**Files:**
- Create: `lib/src/protocols/airplay/airplay_session.dart`
- Create: `test/protocols/airplay/airplay_session_test.dart`

- [ ] **Step 1: Write failing tests**

Tests: loadMedia → POST /play with proxy URL, play/pause via /rate, seek via /scrub, stop via /stop, position polling via /playback-info, subtitle injection via HLS playlist rewriting, state machine transitions, disconnect cleanup

- [ ] **Step 2: Implement AirPlaySession**

- [ ] **Step 3: Run tests and commit**

```bash
git commit -m "feat: add AirPlaySession with playback control and position polling"
```

---

### Task 22: AirPlay Integration Test

**Files:**
- Create: `test/integration/mock_airplay_server.dart`
- Create: `test/integration/airplay_integration_test.dart`

- [ ] **Step 1: Write mock AirPlay HTTP server** — handles /play, /scrub, /rate, /stop, /playback-info, /server-info

- [ ] **Step 2: Write integration test** — full flow

- [ ] **Step 3: Run and commit**

```bash
git commit -m "test: add AirPlay integration test with mock HTTP server"
```

---

## Chunk 6: Discovery Manager + CastService + Polish

### Task 23: Discovery Provider Interface and Manager

**Files:**
- Create: `lib/src/core/discovery_provider.dart`
- Create: `lib/src/core/discovery_manager.dart`
- Create: `test/core/discovery_manager_test.dart`

- [ ] **Step 1: Write failing tests**

Tests: DiscoveryManager merges devices from multiple providers, deduplicates by device ID, emits updated lists as devices appear/disappear, filters by protocol, respects timeout

- [ ] **Step 2: Implement DiscoveryProvider interface and DiscoveryManager**

```dart
abstract class DeviceDiscoveryProvider {
  CastProtocol get protocol;
  Stream<List<CastDevice>> startDiscovery({Duration timeout});
  void stopDiscovery();
}
```

DiscoveryManager takes a list of providers, merges their streams, deduplicates.

- [ ] **Step 3: Run tests and commit**

```bash
git commit -m "feat: add pluggable DiscoveryManager merging multiple protocol providers"
```

---

### Task 24: DLNA, Chromecast, and AirPlay Discovery Providers

**Files:**
- Create: `lib/src/protocols/dlna/dlna_discovery_provider.dart`
- Create: `lib/src/protocols/chromecast/chromecast_discovery_provider.dart`
- Create: `lib/src/protocols/airplay/airplay_discovery_provider.dart`

Each provider implements `DeviceDiscoveryProvider` and wraps the protocol-specific discovery logic.

- [ ] **Step 1: Write failing tests for each discovery provider**

Tests should cover:
- DlnaDiscoveryProvider: sends M-SEARCH, parses responses, fetches device descriptions, returns CastDevice list
- ChromecastDiscoveryProvider: queries mDNS for `_googlecast._tcp.local`, parses TXT records, returns CastDevice list
- AirPlayDiscoveryProvider: queries mDNS for `_airplay._tcp.local`, filters by video support bit, returns CastDevice list
- All providers implement `DeviceDiscoveryProvider` interface correctly
- `stopDiscovery()` cleans up resources

- [ ] **Step 2: Implement providers**
- [ ] **Step 3: Run tests to verify they pass**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: add discovery providers for DLNA, Chromecast, and AirPlay"
```

---

### Task 25: CastService (Main Entry Point)

**Files:**
- Create: `lib/src/core/cast_service.dart`
- Create: `test/core/cast_service_test.dart`

- [ ] **Step 1: Write failing tests**

Tests (happy path):
- `startDiscovery()` returns stream of devices
- `stopDiscovery()` stops all providers
- `connect(device)` creates correct session type based on protocol (DlnaSession for dlna, ChromecastSession for chromecast, AirPlaySession for airplay)
- `connect()` while connected auto-disconnects previous session then connects new
- `activeSession` returns current session, null when not connected
- `lastDevice` returns last connected device
- `setLastDevice()` / `reconnect()` workflow
- `dispose()` stops proxy and discovery

Tests (error handling — per design spec "Error Behavior by Method" table):
- `startDiscovery()` with no network returns empty stream
- `startDiscovery()` called twice stops previous discovery and starts new
- `connect()` to offline device throws `DeviceUnreachableException`
- `reconnect()` with no last device returns null
- `reconnect()` with offline last device throws `DeviceUnreachableException`
- `loadMedia()` called while loading cancels previous load
- Proxy starts automatically on first `loadMedia()` call

- [ ] **Step 2: Implement CastService**

```dart
class CastService {
  final DiscoveryManager _discoveryManager;
  final MediaProxy _proxy;
  CastSession? _activeSession;
  CastDevice? _lastDevice;

  // ... implementation per design spec
}
```

- [ ] **Step 3: Run tests and commit**

```bash
git commit -m "feat: add CastService as unified entry point for casting"
```

---

### Task 26: Update Barrel Export

- [ ] **Step 1: Update `lib/dart_cast.dart` to export all public APIs**

```dart
library dart_cast;

export 'src/core/cast_device.dart';
export 'src/core/cast_media.dart';
export 'src/core/cast_session.dart';
export 'src/core/cast_exceptions.dart';
export 'src/core/cast_service.dart';
export 'src/core/discovery_provider.dart';
```

- [ ] **Step 2: Run all tests**

```bash
dart test
```

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: update barrel exports for complete public API"
```

---

## Chunk 7: Example App + Documentation

### Task 27: Flutter Example App

**Files:**
- Create: `example/pubspec.yaml`
- Create: `example/lib/main.dart`
- Create: `example/lib/device_discovery_page.dart`
- Create: `example/lib/remote_control_page.dart`

- [ ] **Step 1: Create example pubspec.yaml**

```yaml
name: dart_cast_example
description: Example app demonstrating dart_cast usage.
publish_to: none

environment:
  sdk: ^3.0.0
  flutter: ">=3.0.0"

dependencies:
  flutter:
    sdk: flutter
  dart_cast:
    path: ../
  bonsoir: ^5.1.0  # For Apple platform mDNS
```

- [ ] **Step 2: Implement main.dart** — MaterialApp with device discovery page as home

- [ ] **Step 3: Implement device_discovery_page.dart** — shows cast button, opens device picker dialog, lists discovered devices by protocol

- [ ] **Step 4: Implement remote_control_page.dart** — full remote control: play/pause, seek slider, volume slider, subtitle picker, episode info, disconnect button

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: add Flutter example app with device picker and remote control"
```

---

### Task 28: README and Documentation

**Files:**
- Create: `README.md`
- Create: `CHANGELOG.md`
- Create: `CONTRIBUTING.md`
- Create: `LICENSE`

- [ ] **Step 1: Write README.md**

Include:
- Package description and features
- Supported protocols and platforms table
- Quick start code example
- API overview (CastService, CastDevice, CastSession, CastMedia)
- Platform setup (iOS Info.plist, Android permissions, macOS entitlements)
- How the proxy works (brief)
- How to use pluggable discovery (bonsoir injection)
- Link to example app

- [ ] **Step 2: Write CHANGELOG.md**

```markdown
## 0.1.0
- Initial release
- Chromecast (CASTV2), AirPlay, and DLNA support
- Built-in HTTP proxy for header injection
- HLS playlist URL rewriting
- Local file serving for downloaded content
- Subtitle support across all protocols
- Cross-platform: Android, iOS, macOS, Windows, Linux
```

- [ ] **Step 3: Write CONTRIBUTING.md**

Include protobuf regeneration instructions:
```bash
protoc --dart_out=lib/src/protocols/chromecast/proto lib/src/protocols/chromecast/proto/cast_channel.proto
```

- [ ] **Step 4: Add LICENSE** (MIT or your preferred license)

- [ ] **Step 5: Commit**

```bash
git commit -m "docs: add README, CHANGELOG, CONTRIBUTING, and LICENSE"
```

---

### Task 29: Final Verification

- [ ] **Step 1: Run full test suite**

```bash
cd /Users/AbdelazizMahdy/flutter_projects/dart_cast
dart test
```

- [ ] **Step 2: Run dart analyze**

```bash
dart analyze
```

- [ ] **Step 3: Run dart format**

```bash
dart format lib/ test/
```

- [ ] **Step 4: Fix any issues and commit**

```bash
git commit -m "chore: fix analysis warnings and format code"
```

- [ ] **Step 5: Verify example app builds**

```bash
cd example && flutter pub get && flutter analyze
```

---

## Chunk 8: anime_here Integration (Separate Repo)

> This chunk is executed in the anime_here repository at `/Users/AbdelazizMahdy/flutter_projects/anime_here/`

### Task 30: Add dart_cast Dependency

- [ ] **Step 1: Add to pubspec.yaml**

```yaml
dependencies:
  dart_cast:
    path: ../dart_cast
  bonsoir: ^5.1.0
```

- [ ] **Step 2: Run flutter pub get**

- [ ] **Step 3: Commit**

---

### Task 31: CastController

**Files:**
- Create: `lib/controllers/cast_controller.dart`

Wraps CastService with GetX controller (the app uses GetX). Manages:
- Discovery state
- Active session
- Last device persistence (SharedPreferences)
- Watch progress sync via positionStream → database

---

### Task 32: Cast UI

**Files:**
- Create: `lib/widgets/cast_button.dart`
- Create: `lib/screens/cast/device_picker_dialog.dart`
- Create: `lib/screens/cast/remote_control_screen.dart`
- Modify: `lib/screens/video_player/streaming_content_video_player.dart` — add cast button
- Modify: `lib/screens/video_player/downloaded_content_video_player.dart` — add cast button
- Modify: Episode detail screen — add cast button

---

### Task 33: VideoPlayerListener Refactoring

**Files:**
- Modify: `lib/controllers/video_player_listener.dart`

Refactor to accept `Stream<Duration>` position source (backward-compatible).

---

### Task 34: Platform Configuration

**Files:**
- Modify: `ios/Runner/Info.plist` — add NSLocalNetworkUsageDescription, NSBonjourServices
- Modify: `android/app/src/main/AndroidManifest.xml` — add multicast and nearby device permissions
- Modify: `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` — add network entitlements

---

### Task 35: Integration Testing

- [ ] Run all existing 470+ tests to verify no regressions
- [ ] Manual testing with real Chromecast/DLNA/AirPlay devices
