import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:test/test.dart';

void main() {
  group('DefaultMediaTransformer', () {
    late MediaProxy proxy;

    setUp(() async {
      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
    });

    test('serves local MP4 directly', () async {
      final dir = await Directory.systemTemp.createTemp('test_');
      final file = File('${dir.path}/test.mp4');
      await file.writeAsBytes(List.filled(1024, 0));

      try {
        final transformer = DefaultMediaTransformer();
        final media = CastMedia.file(
          filePath: file.path,
          type: CastMediaType.mp4,
        );

        final result = await transformer.transform(media, proxy);

        expect(result.effectiveType, CastMediaType.mp4);
        expect(result.proxyUrl, contains('/file/'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('serves local TS directly without HLS wrapping', () async {
      final dir = await Directory.systemTemp.createTemp('test_');
      final file = File('${dir.path}/test.ts');
      await file.writeAsBytes(List.filled(1024, 0));

      try {
        final transformer = DefaultMediaTransformer();
        final media = CastMedia.file(
          filePath: file.path,
          type: CastMediaType.mpegTs,
        );

        final result = await transformer.transform(media, proxy);

        expect(result.effectiveType, CastMediaType.mpegTs);
        expect(result.proxyUrl, contains('/file/'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('serves local TS directly even when wrapRemoteTs is true', () async {
      final dir = await Directory.systemTemp.createTemp('test_');
      final file = File('${dir.path}/test.ts');
      await file.writeAsBytes(List.filled(1024, 0));

      try {
        final transformer = DefaultMediaTransformer(wrapRemoteTs: true);
        final media = CastMedia.file(
          filePath: file.path,
          type: CastMediaType.mpegTs,
        );

        final result = await transformer.transform(media, proxy);

        // Local files are never wrapped, even with wrapRemoteTs: true
        expect(result.effectiveType, CastMediaType.mpegTs);
        expect(result.proxyUrl, contains('/file/'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('wraps remote TS in HLS when wrapRemoteTs is true', () async {
      final transformer = DefaultMediaTransformer(wrapRemoteTs: true);
      final media = CastMedia(
        url: 'http://example.com/video.ts',
        type: CastMediaType.mpegTs,
      );

      final result = await transformer.transform(media, proxy);

      expect(result.effectiveType, CastMediaType.hls);
      expect(result.proxyUrl, contains('/synthetic/'));
    });

    test('does NOT wrap remote TS when wrapRemoteTs is false', () async {
      final transformer = DefaultMediaTransformer(wrapRemoteTs: false);
      final media = CastMedia(
        url: 'http://example.com/video.ts',
        type: CastMediaType.mpegTs,
      );

      final result = await transformer.transform(media, proxy);

      expect(result.effectiveType, CastMediaType.mpegTs);
      expect(result.proxyUrl, contains('/stream/'));
    });

    test('passes through remote MP4', () async {
      final transformer = DefaultMediaTransformer();
      final media = CastMedia(
        url: 'http://example.com/video.mp4',
        type: CastMediaType.mp4,
      );

      final result = await transformer.transform(media, proxy);

      expect(result.effectiveType, CastMediaType.mp4);
      expect(result.proxyUrl, contains('/stream/'));
    });
  });
}
