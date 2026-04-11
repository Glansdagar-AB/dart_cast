import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/discovery_manager.dart';
import 'package:dart_cast/src/core/discovery_provider.dart';
import 'package:test/test.dart';

/// A mock discovery provider for testing.
class MockDiscoveryProvider implements DeviceDiscoveryProvider {
  @override
  final CastProtocol protocol;

  final List<List<CastDevice>> emissions;
  final Duration emissionInterval;

  StreamController<List<CastDevice>>? _controller;
  Timer? _timer;
  bool disposed = false;
  bool stopped = false;

  MockDiscoveryProvider({
    required this.protocol,
    required this.emissions,
    this.emissionInterval = const Duration(milliseconds: 50),
  });

  @override
  Stream<List<CastDevice>> startDiscovery({
    Duration timeout = const Duration(seconds: 10),
  }) {
    stopped = false;
    _controller = StreamController<List<CastDevice>>();
    var index = 0;
    _timer = Timer.periodic(emissionInterval, (timer) {
      if (index < emissions.length) {
        _controller?.add(emissions[index]);
        index++;
      } else {
        timer.cancel();
        _controller?.close();
      }
    });
    return _controller!.stream;
  }

  @override
  void stopDiscovery() {
    stopped = true;
    _timer?.cancel();
    _controller?.close();
  }

  @override
  void dispose() {
    disposed = true;
    stopDiscovery();
  }
}

CastDevice _device(String id, String name, CastProtocol protocol) {
  return CastDevice(
    id: id,
    name: name,
    protocol: protocol,
    address: InternetAddress('192.168.1.1'),
    port: 8008,
  );
}

void main() {
  group('DiscoveryManager', () {
    test('merges devices from multiple providers', () async {
      final dlnaDevice = _device('dlna-1', 'DLNA TV', CastProtocol.dlna);
      final chromecastDevice = _device(
        'cc-1',
        'Chromecast',
        CastProtocol.chromecast,
      );

      final dlnaProvider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [dlnaDevice],
        ],
      );
      final ccProvider = MockDiscoveryProvider(
        protocol: CastProtocol.chromecast,
        emissions: [
          [chromecastDevice],
        ],
      );

      final manager = DiscoveryManager([dlnaProvider, ccProvider]);
      final results = await manager.startDiscovery().toList();

      // At least the final emission should contain both devices
      final lastList = results.last;
      expect(lastList, hasLength(2));
      expect(lastList.any((d) => d.id == 'dlna-1'), isTrue);
      expect(lastList.any((d) => d.id == 'cc-1'), isTrue);

      manager.dispose();
    });

    test('deduplicates devices by ID', () async {
      final device1 = _device('same-id', 'Device A', CastProtocol.dlna);
      final device2 = _device('same-id', 'Device B', CastProtocol.chromecast);

      final provider1 = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [device1],
        ],
      );
      final provider2 = MockDiscoveryProvider(
        protocol: CastProtocol.chromecast,
        emissions: [
          [device2],
        ],
      );

      final manager = DiscoveryManager([provider1, provider2]);
      final results = await manager.startDiscovery().toList();
      final lastList = results.last;

      // Should only contain one device with ID 'same-id'
      expect(lastList.where((d) => d.id == 'same-id').length, 1);

      manager.dispose();
    });

    test('filters by protocol', () async {
      final dlnaDevice = _device('dlna-1', 'DLNA TV', CastProtocol.dlna);
      final chromecastDevice = _device(
        'cc-1',
        'Chromecast',
        CastProtocol.chromecast,
      );

      final dlnaProvider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [dlnaDevice],
        ],
      );
      final ccProvider = MockDiscoveryProvider(
        protocol: CastProtocol.chromecast,
        emissions: [
          [chromecastDevice],
        ],
      );

      final manager = DiscoveryManager([dlnaProvider, ccProvider]);
      final results =
          await manager.startDiscovery(protocols: {CastProtocol.dlna}).toList();

      // Only DLNA provider was started, so only DLNA device should appear
      for (final list in results) {
        for (final device in list) {
          expect(device.protocol, equals(CastProtocol.dlna));
        }
      }

      // Chromecast provider should not have been stopped (it was never started)
      expect(ccProvider.stopped, isFalse);

      manager.dispose();
    });

    test('stopDiscovery stops all providers', () async {
      final dlnaProvider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [_device('d1', 'D1', CastProtocol.dlna)],
        ],
        emissionInterval: const Duration(seconds: 5), // slow, won't emit
      );
      final ccProvider = MockDiscoveryProvider(
        protocol: CastProtocol.chromecast,
        emissions: [
          [_device('c1', 'C1', CastProtocol.chromecast)],
        ],
        emissionInterval: const Duration(seconds: 5),
      );

      final manager = DiscoveryManager([dlnaProvider, ccProvider]);
      // Start but don't await completion
      manager.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      manager.stopDiscovery();

      expect(dlnaProvider.stopped, isTrue);
      expect(ccProvider.stopped, isTrue);

      manager.dispose();
    });

    test('dispose disposes all providers', () {
      final dlnaProvider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [],
      );
      final ccProvider = MockDiscoveryProvider(
        protocol: CastProtocol.chromecast,
        emissions: [],
      );

      final manager = DiscoveryManager([dlnaProvider, ccProvider]);
      manager.dispose();

      expect(dlnaProvider.disposed, isTrue);
      expect(ccProvider.disposed, isTrue);
    });

    test('startDiscovery with timeout parameter', () async {
      final provider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [_device('d1', 'D1', CastProtocol.dlna)],
        ],
      );

      final manager = DiscoveryManager([provider]);
      final results =
          await manager
              .startDiscovery(timeout: const Duration(milliseconds: 200))
              .toList();

      expect(results, isNotEmpty);

      manager.dispose();
    });

    test('emits updated combined list as devices appear', () async {
      final device1 = _device('d1', 'Device 1', CastProtocol.dlna);
      final device2 = _device('d2', 'Device 2', CastProtocol.dlna);

      final provider = MockDiscoveryProvider(
        protocol: CastProtocol.dlna,
        emissions: [
          [device1],
          [device1, device2],
        ],
      );

      final manager = DiscoveryManager([provider]);
      final results = await manager.startDiscovery().toList();

      expect(results.length, greaterThanOrEqualTo(2));
      expect(results.first.length, 1);
      expect(results.last.length, 2);

      manager.dispose();
    });
  });
}
