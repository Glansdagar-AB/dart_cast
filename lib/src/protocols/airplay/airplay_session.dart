import 'dart:async';

import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import '../../core/media_proxy.dart';
import 'airplay_client.dart';
import 'plist_codec.dart';

/// AirPlay 1 cast session with playback control and position polling.
///
/// Extends [CastSession] to implement AirPlay-specific behavior:
/// - Connects to a device via [AirPlayClient]
/// - Proxies media through [MediaProxy] so the AirPlay device can reach it
/// - Polls `/playback-info` periodically to update position/duration/state
class AirPlaySession extends CastSession {
  AirPlayClient? _client;
  final MediaProxy _proxy = MediaProxy();
  Timer? _pollTimer;
  bool _isPolling = false;
  CastMedia? _currentMedia;

  /// Creates an [AirPlaySession] for the given AirPlay [device].
  AirPlaySession(super.device);

  /// The underlying AirPlay HTTP client (available after [connect]).
  AirPlayClient? get client => _client;

  /// Connects to the AirPlay device.
  ///
  /// Creates an [AirPlayClient], calls `getServerInfo()` to verify the device
  /// is reachable, and transitions to [SessionState.connected].
  @override
  Future<void> connect() async {
    stateMachine.transitionTo(SessionState.connecting);

    _client = AirPlayClient(
      host: device.address.address,
      port: device.port,
    );

    try {
      await _client!.getServerInfo();
      stateMachine.transitionTo(SessionState.connected);
    } catch (e) {
      _client?.close();
      _client = null;
      stateMachine.transitionTo(SessionState.disconnected);
      rethrow;
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

      // Start playback on the device
      // AirPlay start position is fractional (0.0-1.0); without knowing
      // total duration we default to 0.0.
      await _client!.play(playUrl, startPosition: 0.0);

      // Start polling for playback state
      _startPolling();
    } catch (e) {
      stateMachine.transitionTo(SessionState.disconnected);
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
    await _client!.rate(1);
    if (stateMachine.canTransitionTo(SessionState.playing)) {
      stateMachine.transitionTo(SessionState.playing);
    }
  }

  /// Pauses playback (sends rate=0 to device).
  @override
  Future<void> pause() async {
    _ensureClient();
    await _client!.rate(0);
    if (stateMachine.canTransitionTo(SessionState.paused)) {
      stateMachine.transitionTo(SessionState.paused);
    }
  }

  /// Stops playback, cancels polling, and transitions to idle.
  @override
  Future<void> stop() async {
    _ensureClient();
    _stopPolling();
    await _client!.stop();
    _proxy.cleanupPreviousMedia();
    if (stateMachine.canTransitionTo(SessionState.idle)) {
      stateMachine.transitionTo(SessionState.idle);
    }
  }

  /// Seeks to the given [position] (sends scrub with seconds).
  @override
  Future<void> seek(Duration position) async {
    _ensureClient();
    await _client!.scrub(position.inMilliseconds / 1000.0);
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

    await _client!.play(playUrl, startPosition: 0.0);
  }

  /// Disconnects from the device, stopping playback and cleaning up.
  @override
  Future<void> disconnect() async {
    _stopPolling();

    try {
      if (_client != null) {
        await _client!.stop();
      }
    } catch (_) {
      // Ignore errors during disconnect cleanup
    }

    _client?.close();
    _client = null;
    await _proxy.stop();
    stateMachine.transitionTo(SessionState.disconnected);
  }

  /// Disposes all resources.
  @override
  void dispose() {
    _stopPolling();
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
      final info = await _client!.getPlaybackInfo();
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
}
