import 'dart:io';

import 'package:dart_cast/src/core/hls_parser.dart';
import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

/// Sample master playlist that mirrors the real-world krussdomi.com layout
/// (alternate audio renditions in their own playlists, video-only variants).
/// Used by the alt-audio tests below.
const _altAudioMaster =
    '#EXTM3U\n'
    '#EXT-X-INDEPENDENT-SEGMENTS\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="Japanese",'
    'DEFAULT=YES,LANGUAGE="jpn",CHANNELS="2",URI="audio-jpn.m3u8"\n'
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="English",'
    'LANGUAGE="eng",CHANNELS="2",URI="audio-eng.m3u8"\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="avc1.4D4828,mp4a.40.2",'
    'RESOLUTION=1920x1080,AUDIO="stereo"\n'
    'video-1080p.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.4D401F,mp4a.40.2",'
    'RESOLUTION=1280x720,AUDIO="stereo"\n'
    'video-720p.m3u8\n';

/// Sample master playlist with muxed audio + video (legacy / "normal" HLS).
/// No `EXT-X-MEDIA:TYPE=AUDIO` and no `AUDIO=` attribute on the variants.
const _muxedAudioMaster =
    '#EXTM3U\n'
    '#EXT-X-INDEPENDENT-SEGMENTS\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="avc1.4D4828,mp4a.40.2",'
    'RESOLUTION=1920x1080\n'
    '1080p.m3u8\n'
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,CODECS="avc1.4D401F,mp4a.40.2",'
    'RESOLUTION=1280x720\n'
    '720p.m3u8\n';

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

    test('captures AUDIO group reference on variants', () {
      final variants = HlsParser.extractVariants(
        _altAudioMaster,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(2));
      // Highest-bandwidth variant carries the AUDIO=group attribute.
      expect(variants[0].audioGroup, 'stereo');
      expect(variants[1].audioGroup, 'stereo');
    });

    test('audioGroup is null when no AUDIO attribute is present', () {
      final variants = HlsParser.extractVariants(
        _muxedAudioMaster,
        'https://cdn.example.com/master.m3u8',
      );

      expect(variants, hasLength(2));
      expect(variants[0].audioGroup, isNull);
      expect(variants[1].audioGroup, isNull);
    });
  });

  group('HlsParser.extractAudioRenditions', () {
    test('parses TYPE=AUDIO entries with their URIs resolved', () {
      final renditions = HlsParser.extractAudioRenditions(
        _altAudioMaster,
        'https://cdn.example.com/streams/master.m3u8',
      );

      expect(renditions, hasLength(2));
      expect(renditions[0].groupId, 'stereo');
      expect(renditions[0].name, 'Japanese');
      expect(renditions[0].isDefault, isTrue);
      expect(
        renditions[0].uri,
        'https://cdn.example.com/streams/audio-jpn.m3u8',
      );
      expect(renditions[1].groupId, 'stereo');
      expect(renditions[1].name, 'English');
      expect(renditions[1].isDefault, isFalse);
      expect(
        renditions[1].uri,
        'https://cdn.example.com/streams/audio-eng.m3u8',
      );
    });

    test('returns empty list when no EXT-X-MEDIA:TYPE=AUDIO entries exist', () {
      final renditions = HlsParser.extractAudioRenditions(
        _muxedAudioMaster,
        'https://cdn.example.com/master.m3u8',
      );

      expect(renditions, isEmpty);
    });

    test('ignores EXT-X-MEDIA entries with non-AUDIO types', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",'
          'URI="subs-eng.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
          'video.m3u8\n';

      final renditions = HlsParser.extractAudioRenditions(
        content,
        'https://cdn.example.com/master.m3u8',
      );

      expect(renditions, isEmpty);
    });
  });

  group('HlsParser.rewritePlaylist segment URL extension', () {
    test('rewrites segment URLs to end in .ts even when upstream is .jpg', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-TARGETDURATION:6\n'
          '#EXTINF:6.0,\n'
          'https://cdn.example.com/seg/000.jpg\n'
          '#EXTINF:6.0,\n'
          'https://cdn.example.com/seg/001.jpg\n'
          '#EXT-X-ENDLIST\n';

      final rewritten = HlsParser.rewritePlaylist(
        content,
        'https://cdn.example.com/media.m3u8',
        'http://192.168.1.5:8234',
        'tok123',
      );

      final segLines =
          rewritten
              .split('\n')
              .where((l) => l.startsWith('http://192.168.1.5'))
              .toList();
      expect(segLines, hasLength(2));
      // Path component (before `?`) must end in `.ts`.
      for (final line in segLines) {
        final qIdx = line.indexOf('?');
        final pathPart = qIdx > 0 ? line.substring(0, qIdx) : line;
        expect(
          pathPart,
          endsWith('.ts'),
          reason:
              'segment proxy URL must end in `.ts` so Chromecast/Shaka '
              'capability probe succeeds. Got: $pathPart',
        );
        expect(pathPart, contains('/stream/tok123/seg'));
      }
      // Segment indices increment.
      expect(segLines[0], contains('/seg1.ts'));
      expect(segLines[1], contains('/seg2.ts'));
    });

    test('leaves variant playlist URLs unchanged (no .ts suffix on STREAM-INF '
        'next-line URIs)', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720\n'
          '720p/playlist.m3u8\n';

      final rewritten = HlsParser.rewritePlaylist(
        content,
        'https://cdn.example.com/master.m3u8',
        'http://192.168.1.5:8234',
        'tok123',
      );

      final variantLine = rewritten
          .split('\n')
          .firstWhere((l) => l.startsWith('http://192.168.1.5'));
      // Variant playlist URLs keep the plain `/stream/<token>` form (no
      // segment index suffix).
      final qIdx = variantLine.indexOf('?');
      final pathPart = qIdx > 0 ? variantLine.substring(0, qIdx) : variantLine;
      expect(pathPart, equals('http://192.168.1.5:8234/stream/tok123'));
      expect(pathPart, isNot(contains('/seg')));
    });

    test('rewrites alt-audio rendition URIs with plain /stream/<token>', () {
      const content =
          '#EXTM3U\n'
          '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="stereo",NAME="Japanese",'
          'DEFAULT=YES,URI="audio.m3u8"\n'
          '#EXT-X-STREAM-INF:BANDWIDTH=1000000,AUDIO="stereo"\n'
          'video.m3u8\n';

      final rewritten = HlsParser.rewritePlaylist(
        content,
        'https://cdn.example.com/master.m3u8',
        'http://192.168.1.5:8234',
        'tok123',
      );

      // EXT-X-MEDIA URI attribute is rewritten via _rewriteUriAttribute which
      // uses the plain proxy URL form (no segment suffix).
      final audioLine = rewritten
          .split('\n')
          .firstWhere((l) => l.startsWith('#EXT-X-MEDIA'));
      expect(audioLine, contains('http://192.168.1.5:8234/stream/tok123?url='));
      expect(audioLine, isNot(contains('/seg')));
    });
  });

  group('MediaProxy /stream/<token>/<extra>.ts routing', () {
    late MediaProxy proxy;
    late HttpServer upstreamServer;
    late String upstreamBaseUrl;

    setUp(() async {
      proxy = MediaProxy();
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamBaseUrl = 'http://127.0.0.1:${upstreamServer.port}';

      upstreamServer.listen((request) async {
        if (request.uri.path == '/seg.bin') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add([0x47, 0x00, 0x01, 0x02, 0x03]);
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

    test(
      'a request to /stream/<token>/anything.ts routes to the same token',
      () async {
        await proxy.start();
        // Register a remote route so the proxy has the token.
        final baseProxyUrl = proxy.registerMedia('$upstreamBaseUrl/seg.bin');
        // Extract token from the registered URL.
        final tokenMatch =
            RegExp(r'/stream/([^/?]+)').firstMatch(baseProxyUrl)!;
        final token = tokenMatch.group(1)!;

        // Hit the proxy with a `.ts`-suffixed path (what the rewritten HLS
        // playlist would point Chromecast at).
        final segUrl =
            '${proxy.baseUrl}/stream/$token/seg42.ts'
            '?url=${Uri.encodeComponent("$upstreamBaseUrl/seg.bin")}';

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(segUrl));
          final response = await request.close();
          final body = await response.fold<List<int>>(
            <int>[],
            (prev, chunk) => prev..addAll(chunk),
          );
          expect(response.statusCode, HttpStatus.ok);
          expect(body, [0x47, 0x00, 0x01, 0x02, 0x03]);
        } finally {
          client.close();
        }
      },
    );
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
