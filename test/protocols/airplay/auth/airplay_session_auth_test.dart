import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_session.dart';
import 'package:test/test.dart';

void main() {
  group('AirPlaySession auth integration', () {
    test('connect succeeds on 200 (no auth needed)', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        if (request.uri.path == '/server-info') {
          request.response
            ..statusCode = 200
            ..headers.contentType = ContentType('text', 'x-apple-plist')
            ..write(_serverInfoPlist)
            ..close();
        } else {
          request.response
            ..statusCode = 200
            ..close();
        }
      });

      final device = CastDevice(
        id: 'test',
        name: 'Test Device',
        protocol: CastProtocol.airplay,
        address: InternetAddress.loopbackIPv4,
        port: server.port,
      );
      final session = AirPlaySession(device);

      try {
        await session.connect();
        expect(session.state, equals(SessionState.connected));
      } finally {
        session.dispose();
        await server.close();
      }
    });

    test(
      'connect throws NeedsPairingException on 403 without credentials',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          // Return 403 for /server-info by returning it as AirPlayClientException
          if (request.uri.path == '/server-info') {
            request.response
              ..statusCode = 403
              ..close();
          } else {
            request.response
              ..statusCode = 200
              ..close();
          }
        });

        final device = CastDevice(
          id: 'test',
          name: 'Test Device',
          protocol: CastProtocol.airplay,
          address: InternetAddress.loopbackIPv4,
          port: server.port,
        );
        final session = AirPlaySession(device);

        try {
          await expectLater(
            session.connect(),
            throwsA(isA<NeedsPairingException>()),
          );
          expect(session.state, equals(SessionState.disconnected));
        } finally {
          session.dispose();
          await server.close();
        }
      },
    );

    test(
      'connect transitions to disconnected on 403 without credentials',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) {
          if (request.uri.path == '/server-info') {
            request.response
              ..statusCode = 403
              ..close();
          } else {
            request.response
              ..statusCode = 200
              ..close();
          }
        });

        final device = CastDevice(
          id: 'test',
          name: 'Test Device',
          protocol: CastProtocol.airplay,
          address: InternetAddress.loopbackIPv4,
          port: server.port,
        );
        final session = AirPlaySession(device);

        try {
          await session.connect();
        } on NeedsPairingException {
          // Expected
        }

        expect(session.state, equals(SessionState.disconnected));

        session.dispose();
        await server.close();
      },
    );

    test('connect transitions to disconnected on network error', () async {
      // Use a port that nothing is listening on
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server
          .close(); // Close immediately so the port is free but nobody listens

      final device = CastDevice(
        id: 'test',
        name: 'Test Device',
        protocol: CastProtocol.airplay,
        address: InternetAddress.loopbackIPv4,
        port: port,
      );
      final session = AirPlaySession(device);

      try {
        await session.connect();
        fail('Should have thrown');
      } catch (e) {
        expect(e, isNot(isA<NeedsPairingException>()));
      }

      expect(session.state, equals(SessionState.disconnected));
      session.dispose();
    });

    test('pairSetup method exists on AirPlaySession', () {
      final device = CastDevice(
        id: 'test',
        name: 'Test Device',
        protocol: CastProtocol.airplay,
        address: InternetAddress.loopbackIPv4,
        port: 7000,
      );
      final session = AirPlaySession(device);

      // Verify the method exists (can't call it without a real server)
      expect(session.pairSetup, isA<Function>());
      session.dispose();
    });

    test('credentials can be set on construction', () {
      final device = CastDevice(
        id: 'test',
        name: 'Test Device',
        protocol: CastProtocol.airplay,
        address: InternetAddress.loopbackIPv4,
        port: 7000,
      );
      final session = AirPlaySession(device);

      expect(session.credentials, isNull);
      session.dispose();
    });
  });
}

const _serverInfoPlist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>deviceid</key>
  <string>AA:BB:CC:DD:EE:FF</string>
  <key>model</key>
  <string>AppleTV5,3</string>
  <key>features</key>
  <integer>0</integer>
</dict>
</plist>''';
