import 'dart:io';

import 'package:dart_cast/src/core/hls_parser.dart';
import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

void main() {
  group('HlsParser.extractSegmentUrls', () {
    test('parses segment URLs from a media playlist', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          'segment000.ts\n'
          '#EXTINF:9.009,\n'
          'segment001.ts\n'
          '#EXTINF:8.341,\n'
          'segment002.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/streams/720p/playlist.m3u8',
      );

      expect(urls, hasLength(3));
      expect(urls[0], 'https://cdn.example.com/streams/720p/segment000.ts');
      expect(urls[1], 'https://cdn.example.com/streams/720p/segment001.ts');
      expect(urls[2], 'https://cdn.example.com/streams/720p/segment002.ts');
    });

    test('resolves absolute segment URLs', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          'https://cdn2.example.com/seg000.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/streams/playlist.m3u8',
      );

      expect(urls, hasLength(1));
      expect(urls[0], 'https://cdn2.example.com/seg000.ts');
    });

    test('handles EXT-X-BYTERANGE between EXTINF and segment URI', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          '#EXT-X-BYTERANGE:500000@0\n'
          'combined.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/streams/playlist.m3u8',
      );

      expect(urls, hasLength(1));
      expect(urls[0], 'https://cdn.example.com/streams/combined.ts');
    });

    test('returns empty list for playlist with no segments', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/playlist.m3u8',
      );

      expect(urls, isEmpty);
    });

    test('handles empty lines between entries', () {
      const content =
          '#EXTM3U\n'
          '\n'
          '#EXT-X-TARGETDURATION:10\n'
          '\n'
          '#EXTINF:9.009,\n'
          'segment000.ts\n'
          '\n'
          '#EXTINF:9.009,\n'
          'segment001.ts\n'
          '#EXT-X-ENDLIST\n';

      final urls = HlsParser.extractSegmentUrls(
        content,
        'https://cdn.example.com/playlist.m3u8',
      );

      expect(urls, hasLength(2));
    });
  });

  group('HlsParser.extractVariants', () {
    test('parses variant streams from a master playlist', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
          '720p/playlist.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
          '1080p/playlist.m3u8\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360\n'
          '360p/playlist.m3u8\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/streams/master.m3u8',
      );

      expect(variants, hasLength(3));
      // Sorted by bandwidth descending
      expect(variants[0].bandwidth, 5000000);
      expect(
        variants[0].url,
        'https://cdn.example.com/streams/1080p/playlist.m3u8',
      );
      expect(variants[1].bandwidth, 2000000);
      expect(
        variants[1].url,
        'https://cdn.example.com/streams/720p/playlist.m3u8',
      );
      expect(variants[2].bandwidth, 800000);
      expect(
        variants[2].url,
        'https://cdn.example.com/streams/360p/playlist.m3u8',
      );
    });

    test('handles absolute variant URLs', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=3000000\n'
          'https://other.cdn.com/720p/playlist.m3u8\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(1));
      expect(variants[0].url, 'https://other.cdn.com/720p/playlist.m3u8');
      expect(variants[0].bandwidth, 3000000);
    });

    test('returns empty list for media playlist', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:10\n'
          '#EXTINF:9.009,\n'
          'segment000.ts\n'
          '#EXT-X-ENDLIST\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/playlist.m3u8',
      );

      expect(variants, isEmpty);
    });

    test('defaults bandwidth to 0 when missing', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:RESOLUTION=1280x720\n'
          '720p/playlist.m3u8\n';

      final variants = HlsParser.extractVariants(
        content,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(1));
      expect(variants[0].bandwidth, 0);
    });
  });

  group('MediaProxy.registerHlsAsStream', () {
    late MediaProxy proxy;
    late HttpServer upstreamServer;
    late String upstreamBaseUrl;

    setUp(() async {
      proxy = MediaProxy();

      // Create upstream server to simulate HLS content
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';

      upstreamServer.listen((request) async {
        final path = request.uri.path;

        if (path == '/master.m3u8') {
          final content =
              '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
              'media.m3u8\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(content);
          await request.response.close();
        } else if (path == '/media.m3u8') {
          final content =
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2.0,\n'
              'seg0.ts\n'
              '#EXTINF:2.0,\n'
              'seg1.ts\n'
              '#EXT-X-ENDLIST\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(content);
          await request.response.close();
        } else if (path == '/seg0.ts') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([0x47, 0x00, 0x01, 0x02]); // fake TS data
          await request.response.close();
        } else if (path == '/seg1.ts') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([0x47, 0x03, 0x04, 0x05]); // fake TS data
          await request.response.close();
        } else if (path == '/simple.m3u8') {
          // A simple media playlist (not master)
          final content =
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2.0,\n'
              'seg0.ts\n'
              '#EXT-X-ENDLIST\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(content);
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });
    });

    tearDown(() async {
      await proxy.stop();
      await upstreamServer.close(force: true);
    });

    test('returns a URL with /ts-stream/ route', () async {
      await proxy.start();
      final url = proxy.registerHlsAsStream('$upstreamBaseUrl/master.m3u8');
      expect(url, contains('/ts-stream/'));
      expect(url, startsWith(proxy.baseUrl!));
    });

    test('serves HLS as continuous MPEG-TS from master playlist', () async {
      await proxy.start();
      final proxyUrl = proxy.registerHlsAsStream(
        '$upstreamBaseUrl/master.m3u8',
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers.contentType?.mimeType, 'video/mp2t');

        final body = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        // Should contain both segments' data concatenated
        expect(body, [0x47, 0x00, 0x01, 0x02, 0x47, 0x03, 0x04, 0x05]);
      } finally {
        client.close();
      }
    });

    test('serves HLS as MPEG-TS from simple media playlist', () async {
      await proxy.start();
      final proxyUrl = proxy.registerHlsAsStream(
        '$upstreamBaseUrl/simple.m3u8',
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();

        expect(response.statusCode, HttpStatus.ok);
        expect(response.headers.contentType?.mimeType, 'video/mp2t');

        final body = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        // Only the first segment (simple playlist has just seg0.ts)
        expect(body, [0x47, 0x00, 0x01, 0x02]);
      } finally {
        client.close();
      }
    });

    test('returns 404 for unknown ts-stream token', () async {
      await proxy.start();

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('${proxy.baseUrl}/ts-stream/nonexistent'),
        );
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('forwards custom headers to upstream', () async {
      // Replace upstream with a header-checking server
      await upstreamServer.close(force: true);
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';

      upstreamServer.listen((request) async {
        final path = request.uri.path;
        final referer = request.headers.value('Referer');

        if (referer != 'https://mysite.com') {
          request.response.statusCode = HttpStatus.forbidden;
          await request.response.close();
          return;
        }

        if (path == '/protected.m3u8') {
          final content =
              '#EXTM3U\n'
              '#EXT-X-TARGETDURATION:2\n'
              '#EXTINF:2.0,\n'
              'pseg.ts\n'
              '#EXT-X-ENDLIST\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.write(content);
          await request.response.close();
        } else if (path == '/pseg.ts') {
          request.response.statusCode = HttpStatus.ok;
          request.response.add([0xAA, 0xBB]);
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      });

      await proxy.start();
      final proxyUrl = proxy.registerHlsAsStream(
        '$upstreamBaseUrl/protected.m3u8',
        headers: {'Referer': 'https://mysite.com'},
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        final body = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        expect(response.statusCode, HttpStatus.ok);
        expect(body, [0xAA, 0xBB]);
      } finally {
        client.close();
      }
    });
  });
}
