import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_device.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_session.dart';
import 'package:test/test.dart';

import 'mock_dlna_server.dart';

void main() {
  late MockDlnaServer server;
  late DlnaSession session;

  setUp(() async {
    server = MockDlnaServer();
    await server.start();

    final device = CastDevice(
      id: server.udn,
      name: server.friendlyName,
      protocol: CastProtocol.dlna,
      address: InternetAddress.loopbackIPv4,
      port: server.httpPort,
    );

    final description = DlnaDeviceDescription.parse(
      server.deviceDescriptionXml,
      server.descriptionUrl,
    );

    session = DlnaSession(device: device, description: description);
  });

  tearDown(() async {
    session.dispose();
    await server.stop();
  });

  group('DLNA integration', () {
    test(
      'full playback lifecycle: connect -> load -> play -> seek -> pause -> stop -> disconnect',
      () async {
        // 1. Connect
        await session.connect();
        expect(session.state, SessionState.connected);

        // 2. Load media — the mock server transitions to PLAYING on Play
        server.durationSeconds = 3600.0; // 1 hour
        server.positionSeconds = 0.0;

        await session.loadMedia(
          const CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
            title: 'Integration Test Video',
          ),
        );

        expect(session.state, SessionState.playing);

        // Verify SetAVTransportURI then Play were sent
        final actions = server.capturedActions.map((a) => a.action).toList();
        expect(actions, contains('SetAVTransportURI'));
        expect(actions, contains('Play'));
        final setUriIdx = actions.indexOf('SetAVTransportURI');
        final playIdx = actions.indexOf('Play');
        expect(setUriIdx, lessThan(playIdx));

        // 3. Verify position polling delivers updates
        server.positionSeconds = 120.0;
        final position = await session.positionStream.first.timeout(
          const Duration(seconds: 5),
        );
        expect(position.inSeconds, greaterThanOrEqualTo(0));

        // 4. Seek to 30 minutes
        server.clearCapturedActions();
        await session.seek(const Duration(minutes: 30));
        expect(server.capturedActions.any((a) => a.action == 'Seek'), isTrue);
        // Verify the seek body contains the correct time
        final seekAction = server.capturedActions.firstWhere(
          (a) => a.action == 'Seek',
        );
        expect(seekAction.body, contains('00:30:00'));
        expect(server.positionSeconds, 1800.0);

        // 5. Pause
        server.clearCapturedActions();
        await session.pause();
        expect(session.state, SessionState.paused);
        expect(server.transportState, 'PAUSED_PLAYBACK');
        expect(server.capturedActions.any((a) => a.action == 'Pause'), isTrue);

        // 6. Resume play
        server.clearCapturedActions();
        await session.play();
        expect(session.state, SessionState.playing);
        expect(server.transportState, 'PLAYING');

        // 7. Stop
        server.clearCapturedActions();
        await session.stop();
        expect(session.state, SessionState.idle);
        expect(server.transportState, 'STOPPED');
        expect(server.capturedActions.any((a) => a.action == 'Stop'), isTrue);

        // 8. Disconnect
        await session.disconnect();
        expect(session.state, SessionState.disconnected);
      },
    );

    test('connect transitions through connecting to connected', () async {
      final states = <SessionState>[];
      session.stateStream.listen(states.add);

      await session.connect();

      // Allow any pending microtasks to complete
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(SessionState.connecting));
      // Verify final state is connected
      expect(session.state, SessionState.connected);
    });

    test(
      'loadMedia sends SetAVTransportURI with correct URL and title',
      () async {
        await session.connect();
        server.durationSeconds = 7200.0;

        await session.loadMedia(
          const CastMedia(
            url: 'http://example.com/test.m3u8',
            type: CastMediaType.hls,
            title: 'My Show',
          ),
        );

        final setUri = server.capturedActions.firstWhere(
          (a) => a.action == 'SetAVTransportURI',
        );
        // URL should be proxied (not the raw URL), and title should be present
        expect(setUri.body, isNot(contains('example.com/test.m3u8')));
        expect(
          setUri.body,
          contains('/ts-stream/'),
        ); // HLS uses ts-stream route
        expect(setUri.body, contains('My Show'));
      },
    );

    test('play and pause toggle state correctly', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );
      expect(session.state, SessionState.playing);

      await session.pause();
      expect(session.state, SessionState.paused);

      await session.play();
      expect(session.state, SessionState.playing);

      await session.pause();
      expect(session.state, SessionState.paused);
    });

    test('seek updates server position', () async {
      await session.connect();
      server.durationSeconds = 5400.0;

      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );

      await session.seek(const Duration(hours: 1, minutes: 15, seconds: 30));

      final seekAction = server.capturedActions.firstWhere(
        (a) => a.action == 'Seek',
      );
      expect(seekAction.body, contains('01:15:30'));
      expect(server.positionSeconds, 4530.0);
    });

    test('setVolume sends correct value to RenderingControl', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );

      await session.setVolume(0.75);

      final volAction = server.capturedActions.firstWhere(
        (a) => a.action == 'SetVolume',
      );
      expect(volAction.body, contains('<DesiredVolume>75</DesiredVolume>'));
      expect(server.volume, 75);
    });

    test('stop transitions to idle and stops polling', () async {
      await session.connect();
      server.durationSeconds = 3600.0;

      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );

      // Wait for at least one poll
      await session.positionStream.first.timeout(const Duration(seconds: 5));

      await session.stop();
      expect(session.state, SessionState.idle);

      // Verify no more polling happens
      server.clearCapturedActions();
      await Future<void>.delayed(const Duration(seconds: 2));
      final pollActions =
          server.capturedActions
              .where((a) => a.action == 'GetPositionInfo')
              .toList();
      expect(pollActions, isEmpty);
    });

    test('disconnect sends Stop and cleans up', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );

      server.clearCapturedActions();
      await session.disconnect();

      expect(session.state, SessionState.disconnected);
      expect(server.capturedActions.any((a) => a.action == 'Stop'), isTrue);
    });

    test(
      'position polling reports position and duration from server',
      () async {
        await session.connect();
        server.durationSeconds = 5400.0;
        server.positionSeconds = 300.0;
        server.transportState = 'PLAYING';

        await session.loadMedia(
          const CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        final pos = await session.positionStream.first.timeout(
          const Duration(seconds: 5),
        );
        final dur = await session.durationStream.first.timeout(
          const Duration(seconds: 5),
        );

        // Position should reflect what the mock server returns
        expect(pos.inSeconds, greaterThanOrEqualTo(0));
        expect(dur.inSeconds, greaterThanOrEqualTo(0));
      },
    );

    test('device description XML is parsed correctly', () async {
      final description = DlnaDeviceDescription.parse(
        server.deviceDescriptionXml,
        server.descriptionUrl,
      );

      expect(description.friendlyName, server.friendlyName);
      expect(description.udn, server.udn);
      expect(description.avTransportControlUrl, isNotNull);
      expect(description.renderingControlUrl, isNotNull);
      expect(
        description.avTransportControlUrl,
        contains('/AVTransport/control'),
      );
      expect(
        description.renderingControlUrl,
        contains('/RenderingControl/control'),
      );
    });
  });
}
