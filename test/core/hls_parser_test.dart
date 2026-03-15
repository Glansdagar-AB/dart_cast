import 'package:dart_cast/src/core/hls_parser.dart';
import 'package:test/test.dart';

void main() {
  group('HlsParser', () {
    group('isMasterPlaylist', () {
      test('returns true when content contains #EXT-X-STREAM-INF', () {
        const content = '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
            '720p/playlist.m3u8\n';
        expect(HlsParser.isMasterPlaylist(content), isTrue);
      });

      test('returns false for a media playlist with #EXTINF', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';
        expect(HlsParser.isMasterPlaylist(content), isFalse);
      });

      test('returns true when content contains #EXT-X-I-FRAME-STREAM-INF', () {
        const content = '#EXTM3U\n'
            '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=900000,URI="720p/iframes.m3u8"\n';
        expect(HlsParser.isMasterPlaylist(content), isTrue);
      });
    });

    group('resolveUrl', () {
      test('returns absolute URL unchanged', () {
        expect(
          HlsParser.resolveUrl(
            'https://other.cdn.com/720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://other.cdn.com/720p/playlist.m3u8',
        );
      });

      test('resolves protocol-relative URL', () {
        expect(
          HlsParser.resolveUrl(
            '//other.cdn.com/720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://other.cdn.com/720p/playlist.m3u8',
        );
      });

      test('resolves absolute path URL', () {
        expect(
          HlsParser.resolveUrl(
            '/live/720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://cdn.example.com/live/720p/playlist.m3u8',
        );
      });

      test('resolves relative path URL', () {
        expect(
          HlsParser.resolveUrl(
            '720p/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://cdn.example.com/streams/720p/playlist.m3u8',
        );
      });

      test('resolves relative path with parent directory (..)', () {
        expect(
          HlsParser.resolveUrl(
            '../other/playlist.m3u8',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'https://cdn.example.com/other/playlist.m3u8',
        );
      });

      test('resolves http URL unchanged', () {
        expect(
          HlsParser.resolveUrl(
            'http://cdn.example.com/seg.ts',
            'https://cdn.example.com/streams/master.m3u8',
          ),
          'http://cdn.example.com/seg.ts',
        );
      });
    });

    group('rewritePlaylist', () {
      const baseUrl = 'https://cdn.example.com/streams/master.m3u8';
      const proxyBaseUrl = 'http://192.168.1.5:8234';
      const token = 'abc123';

      test('rewrites master playlist variant URIs (Pattern A)', () {
        const content = '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720\n'
            '720p/playlist.m3u8\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\n'
            '1080p/playlist.m3u8\n';

        final result =
            HlsParser.rewritePlaylist(content, baseUrl, proxyBaseUrl, token);
        final lines = result.split('\n');

        // Line 0: #EXTM3U
        expect(lines[0], '#EXTM3U');
        // Line 1: #EXT-X-STREAM-INF unchanged
        expect(lines[1], startsWith('#EXT-X-STREAM-INF:'));
        // Line 2: rewritten variant URI
        expect(lines[2], startsWith('$proxyBaseUrl/stream/$token?url='));
        expect(
            lines[2],
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/playlist.m3u8',
            )));
        // Line 4: rewritten 1080p variant URI
        expect(
            lines[4],
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/1080p/playlist.m3u8',
            )));
      });

      test('rewrites media playlist segment URIs (Pattern A)', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXTINF:9.009,\n'
            'segment001.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
            content, mediaBaseUrl, proxyBaseUrl, token);
        final lines = result.split('\n');

        expect(lines[3], startsWith('$proxyBaseUrl/stream/$token?url='));
        expect(
            lines[3],
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/segment000.ts',
            )));
        expect(
            lines[5],
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/segment001.ts',
            )));
      });

      test('rewrites #EXT-X-KEY URI attribute (Pattern B)', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="https://keys.cdn.com/key1.bin",IV=0x00000001\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';

        final result =
            HlsParser.rewritePlaylist(content, baseUrl, proxyBaseUrl, token);

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
            result,
            contains(Uri.encodeComponent(
              'https://keys.cdn.com/key1.bin',
            )));
        // IV should be preserved
        expect(result, contains('IV=0x00000001'));
        expect(result, contains('METHOD=AES-128'));
      });

      test('rewrites #EXT-X-MAP URI attribute (Pattern B)', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-MAP:URI="init.mp4"\n'
            '#EXTINF:9.009,\n'
            'segment000.m4s\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
            content, mediaBaseUrl, proxyBaseUrl, token);

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
            result,
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/init.mp4',
            )));
      });

      test('rewrites #EXT-X-MEDIA URI attribute (Pattern B)', () {
        const content = '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",URI="audio/en/playlist.m3u8"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,AUDIO="aac"\n'
            '720p/playlist.m3u8\n';

        final result =
            HlsParser.rewritePlaylist(content, baseUrl, proxyBaseUrl, token);

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
            result,
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/audio/en/playlist.m3u8',
            )));
      });

      test('rewrites #EXT-X-I-FRAME-STREAM-INF URI attribute', () {
        const content = '#EXTM3U\n'
            '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=900000,URI="720p/iframes.m3u8"\n';

        final result =
            HlsParser.rewritePlaylist(content, baseUrl, proxyBaseUrl, token);

        expect(result, contains('URI="$proxyBaseUrl/stream/$token?url='));
        expect(
            result,
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/iframes.m3u8',
            )));
      });

      test('preserves non-URI lines unchanged', () {
        const content = '#EXTM3U\n'
            '#EXT-X-VERSION:3\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-MEDIA-SEQUENCE:0\n'
            '#EXT-X-PLAYLIST-TYPE:VOD\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
            content, mediaBaseUrl, proxyBaseUrl, token);
        final lines = result.split('\n');

        expect(lines[0], '#EXTM3U');
        expect(lines[1], '#EXT-X-VERSION:3');
        expect(lines[2], '#EXT-X-TARGETDURATION:10');
        expect(lines[3], '#EXT-X-MEDIA-SEQUENCE:0');
        expect(lines[4], '#EXT-X-PLAYLIST-TYPE:VOD');
        expect(lines[7], '#EXT-X-ENDLIST');
      });

      test('handles absolute segment URLs', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            'https://cdn2.example.com/seg000.ts\n'
            '#EXT-X-ENDLIST\n';

        final result =
            HlsParser.rewritePlaylist(content, baseUrl, proxyBaseUrl, token);

        expect(
            result,
            contains(Uri.encodeComponent(
              'https://cdn2.example.com/seg000.ts',
            )));
      });

      test('handles #EXT-X-BYTERANGE between #EXTINF and segment URI', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXTINF:9.009,\n'
            '#EXT-X-BYTERANGE:500000@0\n'
            'combined.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
            content, mediaBaseUrl, proxyBaseUrl, token);
        final lines = result.split('\n');

        // #EXT-X-BYTERANGE should be preserved
        expect(lines[3], '#EXT-X-BYTERANGE:500000@0');
        // The URI after byterange should be rewritten
        expect(lines[4], startsWith('$proxyBaseUrl/stream/$token?url='));
      });

      test('handles #EXT-X-MEDIA without URI attribute', () {
        const content = '#EXTM3U\n'
            '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English"\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'
            '720p/playlist.m3u8\n';

        final result =
            HlsParser.rewritePlaylist(content, baseUrl, proxyBaseUrl, token);

        // The #EXT-X-MEDIA line without URI should remain unchanged
        expect(
            result,
            contains(
              '#EXT-X-MEDIA:TYPE=CLOSED-CAPTIONS,GROUP-ID="cc",NAME="English"',
            ));
      });

      test('rewrites #EXT-X-KEY with relative URI', () {
        const content = '#EXTM3U\n'
            '#EXT-X-TARGETDURATION:10\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="keys/enc.key"\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
            content, mediaBaseUrl, proxyBaseUrl, token);

        expect(
            result,
            contains(Uri.encodeComponent(
              'https://cdn.example.com/streams/720p/keys/enc.key',
            )));
      });

      test('handles empty lines gracefully', () {
        const content = '#EXTM3U\n'
            '\n'
            '#EXT-X-TARGETDURATION:10\n'
            '\n'
            '#EXTINF:9.009,\n'
            'segment000.ts\n'
            '\n'
            '#EXT-X-ENDLIST\n';

        final mediaBaseUrl =
            'https://cdn.example.com/streams/720p/playlist.m3u8';
        final result = HlsParser.rewritePlaylist(
            content, mediaBaseUrl, proxyBaseUrl, token);

        // Should not throw and should contain rewritten segment
        expect(result, contains('$proxyBaseUrl/stream/$token?url='));
      });
    });
  });
}
