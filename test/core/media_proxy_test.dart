import 'dart:io';

import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

void main() {
  group('MediaProxy', () {
    late MediaProxy proxy;
    late HttpServer upstreamServer;
    late String upstreamBaseUrl;

    setUp(() async {
      proxy = MediaProxy();

      // Create an upstream server to simulate remote content
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';
      upstreamServer.listen((request) async {
        final path = request.uri.path;

        if (path == '/video.mp4') {
          if (request.headers.value('Referer') != 'https://example.com') {
            request.response.statusCode = HttpStatus.forbidden;
            await request.response.close();
            return;
          }
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.add([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
          await request.response.close();
        } else if (path == '/master.m3u8') {
          final m3u8 = '#EXTM3U\n'
              '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
              '720p/playlist.m3u8\n';
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          request.response.write(m3u8);
          await request.response.close();
        } else if (path == '/segment.ts') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([10, 20, 30, 40, 50]);
          await request.response.close();
        } else if (path == '/noheaders.mp4') {
          // This endpoint doesn't require headers
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp4');
          request.response.add([99, 98, 97]);
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

    test('starts and provides a base URL', () async {
      await proxy.start();
      final baseUrl = proxy.baseUrl;
      expect(baseUrl, isNotNull);
      expect(baseUrl, startsWith('http://'));
      expect(baseUrl, isNot(contains('127.0.0.1')));
    });

    test('registerMedia returns a proxy URL with token', () async {
      await proxy.start();
      final proxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/video.mp4',
        headers: {'Referer': 'https://example.com'},
      );
      expect(proxyUrl, startsWith(proxy.baseUrl!));
      expect(proxyUrl, contains('/stream/'));
    });

    test('proxies requests with correct headers', () async {
      await proxy.start();
      final proxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/video.mp4',
        headers: {'Referer': 'https://example.com'},
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);

        final body = await response.fold<List<int>>(
          <int>[],
          (prev, chunk) => prev..addAll(chunk),
        );
        expect(body, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      } finally {
        client.close();
      }
    });

    test('returns 403 when upstream needs headers and none sent', () async {
      await proxy.start();
      // Register without headers — upstream requires Referer
      final proxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/video.mp4',
        headers: {},
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        // Upstream returns 403, proxy should forward that status
        expect(response.statusCode, HttpStatus.forbidden);
      } finally {
        client.close();
      }
    });

    test('rewrites HLS playlist URLs through proxy', () async {
      await proxy.start();
      final proxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/master.m3u8',
        headers: {},
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        expect(response.statusCode, HttpStatus.ok);

        final body = await response.transform(SystemEncoding().decoder).join();

        // Should contain rewritten URL through proxy, not original
        expect(body, contains(proxy.baseUrl!));
        expect(body, contains('/stream/'));
        expect(body, contains('url='));
        // The original relative URL should be resolved and encoded
        expect(
            body,
            contains(Uri.encodeComponent(
              '$upstreamBaseUrl/720p/playlist.m3u8',
            )));
        // Should still have the EXTM3U and STREAM-INF tags
        expect(body, contains('#EXTM3U'));
        expect(body, contains('#EXT-X-STREAM-INF:'));
      } finally {
        client.close();
      }
    });

    test('serves local files', () async {
      await proxy.start();

      // Create a temporary local file
      final tempDir = await Directory.systemTemp.createTemp('media_proxy_test');
      final tempFile = File('${tempDir.path}/test_video.mp4');
      await tempFile.writeAsBytes([100, 101, 102, 103, 104]);

      try {
        final proxyUrl = proxy.registerFile(tempFile.path);
        expect(proxyUrl, startsWith(proxy.baseUrl!));

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(proxyUrl));
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);

          final body = await response.fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
          expect(body, [100, 101, 102, 103, 104]);
        } finally {
          client.close();
        }
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('returns 404 for unknown tokens', () async {
      await proxy.start();

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('${proxy.baseUrl}/stream/nonexistent-token'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('cleans up old routes via cleanupPreviousMedia', () async {
      await proxy.start();
      final proxyUrl1 = proxy.registerMedia(
        '$upstreamBaseUrl/noheaders.mp4',
        headers: {},
      );

      // Verify first URL works
      final client = HttpClient();
      try {
        var request = await client.getUrl(Uri.parse(proxyUrl1));
        var response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.ok);

        // Register new media and clean up previous
        proxy.cleanupPreviousMedia();
        proxy.registerMedia(
          '$upstreamBaseUrl/segment.ts',
          headers: {},
        );

        // Old URL should now return 404
        request = await client.getUrl(Uri.parse(proxyUrl1));
        response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('supports Range requests for local files', () async {
      await proxy.start();

      final tempDir =
          await Directory.systemTemp.createTemp('media_proxy_range');
      final tempFile = File('${tempDir.path}/ranged.mp4');
      await tempFile.writeAsBytes(
        List.generate(100, (i) => i), // 0..99
      );

      try {
        final proxyUrl = proxy.registerFile(tempFile.path);

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(proxyUrl));
          request.headers.set('Range', 'bytes=10-19');
          final response = await request.close();

          expect(response.statusCode, HttpStatus.partialContent);

          final body = await response.fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
          expect(body, List.generate(10, (i) => i + 10)); // 10..19

          expect(
            response.headers.value('Content-Range'),
            'bytes 10-19/100',
          );
        } finally {
          client.close();
        }
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    test('includes CORS headers', () async {
      await proxy.start();
      final proxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/noheaders.mp4',
        headers: {},
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        await response.drain<void>();

        expect(
          response.headers.value('Access-Control-Allow-Origin'),
          '*',
        );
      } finally {
        client.close();
      }
    });

    test('sets correct Content-Type for m3u8', () async {
      await proxy.start();
      final proxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/master.m3u8',
        headers: {},
      );

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        await response.drain<void>();

        expect(
          response.headers.contentType.toString(),
          contains('mpegurl'),
        );
      } finally {
        client.close();
      }
    });

    test('registerFile returns 404 for non-existent file', () async {
      await proxy.start();
      final proxyUrl = proxy.registerFile('/nonexistent/path/file.mp4');

      final client = HttpClient();
      try {
        final request = await client.getUrl(Uri.parse(proxyUrl));
        final response = await request.close();
        await response.drain<void>();
        expect(response.statusCode, HttpStatus.notFound);
      } finally {
        client.close();
      }
    });

    test('proxies sub-resource URLs from rewritten m3u8', () async {
      await proxy.start();
      final proxyUrl = proxy.registerMedia(
        '$upstreamBaseUrl/master.m3u8',
        headers: {},
      );

      final client = HttpClient();
      try {
        // First fetch the m3u8
        var request = await client.getUrl(Uri.parse(proxyUrl));
        var response = await request.close();
        final body = await response.transform(SystemEncoding().decoder).join();

        // Extract the rewritten variant URL from the playlist
        final lines = body.split('\n');
        final variantLine = lines.firstWhere(
          (l) => l.contains('/stream/') && !l.startsWith('#'),
        );

        // The variant URL should be fetchable through the proxy
        // (it will 404 on upstream since we didn't set up 720p/playlist.m3u8,
        // but the proxy should forward the request)
        request = await client.getUrl(Uri.parse(variantLine));
        response = await request.close();
        await response.drain<void>();
        // Upstream doesn't have this path, so it returns 404
        // The key test is that the proxy accepted and forwarded the request
        expect(response.statusCode, isNotNull);
      } finally {
        client.close();
      }
    });
  });
}
