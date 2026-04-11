import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/chromecast/cast_media_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/cast_receiver_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/chromecast_session.dart';
import 'package:test/test.dart';

import 'mock_chromecast_server.dart';

void main() {
  late CastDevice device;
  late MockChromecastServer server;
  late ChromecastSession session;

  setUp(() {
    device = CastDevice(
      id: 'test-chromecast-integration',
      name: 'Integration Test Chromecast',
      protocol: CastProtocol.chromecast,
      address: InternetAddress('192.168.1.100'),
      port: 8009,
    );

    server = MockChromecastServer();

    session = ChromecastSession.withMocks(device: device, channel: server);
  });

  tearDown(() {
    session.dispose();
  });

  group('Chromecast integration', () {
    test(
      'full playback lifecycle: connect -> load -> play -> seek -> pause -> stop -> disconnect',
      () async {
        // 1. Connect — sends CONNECT, LAUNCH, waits for RECEIVER_STATUS
        await session.connect();
        expect(session.state, SessionState.connected);

        // Verify CONNECT was sent to receiver-0
        final connectMsg = server.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.connectionNamespace &&
              m.destinationId == 'receiver-0' &&
              m.type == 'CONNECT',
        );
        expect(connectMsg, isNotNull);

        // Verify LAUNCH was sent
        final launchMsg = server.sentMessages.firstWhere(
          (m) => m.type == 'LAUNCH',
        );
        expect(launchMsg.payload['appId'], 'CC1AD845');

        // Verify CONNECT was sent to transport ID
        final appConnect = server.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.connectionNamespace &&
              m.destinationId == server.transportId &&
              m.type == 'CONNECT',
        );
        expect(appConnect, isNotNull);

        // 2. Load media
        server.duration = 7200.0; // 2 hours
        server.clearMessages();

        await session.loadMedia(
          const CastMedia(
            url: 'http://example.com/video.m3u8',
            type: CastMediaType.hls,
            title: 'Integration Test Video',
            imageUrl: 'http://example.com/thumb.jpg',
          ),
        );

        // Should be playing after LOAD + MEDIA_STATUS response
        expect(session.state, SessionState.playing);

        // Verify LOAD was sent to transport ID
        final loadMsg = server.sentMessages.firstWhere((m) => m.type == 'LOAD');
        expect(loadMsg.destinationId, server.transportId);
        // The real MediaProxy proxies the URL — verify it uses a proxy URL
        expect(loadMsg.payload['media']['contentId'], contains('/stream/'));
        expect(loadMsg.payload['autoplay'], isTrue);

        // 3. Seek to 1 hour
        server.clearMessages();
        await session.seek(const Duration(hours: 1));

        final seekMsg = server.sentMessages.firstWhere((m) => m.type == 'SEEK');
        expect(seekMsg.payload['currentTime'], 3600.0);

        // Wait for MEDIA_STATUS response to update position
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        expect(server.currentTime, 3600.0);

        // 4. Pause
        server.clearMessages();
        await session.pause();

        final pauseMsg = server.sentMessages.firstWhere(
          (m) => m.type == 'PAUSE',
        );
        expect(pauseMsg, isNotNull);

        // Wait for state update
        await session.stateStream
            .firstWhere((s) => s == SessionState.paused)
            .timeout(const Duration(seconds: 2));
        expect(session.state, SessionState.paused);
        expect(server.playerState, 'PAUSED');

        // 5. Resume play
        server.clearMessages();
        await session.play();

        final playMsg = server.sentMessages.firstWhere((m) => m.type == 'PLAY');
        expect(playMsg, isNotNull);

        await session.stateStream
            .firstWhere((s) => s == SessionState.playing)
            .timeout(const Duration(seconds: 2));
        expect(session.state, SessionState.playing);

        // 6. Stop media
        server.clearMessages();
        await session.stop();

        final stopMsg = server.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastMediaChannel.mediaNamespace &&
              m.type == 'STOP',
        );
        expect(stopMsg, isNotNull);

        // Wait for idle state
        await session.stateStream
            .firstWhere((s) => s == SessionState.idle)
            .timeout(const Duration(seconds: 2));
        expect(session.state, SessionState.idle);

        // 7. Disconnect
        server.clearMessages();
        await session.disconnect();

        expect(session.state, SessionState.disconnected);

        // Verify CLOSE messages were sent
        final closeMessages =
            server.sentMessages.where((m) => m.type == 'CLOSE').toList();
        expect(closeMessages.length, greaterThanOrEqualTo(2));

        // CLOSE to transport ID
        expect(
          closeMessages.any((m) => m.destinationId == server.transportId),
          isTrue,
        );
        // CLOSE to receiver-0
        expect(
          closeMessages.any((m) => m.destinationId == 'receiver-0'),
          isTrue,
        );
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

    test('connect starts heartbeat timer', () async {
      await session.connect();
      expect(session.isHeartbeatActive, isTrue);
    });

    test('loadMedia transitions through loading to playing', () async {
      await session.connect();

      final states = <SessionState>[];
      session.stateStream.listen(states.add);

      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ),
      );

      expect(states, contains(SessionState.loading));
      expect(states, contains(SessionState.playing));
    });

    test('loadMedia sends correct content type for HLS', () async {
      await session.connect();
      server.clearMessages();

      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ),
      );

      final loadMsg = server.sentMessages.firstWhere((m) => m.type == 'LOAD');
      expect(loadMsg.payload['media']['contentType'], 'application/x-mpegURL');
    });

    test('loadMedia sends correct content type for MP4', () async {
      await session.connect();
      server.clearMessages();

      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        ),
      );

      final loadMsg = server.sentMessages.firstWhere((m) => m.type == 'LOAD');
      expect(loadMsg.payload['media']['contentType'], 'video/mp4');
    });

    test('play and pause toggle state correctly', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ),
      );
      expect(session.state, SessionState.playing);

      // Pause
      await session.pause();
      await session.stateStream
          .firstWhere((s) => s == SessionState.paused)
          .timeout(const Duration(seconds: 2));
      expect(session.state, SessionState.paused);

      // Play
      await session.play();
      await session.stateStream
          .firstWhere((s) => s == SessionState.playing)
          .timeout(const Duration(seconds: 2));
      expect(session.state, SessionState.playing);
    });

    test('seek sends correct position in seconds', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ),
      );

      server.clearMessages();
      await session.seek(const Duration(minutes: 45, seconds: 30));

      final seekMsg = server.sentMessages.firstWhere((m) => m.type == 'SEEK');
      // 45*60 + 30 = 2730 seconds
      expect(seekMsg.payload['currentTime'], 2730.0);
    });

    test('seek updates position via MEDIA_STATUS', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ),
      );

      final positionFuture = session.positionStream.first;
      await session.seek(const Duration(minutes: 10));

      final position = await positionFuture.timeout(const Duration(seconds: 2));
      expect(position.inSeconds, 600);
    });

    test('stop transitions to idle', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ),
      );

      await session.stop();
      await session.stateStream
          .firstWhere((s) => s == SessionState.idle)
          .timeout(const Duration(seconds: 2));
      expect(session.state, SessionState.idle);
    });

    test('setVolume sends SET_VOLUME to receiver', () async {
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ),
      );

      server.clearMessages();
      await session.setVolume(0.7);

      final volMsg = server.sentMessages.firstWhere(
        (m) => m.type == 'SET_VOLUME',
      );
      expect(volMsg.payload['volume']['level'], 0.7);
      expect(volMsg.destinationId, 'receiver-0');
    });

    test('disconnect stops heartbeat and cleans up', () async {
      await session.connect();
      expect(session.isHeartbeatActive, isTrue);

      await session.disconnect();

      expect(session.state, SessionState.disconnected);
      expect(session.isHeartbeatActive, isFalse);
      expect(session.sessionId, isNull);
    });

    test(
      'position updates from MEDIA_STATUS are emitted on positionStream',
      () async {
        await session.connect();

        server.currentTime = 42.5;
        server.duration = 3600.0;

        final positionFuture = session.positionStream.first;
        final durationFuture = session.durationStream.first;

        await session.loadMedia(
          const CastMedia(
            url: 'http://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        final pos = await positionFuture.timeout(const Duration(seconds: 2));
        final dur = await durationFuture.timeout(const Duration(seconds: 2));

        expect(pos.inMilliseconds, closeTo(42500, 100));
        expect(dur.inMilliseconds, closeTo(3600000, 100));
      },
    );

    test('media with subtitles includes tracks in LOAD', () async {
      await session.connect();
      server.clearMessages();

      await session.loadMedia(
        const CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
          subtitles: [
            CastSubtitle(
              url: 'http://example.com/en.vtt',
              label: 'English',
              language: 'en',
              format: 'vtt',
            ),
          ],
        ),
      );

      final loadMsg = server.sentMessages.firstWhere((m) => m.type == 'LOAD');
      final tracks = loadMsg.payload['media']['tracks'] as List;
      expect(tracks, hasLength(1));
      // Subtitle URLs are proxied through real MediaProxy for CORS support
      expect(tracks[0]['trackContentId'], contains('/stream/'));
      expect(tracks[0]['language'], 'en');
    });
  });
}
