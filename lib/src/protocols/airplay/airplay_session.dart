import 'dart:async';
import 'dart:math';

import '../../core/cast_exceptions.dart';
import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import '../../core/media_proxy.dart';
import '../../utils/logger.dart';
import 'airplay_client.dart';
import 'auth/airplay_auth.dart';
import 'auth/hap_credentials.dart';
import 'auth/hap_session.dart';
import 'plist_codec.dart';

/// AirPlay 1 cast session with playback control and position polling.
///
/// Extends [CastSession] to implement AirPlay-specific behavior:
/// - Connects to a device via [AirPlayClient]
/// - Proxies media through [MediaProxy] so the AirPlay device can reach it
/// - Polls `/playback-info` periodically to update position/duration/state
/// - Supports HAP authentication for devices that require it (Apple TV tvOS 10.2+)
class AirPlaySession extends CastSession {
  AirPlayClient? _client;
  HapSession? _hapSession;
  final MediaProxy _proxy = MediaProxy();
  Timer? _pollTimer;
  bool _isPolling = false;
  CastMedia? _currentMedia;

  /// Stored HAP credentials for pair-verify. Set these before calling
  /// [connect] if the device requires authentication.
  HapCredentials? credentials;

  /// Creates an [AirPlaySession] for the given AirPlay [device].
  AirPlaySession(super.device, {this.credentials});

  /// The underlying AirPlay HTTP client (available after [connect]).
  AirPlayClient? get client => _client;

  /// Connects to the AirPlay device.
  ///
  /// Creates an [AirPlayClient], calls `getServerInfo()` to verify the device
  /// is reachable. If the device returns HTTP 403, attempts pair-verify with
  /// stored [credentials]. If no credentials are available, throws
  /// [NeedsPairingException].
  @override
  Future<void> connect() async {
    CastLogger.info(
        'AirPlay: connecting to ${device.name} at ${device.address.address}:${device.port}');
    stateMachine.transitionTo(SessionState.connecting);

    _client = AirPlayClient(
      host: device.address.address,
      port: device.port,
    );

    try {
      await _client!.getServerInfo();
      CastLogger.info('AirPlay: connected to ${device.name}');
      stateMachine.transitionTo(SessionState.connected);
    } on AirPlayClientException catch (e) {
      if (e.message.contains('403')) {
        CastLogger.info('AirPlay: device requires authentication');
        await _handleAuthRequired();
      } else {
        CastLogger.error('AirPlay: connection failed to ${device.name}: $e');
        _client?.close();
        _client = null;
        stateMachine.transitionTo(SessionState.disconnected);
        rethrow;
      }
    } catch (e) {
      CastLogger.error('AirPlay: connection failed to ${device.name}: $e');
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      rethrow;
    }
  }

  /// Handles the case where the device requires HAP authentication.
  Future<void> _handleAuthRequired() async {
    if (credentials == null) {
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      throw NeedsPairingException(
          'AirPlay device "${device.name}" requires pairing. '
          'Call pairSetup(pin) first.');
    }

    // Attempt pair-verify using the SAME http client as AirPlayClient
    // so the authenticated connection is shared for subsequent /play commands.
    final pairVerify = AirPlayPairVerify(
      host: device.address.address,
      port: device.port,
      httpClient: _client!.httpClient,
    );
    try {
      CastLogger.info(
          'AirPlay: attempting pair-verify with stored credentials');
      final sharedSecret = await pairVerify.execute(credentials!);

      CastLogger.info('AirPlay: pair-verify successful, creating HAP session');

      // Create encrypted HAP session for all subsequent media commands
      _hapSession = await HapSession.connect(
        host: device.address.address,
        port: device.port,
        sharedSecret: sharedSecret,
        sessionId: _client!.sessionId,
      );

      CastLogger.info('AirPlay: HAP encrypted session established');
      stateMachine.transitionTo(SessionState.connected);
    } on AirPlayAuthException catch (e) {
      // Auth failure — credentials may be stale, need re-pairing
      CastLogger.error('AirPlay: pair-verify auth failed: $e');
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      throw NeedsPairingException(
          'AirPlay pair-verify failed. Device may need re-pairing. '
          'Call pairSetup(pin) to re-pair.');
    } catch (e) {
      // Network error — don't discard credentials
      CastLogger.error('AirPlay: pair-verify network error: $e');
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      rethrow;
    } finally {
      // Do NOT close pairVerify — it shares the AirPlayClient's http.Client
    }
  }

  /// Performs HAP pair-setup with the device using the given [pin].
  ///
  /// This triggers the device to display a 4-digit PIN, which the user
  /// must enter. On success, stores [credentials] for future sessions.
  ///
  /// [clientId] is an optional identifier for this client. If not provided,
  /// a random UUID is generated.
  Future<HapCredentials> pairSetup(
    String pin, {
    String? clientId,
    bool triggerPinDisplay = true,
  }) async {
    final id = clientId ?? _generateUuid();

    final pairSetup = AirPlayPairSetup(
      host: device.address.address,
      port: device.port,
    );

    try {
      // Trigger PIN display on TV (skip if already triggered externally)
      if (triggerPinDisplay) {
        CastLogger.info('AirPlay: triggering PIN display on TV');
        pairSetup.startPinDisplay(); // Fire-and-forget — TV may not respond
      }

      // Run pair-setup SRP flow with the user-entered PIN
      CastLogger.info('AirPlay: starting SRP pair-setup with PIN');
      credentials = await pairSetup.pairSetup(pin: pin, clientId: id);

      CastLogger.info('AirPlay: pair-setup complete, credentials stored');
      return credentials!;
    } finally {
      pairSetup.close();
    }
  }

  /// Loads media onto the AirPlay device.
  ///
  /// Starts the media proxy, registers the media URL, and sends a `POST /play`
  /// to the device. Begins position polling after playback starts.
  @override
  Future<void> loadMedia(CastMedia media) async {
    _ensureClient();
    stateMachine.transitionTo(SessionState.loading);

    try {
      // Start proxy server
      await _proxy.start();

      _currentMedia = media;

      // Register the media URL with the proxy
      final proxyUrl = _proxy.registerMedia(
        media.url,
        headers: media.httpHeaders,
      );

      // Determine the final URL to send to the device
      String playUrl;

      if (media.subtitles.isNotEmpty && media.type == CastMediaType.hls) {
        // Inject subtitles into HLS playlist via wrapper m3u8
        playUrl =
            _buildSubtitleWrapper(proxyUrl, media.subtitles, media.httpHeaders);
      } else {
        playUrl = proxyUrl;
      }

      // Start playback on the device via encrypted channel if available
      // AirPlay start position is fractional (0.0-1.0); without knowing
      // total duration we default to 0.0.
      if (_hapSession != null) {
        await _hapSession!.play(playUrl, startPosition: 0.0);
      } else {
        await _client!.play(playUrl, startPosition: 0.0);
      }

      // Start polling for playback state
      _startPolling();
    } catch (e) {
      if (stateMachine.canTransitionTo(SessionState.idle)) {
        stateMachine.transitionTo(SessionState.idle);
      }
      rethrow;
    }
  }

  /// Builds a wrapper m3u8 that adds subtitle tracks to the original HLS stream.
  String _buildSubtitleWrapper(
    String originalProxyUrl,
    List<CastSubtitle> subtitles,
    Map<String, String> headers,
  ) {
    final subtitleEntries = <({String name, String language, String url})>[];

    for (final sub in subtitles) {
      // Register each subtitle as an HLS subtitle playlist
      final subPlaylistUrl = _proxy.registerSubtitlePlaylist(
        sub.url,
        headers: headers,
      );
      subtitleEntries.add((
        name: sub.label,
        language: sub.language,
        url: subPlaylistUrl,
      ));
    }

    return _proxy.registerSubtitleWrapper(
      originalM3u8ProxyUrl: originalProxyUrl,
      subtitleEntries: subtitleEntries,
    );
  }

  /// Resumes playback (sends rate=1 to device).
  @override
  Future<void> play() async {
    _ensureClient();
    if (_hapSession != null) {
      await _hapSession!.rate(1);
    } else {
      await _client!.rate(1);
    }
    if (stateMachine.canTransitionTo(SessionState.playing)) {
      stateMachine.transitionTo(SessionState.playing);
    }
  }

  /// Pauses playback (sends rate=0 to device).
  @override
  Future<void> pause() async {
    _ensureClient();
    if (_hapSession != null) {
      await _hapSession!.rate(0);
    } else {
      await _client!.rate(0);
    }
    if (stateMachine.canTransitionTo(SessionState.paused)) {
      stateMachine.transitionTo(SessionState.paused);
    }
  }

  /// Stops playback, cancels polling, and transitions to idle.
  @override
  Future<void> stop() async {
    _ensureClient();
    _stopPolling();
    if (_hapSession != null) {
      await _hapSession!.stop();
    } else {
      await _client!.stop();
    }
    _proxy.cleanupPreviousMedia();
    if (stateMachine.canTransitionTo(SessionState.idle)) {
      stateMachine.transitionTo(SessionState.idle);
    }
  }

  /// Seeks to the given [position] (sends scrub with seconds).
  @override
  Future<void> seek(Duration position) async {
    _ensureClient();
    if (_hapSession != null) {
      await _hapSession!.scrub(position.inMilliseconds / 1000.0);
    } else {
      await _client!.scrub(position.inMilliseconds / 1000.0);
    }
  }

  /// Sets volume. AirPlay 1 has no volume endpoint, so this stores locally.
  @override
  Future<void> setVolume(double volume) async {
    updateVolume(volume);
  }

  /// Sets the active subtitle track.
  ///
  /// For AirPlay 1, subtitles are delivered by rewriting the HLS playlist.
  /// This re-loads the media with a modified playlist containing the selected
  /// subtitle track, or without subtitles if [subtitle] is null.
  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {
    if (_currentMedia == null || _client == null) return;

    final media = _currentMedia!;

    // Build new media with only the selected subtitle (or none)
    final newMedia = CastMedia(
      url: media.url,
      type: media.type,
      httpHeaders: media.httpHeaders,
      title: media.title,
      imageUrl: media.imageUrl,
      startPosition: media.startPosition,
      subtitles: subtitle != null ? [subtitle] : const [],
    );

    // Clean up old proxy routes and re-register
    _proxy.cleanupPreviousMedia();

    final proxyUrl = _proxy.registerMedia(
      newMedia.url,
      headers: newMedia.httpHeaders,
    );

    String playUrl;
    if (newMedia.subtitles.isNotEmpty && newMedia.type == CastMediaType.hls) {
      playUrl = _buildSubtitleWrapper(
          proxyUrl, newMedia.subtitles, newMedia.httpHeaders);
    } else {
      playUrl = proxyUrl;
    }

    if (_hapSession != null) {
      await _hapSession!.play(playUrl, startPosition: 0.0);
    } else {
      await _client!.play(playUrl, startPosition: 0.0);
    }
  }

  /// Disconnects from the device, stopping playback and cleaning up.
  @override
  Future<void> disconnect() async {
    _stopPolling();

    try {
      if (_hapSession != null) {
        await _hapSession!.stop();
      } else if (_client != null) {
        await _client!.stop();
      }
    } catch (_) {
      // Ignore errors during disconnect cleanup
    }

    await _hapSession?.close();
    _hapSession = null;
    _client?.close();
    _client = null;
    await _proxy.stop();
    stateMachine.transitionTo(SessionState.disconnected);
  }

  /// Disposes all resources.
  @override
  void dispose() {
    _stopPolling();
    _hapSession?.close();
    _hapSession = null;
    _client?.close();
    _client = null;
    // Don't await — fire and forget during dispose
    _proxy.stop();
    super.dispose();
  }

  /// Starts periodic polling of playback info.
  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollPlaybackInfo(),
    );
  }

  /// Stops the polling timer.
  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Polls the device for playback info and updates session state.
  Future<void> _pollPlaybackInfo() async {
    if (_client == null || _isPolling) return;
    _isPolling = true;

    try {
      final PlaybackInfo info;
      if (_hapSession != null) {
        info = await _hapSession!.getPlaybackInfo();
      } else {
        info = await _client!.getPlaybackInfo();
      }
      _updateFromPlaybackInfo(info);
    } catch (_) {
      // Connection lost or device unresponsive — could transition to disconnected
    } finally {
      _isPolling = false;
    }
  }

  /// Updates session state based on parsed playback info.
  void _updateFromPlaybackInfo(PlaybackInfo info) {
    // Update position and duration
    updatePosition(Duration(
      milliseconds: (info.position * 1000).round(),
    ));
    updateDuration(Duration(
      milliseconds: (info.duration * 1000).round(),
    ));

    // Update playback state based on rate and readiness
    if (!info.readyToPlay) {
      if (stateMachine.canTransitionTo(SessionState.buffering)) {
        stateMachine.transitionTo(SessionState.buffering);
      }
    } else if (info.rate == 0.0) {
      if (stateMachine.canTransitionTo(SessionState.paused)) {
        stateMachine.transitionTo(SessionState.paused);
      }
    } else if (info.rate > 0.0) {
      if (stateMachine.canTransitionTo(SessionState.playing)) {
        stateMachine.transitionTo(SessionState.playing);
      }
    }
  }

  void _ensureClient() {
    if (_client == null) {
      throw StateError(
          'AirPlaySession is not connected. Call connect() first.');
    }
  }

  /// Generates a UUID v4-like string.
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
