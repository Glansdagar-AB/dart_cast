import 'dart:io';
import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('CastProtocol', () {
    test('has expected values', () {
      expect(CastProtocol.values, contains(CastProtocol.chromecast));
      expect(CastProtocol.values, contains(CastProtocol.airplay));
      expect(CastProtocol.values, contains(CastProtocol.dlna));
    });
  });

  group('CastDevice', () {
    late CastDevice device;

    setUp(() {
      device = CastDevice(
        id: 'test-id-123',
        name: 'Living Room TV',
        protocol: CastProtocol.chromecast,
        address: InternetAddress('192.168.1.100'),
        port: 8009,
      );
    });

    test('creation with required fields', () {
      expect(device.id, 'test-id-123');
      expect(device.name, 'Living Room TV');
      expect(device.protocol, CastProtocol.chromecast);
      expect(device.address, InternetAddress('192.168.1.100'));
      expect(device.port, 8009);
      expect(device.metadata, isEmpty);
    });

    test('creation with metadata', () {
      final d = CastDevice(
        id: 'test-id',
        name: 'TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('10.0.0.1'),
        port: 1900,
        metadata: {'model': 'Samsung', 'firmware': '1.0'},
      );
      expect(d.metadata, {'model': 'Samsung', 'firmware': '1.0'});
    });

    test('toJson produces expected map', () {
      final json = device.toJson();
      expect(json['id'], 'test-id-123');
      expect(json['name'], 'Living Room TV');
      expect(json['protocol'], 'chromecast');
      expect(json['address'], '192.168.1.100');
      expect(json['port'], 8009);
      expect(json['metadata'], <String, String>{});
    });

    test('fromJson creates equivalent device', () {
      final json = {
        'id': 'abc',
        'name': 'Kitchen',
        'protocol': 'airplay',
        'address': '192.168.1.50',
        'port': 7000,
        'metadata': <String, dynamic>{'key': 'value'},
      };
      final d = CastDevice.fromJson(json);
      expect(d.id, 'abc');
      expect(d.name, 'Kitchen');
      expect(d.protocol, CastProtocol.airplay);
      expect(d.address, InternetAddress('192.168.1.50'));
      expect(d.port, 7000);
      expect(d.metadata, {'key': 'value'});
    });

    test('toJson/fromJson roundtrip', () {
      final restored = CastDevice.fromJson(device.toJson());
      expect(restored, equals(device));
    });

    test('equality is based on id', () {
      final other = CastDevice(
        id: 'test-id-123',
        name: 'Different Name',
        protocol: CastProtocol.dlna,
        address: InternetAddress('10.0.0.5'),
        port: 9999,
      );
      expect(device, equals(other));
      expect(device.hashCode, other.hashCode);
    });

    test('different ids are not equal', () {
      final other = CastDevice(
        id: 'different-id',
        name: 'Living Room TV',
        protocol: CastProtocol.chromecast,
        address: InternetAddress('192.168.1.100'),
        port: 8009,
      );
      expect(device, isNot(equals(other)));
    });

    test('toString contains useful info', () {
      final s = device.toString();
      expect(s, contains('Living Room TV'));
      expect(s, contains('chromecast'));
    });
  });
}
