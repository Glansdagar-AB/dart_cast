import 'dart:io';

/// An extended mock AirPlay HTTP server for integration testing.
///
/// Builds on the patterns from `test/protocols/airplay/mock_airplay_server.dart`
/// but adds stateful tracking of playback position, duration, and rate so that
/// the integration tests can verify the full session lifecycle.
class MockAirPlayServer {
  HttpServer? _server;

  /// The port the mock server is listening on.
  int get port => _server!.port;

  /// The host address (always loopback for testing).
  String get host => '127.0.0.1';

  // -- Stateful playback tracking --

  /// Current playback rate: 0.0 = paused, 1.0 = playing.
  double rate = 0.0;

  /// Current playback position in seconds.
  double position = 0.0;

  /// Total media duration in seconds.
  double duration = 0.0;

  /// Whether media is loaded and ready to play.
  bool readyToPlay = false;

  /// Whether the server is currently "playing" (media loaded).
  bool get isPlaying => rate > 0.0 && readyToPlay;

  /// The last media URL received via /play.
  String? lastMediaUrl;

  /// Ordered log of received request paths for verification.
  final List<String> requestLog = [];

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

  /// Clears the request log.
  void clearLog() => requestLog.clear();

  /// Resets all playback state to defaults.
  void reset() {
    rate = 0.0;
    position = 0.0;
    duration = 0.0;
    readyToPlay = false;
    lastMediaUrl = null;
    requestLog.clear();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    requestLog.add('$method $path');

    switch (path) {
      case '/play':
        await _handlePlay(request);
      case '/scrub':
        if (method == 'GET') {
          _handleGetScrub(request);
        } else {
          _handlePostScrub(request);
        }
      case '/rate':
        _handleRate(request);
      case '/stop':
        _handleStop(request);
      case '/playback-info':
        _handlePlaybackInfo(request);
      case '/server-info':
        _handleServerInfo(request);
      default:
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
    }
  }

  Future<void> _handlePlay(HttpRequest request) async {
    // Parse the text/parameters body
    final bodyBytes = await request.fold<List<int>>(
      <int>[],
      (prev, chunk) => prev..addAll(chunk),
    );
    final body = String.fromCharCodes(bodyBytes);

    // Extract Content-Location
    final locationMatch = RegExp(r'Content-Location:\s*(.+)').firstMatch(body);
    if (locationMatch != null) {
      lastMediaUrl = locationMatch.group(1)!.trim();
    }

    // Start playing
    readyToPlay = true;
    rate = 1.0;
    position = 0.0;
    duration = 5400.0; // Default 1.5 hours

    request.response.statusCode = HttpStatus.ok;
    await request.response.close();
  }

  void _handlePostScrub(HttpRequest request) {
    final posParam = request.uri.queryParameters['position'];
    if (posParam != null) {
      position = double.tryParse(posParam) ?? position;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.close();
  }

  void _handleGetScrub(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType('text', 'parameters');
    request.response.write(
      'duration: ${duration.toStringAsFixed(6)}\n'
      'position: ${position.toStringAsFixed(6)}\n',
    );
    request.response.close();
  }

  void _handleRate(HttpRequest request) {
    final value = request.uri.queryParameters['value'];
    if (value != null) {
      rate = double.tryParse(value) ?? rate;
    }
    request.response.statusCode = HttpStatus.ok;
    request.response.close();
  }

  void _handleStop(HttpRequest request) {
    rate = 0.0;
    readyToPlay = false;
    position = 0.0;
    lastMediaUrl = null;
    request.response.statusCode = HttpStatus.ok;
    request.response.close();
  }

  void _handlePlaybackInfo(HttpRequest request) {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType(
      'text',
      'x-apple-plist+xml',
    );
    request.response.write('''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>duration</key>
    <real>${duration.toStringAsFixed(6)}</real>
    <key>position</key>
    <real>${position.toStringAsFixed(6)}</real>
    <key>rate</key>
    <real>${rate.toStringAsFixed(6)}</real>
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
    request.response.headers.contentType = ContentType(
      'text',
      'x-apple-plist+xml',
    );
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
    <string>MockAppleTV</string>
    <key>protovers</key>
    <string>1.0</string>
    <key>srcvers</key>
    <string>220.68</string>
</dict>
</plist>''');
    request.response.close();
  }
}
