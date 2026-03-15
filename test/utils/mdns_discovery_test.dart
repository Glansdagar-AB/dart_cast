import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/utils/mdns_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('MdnsServiceInfo', () {
    group('Chromecast TXT records', () {
      test('parses friendly name from fn', () {
        final info = MdnsServiceInfo(
          name: 'Chromecast-abc123._googlecast._tcp.local',
          host: '192.168.1.100',
          port: 8009,
          txtRecords: {
            'fn': 'Living Room TV',
            'md': 'Chromecast',
            'id': 'abc-123'
          },
        );

        expect(info.friendlyName, 'Living Room TV');
      });

      test('parses device id from id', () {
        final info = MdnsServiceInfo(
          name: 'Chromecast-abc123._googlecast._tcp.local',
          host: '192.168.1.100',
          port: 8009,
          txtRecords: {
            'fn': 'Living Room TV',
            'md': 'Chromecast',
            'id': 'abc-123'
          },
        );

        expect(info.deviceId, 'abc-123');
      });

      test('parses model from md', () {
        final info = MdnsServiceInfo(
          name: 'Chromecast-abc123._googlecast._tcp.local',
          host: '192.168.1.100',
          port: 8009,
          txtRecords: {
            'fn': 'Living Room TV',
            'md': 'Chromecast Ultra',
            'id': 'abc-123'
          },
        );

        expect(info.model, 'Chromecast Ultra');
      });
    });

    group('AirPlay TXT records', () {
      test('parses device id from deviceid', () {
        final info = MdnsServiceInfo(
          name: 'Apple TV._airplay._tcp.local',
          host: '192.168.1.200',
          port: 7000,
          txtRecords: {
            'deviceid': 'AA:BB:CC:DD:EE:FF',
            'features': '0x5A7FFFF7,0x1E',
            'model': 'AppleTV3,2'
          },
        );

        expect(info.deviceId, 'AA:BB:CC:DD:EE:FF');
      });

      test('parses model from model field', () {
        final info = MdnsServiceInfo(
          name: 'Apple TV._airplay._tcp.local',
          host: '192.168.1.200',
          port: 7000,
          txtRecords: {'deviceid': 'AA:BB:CC:DD:EE:FF', 'model': 'AppleTV3,2'},
        );

        expect(info.model, 'AppleTV3,2');
      });

      test('falls back to service name for friendlyName when no fn', () {
        final info = MdnsServiceInfo(
          name: 'Apple TV._airplay._tcp.local',
          host: '192.168.1.200',
          port: 7000,
          txtRecords: {'deviceid': 'AA:BB:CC:DD:EE:FF'},
        );

        expect(info.friendlyName, 'Apple TV');
      });
    });

    group('supportsVideo', () {
      test('detects video support from single-part features', () {
        // 0x5A7FFFF7 has bit 0 set (ends in 7, which is ...0111 in binary)
        expect(MdnsServiceInfo.supportsVideo('0x5A7FFFF7'), true);
      });

      test('detects video support from two-part features', () {
        expect(MdnsServiceInfo.supportsVideo('0x5A7FFFF7,0x1E'), true);
      });

      test('detects no video support when bit 0 is not set', () {
        // 0x02 = 0b10 — bit 0 is not set
        expect(MdnsServiceInfo.supportsVideo('0x02'), false);
      });

      test('detects no video support in two-part format', () {
        expect(MdnsServiceInfo.supportsVideo('0x5A7FFFF0,0x1E'), false);
      });

      test('handles empty features string', () {
        expect(MdnsServiceInfo.supportsVideo(''), false);
      });
    });

    group('toChromecastDevice', () {
      test('creates correct CastDevice with chromecast protocol', () {
        final info = MdnsServiceInfo(
          name: 'Chromecast-abc._googlecast._tcp.local',
          host: '192.168.1.100',
          port: 8009,
          txtRecords: {
            'fn': 'Living Room TV',
            'md': 'Chromecast',
            'id': 'abc-123'
          },
        );

        final device = info.toChromecastDevice();
        expect(device.id, 'abc-123');
        expect(device.name, 'Living Room TV');
        expect(device.protocol, CastProtocol.chromecast);
        expect(device.address, InternetAddress('192.168.1.100'));
        expect(device.port, 8009);
        expect(device.metadata['md'], 'Chromecast');
      });
    });

    group('toAirplayDevice', () {
      test('creates correct CastDevice with airplay protocol', () {
        final info = MdnsServiceInfo(
          name: 'Apple TV._airplay._tcp.local',
          host: '192.168.1.200',
          port: 7000,
          txtRecords: {
            'deviceid': 'AA:BB:CC:DD:EE:FF',
            'features': '0x5A7FFFF7,0x1E',
            'model': 'AppleTV3,2',
          },
        );

        final device = info.toAirplayDevice();
        expect(device.id, 'AA:BB:CC:DD:EE:FF');
        expect(device.name, 'Apple TV');
        expect(device.protocol, CastProtocol.airplay);
        expect(device.address, InternetAddress('192.168.1.200'));
        expect(device.port, 7000);
        expect(device.metadata['model'], 'AppleTV3,2');
      });
    });
  });

  group('MdnsDiscovery', () {
    test('has correct chromecast service type', () {
      expect(MdnsDiscovery.chromecastServiceType, '_googlecast._tcp.local');
    });

    test('has correct airplay service type', () {
      expect(MdnsDiscovery.airplayServiceType, '_airplay._tcp.local');
    });

    test('discover returns a Stream (does not throw on creation)', () {
      // Verifies that MdnsDiscovery.discover produces a valid Stream.
      // Actual device discovery requires a network so we only check the type.
      final stream = MdnsDiscovery.discover('_test._tcp.local');
      expect(stream, isA<Stream<MdnsServiceInfo>>());
    });
  });
}
