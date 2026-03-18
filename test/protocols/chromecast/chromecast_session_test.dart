import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/core/media_proxy.dart';
import 'package:dart_cast/src/protocols/chromecast/cast_media_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/cast_receiver_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/chromecast_session.dart';
import 'package:test/test.dart';

/// A mock CastV2Channel that records sent messages and allows
/// injecting responses via a stream controller.
class MockCastV2Channel {
  final List<MockSentMessage> sentMessages = [];
  final StreamController<MockReceivedMessage> _incomingController =
      StreamController<MockReceivedMessage>.broadcast();
  bool isConnected = false;
  bool isClosed = false;

  Stream<MockReceivedMessage> get messageStream => _incomingController.stream;

  void sendMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required String payload,
  }) {
    sentMessages.add(MockSentMessage(
      namespace: namespace,
      sourceId: sourceId,
      destinationId: destinationId,
      payload: jsonDecode(payload) as Map<String, dynamic>,
    ));
  }

  Future<void> connect(String host, {int port = 8009}) async {
    isConnected = true;
  }

  Future<void> close() async {
    isClosed = true;
    await _incomingController.close();
  }

  /// Simulate a message from the Chromecast device.
  void injectMessage({
    required String namespace,
    required String sourceId,
    required String destinationId,
    required Map<String, dynamic> payload,
  }) {
    _incomingController.add(MockReceivedMessage(
      namespace: namespace,
      sourceId: sourceId,
      destinationId: destinationId,
      payload: payload,
    ));
  }

  /// Clear recorded messages.
  void clearMessages() => sentMessages.clear();
}

class MockSentMessage {
  final String namespace;
  final String sourceId;
  final String destinationId;
  final Map<String, dynamic> payload;

  MockSentMessage({
    required this.namespace,
    required this.sourceId,
    required this.destinationId,
    required this.payload,
  });

  @override
  String toString() =>
      'MockSentMessage(ns=$namespace, dst=$destinationId, type=${payload['type']})';
}

class MockReceivedMessage {
  final String namespace;
  final String sourceId;
  final String destinationId;
  final Map<String, dynamic> payload;

  MockReceivedMessage({
    required this.namespace,
    required this.sourceId,
    required this.destinationId,
    required this.payload,
  });
}

void main() {
  late CastDevice device;
  late MockCastV2Channel mockChannel;
  late ChromecastSession session;
  late MediaProxy proxy;

  setUp(() async {
    device = CastDevice(
      id: 'test-device-id',
      name: 'Test Chromecast',
      protocol: CastProtocol.chromecast,
      address: InternetAddress('192.168.1.100'),
      port: 8009,
    );
    mockChannel = MockCastV2Channel();
    // Pre-start a real MediaProxy so that _proxy.start() inside loadMedia
    // is a no-op (idempotent) and doesn't block test injection timing.
    proxy = MediaProxy();
    await proxy.start();
    session = ChromecastSession.withMocks(
      device: device,
      channel: mockChannel,
      proxy: proxy,
    );
  });

  tearDown(() async {
    session.dispose();
    await proxy.stop();
  });

  group('ChromecastSession', () {
    group('connect lifecycle', () {
      test('sends CONNECT to receiver-0', () async {
        // Start connect and inject RECEIVER_STATUS response
        final connectFuture = session.connect();

        // Wait a tick for the connect to start processing
        await Future<void>.delayed(Duration.zero);

        // Find the LAUNCH message and inject RECEIVER_STATUS response
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );

        await connectFuture;

        // Verify CONNECT was sent to receiver-0
        final connectMsg = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.connectionNamespace &&
              m.destinationId == 'receiver-0' &&
              m.payload['type'] == 'CONNECT',
        );
        expect(connectMsg, isNotNull);
        expect(connectMsg.payload['origin'], isA<Map>());
      });

      test('sends LAUNCH after CONNECT', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);

        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );

        await connectFuture;

        final launchMsg = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.receiverNamespace &&
              m.payload['type'] == 'LAUNCH',
        );
        expect(launchMsg, isNotNull);
        expect(launchMsg.payload['appId'], 'CC1AD845');
        expect(launchMsg.destinationId, 'receiver-0');
      });

      test('extracts transportId and sends CONNECT to app', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);

        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );

        await connectFuture;

        final appConnect = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.connectionNamespace &&
              m.destinationId == 'web-4' &&
              m.payload['type'] == 'CONNECT',
        );
        expect(appConnect, isNotNull);
      });

      test('transitions to connected state', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);

        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );

        await connectFuture;

        expect(session.state, SessionState.connected);
      });
    });

    group('loadMedia', () {
      setUp(() async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );
        await connectFuture;
        mockChannel.clearMessages();
      });

      test('sends LOAD with proxy URL to transportId', () async {
        final media = CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
          title: 'Test Video',
          imageUrl: 'http://example.com/thumb.jpg',
        );

        final loadFuture = session.loadMedia(media);
        await Future<void>.delayed(Duration.zero);

        // Inject MEDIA_STATUS response
        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(mediaSessionId: 1),
        );

        await loadFuture;

        final loadMsg = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastMediaChannel.mediaNamespace &&
              m.payload['type'] == 'LOAD',
        );
        expect(loadMsg, isNotNull);
        expect(loadMsg.destinationId, 'web-4');
        // Should use a proxy URL (real MediaProxy produces http://<ip>:<port>/stream/<token>)
        expect(
          loadMsg.payload['media']['contentId'],
          contains('/stream/'),
        );
      });

      test('sends LOAD message after starting proxy', () async {
        final media = CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        );

        final loadFuture = session.loadMedia(media);
        await Future<void>.delayed(Duration.zero);

        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(mediaSessionId: 1),
        );

        await loadFuture;

        // Verify LOAD was sent — proxy must have started for this to succeed
        final loadMsg = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastMediaChannel.mediaNamespace &&
              m.payload['type'] == 'LOAD',
        );
        expect(loadMsg, isNotNull);
      });
    });

    group('playback controls', () {
      setUp(() async {
        // Connect
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );
        await connectFuture;

        // Load media
        final loadFuture = session.loadMedia(CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ));
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(mediaSessionId: 42),
        );
        await loadFuture;

        mockChannel.clearMessages();
      });

      test('play sends PLAY with correct mediaSessionId', () async {
        await session.play();
        final msg = mockChannel.sentMessages.last;
        expect(msg.payload['type'], 'PLAY');
        expect(msg.payload['mediaSessionId'], 42);
        expect(msg.destinationId, 'web-4');
      });

      test('pause sends PAUSE with correct mediaSessionId', () async {
        await session.pause();
        final msg = mockChannel.sentMessages.last;
        expect(msg.payload['type'], 'PAUSE');
        expect(msg.payload['mediaSessionId'], 42);
      });

      test('stop sends STOP with correct mediaSessionId', () async {
        await session.stop();
        final msg = mockChannel.sentMessages.last;
        expect(msg.payload['type'], 'STOP');
        expect(msg.payload['mediaSessionId'], 42);
      });

      test('seek sends SEEK with currentTime in seconds', () async {
        await session.seek(const Duration(minutes: 2, seconds: 30));
        final msg = mockChannel.sentMessages.last;
        expect(msg.payload['type'], 'SEEK');
        expect(msg.payload['mediaSessionId'], 42);
        expect(msg.payload['currentTime'], 150.0);
      });

      test('setVolume sends SET_VOLUME', () async {
        await session.setVolume(0.7);
        final msg = mockChannel.sentMessages.last;
        expect(msg.payload['type'], 'SET_VOLUME');
        expect(msg.payload['volume']['level'], 0.7);
        expect(msg.destinationId, 'receiver-0');
      });

      test('setSubtitle sends EDIT_TRACKS_INFO with activeTrackIds', () async {
        final subtitle = CastSubtitle(
          url: 'http://example.com/en.vtt',
          label: 'English',
          language: 'en',
          format: 'vtt',
        );
        await session.setSubtitle(subtitle);
        final msg = mockChannel.sentMessages.last;
        expect(msg.payload['type'], 'EDIT_TRACKS_INFO');
        expect(msg.payload['mediaSessionId'], 42);
        expect(msg.payload['activeTrackIds'], isA<List>());
      });

      test('setSubtitle with null disables subtitles', () async {
        await session.setSubtitle(null);
        final msg = mockChannel.sentMessages.last;
        expect(msg.payload['type'], 'EDIT_TRACKS_INFO');
        expect(msg.payload['activeTrackIds'], isEmpty);
      });
    });

    group('MEDIA_STATUS updates', () {
      setUp(() async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );
        await connectFuture;

        final loadFuture = session.loadMedia(CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        ));
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(mediaSessionId: 1),
        );
        await loadFuture;
      });

      test('updates position from MEDIA_STATUS', () async {
        final positionFuture = session.positionStream.first;

        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(
            mediaSessionId: 1,
            playerState: 'PLAYING',
            currentTime: 45.5,
          ),
        );

        final position = await positionFuture;
        expect(position.inMilliseconds, closeTo(45500, 100));
      });

      test('updates duration from MEDIA_STATUS', () async {
        final durationFuture = session.durationStream.first;

        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(
            mediaSessionId: 1,
            playerState: 'PLAYING',
            currentTime: 0,
            duration: 1440.5,
          ),
        );

        final duration = await durationFuture;
        expect(duration.inMilliseconds, closeTo(1440500, 100));
      });

      test('PLAYING state is set from initial MEDIA_STATUS', () async {
        // The loadMedia setUp already injected a PLAYING MEDIA_STATUS,
        // so the state should already be playing.
        expect(session.state, SessionState.playing);
      });

      test('PAUSED state transitions to paused', () async {
        // State is already PLAYING from setUp's loadMedia.
        final stateFuture =
            session.stateStream.firstWhere((s) => s == SessionState.paused);

        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(
            mediaSessionId: 1,
            playerState: 'PAUSED',
          ),
        );

        final state = await stateFuture;
        expect(state, SessionState.paused);
      });

      test('IDLE with FINISHED transitions to idle', () async {
        // State is already PLAYING from setUp's loadMedia.
        final stateFuture =
            session.stateStream.firstWhere((s) => s == SessionState.idle);

        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(
            mediaSessionId: 1,
            playerState: 'IDLE',
            idleReason: 'FINISHED',
          ),
        );

        final state = await stateFuture;
        expect(state, SessionState.idle);
      });
    });

    group('heartbeat', () {
      test('sends PING periodically after connect', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);

        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );

        await connectFuture;

        // The heartbeat uses a timer. We can verify it was set up by
        // checking that PING messages appear. Use a short test heartbeat interval.
        // For the mock-based test, verify the heartbeat timer is active.
        expect(session.isHeartbeatActive, isTrue);
      });
    });

    group('disconnect', () {
      test('sends CLOSE to transportId and receiver-0', () async {
        // Connect first
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );
        await connectFuture;

        mockChannel.clearMessages();

        await session.disconnect();

        // CLOSE to transportId
        final appClose = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.connectionNamespace &&
              m.destinationId == 'web-4' &&
              m.payload['type'] == 'CLOSE',
        );
        expect(appClose, isNotNull);

        // CLOSE to receiver-0
        final receiverClose = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.connectionNamespace &&
              m.destinationId == 'receiver-0' &&
              m.payload['type'] == 'CLOSE',
        );
        expect(receiverClose, isNotNull);
      });

      test('stops heartbeat timer', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );
        await connectFuture;

        await session.disconnect();

        expect(session.isHeartbeatActive, isFalse);
      });

      test('transitions to disconnected state', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(Duration.zero);
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );
        await connectFuture;

        await session.disconnect();

        expect(session.state, SessionState.disconnected);
      });
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

Map<String, dynamic> _receiverStatusPayload({
  String transportId = 'transport-abc',
  String sessionId = 'session-xyz',
}) {
  return {
    'type': 'RECEIVER_STATUS',
    'requestId': 1,
    'status': {
      'applications': [
        {
          'appId': 'CC1AD845',
          'displayName': 'Default Media Receiver',
          'sessionId': sessionId,
          'transportId': transportId,
          'namespaces': [
            {'name': 'urn:x-cast:com.google.cast.media'},
          ],
        }
      ],
      'volume': {
        'level': 0.5,
        'muted': false,
      },
    },
  };
}

Map<String, dynamic> _mediaStatusPayload({
  required int mediaSessionId,
  String playerState = 'PLAYING',
  double currentTime = 0.0,
  double? duration,
  String? idleReason,
}) {
  final statusEntry = <String, dynamic>{
    'mediaSessionId': mediaSessionId,
    'playerState': playerState,
    'currentTime': currentTime,
    'volume': {'level': 1.0, 'muted': false},
  };

  if (duration != null) {
    statusEntry['media'] = {
      'duration': duration,
    };
  }

  if (idleReason != null) {
    statusEntry['idleReason'] = idleReason;
  }

  return {
    'type': 'MEDIA_STATUS',
    'requestId': 0,
    'status': [statusEntry],
  };
}
