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


  /// Creates an [AirPlaySession] for the given AirPlay [device].
  AirPlaySession(super.device);

  /// The underlying AirPlay HTTP client (available after [connect]).
  AirPlayClient? get client => _client;

  /// Connects to the AirPlay device.
  ///
  /// Creates an [AirPlayClient], calls `getServerInfo()` to verify the device
  /// is reachable, and transitions to [SessionState.connected].
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

      // Register the media URL with the proxy
      final proxyUrl = _proxy.registerMedia(
        media.url,
        headers: media.httpHeaders,
      );

      // Start playback on the device
      // AirPlay start position is fractional (0.0-1.0); without knowing
      // total duration we default to 0.0.
      await _client!.play(proxyUrl, startPosition: 0.0);

      // Start polling for playback state
      _startPolling();
    } catch (e) {
      stateMachine.transitionTo(SessionState.disconnected);
      rethrow;
    }
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
  /// For AirPlay, subtitles need to be embedded in the HLS playlist.
  /// Re-loading the media with the subtitle injected is required.
  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {
    // AirPlay 1 subtitle support requires HLS playlist modification.
    // A full implementation would re-load media with modified playlist.
    // For now, this is a no-op placeholder.
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
    if (_client == null) return;

    try {
      final info = await _client!.getPlaybackInfo();
      _updateFromPlaybackInfo(info);
    } catch (_) {
      // Connection lost or device unresponsive — could transition to disconnected
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
      throw StateError('AirPlaySession is not connected. Call connect() first.');
    }
  }
}
