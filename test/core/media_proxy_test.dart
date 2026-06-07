import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

void main() {
  group('MediaProxy', () {
    late HttpServer upstreamServer;
    late MediaProxy proxy;
    String? segmentUserAgent;
    String? segmentReferer;
    String? segmentCookie;
    String? segmentAcceptEncoding;

    setUp(() async {
      upstreamServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstreamServer.listen((request) async {
        if (request.uri.path == '/live/channel.m3u8') {
          request.response.headers.contentType = ContentType(
            'application',
            'x-mpegURL',
          );
          request.response.headers.add(
            HttpHeaders.setCookieHeader,
            'iptv_session=playlist-token; Path=/',
          );
          request.response.write('''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:1
#EXTINF:10.0,
http://${upstreamServer.address.host}:${upstreamServer.port}/hls/segment.ts
''');
          await request.response.close();
          return;
        }

        if (request.uri.path == '/hls/segment.ts') {
          segmentUserAgent = request.headers.value(HttpHeaders.userAgentHeader);
          segmentReferer = request.headers.value(HttpHeaders.refererHeader);
          segmentCookie = request.headers.value(HttpHeaders.cookieHeader);
          segmentAcceptEncoding = request.headers.value(
            HttpHeaders.acceptEncodingHeader,
          );

          if (segmentUserAgent?.contains('Chrome/') != true ||
              segmentUserAgent?.contains('CrKey') == true ||
              segmentReferer == null ||
              segmentCookie != 'iptv_session=playlist-token') {
            request.response.statusCode = HttpStatus.forbidden;
            request.response.write('forbidden');
            await request.response.close();
            return;
          }

          request.response.headers.contentType = ContentType('video', 'mp2t');
          request.response.add(List<int>.filled(188, 0x47));
          await request.response.close();
          return;
        }

        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });

      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
      await upstreamServer.close(force: true);
    });

    test(
      'uses browser-like HLS headers and forwards playlist cookies to segments',
      () async {
        final playlistUrl =
            'http://${upstreamServer.address.host}:${upstreamServer.port}/live/channel.m3u8';
        final proxiedPlaylistUrl = proxy.registerMedia(playlistUrl);
        final client = HttpClient();
        addTearDown(() => client.close(force: true));

        final playlistRequest = await client.getUrl(
          Uri.parse(proxiedPlaylistUrl),
        );
        playlistRequest.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 CrKey/1.56.500000',
        );
        final playlistResponse = await playlistRequest.close();
        final playlistBody =
            await playlistResponse.transform(utf8.decoder).join();
        expect(playlistResponse.statusCode, HttpStatus.ok);

        final segmentUrl = playlistBody
            .split('\n')
            .firstWhere((line) => line.startsWith('http://'));
        final segmentRequest = await client.getUrl(Uri.parse(segmentUrl));
        segmentRequest.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 CrKey/1.56.500000',
        );
        segmentRequest.headers.set(HttpHeaders.acceptHeader, '*/*');
        segmentRequest.headers.set(HttpHeaders.acceptLanguageHeader, 'sv');
        final segmentResponse = await segmentRequest.close();
        await segmentResponse.drain<void>();

        expect(segmentResponse.statusCode, HttpStatus.ok);
        expect(segmentUserAgent, contains('Chrome/'));
        expect(segmentUserAgent, isNot(contains('CrKey')));
        expect(segmentReferer, playlistUrl);
        expect(segmentCookie, 'iptv_session=playlist-token');
        expect(segmentAcceptEncoding, 'identity');
      },
    );
  });
}
