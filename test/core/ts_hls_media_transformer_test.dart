import 'dart:io';

import 'package:dart_cast/dart_cast.dart';
import 'package:dart_cast/src/core/ts_hls_media_transformer.dart';
import 'package:test/test.dart';

void main() {
  group('TsHlsMediaTransformer', () {
    late MediaProxy proxy;

    setUp(() async {
      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
    });

    test('delegates non-TS media to parent', () async {
      final transformer = TsHlsMediaTransformer();
      final media = CastMedia(
        url: 'http://example.com/video.mp4',
        type: CastMediaType.mp4,
      );

      final result = await transformer.transform(media, proxy);

      expect(result.effectiveType, CastMediaType.mp4);
      expect(result.proxyUrl, contains('/stream/'));
    });

    test('delegates remote TS to parent HLS wrapping', () async {
      // TsHlsMediaTransformer defaults to wrapRemoteTs: true
      final transformer = TsHlsMediaTransformer();
      final media = CastMedia(
        url: 'http://example.com/video.ts',
        type: CastMediaType.mpegTs,
      );

      final result = await transformer.transform(media, proxy);

      expect(result.effectiveType, CastMediaType.hls);
      expect(result.proxyUrl, contains('/synthetic/'));
    });

    test('wraps local TS file in HLS', () async {
      final dir = await Directory.systemTemp.createTemp('test_');
      final file = File('${dir.path}/test.ts');
      await file.writeAsBytes(List.filled(1024, 0));

      try {
        final transformer = TsHlsMediaTransformer();
        final media = CastMedia.file(
          filePath: file.path,
          type: CastMediaType.mpegTs,
        );

        final result = await transformer.transform(media, proxy);

        expect(result.effectiveType, CastMediaType.hls);
        expect(result.proxyUrl, contains('/synthetic/'));
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('serves local MP4 directly via parent', () async {
      final dir = await Directory.systemTemp.createTemp('test_');
      final file = File('${dir.path}/test.mp4');
      await file.writeAsBytes(List.filled(1024, 0));

      try {
        final transformer = TsHlsMediaTransformer();
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
  });
}
