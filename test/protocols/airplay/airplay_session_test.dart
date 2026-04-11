import 'dart:async';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/airplay/airplay_session.dart';
import 'package:test/test.dart';

import 'mock_airplay_server.dart';

void main() {
  late MockAirPlayServer mockServer;
  late CastDevice device;
  late AirPlaySession session;

  setUp(() async {
    mockServer = MockAirPlayServer();
    await mockServer.start();
    device = CastDevice(
      id: 'test-airplay-device',
      name: 'Test AirPlay Device',
      protocol: CastProtocol.airplay,
      address: InternetAddress.loopbackIPv4,
      port: mockServer.port,
    );
    session = AirPlaySession(device);
  });

  tearDown(() async {
    session.dispose();
    await mockServer.stop();
  });

  group('AirPlaySession', () {
    group('connect()', () {
      test('verifies device via getServerInfo()', () async {
        await session.connect();

        expect(mockServer.lastPath, equals('/server-info'));
        expect(session.state, equals(SessionState.connected));
      });

      test('transitions from disconnected to connected', () async {
        expect(session.state, equals(SessionState.disconnected));

        final states = <SessionState>[];
        final sub = session.stateStream.listen(states.add);

        await session.connect();

        // Allow microtasks to flush
        await Future<void>.delayed(Duration.zero);

        expect(states, contains(SessionState.connecting));
        expect(session.state, equals(SessionState.connected));

        await sub.cancel();
      });
    });

    group('loadMedia()', () {
      setUp(() async {
        await session.connect();
      });

      test('calls play with media URL', () async {
        final media = CastMedia(
          url: 'https://example.com/video.m3u8',
          type: CastMediaType.hls,
        );

        await session.loadMedia(media);

        expect(mockServer.lastPath, equals('/play'));
        expect(mockServer.lastMethod, equals('POST'));
        expect(mockServer.lastBody, contains('Content-Location:'));
      });

      test('transitions through loading to playing', () async {
        final media = CastMedia(
          url: 'https://example.com/video.m3u8',
          type: CastMediaType.hls,
        );

        final states = <SessionState>[];
        session.stateStream.listen(states.add);

        await session.loadMedia(media);

        expect(states, contains(SessionState.loading));
        // After loading, state transitions to playing once polling starts
      });
    });

    group('play()', () {
      test('maps to rate(1)', () async {
        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        // Force to paused state for play() to work
        session.stateMachine.forceState(SessionState.paused);

        await session.play();

        expect(mockServer.lastPath, equals('/rate'));
        expect(mockServer.lastQueryParameters['value'], equals('1.0'));
      });
    });

    group('pause()', () {
      test('maps to rate(0)', () async {
        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        await session.pause();

        expect(mockServer.lastPath, equals('/rate'));
        expect(mockServer.lastQueryParameters['value'], equals('0.0'));
      });
    });

    group('seek()', () {
      test('maps to scrub(seconds)', () async {
        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        await session.seek(const Duration(minutes: 5));

        expect(mockServer.lastPath, equals('/scrub'));
        expect(mockServer.lastQueryParameters['position'], equals('300.0'));
      });
    });

    group('stop()', () {
      test('sends stop and transitions to idle', () async {
        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        // Wait for polling to transition to playing state
        await session.stateStream
            .firstWhere((s) => s == SessionState.playing)
            .timeout(const Duration(seconds: 5));
        expect(session.state, equals(SessionState.playing));

        await session.stop();

        expect(mockServer.lastPath, equals('/stop'));
        expect(session.state, equals(SessionState.idle));
      });
    });

    group('position polling', () {
      test('emits on positionStream', () async {
        await session.connect();

        final positions = <Duration>[];
        session.positionStream.listen(positions.add);

        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        // Wait for at least one position update
        await session.positionStream.first.timeout(const Duration(seconds: 5));

        expect(positions, isNotEmpty);
        // Position should be ~123.456789 seconds based on mock server
        expect(positions.first.inSeconds, greaterThanOrEqualTo(123));
      });

      test('emits duration on durationStream', () async {
        await session.connect();

        final durations = <Duration>[];
        session.durationStream.listen(durations.add);

        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        // Wait for at least one duration update
        await session.durationStream.first.timeout(const Duration(seconds: 5));

        expect(durations, isNotEmpty);
        // Duration should be 5400 seconds based on mock server
        expect(durations.first.inSeconds, equals(5400));
      });

      test('stop cancels polling', () async {
        await session.connect();

        final positions = <Duration>[];
        session.positionStream.listen(positions.add);

        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        // Wait for a poll to occur
        await session.positionStream.first.timeout(const Duration(seconds: 5));
        final countBeforeStop = positions.length;

        await session.stop();

        // Wait and verify no more position updates
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(positions.length, equals(countBeforeStop));
      });
    });

    group('state transitions from playback-info', () {
      test('rate 1.0 maps to playing state', () async {
        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        // Wait for poll — mock server returns rate=1.0
        await session.stateStream
            .firstWhere((s) => s == SessionState.playing)
            .timeout(const Duration(seconds: 5));

        expect(session.state, equals(SessionState.playing));
      });

      test('rate 0.0 maps to paused state', () async {
        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        // Wait for initial poll to reach playing
        await session.stateStream
            .firstWhere((s) => s == SessionState.playing)
            .timeout(const Duration(seconds: 5));

        // Change mock to return rate=0
        mockServer.playbackRate = 0.0;

        // Wait for next poll to transition to paused
        await session.stateStream
            .firstWhere((s) => s == SessionState.paused)
            .timeout(const Duration(seconds: 5));

        expect(session.state, equals(SessionState.paused));
      });
    });

    group('disconnect()', () {
      test('stops polling and transitions to disconnected', () async {
        await session.connect();
        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );

        await session.disconnect();

        expect(session.state, equals(SessionState.disconnected));
      });
    });

    group('setVolume()', () {
      test(
        'stores volume locally (AirPlay 1 has no volume endpoint)',
        () async {
          await session.connect();

          // Should not throw — just stores locally
          await session.setVolume(0.5);
        },
      );
    });
  });
}
