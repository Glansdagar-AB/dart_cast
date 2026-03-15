import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_service.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/core/discovery_provider.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Mock discovery provider
// ---------------------------------------------------------------------------

class MockDiscoveryProvider implements DeviceDiscoveryProvider {
  @override
  final CastProtocol protocol;
  final List<List<CastDevice>> emissions;
  bool stopped = false;
  bool disposed = false;
  int stopCount = 0;

  MockDiscoveryProvider({
    required this.protocol,
    this.emissions = const [],
  });

  @override
  Stream<List<CastDevice>> startDiscovery({Duration timeout = const Duration(seconds: 10)}) {
    stopped = false;
    final controller = StreamController<List<CastDevice>>();
    () async {
      for (final list in emissions) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (!controller.isClosed) {
          controller.add(list);
        }
      }
      if (!controller.isClosed) {
        controller.close();
      }
    }();
    return controller.stream;
  }

  @override
  void stopDiscovery() {
    stopped = true;
    stopCount++;
  }

  @override
  void dispose() {
    disposed = true;
    stopDiscovery();
  }
}

// ---------------------------------------------------------------------------
// Mock session
// ---------------------------------------------------------------------------

class MockCastSession extends CastSession {
  bool disconnected = false;
  bool loadCalled = false;

  MockCastSession(super.device);

  @override
  Future<void> loadMedia(CastMedia media) async {
    loadCalled = true;
  }

  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {}

  @override
  Future<void> disconnect() async {
    disconnected = true;
    stateMachine.forceState(SessionState.disconnected);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

CastDevice _device(String id, CastProtocol protocol) => CastDevice(
      id: id,
      name: 'Device $id',
      protocol: protocol,
      address: InternetAddress('192.168.1.1'),
      port: 8008,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('CastService', () {
    test('startDiscovery returns stream of devices', () async {
      final dlnaDevice = _device('d1', CastProtocol.dlna);
      final provider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [dlnaDevice],
        ],
      );

      final service = CastService(
        discoveryProviders: [provider],
        sessionFactory: (device) => MockCastSession(device),
      );

      final results = await service.startDiscovery(
        timeout: const Duration(milliseconds: 500),
      ).toList();

      expect(results, isNotEmpty);
      expect(results.last.first.id, equals('d1'));

      service.dispose();
    });

    test('stopDiscovery stops all providers', () async {
      final provider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [_device('d1', CastProtocol.dlna)],
        ],
      );

      final service = CastService(
        discoveryProviders: [provider],
        sessionFactory: (device) => MockCastSession(device),
      );

      service.startDiscovery(timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      service.stopDiscovery();

      // The DiscoveryManager calls stop on the provider
      expect(provider.stopped, isTrue);

      service.dispose();
    });

    test('connect creates correct session type per protocol', () async {
      final dlnaDevice = _device('d1', CastProtocol.dlna);
      final ccDevice = _device('c1', CastProtocol.chromecast);
      final apDevice = _device('a1', CastProtocol.airplay);

      final sessions = <String, MockCastSession>{};
      final service = CastService(
        discoveryProviders: [],
        sessionFactory: (device) {
          final session = MockCastSession(device);
          sessions[device.id] = session;
          return session;
        },
      );

      final s1 = await service.connect(dlnaDevice);
      expect(s1.device.protocol, equals(CastProtocol.dlna));

      // Disconnect before connecting to next
      final s2 = await service.connect(ccDevice);
      expect(s2.device.protocol, equals(CastProtocol.chromecast));
      expect(sessions['d1']!.disconnected, isTrue); // auto-disconnect

      final s3 = await service.connect(apDevice);
      expect(s3.device.protocol, equals(CastProtocol.airplay));
      expect(sessions['c1']!.disconnected, isTrue);

      service.dispose();
    });

    test('connect while connected auto-disconnects previous', () async {
      final device1 = _device('d1', CastProtocol.dlna);
      final device2 = _device('d2', CastProtocol.chromecast);

      MockCastSession? firstSession;
      final service = CastService(
        discoveryProviders: [],
        sessionFactory: (device) {
          final session = MockCastSession(device);
          if (device.id == 'd1') firstSession = session;
          return session;
        },
      );

      await service.connect(device1);
      expect(firstSession, isNotNull);
      expect(firstSession!.disconnected, isFalse);

      await service.connect(device2);
      expect(firstSession!.disconnected, isTrue);

      service.dispose();
    });

    test('activeSession returns current session', () async {
      final device = _device('d1', CastProtocol.dlna);

      final service = CastService(
        discoveryProviders: [],
        sessionFactory: (device) => MockCastSession(device),
      );

      expect(service.activeSession, isNull);

      final session = await service.connect(device);
      expect(service.activeSession, same(session));

      service.dispose();
    });

    test('lastDevice / setLastDevice / reconnect workflow', () async {
      final device = _device('d1', CastProtocol.dlna);

      final service = CastService(
        discoveryProviders: [],
        sessionFactory: (device) => MockCastSession(device),
      );

      expect(service.lastDevice, isNull);

      service.setLastDevice(device);
      expect(service.lastDevice, equals(device));

      final session = await service.reconnect();
      expect(session, isNotNull);
      expect(session!.device.id, equals('d1'));

      service.dispose();
    });

    test('reconnect with no last device returns null', () async {
      final service = CastService(
        discoveryProviders: [],
        sessionFactory: (device) => MockCastSession(device),
      );

      final session = await service.reconnect();
      expect(session, isNull);

      service.dispose();
    });

    test('connect sets lastDevice', () async {
      final device = _device('d1', CastProtocol.dlna);

      final service = CastService(
        discoveryProviders: [],
        sessionFactory: (device) => MockCastSession(device),
      );

      await service.connect(device);
      expect(service.lastDevice, equals(device));

      service.dispose();
    });

    test('startDiscovery called twice stops previous', () async {
      final provider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [_device('d1', CastProtocol.dlna)],
        ],
      );

      final service = CastService(
        discoveryProviders: [provider],
        sessionFactory: (device) => MockCastSession(device),
      );

      service.startDiscovery(timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final stopsBefore = provider.stopCount;

      // Second call should stop first
      service.startDiscovery(timeout: const Duration(milliseconds: 200));

      // Provider was stopped by the first discovery being cancelled then re-started
      expect(provider.stopCount, greaterThan(stopsBefore));

      service.dispose();
    });

    test('dispose cleans up everything', () async {
      final provider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [],
      );

      MockCastSession? session;
      final service = CastService(
        discoveryProviders: [provider],
        sessionFactory: (device) {
          session = MockCastSession(device);
          return session!;
        },
      );

      await service.connect(_device('d1', CastProtocol.dlna));
      expect(session, isNotNull);

      service.dispose();

      expect(provider.disposed, isTrue);
      expect(session!.disconnected, isTrue);
    });
  });
}
