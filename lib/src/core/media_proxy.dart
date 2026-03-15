import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'hls_parser.dart';
import 'hls_stream_proxy.dart';
import '../utils/network_utils.dart';

/// Route type for proxy routing.
enum _RouteType { remote, localFile, hlsStream }

/// Synthetic content served directly by the proxy (e.g., generated playlists).
class _SyntheticContent {
  final String content;
  final ContentType contentType;

  _SyntheticContent({required this.content, required this.contentType});
}

/// A registered proxy route.
class _ProxyRoute {
  final _RouteType type;
  final String url; // remote URL or local file path
  final Map<String, String> headers;

  _ProxyRoute({
    required this.type,
    required this.url,
    this.headers = const {},
  });
}

/// Local HTTP proxy server for casting.
///
/// Proxies remote URLs with custom header injection and rewrites HLS playlists.
/// Also serves local files for casting downloaded content.
class MediaProxy {
  HttpServer? _server;
  HttpClient? _httpClient;
  HlsStreamHandler? _hlsStreamHandler;
  String? _baseUrl;
  final Map<String, _ProxyRoute> _routes = {};
  final Map<String, _SyntheticContent> _syntheticContent = {};
  final Random _random = Random.secure();

  /// The base URL of the running proxy server, or null if not started.
  String? get baseUrl => _baseUrl;

  /// Starts the proxy server bound to the local WiFi IP.
  ///
  /// An optional [port] can be provided; otherwise binds to port 0 to let the
  /// OS assign an available port, eliminating TOCTOU races.
  Future<void> start({int? port}) async {
    if (_server != null) return;

    _httpClient = HttpClient();
    _hlsStreamHandler = HlsStreamHandler(httpClient: _httpClient);

    final ip = await NetworkUtils.getLocalIpAddress();
    final bindAddress = ip ?? '0.0.0.0';

    _server = await HttpServer.bind(bindAddress, port ?? 0);
    final actualPort = _server!.port;
    _baseUrl = 'http://${ip ?? bindAddress}:$actualPort';

    _server!.listen(_handleRequest);
  }

  /// Stops the proxy server and cleans up resources.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    _hlsStreamHandler = null;
    _baseUrl = null;
    _routes.clear();
    _syntheticContent.clear();
  }

  /// Registers a remote media URL for proxying.
  ///
  /// Returns a proxy URL that can be given to a cast device.
  String registerMedia(String url, {Map<String, String> headers = const {}}) {
    final token = _generateToken();
    _routes[token] = _ProxyRoute(
      type: _RouteType.remote,
      url: url,
      headers: headers,
    );
    return '$_baseUrl/stream/$token';
  }

  /// Registers a local file for serving.
  ///
  /// Returns a proxy URL that can be given to a cast device.
  String registerFile(String filePath) {
    final token = _generateToken();
    _routes[token] = _ProxyRoute(
      type: _RouteType.localFile,
      url: filePath,
    );
    return '$_baseUrl/file/$token';
  }

  /// Registers an HLS stream to be served as continuous MPEG-TS.
  ///
  /// When a client (e.g. a DLNA TV) GETs the returned URL, the proxy fetches
  /// the m3u8 playlist, resolves all segments, and pipes them sequentially
  /// as a single `video/mp2t` response. This is useful for devices that do
  /// not support HLS natively.
  String registerHlsAsStream(
    String m3u8Url, {
    Map<String, String> headers = const {},
  }) {
    final token = _generateToken();
    _routes[token] = _ProxyRoute(
      type: _RouteType.hlsStream,
      url: m3u8Url,
      headers: headers,
    );
    return '$_baseUrl/ts-stream/$token';
  }

  /// Registers a VTT subtitle file as an HLS subtitle playlist.
  ///
  /// Creates a simple HLS media playlist wrapping the VTT file so it can be
  /// referenced via `#EXT-X-MEDIA:TYPE=SUBTITLES` in a master playlist.
  /// Returns a proxy URL pointing to the generated m3u8.
  String registerSubtitlePlaylist(
    String vttUrl, {
    Map<String, String> headers = const {},
  }) {
    // First, register the VTT file itself through the proxy
    final proxiedVttUrl = registerMedia(vttUrl, headers: headers);

    // Create a simple HLS playlist wrapping the VTT
    final playlistContent = '#EXTM3U\n'
        '#EXT-X-TARGETDURATION:99999\n'
        '#EXTINF:99999.0,\n'
        '$proxiedVttUrl\n'
        '#EXT-X-ENDLIST\n';

    // Register the playlist content as a synthetic route
    final token = _generateToken();
    _syntheticContent[token] = _SyntheticContent(
      content: playlistContent,
      contentType: ContentType('application', 'vnd.apple.mpegurl'),
    );
    return '$_baseUrl/synthetic/$token';
  }

  /// Creates a wrapper master playlist that adds subtitle tracks to an
  /// existing HLS stream.
  ///
  /// [originalM3u8ProxyUrl] is the already-proxied URL of the original master
  /// playlist. [subtitleEntries] is a list of `(name, language, subtitleM3u8Url)`
  /// tuples, where each URL points to a subtitle HLS playlist (e.g., from
  /// [registerSubtitlePlaylist]).
  ///
  /// Returns a proxy URL for the wrapper master playlist.
  String registerSubtitleWrapper({
    required String originalM3u8ProxyUrl,
    required List<({String name, String language, String url})> subtitleEntries,
  }) {
    final buffer = StringBuffer('#EXTM3U\n');

    for (var i = 0; i < subtitleEntries.length; i++) {
      final entry = subtitleEntries[i];
      final isDefault = i == 0 ? 'YES' : 'NO';
      buffer.writeln(
        '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",'
        'NAME="${entry.name}",DEFAULT=$isDefault,AUTOSELECT=$isDefault,'
        'LANGUAGE="${entry.language}",URI="${entry.url}"',
      );
    }

    buffer.writeln('#EXT-X-STREAM-INF:BANDWIDTH=1280000,SUBTITLES="subs"');
    buffer.writeln(originalM3u8ProxyUrl);

    final token = _generateToken();
    _syntheticContent[token] = _SyntheticContent(
      content: buffer.toString(),
      contentType: ContentType('application', 'vnd.apple.mpegurl'),
    );
    return '$_baseUrl/synthetic/$token';
  }

  /// Removes all previously registered routes, optionally keeping [excludeToken].
  void cleanupPreviousMedia({String? excludeToken}) {
    if (excludeToken != null) {
      final kept = _routes[excludeToken];
      _routes.clear();
      if (kept != null) {
        _routes[excludeToken] = kept;
      }
    } else {
      _routes.clear();
    }
    _syntheticContent.clear();
  }

  String _generateToken() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(16, (_) => chars[_random.nextInt(chars.length)])
        .join();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;

      // Route: /ts-stream/<token> — HLS-to-MPEG-TS streaming
      if (path.startsWith('/ts-stream/')) {
        final token = path.substring('/ts-stream/'.length);
        await _handleHlsStreamRequest(request, token);
        return;
      }

      // Route: /stream/<token> — remote proxy (direct or sub-resource via ?url=)
      if (path.startsWith('/stream/')) {
        final token = path.substring('/stream/'.length);
        await _handleStreamRequest(request, token);
        return;
      }

      // Route: /synthetic/<token> — generated content (subtitle playlists, wrappers)
      if (path.startsWith('/synthetic/')) {
        final token = path.substring('/synthetic/'.length);
        await _handleSyntheticRequest(request, token);
        return;
      }

      // Route: /file/<token> — local file serving
      if (path.startsWith('/file/')) {
        final token = path.substring('/file/'.length);
        await _handleFileRequest(request, token);
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {
        // Response may already be closed
      }
    }
  }

  Future<void> _handleSyntheticRequest(
      HttpRequest request, String token) async {
    final synthetic = _syntheticContent[token];
    if (synthetic == null) {
      request.response.statusCode = HttpStatus.notFound;
      _addCorsHeaders(request.response);
      await request.response.close();
      return;
    }

    final encoded = utf8.encode(synthetic.content);
    _addCorsHeaders(request.response);
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = synthetic.contentType;
    request.response.headers.set('Content-Length', encoded.length.toString());
    request.response.add(encoded);
    await request.response.close();
  }

  Future<void> _handleHlsStreamRequest(
    HttpRequest request,
    String token,
  ) async {
    if (_hlsStreamHandler == null) {
      request.response
        ..statusCode = HttpStatus.serviceUnavailable
        ..close();
      return;
    }

    final route = _routes[token];
    if (route == null || route.type != _RouteType.hlsStream) {
      request.response.statusCode = HttpStatus.notFound;
      _addCorsHeaders(request.response);
      await request.response.close();
      return;
    }

    await _hlsStreamHandler!.streamAsTransportStream(
      route.url,
      route.headers,
      request.response,
    );
  }

  Future<void> _handleStreamRequest(HttpRequest request, String token) async {
    final route = _routes[token];
    if (route == null || route.type != _RouteType.remote) {
      request.response.statusCode = HttpStatus.notFound;
      _addCorsHeaders(request.response);
      await request.response.close();
      return;
    }

    // Determine the actual URL to fetch:
    // If ?url= query param is present, use that (sub-resource from rewritten m3u8).
    // Otherwise, use the registered URL directly.
    final urlParam = request.uri.queryParameters['url'];
    final targetUrl = urlParam ?? route.url;

    // Fetch upstream
    final upstreamUri = Uri.parse(targetUrl);
    final upstreamRequest = await _httpClient!.openUrl('GET', upstreamUri);

    // Inject registered headers
    for (final entry in route.headers.entries) {
      upstreamRequest.headers.set(entry.key, entry.value);
    }

    // Forward Range header if present
    final rangeHeader = request.headers.value('Range');
    if (rangeHeader != null) {
      upstreamRequest.headers.set('Range', rangeHeader);
    }

    final upstreamResponse = await upstreamRequest.close();

    // Set response status
    request.response.statusCode = upstreamResponse.statusCode;
    _addCorsHeaders(request.response);

    // Forward relevant headers
    final upstreamContentType = upstreamResponse.headers.contentType;
    if (upstreamContentType != null) {
      request.response.headers.contentType = upstreamContentType;
    }

    final contentRange = upstreamResponse.headers.value('Content-Range');
    if (contentRange != null) {
      request.response.headers.set('Content-Range', contentRange);
      request.response.headers.set('Accept-Ranges', 'bytes');
    }

    final contentLength = upstreamResponse.headers.value('Content-Length');
    if (contentLength != null) {
      request.response.headers.set('Content-Length', contentLength);
    }

    // Check if this is an HLS playlist that needs rewriting
    if (_isHlsResponse(targetUrl, upstreamContentType) &&
        upstreamResponse.statusCode == HttpStatus.ok) {
      // Buffer the playlist content for rewriting
      final body = await upstreamResponse
          .fold<List<int>>(<int>[], (prev, chunk) => prev..addAll(chunk));
      final content = utf8.decode(body);

      if (content.trimLeft().startsWith('#EXTM3U')) {
        final rewritten = HlsParser.rewritePlaylist(
          content,
          targetUrl,
          _baseUrl!,
          token,
        );

        // Override content type and length for rewritten playlist
        final encoded = utf8.encode(rewritten);
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response.headers.set(
          'Content-Length',
          encoded.length.toString(),
        );
        request.response.add(encoded);
        await request.response.close();
        return;
      }

      // Not actually a valid m3u8 — send the body as-is
      request.response.add(body);
      await request.response.close();
      return;
    }

    // Stream non-playlist content directly
    await upstreamResponse.pipe(request.response);
  }

  Future<void> _handleFileRequest(HttpRequest request, String token) async {
    final route = _routes[token];
    if (route == null || route.type != _RouteType.localFile) {
      request.response.statusCode = HttpStatus.notFound;
      _addCorsHeaders(request.response);
      await request.response.close();
      return;
    }

    final file = File(route.url);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      _addCorsHeaders(request.response);
      await request.response.close();
      return;
    }

    final fileLength = await file.length();
    final contentType = _contentTypeForPath(route.url);

    _addCorsHeaders(request.response);
    request.response.headers.contentType = contentType;
    request.response.headers.set('Accept-Ranges', 'bytes');

    // Handle Range requests
    final rangeHeader = request.headers.value('Range');
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final rangeSpec = rangeHeader.substring('bytes='.length);
      final parts = rangeSpec.split('-');

      int start;
      int end;

      if (parts[0].isEmpty) {
        // Suffix range: bytes=-500 means last 500 bytes
        final suffixLength = int.parse(parts[1]);
        start = (fileLength - suffixLength).clamp(0, fileLength - 1);
        end = fileLength - 1;
      } else {
        start = int.parse(parts[0]);
        end = (parts[1].isNotEmpty ? int.parse(parts[1]) : fileLength - 1)
            .clamp(0, fileLength - 1);
      }

      final length = end - start + 1;

      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers
          .set('Content-Range', 'bytes $start-$end/$fileLength');
      request.response.headers.set('Content-Length', length.toString());

      final raf = await file.open();
      try {
        await raf.setPosition(start);
        final bytes = await raf.read(length);
        request.response.add(bytes);
      } finally {
        await raf.close();
      }
      await request.response.close();
      return;
    }

    // Full file
    request.response.headers.set('Content-Length', fileLength.toString());
    await file.openRead().pipe(request.response);
  }

  bool _isHlsResponse(String url, ContentType? contentType) {
    // Check URL extension
    if (url.contains('.m3u8') || url.contains('.m3u')) return true;

    // Check content type
    if (contentType != null) {
      final mimeType =
          '${contentType.primaryType}/${contentType.subType}'.toLowerCase();
      if (mimeType.contains('mpegurl') || mimeType.contains('x-mpegurl')) {
        return true;
      }
    }

    return false;
  }

  ContentType _contentTypeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.m3u8') || lower.endsWith('.m3u')) {
      return ContentType('application', 'vnd.apple.mpegurl');
    }
    if (lower.endsWith('.mp4') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.m4s')) {
      return ContentType('video', 'mp4');
    }
    if (lower.endsWith('.ts')) {
      return ContentType('video', 'mp2t');
    }
    if (lower.endsWith('.vtt')) {
      return ContentType('text', 'vtt');
    }
    if (lower.endsWith('.aac')) {
      return ContentType('audio', 'aac');
    }
    return ContentType('application', 'octet-stream');
  }

  void _addCorsHeaders(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Headers', 'Range');
    response.headers.set(
      'Access-Control-Expose-Headers',
      'Content-Range, Content-Length',
    );
  }
}
