import 'dart:io';

import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:test/test.dart';

/// Fetches the body of [url] as a UTF-8 string using dart:io HttpClient.
Future<String> _fetchString(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    final chunks = await response.fold<List<int>>(
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
    return String.fromCharCodes(chunks);
  } finally {
    client.close();
  }
}

/// Creates a temporary directory + file filled with [size] zero-bytes.
/// Returns both objects; callers must delete the directory when done.
Future<({Directory dir, File file})> _createTempFile(int size) async {
  final dir =
      await Directory.systemTemp.createTemp('media_proxy_hls_test_');
  final file = File('${dir.path}/test_video.ts');
  await file.writeAsBytes(List.filled(size, 0));
  return (dir: dir, file: file);
}

void main() {
  group('MediaProxy HLS playlist generation', () {
    late MediaProxy proxy;

    setUp(() async {
      proxy = MediaProxy();
      await proxy.start();
    });

    tearDown(() async {
      await proxy.stop();
    });

    // -------------------------------------------------------------------------
    // wrapInHlsPlaylist
    // -------------------------------------------------------------------------
    group('wrapInHlsPlaylist', () {
      test('returns a URL that starts with http://', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        expect(playlistUrl, startsWith('http://'));
      });

      test('returns a proxy URL under the same base URL', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        expect(playlistUrl, startsWith(proxy.baseUrl!));
      });

      test('returned URL path contains /synthetic/', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        expect(playlistUrl, contains('/synthetic/'));
      });

      test('playlist starts with #EXTM3U', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        final content = await _fetchString(playlistUrl);
        expect(content.trimLeft(), startsWith('#EXTM3U'));
      });

      test('playlist contains #EXT-X-PLAYLIST-TYPE:VOD', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        final content = await _fetchString(playlistUrl);
        expect(content, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
      });

      test('playlist contains #EXT-X-ENDLIST (marks VOD, not live)', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        final content = await _fetchString(playlistUrl);
        expect(content, contains('#EXT-X-ENDLIST'));
      });

      test('playlist contains the original media URL', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        final content = await _fetchString(playlistUrl);
        expect(content, contains(mediaUrl));
      });

      test('playlist contains #EXTINF tag', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);
        final content = await _fetchString(playlistUrl);
        expect(content, contains('#EXTINF:'));
      });

      test('playlist has correct content-type header (mpegurl)', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final playlistUrl = proxy.wrapInHlsPlaylist(mediaUrl);

        final client = HttpClient();
        try {
          final request = await client.getUrl(Uri.parse(playlistUrl));
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

      test('two calls produce different proxy URLs', () async {
        final mediaUrl = '${proxy.baseUrl}/stream/fakemediatoken';
        final url1 = proxy.wrapInHlsPlaylist(mediaUrl);
        final url2 = proxy.wrapInHlsPlaylist(mediaUrl);
        expect(url1, isNot(url2));
      });
    });

    // -------------------------------------------------------------------------
    // wrapLocalFileAsHls
    // -------------------------------------------------------------------------
    group('wrapLocalFileAsHls', () {
      test('returns a URL that starts with http://', () async {
        final tmp = await _createTempFile(1024 * 1024); // 1 MB
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          expect(playlistUrl, startsWith('http://'));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('returned URL path contains /synthetic/', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          expect(playlistUrl, contains('/synthetic/'));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('playlist starts with #EXTM3U', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          final content = await _fetchString(playlistUrl);
          expect(content.trimLeft(), startsWith('#EXTM3U'));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('playlist contains #EXT-X-VERSION:4 (required for byte-range)',
          () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          final content = await _fetchString(playlistUrl);
          expect(content, contains('#EXT-X-VERSION:4'));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('playlist contains #EXT-X-PLAYLIST-TYPE:VOD', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          final content = await _fetchString(playlistUrl);
          expect(content, contains('#EXT-X-PLAYLIST-TYPE:VOD'));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('playlist contains #EXT-X-ENDLIST', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          final content = await _fetchString(playlistUrl);
          expect(content, contains('#EXT-X-ENDLIST'));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('playlist contains #EXT-X-BYTERANGE tags', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          final content = await _fetchString(playlistUrl);
          expect(content, contains('#EXT-X-BYTERANGE:'));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('generates correct number of segments for known duration', () async {
        // 120s / 20s-per-segment = 6 segments
        final tmp = await _createTempFile(10 * 1024 * 1024); // 10 MB
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 120.0,
          );
          final content = await _fetchString(playlistUrl);
          final extinfCount =
              '#EXTINF:'.allMatches(content).length;
          expect(extinfCount, 6);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('each segment has #EXTINF with ~20s duration', () async {
        final tmp = await _createTempFile(10 * 1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 120.0,
          );
          final content = await _fetchString(playlistUrl);

          // Extract all EXTINF durations
          final extinfRegex = RegExp(r'#EXTINF:([\d.]+),');
          final matches = extinfRegex.allMatches(content).toList();

          expect(matches, hasLength(6));
          for (final m in matches) {
            final duration = double.parse(m.group(1)!);
            // Each segment should be exactly 20s (120 / 6)
            expect(duration, closeTo(20.0, 0.01));
          }
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('byte ranges cover the full file — sum equals file size', () async {
        const fileSize = 10 * 1024 * 1024; // 10 MB
        final tmp = await _createTempFile(fileSize);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 120.0,
          );
          final content = await _fetchString(playlistUrl);

          // Parse all #EXT-X-BYTERANGE:<length>@<offset> lines
          final byteRangeRegex =
              RegExp(r'#EXT-X-BYTERANGE:(\d+)@(\d+)');
          final matches = byteRangeRegex.allMatches(content).toList();

          expect(matches, isNotEmpty);

          int totalBytes = 0;
          for (final m in matches) {
            totalBytes += int.parse(m.group(1)!);
          }
          expect(totalBytes, fileSize);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('byte ranges are contiguous starting at 0', () async {
        const fileSize = 10 * 1024 * 1024;
        final tmp = await _createTempFile(fileSize);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 120.0,
          );
          final content = await _fetchString(playlistUrl);

          final byteRangeRegex =
              RegExp(r'#EXT-X-BYTERANGE:(\d+)@(\d+)');
          final matches = byteRangeRegex.allMatches(content).toList();

          expect(matches, isNotEmpty);
          expect(int.parse(matches.first.group(2)!), 0, // first offset = 0
              reason: 'First segment offset must be 0');

          int expectedOffset = 0;
          for (final m in matches) {
            final offset = int.parse(m.group(2)!);
            final length = int.parse(m.group(1)!);
            expect(offset, expectedOffset);
            expectedOffset += length;
          }
          expect(expectedOffset, fileSize);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('last segment gets the remainder bytes', () async {
        // 10 MB file, 6 segments → segment sizes will not all be equal
        const fileSize = 10 * 1024 * 1024;
        final tmp = await _createTempFile(fileSize);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 120.0,
          );
          final content = await _fetchString(playlistUrl);

          final byteRangeRegex =
              RegExp(r'#EXT-X-BYTERANGE:(\d+)@(\d+)');
          final matches = byteRangeRegex.allMatches(content).toList();

          // The last offset + last length must equal the file size
          final last = matches.last;
          final lastOffset = int.parse(last.group(2)!);
          final lastLength = int.parse(last.group(1)!);
          expect(lastOffset + lastLength, fileSize);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('segments durations sum equals total duration', () async {
        const totalDuration = 120.0;
        final tmp = await _createTempFile(10 * 1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: totalDuration,
          );
          final content = await _fetchString(playlistUrl);

          final extinfRegex = RegExp(r'#EXTINF:([\d.]+),');
          final durations = extinfRegex
              .allMatches(content)
              .map((m) => double.parse(m.group(1)!))
              .toList();

          final sum = durations.fold<double>(0.0, (a, b) => a + b);
          expect(sum, closeTo(totalDuration, 0.01));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('file proxy URL appears in each segment line', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 60.0,
          );
          final content = await _fetchString(playlistUrl);

          // Segment URL lines (non-tag, non-empty lines)
          final lines = content
              .split('\n')
              .where((l) => l.isNotEmpty && !l.startsWith('#'))
              .toList();

          expect(lines, isNotEmpty);
          for (final line in lines) {
            expect(line.trim(), fileProxyUrl);
          }
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('estimates duration from bitrate when totalDuration is null',
          () async {
        // 5 Mbps (default) → 5_000_000/8 = 625_000 bytes/sec
        // 2_500_000 bytes / 625_000 = 4.0 s → 1 segment at 20s default
        const fileSize = 2500000;
        final tmp = await _createTempFile(fileSize);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            // no totalDuration → uses estimatedBitrateMbps = 5.0
          );
          final content = await _fetchString(playlistUrl);

          // Estimated duration ~4s which is < segmentSeconds(20) → 1 segment
          final extinfCount = '#EXTINF:'.allMatches(content).length;
          expect(extinfCount, 1);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('uses custom bitrate estimate when totalDuration is null', () async {
        // At 1 Mbps → 125_000 bytes/s
        // 5_000_000 bytes / 125_000 = 40s → ceil(40/20) = 2 segments
        const fileSize = 5000000;
        final tmp = await _createTempFile(fileSize);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            estimatedBitrateMbps: 1.0,
          );
          final content = await _fetchString(playlistUrl);

          final extinfCount = '#EXTINF:'.allMatches(content).length;
          expect(extinfCount, 2);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('small file (duration < segmentSeconds) generates single segment',
          () async {
        // 100 KB at 5 Mbps → ~0.16s < 20s → 1 segment
        final tmp = await _createTempFile(100 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 5.0, // only 5s
          );
          final content = await _fetchString(playlistUrl);

          final extinfCount = '#EXTINF:'.allMatches(content).length;
          expect(extinfCount, 1);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('single-segment playlist byte range covers the whole file', () async {
        const fileSize = 100 * 1024;
        final tmp = await _createTempFile(fileSize);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: 20.0,
            totalDuration: 5.0,
          );
          final content = await _fetchString(playlistUrl);

          final byteRangeRegex =
              RegExp(r'#EXT-X-BYTERANGE:(\d+)@(\d+)');
          final matches = byteRangeRegex.allMatches(content).toList();

          expect(matches, hasLength(1));
          expect(int.parse(matches.first.group(1)!), fileSize);
          expect(int.parse(matches.first.group(2)!), 0);
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('falls back to wrapInHlsPlaylist when file does not exist', () async {
        final missingPath = '/nonexistent/path/file.ts';
        final fakeFileProxyUrl = '${proxy.baseUrl}/file/fakefile';
        final playlistUrl =
            proxy.wrapLocalFileAsHls(fakeFileProxyUrl, missingPath);

        // Falls back to single-segment plain HLS playlist
        final content = await _fetchString(playlistUrl);
        expect(content, startsWith('#EXTM3U'));
        expect(content, contains(fakeFileProxyUrl));
        // Should NOT contain byte-range tags since it's a plain playlist
        expect(content, isNot(contains('#EXT-X-BYTERANGE:')));
      });

      test('two calls produce different proxy URLs', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final url1 = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          final url2 = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );
          expect(url1, isNot(url2));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('playlist has correct content-type header (mpegurl)', () async {
        final tmp = await _createTempFile(1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            totalDuration: 60.0,
          );

          final client = HttpClient();
          try {
            final request = await client.getUrl(Uri.parse(playlistUrl));
            final response = await request.close();
            await response.drain<void>();
            expect(
              response.headers.contentType.toString(),
              contains('mpegurl'),
            );
          } finally {
            client.close();
          }
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });

      test('non-round duration produces correct final segment duration',
          () async {
        // 100s / 20s = 5 segments, each exactly 20s, last may differ for odd totals
        // Use 110s / 20s = ceil(5.5) = 6 segments; last segment ~10s
        const totalDuration = 110.0;
        const segmentSeconds = 20.0;
        final tmp = await _createTempFile(10 * 1024 * 1024);
        try {
          final fileProxyUrl = proxy.registerFile(tmp.file.path);
          final playlistUrl = proxy.wrapLocalFileAsHls(
            fileProxyUrl,
            tmp.file.path,
            segmentSeconds: segmentSeconds,
            totalDuration: totalDuration,
          );
          final content = await _fetchString(playlistUrl);

          final extinfRegex = RegExp(r'#EXTINF:([\d.]+),');
          final durations = extinfRegex
              .allMatches(content)
              .map((m) => double.parse(m.group(1)!))
              .toList();

          expect(durations, hasLength(6)); // ceil(110/20) = 6
          // First five segments ~20s each (actualSegmentDuration = 110/6 ≈ 18.333)
          // All durations sum to 110
          final sum = durations.fold<double>(0.0, (a, b) => a + b);
          expect(sum, closeTo(totalDuration, 0.01));
        } finally {
          await tmp.dir.delete(recursive: true);
        }
      });
    });
  });
}
