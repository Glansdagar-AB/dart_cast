import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_session.dart';
import 'package:test/test.dart';

import 'mock_airplay_server.dart';

void main() {
  late MockAirPlayServer server;
  late AirPlaySession session;

  setUp(() async {
    server = MockAirPlayServer();
    await server.start();

    final device = CastDevice(
      id: 'mock-airplay-001',
      name: 'Mock Apple TV',
      protocol: CastProtocol.airplay,
      address: InternetAddress.loopbackIPv4,
      port: server.port,
    );

    session = AirPlaySession(device);
  });

  tearDown(() async {
    session.dispose();
    await server.stop();
  });

  /// Loads media and waits for the session to reach the playing state
  /// (requires polling to pick up the rate from /playback-info).
  Future<void> loadMediaAndWaitForPlaying(AirPlaySession session) async {
    await session.loadMedia(const CastMedia(
      url: 'http://example.com/video.m3u8',
      type: CastMediaType.hls,
      title: 'Test Video',
    ));

    // Wait for polling to detect playing state
    await session.stateStream
        .firstWhere((s) => s == SessionState.playing)
        .timeout(const Duration(seconds: 5));
  }

  group('AirPlay integration', () {
    test(
        'full playback lifecycle: connect -> load -> play -> seek -> pause -> stop -> disconnect',
        () async {
      // 1. Connect — calls /server-info to verify device
      await session.connect();
      expect(session.state, SessionState.connected);
      expect(server.requestLog, contains('GET /server-info'));

      // 2. Load media — calls /play, then wait for polling to detect playing
      await loadMediaAndWaitForPlaying(session);

      // The server should have received a POST /play
      expect(server.requestLog, contains('POST /play'));
      expect(server.rate, 1.0);
      expect(server.readyToPlay, isTrue);
      expect(session.state, SessionState.playing);

      // 3. Seek to 30 minutes
      server.clearLog();
      await session.seek(const Duration(minutes: 30));
      expect(server.requestLog, contains('POST /scrub'));
      expect(server.position, closeTo(1800.0, 1.0));

      // 4. Pause (rate = 0)
      server.clearLog();
      await session.pause();
      expect(server.requestLog, contains('POST /rate'));
      expect(server.rate, 0.0);
      expect(session.state, SessionState.paused);

      // 5. Resume (rate = 1)
      server.clearLog();
      await session.play();
      expect(server.requestLog, contains('POST /rate'));
      expect(server.rate, 1.0);
      expect(session.state, SessionState.playing);

      // 6. Stop
      server.clearLog();
      await session.stop();
      expect(server.requestLog, contains('POST /stop'));
      expect(session.state, SessionState.idle);

      // 7. Disconnect
      await session.disconnect();
      expect(session.state, SessionState.disconnected);
    });

    test('connect verifies device via /server-info', () async {
      await session.connect();

      expect(session.state, SessionState.connected);
      expect(
        server.requestLog.where((r) => r == 'GET /server-info'),
        isNotEmpty,
      );
    });

    test('connect transitions through connecting to connected', () async {
      final states = <SessionState>[];
      session.stateStream.listen(states.add);

      await session.connect();

      // Allow any pending microtasks to complete
      await Future<void>.delayed(Duration.zero);

      expect(states, contains(SessionState.connecting));
      // connected state is reached — verify via session.state
      expect(session.state, SessionState.connected);
    });

    test('loadMedia sends POST /play with media URL', () async {
      await session.connect();

      await session.loadMedia(const CastMedia(
        url: 'http://example.com/test.m3u8',
        type: CastMediaType.hls,
      ));

      expect(server.requestLog, contains('POST /play'));
      expect(server.lastMediaUrl, isNotNull);
      expect(server.readyToPlay, isTrue);
    });

    test('play and pause toggle rate correctly', () async {
      await session.connect();
      await loadMediaAndWaitForPlaying(session);
      expect(session.state, SessionState.playing);

      // Pause
      await session.pause();
      expect(server.rate, 0.0);
      expect(session.state, SessionState.paused);

      // Resume
      await session.play();
      expect(server.rate, 1.0);
      expect(session.state, SessionState.playing);
    });

    test('seek sends scrub with correct position', () async {
      await session.connect();
      await loadMediaAndWaitForPlaying(session);

      await session.seek(const Duration(hours: 1, minutes: 15));
      // 1h15m = 4500 seconds
      expect(server.position, closeTo(4500.0, 1.0));
    });

    test('stop transitions to idle', () async {
      await session.connect();
      await loadMediaAndWaitForPlaying(session);

      await session.stop();
      expect(session.state, SessionState.idle);
      expect(server.readyToPlay, isFalse);
    });

    test('disconnect stops playback and transitions to disconnected', () async {
      await session.connect();
      await loadMediaAndWaitForPlaying(session);

      await session.disconnect();
      expect(session.state, SessionState.disconnected);
      expect(session.client, isNull);
    });

    test('position polling emits position from playback-info', () async {
      await session.connect();

      await session.loadMedia(const CastMedia(
        url: 'http://example.com/video.m3u8',
        type: CastMediaType.hls,
      ));

      // Wait for polling to report position
      final pos = await session.positionStream.first
          .timeout(const Duration(seconds: 5));
      expect(pos.inSeconds, greaterThanOrEqualTo(0));
    });

    test('setVolume stores volume locally (AirPlay 1 limitation)', () async {
      await session.connect();

      final volumeFuture = session.volumeStream.first;
      await session.setVolume(0.5);

      final vol = await volumeFuture.timeout(const Duration(seconds: 2));
      expect(vol, 0.5);
    });
  });
}
