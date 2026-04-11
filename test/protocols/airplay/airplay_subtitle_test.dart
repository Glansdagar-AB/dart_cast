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
      id: 'test-airplay-subtitle',
      name: 'Test AirPlay Subtitle Device',
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

  group('AirPlay subtitle injection', () {
    test('loadMedia with subtitles sends play request', () async {
      await session.connect();

      final media = CastMedia(
        url: 'https://example.com/video.m3u8',
        type: CastMediaType.hls,
        subtitles: [
          const CastSubtitle(
            url: 'https://example.com/subs.vtt',
            label: 'English',
            language: 'en',
            format: 'vtt',
          ),
        ],
      );

      await session.loadMedia(media);

      expect(mockServer.lastPath, equals('/play'));
      expect(mockServer.lastMethod, equals('POST'));
      // The play body should contain a proxy URL (not the original)
      expect(mockServer.lastBody, contains('Content-Location:'));
      // Should contain synthetic (wrapper) URL since subtitles are present
      expect(mockServer.lastBody, contains('/synthetic/'));
    });

    test('loadMedia without subtitles sends original proxy URL', () async {
      await session.connect();

      final media = CastMedia(
        url: 'https://example.com/video.m3u8',
        type: CastMediaType.hls,
      );

      await session.loadMedia(media);

      expect(mockServer.lastPath, equals('/play'));
      expect(mockServer.lastBody, contains('Content-Location:'));
      // Should NOT contain synthetic URL since no subtitles
      expect(mockServer.lastBody, isNot(contains('/synthetic/')));
      expect(mockServer.lastBody, contains('/stream/'));
    });

    test('loadMedia with subtitles on non-HLS type does not inject', () async {
      await session.connect();

      final media = CastMedia(
        url: 'https://example.com/video.mp4',
        type: CastMediaType.mp4,
        subtitles: [
          const CastSubtitle(
            url: 'https://example.com/subs.vtt',
            label: 'English',
            language: 'en',
            format: 'vtt',
          ),
        ],
      );

      await session.loadMedia(media);

      expect(mockServer.lastBody, isNot(contains('/synthetic/')));
      expect(mockServer.lastBody, contains('/stream/'));
    });

    test('setSubtitle re-sends play with subtitle wrapper', () async {
      await session.connect();

      // Load without subtitles first
      final media = CastMedia(
        url: 'https://example.com/video.m3u8',
        type: CastMediaType.hls,
      );

      await session.loadMedia(media);
      expect(mockServer.lastBody, isNot(contains('/synthetic/')));

      // Now set a subtitle
      await session.setSubtitle(
        const CastSubtitle(
          url: 'https://example.com/subs.vtt',
          label: 'English',
          language: 'en',
          format: 'vtt',
        ),
      );

      expect(mockServer.lastPath, equals('/play'));
      expect(mockServer.lastBody, contains('/synthetic/'));
    });

    test('setSubtitle with null removes subtitles', () async {
      await session.connect();

      // Load with subtitles
      final media = CastMedia(
        url: 'https://example.com/video.m3u8',
        type: CastMediaType.hls,
        subtitles: [
          const CastSubtitle(
            url: 'https://example.com/subs.vtt',
            label: 'English',
            language: 'en',
            format: 'vtt',
          ),
        ],
      );

      await session.loadMedia(media);
      expect(mockServer.lastBody, contains('/synthetic/'));

      // Remove subtitles
      await session.setSubtitle(null);

      expect(mockServer.lastPath, equals('/play'));
      // Without subtitles, should use stream URL directly
      expect(mockServer.lastBody, isNot(contains('/synthetic/')));
      expect(mockServer.lastBody, contains('/stream/'));
    });

    test('setSubtitle is no-op when no media loaded', () async {
      await session.connect();

      // Should not throw
      await session.setSubtitle(
        const CastSubtitle(
          url: 'https://example.com/subs.vtt',
          label: 'English',
          language: 'en',
          format: 'vtt',
        ),
      );

      // Server should not have received a /play request
      expect(mockServer.lastPath, isNot(equals('/play')));
    });

    test(
      'loadMedia transitions through loading state with subtitles',
      () async {
        await session.connect();

        final states = <SessionState>[];
        session.stateStream.listen(states.add);

        await session.loadMedia(
          CastMedia(
            url: 'https://example.com/video.m3u8',
            type: CastMediaType.hls,
            subtitles: [
              const CastSubtitle(
                url: 'https://example.com/subs.vtt',
                label: 'English',
                language: 'en',
                format: 'vtt',
              ),
            ],
          ),
        );

        expect(states, contains(SessionState.loading));
      },
    );
  });
}
