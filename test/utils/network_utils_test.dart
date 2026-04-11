import 'dart:io';

import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('NetworkUtils', () {
    test('getLocalIpAddress returns non-loopback or null', () async {
      final ip = await NetworkUtils.getLocalIpAddress();
      // In CI, there may be no non-loopback interface
      if (ip != null) {
        expect(ip, isNot('127.0.0.1'));
        // Should be a valid IPv4 address
        expect(InternetAddress.tryParse(ip), isNotNull);
      }
    });

    test('getLocalIpAddress with targetDeviceIp prefers same subnet', () async {
      // We can't control interfaces in a unit test, but we can verify the
      // method doesn't crash and returns a valid result
      final ip = await NetworkUtils.getLocalIpAddress(
        targetDeviceIp: '192.168.1.100',
      );
      if (ip != null) {
        expect(ip, isNot('127.0.0.1'));
        expect(InternetAddress.tryParse(ip), isNotNull);
      }
    });

    test('getLocalIpAddress with null targetDeviceIp still works', () async {
      final ip = await NetworkUtils.getLocalIpAddress(targetDeviceIp: null);
      if (ip != null) {
        expect(ip, isNot('127.0.0.1'));
        expect(InternetAddress.tryParse(ip), isNotNull);
      }
    });

    test('_isPrivateAddress correctly identifies RFC 1918 ranges', () {
      // Access via the public API — these addresses should be preferred
      // when no same-subnet match is found. We test indirectly by verifying
      // getLocalIpAddress prefers private over non-private.
      // Direct unit tests for the static helpers:
      expect(NetworkUtils.isPrivateAddress('192.168.1.1'), isTrue);
      expect(NetworkUtils.isPrivateAddress('192.168.0.1'), isTrue);
      expect(NetworkUtils.isPrivateAddress('10.0.0.1'), isTrue);
      expect(NetworkUtils.isPrivateAddress('10.255.255.255'), isTrue);
      expect(NetworkUtils.isPrivateAddress('172.16.0.1'), isTrue);
      expect(NetworkUtils.isPrivateAddress('172.31.255.255'), isTrue);
      expect(NetworkUtils.isPrivateAddress('172.15.0.1'), isFalse);
      expect(NetworkUtils.isPrivateAddress('172.32.0.1'), isFalse);
      expect(NetworkUtils.isPrivateAddress('8.8.8.8'), isFalse);
      expect(NetworkUtils.isPrivateAddress('192.0.0.4'), isFalse);
    });

    test('_subnetPrefix extracts /24 prefix', () {
      expect(NetworkUtils.subnetPrefix('192.168.1.100'), '192.168.1');
      expect(NetworkUtils.subnetPrefix('10.0.0.1'), '10.0.0');
      expect(NetworkUtils.subnetPrefix('invalid'), isNull);
      expect(NetworkUtils.subnetPrefix('1.2.3'), isNull);
    });

    test('findAvailablePort returns a usable port', () async {
      final port = await NetworkUtils.findAvailablePort();
      expect(port, greaterThan(0));
      expect(port, lessThanOrEqualTo(65535));

      // Verify port is actually usable by binding to it
      final server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      expect(server.port, port);
      await server.close();
    });

    test('formatDuration produces HH:MM:SS', () {
      expect(NetworkUtils.formatDuration(Duration.zero), '00:00:00');
      expect(NetworkUtils.formatDuration(Duration(seconds: 5)), '00:00:05');
      expect(
        NetworkUtils.formatDuration(Duration(minutes: 3, seconds: 15)),
        '00:03:15',
      );
      expect(
        NetworkUtils.formatDuration(
          Duration(hours: 1, minutes: 30, seconds: 45),
        ),
        '01:30:45',
      );
      expect(
        NetworkUtils.formatDuration(
          Duration(hours: 12, minutes: 0, seconds: 0),
        ),
        '12:00:00',
      );
    });

    test('parseDuration parses HH:MM:SS', () {
      expect(NetworkUtils.parseDuration('00:00:00'), Duration.zero);
      expect(NetworkUtils.parseDuration('00:00:05'), Duration(seconds: 5));
      expect(
        NetworkUtils.parseDuration('00:03:15'),
        Duration(minutes: 3, seconds: 15),
      );
      expect(
        NetworkUtils.parseDuration('01:30:45'),
        Duration(hours: 1, minutes: 30, seconds: 45),
      );
    });

    test('formatDuration/parseDuration roundtrip', () {
      final durations = [
        Duration.zero,
        Duration(seconds: 1),
        Duration(minutes: 59, seconds: 59),
        Duration(hours: 2, minutes: 30, seconds: 15),
      ];
      for (final d in durations) {
        final formatted = NetworkUtils.formatDuration(d);
        final parsed = NetworkUtils.parseDuration(formatted);
        expect(parsed, d, reason: 'Roundtrip failed for $d -> $formatted');
      }
    });
  });
}
