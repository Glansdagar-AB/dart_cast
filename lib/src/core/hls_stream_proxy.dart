import 'dart:io';

import 'hls_parser.dart';

/// Handles fetching an HLS playlist and streaming its segments as a
/// continuous MPEG-TS byte stream.
///
/// This is used for DLNA devices that do not support HLS natively.
/// Instead of sending the m3u8 URL, we resolve all .ts segments and
/// concatenate them into a single response with `Content-Type: video/mp2t`.
class HlsStreamHandler {
  final HttpClient _httpClient;

  /// Creates an [HlsStreamHandler] with an optional [HttpClient].
  HlsStreamHandler({HttpClient? httpClient})
      : _httpClient = httpClient ?? HttpClient();

  /// Fetches the HLS playlist at [m3u8Url], resolves segments, and streams
  /// them sequentially into [response].
  ///
  /// If the playlist is a master playlist, the highest-bandwidth variant is
  /// selected automatically.
  ///
  /// [headers] are forwarded to all upstream requests (playlist + segments).
  Future<void> streamAsTransportStream(
    String m3u8Url,
    Map<String, String> headers,
    HttpResponse response,
  ) async {
    try {
      // Fetch the m3u8 playlist
      final playlistContent = await _fetchString(m3u8Url, headers);

      String mediaPlaylistUrl;
      String mediaPlaylistContent;

      if (HlsParser.isMasterPlaylist(playlistContent)) {
        // Pick the highest bandwidth variant
        final variants = HlsParser.extractVariants(playlistContent, m3u8Url);
        if (variants.isEmpty) {
          response.statusCode = HttpStatus.badGateway;
          await response.close();
          return;
        }
        mediaPlaylistUrl = variants.first.url;
        mediaPlaylistContent =
            await _fetchString(mediaPlaylistUrl, headers);
      } else {
        mediaPlaylistUrl = m3u8Url;
        mediaPlaylistContent = playlistContent;
      }

      // Extract segment URLs
      final segmentUrls =
          HlsParser.extractSegmentUrls(mediaPlaylistContent, mediaPlaylistUrl);

      if (segmentUrls.isEmpty) {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
        return;
      }

      // Set up the response as MPEG-TS
      response.statusCode = HttpStatus.ok;
      response.headers.contentType = ContentType('video', 'mp2t');
      response.headers.set('Accept-Ranges', 'none');
      response.headers.set('Access-Control-Allow-Origin', '*');

      // Stream each segment sequentially
      for (final segmentUrl in segmentUrls) {
        try {
          final segUri = Uri.parse(segmentUrl);
          final segRequest = await _httpClient.openUrl('GET', segUri);
          for (final entry in headers.entries) {
            segRequest.headers.set(entry.key, entry.value);
          }
          final segResponse = await segRequest.close();

          if (segResponse.statusCode == HttpStatus.ok) {
            await for (final chunk in segResponse) {
              response.add(chunk);
            }
          } else {
            // Drain and skip failed segments
            await segResponse.drain<void>();
          }
        } catch (_) {
          // Skip segments that fail to fetch
        }
      }

      await response.close();
    } catch (_) {
      try {
        response.statusCode = HttpStatus.badGateway;
        await response.close();
      } catch (_) {
        // Response may already be closed
      }
    }
  }

  /// Fetches a URL and returns the body as a string.
  Future<String> _fetchString(
    String url,
    Map<String, String> headers,
  ) async {
    final uri = Uri.parse(url);
    final request = await _httpClient.openUrl('GET', uri);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await request.close();
    final bytes = await response
        .fold<List<int>>(<int>[], (prev, chunk) => prev..addAll(chunk));
    return String.fromCharCodes(bytes);
  }

  /// Closes the underlying HTTP client.
  void close() {
    _httpClient.close(force: true);
  }
}
