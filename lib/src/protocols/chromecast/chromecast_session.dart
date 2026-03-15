/// ChromecastSession — full lifecycle management for Chromecast casting.
///
/// Extends [CastSession] to manage TLS connection, receiver/media channels,
/// heartbeat keep-alive, media proxy, and playback state synchronisation.
library;

import 'dart:async';
import 'dart:convert';

import '../../core/cast_device.dart';
import '../../core/cast_media.dart';
import '../../core/cast_session.dart';
import '../../core/media_proxy.dart';
import 'cast_media_channel.dart';
import 'cast_receiver_channel.dart';
import 'castv2_channel.dart';
import 'proto/cast_channel.dart';

/// A casting session with a Chromecast device.
///
/// Manages the full lifecycle: TLS connect, receiver LAUNCH, heartbeat,
/// media LOAD/PLAY/PAUSE/STOP/SEEK, and graceful disconnect.
class ChromecastSession extends CastSession {
  /// The sender ID used in all messages.
  static const _senderId = 'sender-0';

  /// The platform receiver destination ID.
  static const _receiverId = 'receiver-0';

  // ---------------------------------------------------------------------------
  // Dependencies (injectable for testing)
  // ---------------------------------------------------------------------------

  final _ChannelAdapter _channel;
  final _ProxyAdapter _proxy;

  // ---------------------------------------------------------------------------
  // Session state
  // ---------------------------------------------------------------------------

  final CastReceiverChannel _receiverChannel = CastReceiverChannel();
  final CastMediaChannel _mediaChannel = CastMediaChannel();

  String? _transportId;
  String? _sessionId; // Used for STOP app via receiver namespace.
  int? _mediaSessionId;
  StreamSubscription<dynamic>? _mediaStatusSubscription;

  /// The current receiver session ID, if connected.
  String? get sessionId => _sessionId;
  Timer? _heartbeatTimer;
  StreamSubscription<dynamic>? _messageSubscription;

  /// Whether the heartbeat timer is currently active.
  bool get isHeartbeatActive => _heartbeatTimer?.isActive ?? false;

  // ---------------------------------------------------------------------------
  // Constructors
  // ---------------------------------------------------------------------------

  /// Creates a [ChromecastSession] for the given [device].
  ChromecastSession({required CastDevice device})
      : _channel = _RealChannelAdapter(),
        _proxy = _RealProxyAdapter(),
        super(device);

  /// Creates a [ChromecastSession] with mock dependencies for testing.
  ChromecastSession.withMocks({
    required CastDevice device,
    required dynamic channel,
    required dynamic proxy,
  })  : _channel = _MockChannelAdapter(channel),
        _proxy = _MockProxyAdapter(proxy),
        super(device);

  // ---------------------------------------------------------------------------
  // Connect lifecycle
  // ---------------------------------------------------------------------------

  /// Connects to the Chromecast device and launches the Default Media Receiver.
  ///
  /// Sequence: TLS connect -> CONNECT to receiver-0 -> start heartbeat ->
  /// LAUNCH CC1AD845 -> wait for RECEIVER_STATUS -> extract transportId ->
  /// CONNECT to transportId.
  @override
  Future<void> connect() async {
    stateMachine.transitionTo(SessionState.connecting);

    // 1. TLS connect
    await _channel.connect(device.address.address, port: device.port);

    // 2. Start listening for messages
    final completer = Completer<void>();
    _messageSubscription = _channel.messageStream.listen((msg) {
      _handleMessage(msg, completer);
    });

    // 3. CONNECT to receiver-0
    _channel.sendMessage(
      namespace: CastReceiverChannel.connectionNamespace,
      sourceId: _senderId,
      destinationId: _receiverId,
      payload: CastReceiverChannel.buildConnect(),
    );

    // 4. Start heartbeat
    _startHeartbeat();

    // 5. LAUNCH Default Media Receiver
    _channel.sendMessage(
      namespace: CastReceiverChannel.receiverNamespace,
      sourceId: _senderId,
      destinationId: _receiverId,
      payload: _receiverChannel.buildLaunchWithId(),
    );

    // 6. Wait for RECEIVER_STATUS with transportId
    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        stateMachine.transitionTo(SessionState.disconnected);
        throw TimeoutException('Chromecast connect timed out after 15 seconds');
      },
    );

    // 7. CONNECT to app transportId
    _channel.sendMessage(
      namespace: CastReceiverChannel.connectionNamespace,
      sourceId: _senderId,
      destinationId: _transportId!,
      payload: CastReceiverChannel.buildConnect(),
    );

    stateMachine.transitionTo(SessionState.connected);
  }

  // ---------------------------------------------------------------------------
  // Media loading
  // ---------------------------------------------------------------------------

  @override
  Future<void> loadMedia(CastMedia media) async {
    if (_transportId == null) {
      throw StateError('Not connected. Call connect() first.');
    }

    stateMachine.transitionTo(SessionState.loading);

    // Start proxy and register new media BEFORE cleanup to avoid race condition
    // where the cast device requests the old URL during the gap.
    await _proxy.start();
    final proxyUrl = _proxy.registerMedia(
      media.url,
      headers: media.httpHeaders,
    );
    // Extract token from the proxy URL to exclude it from cleanup
    final newToken = Uri.parse(proxyUrl).pathSegments.last;
    _proxy.cleanupPreviousMedia(excludeToken: newToken);

    // Determine content type
    final contentType = _contentTypeForMedia(media.type);

    // Build subtitle tracks
    final subtitles = media.subtitles
        .asMap()
        .entries
        .map((e) => CastMediaTrack(
              trackId: e.key + 1,
              url: e.value.url,
              name: e.value.label,
              language: e.value.language,
            ))
        .toList();

    // Send LOAD
    final loadPayload = _mediaChannel.buildLoad(
      contentId: proxyUrl,
      contentType: contentType,
      title: media.title,
      imageUrl: media.imageUrl,
      startPosition: media.startPosition != null
          ? media.startPosition!.inMilliseconds / 1000.0
          : null,
      subtitles: subtitles.isNotEmpty ? subtitles : null,
    );

    final completer = Completer<void>();
    _waitForMediaStatus(completer);

    _channel.sendMessage(
      namespace: CastMediaChannel.mediaNamespace,
      sourceId: _senderId,
      destinationId: _transportId!,
      payload: loadPayload,
    );

    await completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _mediaStatusSubscription?.cancel();
        _mediaStatusSubscription = null;
        stateMachine.transitionTo(SessionState.idle);
        throw TimeoutException(
            'Chromecast loadMedia timed out after 15 seconds');
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Playback controls
  // ---------------------------------------------------------------------------

  @override
  Future<void> play() async {
    _requireMediaSession();
    _sendMediaCommand(_mediaChannel.buildPlay(_mediaSessionId!));
  }

  @override
  Future<void> pause() async {
    _requireMediaSession();
    _sendMediaCommand(_mediaChannel.buildPause(_mediaSessionId!));
  }

  @override
  Future<void> stop() async {
    _requireMediaSession();
    _sendMediaCommand(_mediaChannel.buildStop(_mediaSessionId!));
  }

  @override
  Future<void> seek(Duration position) async {
    _requireMediaSession();
    final seconds = position.inMilliseconds / 1000.0;
    _sendMediaCommand(_mediaChannel.buildSeek(_mediaSessionId!, seconds));
  }

  @override
  Future<void> setVolume(double volume) async {
    _requireMediaSession();
    // Device-level volume uses receiver namespace to receiver-0
    _channel.sendMessage(
      namespace: CastReceiverChannel.receiverNamespace,
      sourceId: _senderId,
      destinationId: _receiverId,
      payload: _receiverChannel.buildSetVolumeWithId(level: volume),
    );
  }

  @override
  Future<void> setSubtitle(CastSubtitle? subtitle) async {
    _requireMediaSession();
    if (subtitle == null) {
      _sendMediaCommand(
          _mediaChannel.buildEditTracksInfo(_mediaSessionId!, []));
    } else {
      // Activate track ID 1 (conventionally the first subtitle track)
      _sendMediaCommand(
          _mediaChannel.buildEditTracksInfo(_mediaSessionId!, [1]));
    }
  }

  // ---------------------------------------------------------------------------
  // Disconnect
  // ---------------------------------------------------------------------------

  @override
  Future<void> disconnect() async {
    _stopHeartbeat();
    _mediaStatusSubscription?.cancel();
    _mediaStatusSubscription = null;

    // CLOSE to app transportId
    if (_transportId != null) {
      _channel.sendMessage(
        namespace: CastReceiverChannel.connectionNamespace,
        sourceId: _senderId,
        destinationId: _transportId!,
        payload: CastReceiverChannel.buildClose(),
      );
    }

    // CLOSE to receiver-0
    _channel.sendMessage(
      namespace: CastReceiverChannel.connectionNamespace,
      sourceId: _senderId,
      destinationId: _receiverId,
      payload: CastReceiverChannel.buildClose(),
    );

    await _messageSubscription?.cancel();
    _messageSubscription = null;
    await _channel.close();

    _transportId = null;
    _sessionId = null;
    _mediaSessionId = null;

    await _proxy.stop();

    stateMachine.transitionTo(SessionState.disconnected);
  }

  @override
  void dispose() {
    _stopHeartbeat();
    _mediaStatusSubscription?.cancel();
    _proxy.stop();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  void _requireMediaSession() {
    if (_mediaSessionId == null) {
      throw StateError('No active media session. Call loadMedia() first.');
    }
  }

  void _sendMediaCommand(String payload) {
    _channel.sendMessage(
      namespace: CastMediaChannel.mediaNamespace,
      sourceId: _senderId,
      destinationId: _transportId!,
      payload: payload,
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) {
        _channel.sendMessage(
          namespace: CastReceiverChannel.heartbeatNamespace,
          sourceId: _senderId,
          destinationId: _receiverId,
          payload: CastReceiverChannel.buildPing(),
        );
      },
    );
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _handleMessage(dynamic msg, Completer<void> connectCompleter) {
    final namespace = _getNamespace(msg);
    final payload = _getPayload(msg);
    if (payload == null) return;

    // Handle RECEIVER_STATUS during connect
    if (namespace == CastReceiverChannel.receiverNamespace &&
        payload['type'] == 'RECEIVER_STATUS' &&
        !connectCompleter.isCompleted) {
      final status = CastReceiverChannel.parseReceiverStatus(payload);
      if (status != null) {
        _transportId = status.transportId;
        _sessionId = status.sessionId;
        connectCompleter.complete();
      }
    }

    // Handle MEDIA_STATUS
    if (namespace == CastMediaChannel.mediaNamespace &&
        payload['type'] == 'MEDIA_STATUS') {
      _handleMediaStatus(payload);
    }
  }

  void _handleMediaStatus(Map<String, dynamic> payload) {
    final status = CastMediaChannel.parseMediaStatus(payload);
    if (status == null) return;

    _mediaSessionId = status.mediaSessionId;

    // Update position
    updatePosition(Duration(
      milliseconds: (status.currentTime * 1000).round(),
    ));

    // Update duration
    if (status.duration != null) {
      updateDuration(Duration(
        milliseconds: (status.duration! * 1000).round(),
      ));
    }

    // Update state machine based on playerState
    _updateState(status.playerState, status.idleReason);
  }

  void _updateState(String playerState, String? idleReason) {
    final targetState = switch (playerState) {
      'PLAYING' => SessionState.playing,
      'PAUSED' => SessionState.paused,
      'BUFFERING' => SessionState.buffering,
      'IDLE' => SessionState.idle,
      'LOADING' => SessionState.loading,
      _ => null,
    };

    if (targetState != null && stateMachine.canTransitionTo(targetState)) {
      stateMachine.transitionTo(targetState);
    }
  }

  void _waitForMediaStatus(Completer<void> completer) {
    // Cancel any previous media status subscription to prevent leaks
    _mediaStatusSubscription?.cancel();

    // Listen for the next MEDIA_STATUS that sets _mediaSessionId
    _mediaStatusSubscription = _channel.messageStream.listen((msg) {
      final namespace = _getNamespace(msg);
      final payload = _getPayload(msg);
      if (namespace == CastMediaChannel.mediaNamespace &&
          payload != null &&
          payload['type'] == 'MEDIA_STATUS') {
        _handleMediaStatus(payload);
        if (!completer.isCompleted) {
          completer.complete();
        }
        _mediaStatusSubscription?.cancel();
        _mediaStatusSubscription = null;
      }
    });
  }

  String? _getNamespace(dynamic msg) {
    if (msg is CastMessage) return msg.namespace_;
    // Mock message
    if (msg is Map) return msg['namespace'] as String?;
    // Dynamic mock object
    try {
      return (msg as dynamic).namespace as String?;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _getPayload(dynamic msg) {
    if (msg is CastMessage) {
      try {
        return jsonDecode(msg.payloadUtf8) as Map<String, dynamic>;
      } catch (_) {
        return null;
      }
    }
    // Mock message
    if (msg is Map) return msg['payload'] as Map<String, dynamic>?;
    // Dynamic mock object
    try {
      return (msg as dynamic).payload as Map<String, dynamic>?;
    } catch (_) {
      return null;
    }
  }

  static String _contentTypeForMedia(CastMediaType type) {
    return switch (type) {
      CastMediaType.hls => 'application/x-mpegURL',
      CastMediaType.mp4 => 'video/mp4',
      CastMediaType.mpegTs => 'video/mp2t',
    };
  }
}

// ---------------------------------------------------------------------------
// Adapter interfaces for testability
// ---------------------------------------------------------------------------

/// Adapter over CastV2Channel or a mock.
abstract class _ChannelAdapter {
  Future<void> connect(String host, {int port});
  Stream<dynamic> get messageStream;
  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  });
  Future<void> close();
}

/// Adapter over MediaProxy or a mock.
abstract class _ProxyAdapter {
  Future<void> start();
  Future<void> stop();
  String registerMedia(String url, {Map<String, String> headers});
  void cleanupPreviousMedia({String? excludeToken});
}

// ---------------------------------------------------------------------------
// Real adapters (wrap actual implementations)
// ---------------------------------------------------------------------------

class _RealChannelAdapter implements _ChannelAdapter {
  final CastV2Channel _channel = CastV2Channel();

  @override
  Future<void> connect(String host, {int port = 8009}) =>
      _channel.connect(host, port: port);

  @override
  Stream<CastMessage> get messageStream => _channel.messageStream;

  @override
  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  }) {
    _channel.sendMessage(
      namespace: namespace,
      sourceId: sourceId,
      destinationId: destinationId,
      payload: payload,
    );
  }

  @override
  Future<void> close() => _channel.close();
}

class _RealProxyAdapter implements _ProxyAdapter {
  final MediaProxy _proxy = MediaProxy();

  @override
  Future<void> start() => _proxy.start();

  @override
  Future<void> stop() => _proxy.stop();

  @override
  String registerMedia(String url, {Map<String, String> headers = const {}}) =>
      _proxy.registerMedia(url, headers: headers);

  @override
  void cleanupPreviousMedia({String? excludeToken}) =>
      _proxy.cleanupPreviousMedia(excludeToken: excludeToken);
}

// ---------------------------------------------------------------------------
// Mock adapters (wrap test doubles)
// ---------------------------------------------------------------------------

class _MockChannelAdapter implements _ChannelAdapter {
  final dynamic _mock;

  _MockChannelAdapter(this._mock);

  @override
  Future<void> connect(String host, {int port = 8009}) =>
      (_mock as dynamic).connect(host, port: port) as Future<void>;

  @override
  Stream<dynamic> get messageStream =>
      (_mock as dynamic).messageStream as Stream<dynamic>;

  @override
  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  }) {
    (_mock as dynamic).sendMessage(
      namespace: namespace,
      sourceId: sourceId,
      destinationId: destinationId,
      payload: payload,
    );
  }

  @override
  Future<void> close() => (_mock as dynamic).close() as Future<void>;
}

class _MockProxyAdapter implements _ProxyAdapter {
  final dynamic _mock;

  _MockProxyAdapter(this._mock);

  @override
  Future<void> start() => (_mock as dynamic).start() as Future<void>;

  @override
  Future<void> stop() => (_mock as dynamic).stop() as Future<void>;

  @override
  String registerMedia(String url, {Map<String, String> headers = const {}}) =>
      (_mock as dynamic).registerMedia(url, headers: headers) as String;

  @override
  void cleanupPreviousMedia({String? excludeToken}) =>
      (_mock as dynamic).cleanupPreviousMedia(excludeToken: excludeToken);
}
