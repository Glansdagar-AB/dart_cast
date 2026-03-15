import 'dart:async';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_discovery_provider.dart';
import 'package:dart_cast/src/utils/mdns_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('AirPlayDiscoveryProvider', () {
    test('protocol is CastProtocol.airplay', () {
      final provider = AirPlayDiscoveryProvider();
      expect(provider.protocol, equals(CastProtocol.airplay));
    });

    test('default constructor uses real mDNS lookup without error', () {
      // Verifies that constructing with the default (real) mDNS lookup
      // does not throw. Actual discovery requires network devices.
      final provider = AirPlayDiscoveryProvider();
      expect(provider, isA<AirPlayDiscoveryProvider>());
      provider.dispose();
    });

    test('discovers AirPlay devices with video support', () async {
      final provider = AirPlayDiscoveryProvider(
        mdnsLookup: (serviceType) {
          expect(serviceType, equals(MdnsDiscovery.airplayServiceType));
          return Stream.fromIterable([
            const MdnsServiceInfo(
              name: 'Apple TV',
              host: '192.168.1.60',
              port: 7000,
              txtRecords: {
                'deviceid': 'ap-abc-123',
                'model': 'AppleTV6,2',
                'features': '0x5A7FFFF7,0x1E',
              },
            ),
          ]);
        },
      );

      final results = await provider
          .startDiscovery(timeout: const Duration(milliseconds: 500))
          .toList();

      expect(results, isNotEmpty);
      final devices = results.last;
      expect(devices, hasLength(1));
      expect(devices.first.name, equals('Apple TV'));
      expect(devices.first.id, equals('ap-abc-123'));
      expect(devices.first.protocol, equals(CastProtocol.airplay));
      expect(devices.first.port, equals(7000));

      provider.dispose();
    });

    test('includes devices regardless of features bitmask (AirPlay 2 compat)',
        () async {
      final provider = AirPlayDiscoveryProvider(
        mdnsLookup: (serviceType) {
          return Stream.fromIterable([
            const MdnsServiceInfo(
              name: 'AirPlay2 TV',
              host: '192.168.1.70',
              port: 7000,
              txtRecords: {
                'deviceid': 'ap-tv',
                'model': 'TCL_TV',
                'features': '0x7F8AD0,0xBCF46', // AirPlay 2 — bit 0 not set
              },
            ),
          ]);
        },
      );

      final results = await provider
          .startDiscovery(timeout: const Duration(milliseconds: 500))
          .toList();

      // AirPlay 2 devices should NOT be filtered — features bitmask is unreliable
      expect(results.last.where((d) => d.id == 'ap-tv'), isNotEmpty);

      provider.dispose();
    });

    test('includes devices with empty features', () async {
      final provider = AirPlayDiscoveryProvider(
        mdnsLookup: (serviceType) {
          return Stream.fromIterable([
            const MdnsServiceInfo(
              name: 'No Features',
              host: '192.168.1.71',
              port: 7000,
              txtRecords: {
                'deviceid': 'ap-nofeat',
                'model': 'Unknown',
              },
            ),
          ]);
        },
      );

      final results = await provider
          .startDiscovery(timeout: const Duration(milliseconds: 500))
          .toList();

      // Devices without features should still be included
      expect(results.last.where((d) => d.id == 'ap-nofeat'), isNotEmpty);

      provider.dispose();
    });

    test('deduplicates by device ID', () async {
      final provider = AirPlayDiscoveryProvider(
        mdnsLookup: (serviceType) {
          return Stream.fromIterable([
            const MdnsServiceInfo(
              name: 'ATV',
              host: '192.168.1.60',
              port: 7000,
              txtRecords: {
                'deviceid': 'ap-1',
                'features': '0x5A7FFFF7',
              },
            ),
            const MdnsServiceInfo(
              name: 'ATV-dup',
              host: '192.168.1.61',
              port: 7000,
              txtRecords: {
                'deviceid': 'ap-1',
                'features': '0x5A7FFFF7',
              },
            ),
          ]);
        },
      );

      final results = await provider
          .startDiscovery(timeout: const Duration(milliseconds: 500))
          .toList();

      expect(results, isNotEmpty);
      expect(results.last, hasLength(1));

      provider.dispose();
    });

    test('stopDiscovery cancels subscription', () async {
      final controller = StreamController<MdnsServiceInfo>();

      final provider = AirPlayDiscoveryProvider(
        mdnsLookup: (serviceType) => controller.stream,
      );

      provider.startDiscovery(timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      provider.stopDiscovery();

      // Adding after stop should not cause issues
      controller.add(const MdnsServiceInfo(
        name: 'Late',
        host: '192.168.1.99',
        port: 7000,
        txtRecords: {'deviceid': 'late-1', 'features': '0x5A7FFFF7'},
      ));

      await controller.close();
    });
  });
}
