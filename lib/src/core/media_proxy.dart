import 'dart:io';
import 'dart:math';

import 'hls_parser.dart';
import '../utils/network_utils.dart';

/// Route type for proxy routing.
enum _RouteType { remote, localFile }

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
  String? _baseUrl;
  final Map<String, _ProxyRoute> _routes = {};
  final Random _random = Random.secure();

  /// The base URL of the running proxy server, or null if not started.
  String? get baseUrl => _baseUrl;

  /// Starts the proxy server bound to the local WiFi IP.
  Future<void> start() async {
    if (_server != null) return;

    _httpClient = HttpClient();

    final ip = await NetworkUtils.getLocalIpAddress();
    final bindAddress = ip ?? '0.0.0.0';
    final port = await NetworkUtils.findAvailablePort();

    _server = await HttpServer.bind(bindAddress, port);
    _baseUrl = 'http://${ip ?? bindAddress}:$port';

    _server!.listen(_handleRequest);
  }

  /// Stops the proxy server and cleans up resources.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    _baseUrl = null;
    _routes.clear();
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

  /// Removes all previously registered routes for quality switching.
  void cleanupPreviousMedia() {
    _routes.clear();
  }

  String _generateToken() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(16, (_) => chars[_random.nextInt(chars.length)])
        .join();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;

      // Route: /stream/<token> — remote proxy (direct or sub-resource via ?url=)
      if (path.startsWith('/stream/')) {
        final token = path.substring('/stream/'.length);
        await _handleStreamRequest(request, token);
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
      final content = String.fromCharCodes(body);

      if (content.trimLeft().startsWith('#EXTM3U')) {
        final rewritten = HlsParser.rewritePlaylist(
          content,
          targetUrl,
          _baseUrl!,
          token,
        );

        // Override content type and length for rewritten playlist
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        request.response.headers.set(
          'Content-Length',
          rewritten.length.toString(),
        );
        request.response.write(rewritten);
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
      final start = int.parse(parts[0]);
      final end = parts[1].isNotEmpty ? int.parse(parts[1]) : fileLength - 1;
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
