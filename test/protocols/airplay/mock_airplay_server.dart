import 'dart:io';

/// A mock AirPlay HTTP server for testing.
///
/// Simulates AirPlay device endpoints and records request details
/// for verification in tests.
class MockAirPlayServer {
  HttpServer? _server;

  /// The port the mock server is listening on.
  int get port => _server!.port;

  // Recorded request details
  String? lastMethod;
  String? lastPath;
  String? lastBody;
  String? lastContentType;
  String? lastSessionId;
  String? lastUserAgent;
  Map<String, String> lastQueryParameters = {};

  /// Configurable playback rate returned by /playback-info (default 1.0).
  double playbackRate = 1.0;

  /// Configurable readyToPlay returned by /playback-info (default true).
  bool readyToPlay = true;

  /// Starts the mock server on a random available port.
  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
  }

  /// Stops the mock server.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    // Record request details
    lastMethod = request.method;
    lastPath = request.uri.path;
    lastQueryParameters = request.uri.queryParameters;
    lastContentType = request.headers.contentType?.toString();
    lastSessionId = request.headers.value('X-Apple-Session-ID');
    lastUserAgent = request.headers.value('User-Agent');

    // Read body for POST requests
    if (request.method == 'POST') {
      final bodyBytes = await request.fold<List<int>>(
        <int>[],
        (prev, chunk) => prev..addAll(chunk),
      );
      lastBody = String.fromCharCodes(bodyBytes);
    } else {
      lastBody = null;
    }

    // Route to appropriate handler
    switch (request.uri.path) {
      case '/play':
        _handlePlay(request);
        break;
      case '/scrub':
        if (request.method == 'GET') {
          _handleGetScrub(request);
        } else {
          _handlePostScrub(request);
        }
        break;
      case '/rate':
        _handleRate(request);
        break;
      case '/stop':
        _handleStop(request);
        break;
      case '/playback-info':
        _handlePlaybackInfo(request);
        break;
      case '/server-info':
        _handleServerInfo(request);
        break;
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
    }
  }

  void _handlePlay(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.close();
  }

  void _handlePostScrub(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.close();
  }

  void _handleGetScrub(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('text', 'parameters');
    request.response.write('duration: 5400.000000\nposition: 123.456789\n');
    request.response.close();
  }

  void _handleRate(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.close();
  }

  void _handleStop(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.close();
  }

  void _handlePlaybackInfo(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType('text', 'x-apple-plist+xml');
    request.response.write('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>duration</key>
    <real>5400.000000</real>
    <key>position</key>
    <real>123.456789</real>
    <key>rate</key>
    <real>${playbackRate.toStringAsFixed(6)}</real>
    <key>readyToPlay</key>
    <$readyToPlay/>
    <key>playbackBufferEmpty</key>
    <false/>
    <key>playbackLikelyToKeepUp</key>
    <true/>
</dict>
</plist>''');
    request.response.close();
  }

  void _handleServerInfo(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType =
        ContentType('text', 'x-apple-plist+xml');
    request.response.write('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>deviceid</key>
    <string>AA:BB:CC:DD:EE:FF</string>
    <key>features</key>
    <integer>1518338039</integer>
    <key>model</key>
    <string>AppleTV3,2</string>
    <key>protovers</key>
    <string>1.0</string>
    <key>srcvers</key>
    <string>220.68</string>
</dict>
</plist>''');
    request.response.close();
  }
}
