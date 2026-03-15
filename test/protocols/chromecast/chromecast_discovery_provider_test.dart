import 'dart:async';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/protocols/chromecast/chromecast_discovery_provider.dart';
import 'package:dart_cast/src/utils/mdns_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('ChromecastDiscoveryProvider', () {
    test('protocol is CastProtocol.chromecast', () {
      final provider = ChromecastDiscoveryProvider();
      expect(provider.protocol, equals(CastProtocol.chromecast));
    });

    test('discovers devices from mDNS responses', () async {
      final provider = ChromecastDiscoveryProvider(
        mdnsLookup: (serviceType) {
          expect(serviceType, equals(MdnsDiscovery.chromecastServiceType));
          return Stream.fromIterable([
            const MdnsServiceInfo(
              name: 'Living Room',
              host: '192.168.1.50',
              port: 8009,
              txtRecords: {
                'fn': 'Living Room TV',
                'id': 'cc-abc-123',
                'md': 'Chromecast',
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
      expect(devices.first.name, equals('Living Room TV'));
      expect(devices.first.id, equals('cc-abc-123'));
      expect(devices.first.protocol, equals(CastProtocol.chromecast));
      expect(devices.first.port, equals(8009));

      provider.dispose();
    });

    test('deduplicates by device ID', () async {
      final provider = ChromecastDiscoveryProvider(
        mdnsLookup: (serviceType) {
          return Stream.fromIterable([
            const MdnsServiceInfo(
              name: 'CC1',
              host: '192.168.1.50',
              port: 8009,
              txtRecords: {'fn': 'TV', 'id': 'same-id', 'md': 'Chromecast'},
            ),
            const MdnsServiceInfo(
              name: 'CC1-dup',
              host: '192.168.1.51',
              port: 8009,
              txtRecords: {'fn': 'TV2', 'id': 'same-id', 'md': 'Chromecast'},
            ),
          ]);
        },
      );

      final results = await provider
          .startDiscovery(timeout: const Duration(milliseconds: 500))
          .toList();

      expect(results, isNotEmpty);
      // Only one device with that ID
      expect(results.last, hasLength(1));

      provider.dispose();
    });

    test('discovers multiple devices', () async {
      final provider = ChromecastDiscoveryProvider(
        mdnsLookup: (serviceType) {
          return Stream.fromIterable([
            const MdnsServiceInfo(
              name: 'CC1',
              host: '192.168.1.50',
              port: 8009,
              txtRecords: {
                'fn': 'Living Room',
                'id': 'cc-1',
                'md': 'Chromecast'
              },
            ),
            const MdnsServiceInfo(
              name: 'CC2',
              host: '192.168.1.51',
              port: 8009,
              txtRecords: {
                'fn': 'Bedroom',
                'id': 'cc-2',
                'md': 'Chromecast Ultra'
              },
            ),
          ]);
        },
      );

      final results = await provider
          .startDiscovery(timeout: const Duration(milliseconds: 500))
          .toList();

      expect(results.last, hasLength(2));

      provider.dispose();
    });

    test('stopDiscovery cancels subscription', () async {
      final controller = StreamController<MdnsServiceInfo>();

      final provider = ChromecastDiscoveryProvider(
        mdnsLookup: (serviceType) => controller.stream,
      );

      provider.startDiscovery(timeout: const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      provider.stopDiscovery();

      // Adding to the controller after stop should not cause issues
      controller.add(const MdnsServiceInfo(
        name: 'Late',
        host: '192.168.1.99',
        port: 8009,
        txtRecords: {'fn': 'Late Device', 'id': 'late-1'},
      ));

      await controller.close();
    });
  });
}
