import 'dart:async';

import '../../core/cast_device.dart';
import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import '../../core/media_proxy.dart';
import '../../utils/logger.dart';
import 'dlna_controller.dart';
import 'dlna_device.dart';

/// A DLNA casting session that controls playback on a DLNA renderer.
///
/// Uses SOAP/UPnP to send AVTransport and RenderingControl actions.
class DlnaSession extends CastSession {
  /// The parsed device description with control URLs.
  final DlnaDeviceDescription description;

  final DlnaHttpClient _httpClient;
  final MediaProxy _proxy;
  Timer? _pollTimer;
  bool _isPolling = false;
  CastMedia? _currentMedia;
  CastSubtitle? _currentSubtitle;

  /// Creates a [DlnaSession] for the given [device] and [description].
  ///
  /// An optional [httpClient] can be provided for testing.
  ///
  /// Prefer using [DlnaSession.fromDevice] which automatically extracts
  /// the device description from the metadata set by [DlnaDiscoveryProvider].
  DlnaSession({
    required CastDevice device,
    required this.description,
    DlnaHttpClient? httpClient,
    MediaProxy? proxy,
  })  : _httpClient = httpClient ?? DlnaHttpClient(),
        _proxy = proxy ?? MediaProxy(),
        super(device);

  /// Creates a [DlnaSession] from a [CastDevice] discovered by
  /// [DlnaDiscoveryProvider].
  ///
  /// Automatically extracts the device description (control URLs, etc.)
  /// from the device's metadata. This is the recommended constructor
  /// when using devices from discovery.
  ///
  /// Throws [ArgumentError] if the device metadata is missing required
  /// DLNA control URLs (e.g., if the device was not discovered by
  /// [DlnaDiscoveryProvider]).
  factory DlnaSession.fromDevice(CastDevice device, {DlnaHttpClient? httpClient}) {
    final avTransportUrl = device.metadata['avTransportControlUrl'];
    final renderingControlUrl = device.metadata['renderingControlUrl'];

    if (avTransportUrl == null || avTransportUrl.isEmpty) {
      throw ArgumentError(
        'CastDevice "${device.name}" is missing the DLNA AVTransport control URL '
        'in its metadata. This usually means the device was not discovered by '
        'DlnaDiscoveryProvider, or the device description XML did not contain '
        'an AVTransport service. '
        'Expected metadata key: "avTransportControlUrl". '
        'Available metadata keys: ${device.metadata.keys.toList()}',
      );
    }

    final connectionManagerControlUrl =
        device.metadata['connectionManagerControlUrl'];

    final description = DlnaDeviceDescription(
      friendlyName: device.name,
      udn: device.id,
      manufacturer: device.metadata['manufacturer'],
      modelName: device.metadata['modelName'],
      avTransportControlUrl: avTransportUrl,
      renderingControlUrl: renderingControlUrl,
      connectionManagerControlUrl: connectionManagerControlUrl,
      locationUrl: 'http://${device.address.address}:${device.port}',
    );

    return DlnaSession(
      device: device,
      description: description,
      httpClient: httpClient,
    );
  }

  /// Connects to the DLNA device by verifying it is reachable.
  @override
  Future<void> connect() async {
    CastLogger.info('DlnaSession.connect() called, current state: ${stateMachine.state}');
    stateMachine.transitionTo(SessionState.connecting);
    // For DLNA, "connect" simply means we verified the device is reachable.
    // There is no persistent connection — each action is an HTTP POST.
    stateMachine.transitionTo(SessionState.connected);
    CastLogger.info('DlnaSession.connect() done, state: ${stateMachine.state}');
  }

  @override
  Future<void> loadMedia(CastMedia media) async {
    CastLogger.info('DlnaSession.loadMedia called, current state: ${stateMachine.state}');
    stateMachine.transitionTo(SessionState.loading);
    _currentMedia = media;

    // Start proxy and register media URL with headers
    await _proxy.start();

    // Determine proxy URL and protocolInfo based on media type
    final String proxyUrl;
    final String protocolInfo;

    if (media.type == CastMediaType.hls) {
      // For HLS, serve as continuous MPEG-TS stream for DLNA compatibility
      proxyUrl = _proxy.registerHlsAsStream(
        media.url,
        headers: media.httpHeaders,
      );
      protocolInfo = 'http-get:*:video/mp2t:*';
    } else if (media.type == CastMediaType.mpegTs) {
      proxyUrl = _proxy.registerMedia(
        media.url,
        headers: media.httpHeaders,
      );
      protocolInfo = 'http-get:*:video/mp2t:*';
    } else {
      proxyUrl = _proxy.registerMedia(
        media.url,
        headers: media.httpHeaders,
      );
      protocolInfo = 'http-get:*:video/mp4:*';
    }

    CastLogger.info('DlnaSession: proxy URL = $proxyUrl');

    // Proxy subtitle URLs too if available
    String? subtitleProxyUrl;
    if (media.subtitles.isNotEmpty) {
      subtitleProxyUrl = _proxy.registerMedia(
        media.subtitles.first.url,
        headers: media.httpHeaders,
      );
    } else if (_currentSubtitle != null) {
      subtitleProxyUrl = _proxy.registerMedia(
        _currentSubtitle!.url,
        headers: media.httpHeaders,
      );
    }

    // Send SetAVTransportURI with proxy URL (not original URL)
    await _sendAvTransport(
      'SetAVTransportURI',
      DlnaSoapBuilder.buildSetAVTransportURI(
        proxyUrl,
        title: media.title,
        subtitleUrl: subtitleProxyUrl,
        protocolInfo: protocolInfo,
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

    await _proxy.stop();
    stateMachine.transitionTo(SessionState.disconnected);
  }

  @override
  void dispose() {
    _stopPolling();
    _httpClient.close();
    _proxy.stop();
    super.dispose();
  }

  /// Checks whether the device supports the given [mimeType].
  ///
  /// Queries the ConnectionManager's GetProtocolInfo action and checks
  /// whether the Sink list contains the specified MIME type.
  /// Returns `false` if no ConnectionManager URL is available.
  Future<bool> supportsMediaType(String mimeType) async {
    final controlUrl = description.connectionManagerControlUrl;
    if (controlUrl == null) return false;

    try {
      final response = await _httpClient.sendAction(
        controlUrl,
        DlnaServiceType.connectionManager,
        'GetProtocolInfo',
        DlnaSoapBuilder.buildGetProtocolInfo(),
      );
      final protocols = DlnaSoapParser.parseProtocolInfo(response);
      return protocols.any((p) => p.contains(mimeType));
    } catch (_) {
      return false;
    }
  }

  // -- Private helpers --

  Future<String> _sendAvTransport(String action, String body) async {
    final controlUrl = description.avTransportControlUrl;
    if (controlUrl == null) {
      throw StateError(
        'No AVTransport control URL available for "${device.name}". '
        'Use DlnaSession.fromDevice() to auto-extract URLs from discovery metadata, '
        'or ensure DlnaDeviceDescription has avTransportControlUrl set.',
      );
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
