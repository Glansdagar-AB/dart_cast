import 'dart:async';

import '../../core/cast_device.dart';
import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import 'dlna_controller.dart';
import 'dlna_device.dart';

/// A DLNA casting session that controls playback on a DLNA renderer.
///
/// Uses SOAP/UPnP to send AVTransport and RenderingControl actions.
class DlnaSession extends CastSession {
  /// The parsed device description with control URLs.
  final DlnaDeviceDescription description;

  final DlnaHttpClient _httpClient;
  Timer? _pollTimer;
  bool _isPolling = false;
  CastMedia? _currentMedia;
  CastSubtitle? _currentSubtitle;

  /// Creates a [DlnaSession] for the given [device] and [description].
  ///
  /// An optional [httpClient] can be provided for testing.
  DlnaSession({
    required CastDevice device,
    required this.description,
    DlnaHttpClient? httpClient,
  })  : _httpClient = httpClient ?? DlnaHttpClient(),
        super(device);

  /// Connects to the DLNA device by verifying it is reachable.
  @override
  Future<void> connect() async {
    stateMachine.transitionTo(SessionState.connecting);
    // For DLNA, "connect" simply means we verified the device is reachable.
    // There is no persistent connection — each action is an HTTP POST.
    stateMachine.transitionTo(SessionState.connected);
  }

  @override
  Future<void> loadMedia(CastMedia media) async {
    stateMachine.transitionTo(SessionState.loading);
    _currentMedia = media;

    final subtitleUrl = media.subtitles.isNotEmpty
        ? media.subtitles.first.url
        : _currentSubtitle?.url;

    // Send SetAVTransportURI
    await _sendAvTransport(
      'SetAVTransportURI',
      DlnaSoapBuilder.buildSetAVTransportURI(
        media.url,
        title: media.title,
        subtitleUrl: subtitleUrl,
      ),
    );

    // Send Play
    await _sendAvTransport('Play', DlnaSoapBuilder.buildPlay());

    stateMachine.transitionTo(SessionState.playing);

    // Start position polling
    _startPolling();
  }

  @override
  Future<void> play() async {
    await _sendAvTransport('Play', DlnaSoapBuilder.buildPlay());
    if (stateMachine.canTransitionTo(SessionState.playing)) {
      stateMachine.transitionTo(SessionState.playing);
    }
  }

  @override
  Future<void> pause() async {
    await _sendAvTransport('Pause', DlnaSoapBuilder.buildPause());
    if (stateMachine.canTransitionTo(SessionState.paused)) {
      stateMachine.transitionTo(SessionState.paused);
    }
  }

  @override
  Future<void> stop() async {
    _stopPolling();
    await _sendAvTransport('Stop', DlnaSoapBuilder.buildStop());
    if (stateMachine.canTransitionTo(SessionState.idle)) {
      stateMachine.transitionTo(SessionState.idle);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await _sendAvTransport('Seek', DlnaSoapBuilder.buildSeek(position));
  }

  @override
  Future<void> setVolume(double volume) async {
    final intVolume = (volume.clamp(0.0, 1.0) * 100).round();
    final controlUrl = description.renderingControlUrl;
    if (controlUrl == null) return;

    await _httpClient.sendAction(
      controlUrl,
      DlnaServiceType.renderingControl,
      'SetVolume',
      DlnaSoapBuilder.buildSetVolume(intVolume),
    );
    updateVolume(volume);
  }

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {
    _currentSubtitle = subtitle;
    final media = _currentMedia;
    if (media == null) return;

    // Re-send SetAVTransportURI with updated subtitle
    await _sendAvTransport(
      'SetAVTransportURI',
      DlnaSoapBuilder.buildSetAVTransportURI(
        media.url,
        title: media.title,
        subtitleUrl: subtitle?.url,
      ),
    );

    // Resume playback
    await _sendAvTransport('Play', DlnaSoapBuilder.buildPlay());
  }

  @override
  Future<void> disconnect() async {
    _stopPolling();

    // Try to stop playback
    try {
      await _sendAvTransport('Stop', DlnaSoapBuilder.buildStop());
    } catch (_) {
      // Device may already be unreachable
    }

    stateMachine.transitionTo(SessionState.disconnected);
  }

  @override
  void dispose() {
    _stopPolling();
    _httpClient.close();
    super.dispose();
  }

  // -- Private helpers --

  Future<String> _sendAvTransport(String action, String body) async {
    final controlUrl = description.avTransportControlUrl;
    if (controlUrl == null) {
      throw StateError('No AVTransport control URL available');
    }

    return _httpClient.sendAction(
      controlUrl,
      DlnaServiceType.avTransport,
      action,
      body,
    );
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _poll() async {
    if (_isPolling) return;
    _isPolling = true;
    try {
      // Get position info
      final positionResponse = await _sendAvTransport(
        'GetPositionInfo',
        DlnaSoapBuilder.buildGetPositionInfo(),
      );
      final posInfo = DlnaSoapParser.parsePositionInfo(positionResponse);
      updatePosition(posInfo.position);
      updateDuration(posInfo.duration);

      // Get transport info for state detection
      final transportResponse = await _sendAvTransport(
        'GetTransportInfo',
        DlnaSoapBuilder.buildGetTransportInfo(),
      );
      final transportState =
          DlnaSoapParser.parseTransportInfo(transportResponse);

      _handleTransportState(transportState);
    } catch (_) {
      // Polling failure — device may be temporarily unreachable
    } finally {
      _isPolling = false;
    }
  }

  void _handleTransportState(String transportState) {
    switch (transportState) {
      case 'PLAYING':
        if (state != SessionState.playing &&
            stateMachine.canTransitionTo(SessionState.playing)) {
          stateMachine.transitionTo(SessionState.playing);
        }
        break;
      case 'PAUSED_PLAYBACK':
        if (state != SessionState.paused &&
            stateMachine.canTransitionTo(SessionState.paused)) {
          stateMachine.transitionTo(SessionState.paused);
        }
        break;
      case 'STOPPED':
        if (state != SessionState.idle &&
            stateMachine.canTransitionTo(SessionState.idle)) {
          stateMachine.transitionTo(SessionState.idle);
          _stopPolling();
        }
        break;
    }
  }
}
