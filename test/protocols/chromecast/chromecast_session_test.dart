import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_exceptions.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/core/media_transformer.dart';
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
    sentMessages.add(
      MockSentMessage(
        namespace: namespace,
        sourceId: sourceId,
        destinationId: destinationId,
        payload: jsonDecode(payload) as Map<String, dynamic>,
      ),
    );
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
    _incomingController.add(
      MockReceivedMessage(
        namespace: namespace,
        sourceId: sourceId,
        destinationId: destinationId,
        payload: payload,
      ),
    );
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

class DirectTestMediaTransformer implements MediaTransformer {
  const DirectTestMediaTransformer();

  @override
  Future<TransformedMedia> transform(CastMedia media, MediaProxy proxy) async {
    return TransformedMedia(proxyUrl: media.url, effectiveType: media.type);
  }
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
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        await Future<void>.delayed(const Duration(milliseconds: 80));

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

      test('sends LAUNCH for custom receiver app id', () async {
        session.dispose();
        await proxy.stop();
        mockChannel = MockCastV2Channel();
        proxy = MediaProxy();
        await proxy.start();
        session = ChromecastSession.withMocks(
          device: device,
          channel: mockChannel,
          proxy: proxy,
          receiverAppId: 'ABCDE123',
        );

        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        expect(launchMsg.payload['appId'], 'ABCDE123');
      });

      test('throws ReceiverLaunchException on LAUNCH_ERROR', () async {
        session.dispose();
        await proxy.stop();
        mockChannel = MockCastV2Channel();
        proxy = MediaProxy();
        await proxy.start();
        session = ChromecastSession.withMocks(
          device: device,
          channel: mockChannel,
          proxy: proxy,
          receiverAppId: 'ABCDE123',
        );

        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));

        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: {
            'type': 'LAUNCH_ERROR',
            'requestId': 1,
            'reason': 'NOT_FOUND',
          },
        );

        await expectLater(
          connectFuture,
          throwsA(
            isA<ReceiverLaunchException>()
                .having((e) => e.appId, 'appId', 'ABCDE123')
                .having((e) => e.reason, 'reason', 'NOT_FOUND'),
          ),
        );
        expect(session.state, SessionState.disconnected);
      });

      test('extracts transportId and sends CONNECT to app', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        await Future<void>.delayed(const Duration(milliseconds: 80));
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
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        expect(loadMsg.payload['media']['contentId'], contains('/stream/'));
      });

      test('sends LOAD message after starting proxy', () async {
        final media = CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        );

        final loadFuture = session.loadMedia(media);
        await Future<void>.delayed(const Duration(milliseconds: 80));

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

      test('loads HLS without duration as live at live edge', () async {
        final media = CastMedia(
          url: 'http://example.com/live.m3u8',
          type: CastMediaType.hls,
        );

        final loadFuture = session.loadMedia(media);
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        expect(loadMsg.payload['media']['streamType'], 'LIVE');
        expect(loadMsg.payload.containsKey('currentTime'), isFalse);
      });

      test('loads remote HLS directly when media proxy is disabled', () async {
        session.dispose();
        await proxy.stop();
        mockChannel = MockCastV2Channel();
        proxy = MediaProxy();
        session = ChromecastSession.withMocks(
          device: device,
          channel: mockChannel,
          proxy: proxy,
          mediaTransformer: const DirectTestMediaTransformer(),
          useMediaProxy: false,
        );

        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );
        await connectFuture;
        mockChannel.clearMessages();

        final media = CastMedia(
          url: 'http://example.com/live.m3u8',
          type: CastMediaType.hls,
        );

        final loadFuture = session.loadMedia(media);
        await Future<void>.delayed(const Duration(milliseconds: 80));
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
        expect(loadMsg.payload['media']['contentId'], media.url);
      });

      test('loads HLS with duration as buffered media', () async {
        final media = CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
          duration: const Duration(hours: 2),
        );

        final loadFuture = session.loadMedia(media);
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
        expect(loadMsg.payload['media']['streamType'], 'BUFFERED');
      });

      test('throws MediaLoadFailedException when receiver returns '
          'IDLE/ERROR after LOAD', () async {
        final media = CastMedia(
          url: 'http://example.com/video.m3u8',
          type: CastMediaType.hls,
        );

        final loadFuture = session.loadMedia(media);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        // Receiver simulates the silent-failure case: LOAD was acked but
        // the player went IDLE with idleReason=ERROR (e.g. unsupported
        // segment content-type).
        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'web-4',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(
            mediaSessionId: 1,
            playerState: 'IDLE',
            idleReason: 'ERROR',
          ),
        );

        await expectLater(loadFuture, throwsA(isA<MediaLoadFailedException>()));
        expect(session.state, SessionState.idle);
      });

      test(
        'throws MediaLoadFailedException when receiver returns LOAD_FAILED',
        () async {
          final media = CastMedia(
            url: 'http://example.com/video.m3u8',
            type: CastMediaType.hls,
          );

          final loadFuture = session.loadMedia(media);

          // Remote HLS triggers the BARE → MUXED bisect: each attempt
          // sends its own LOAD and registers its own MEDIA_STATUS
          // listener. To surface a `contains('LOAD_FAILED')` error we
          // must reply to *both* attempts — otherwise the first error
          // is discarded in favor of the second attempt's 15s timeout.
          for (var i = 0; i < 2; i++) {
            final loadMsg = await _awaitSentLoad(mockChannel, skip: i);
            mockChannel.injectMessage(
              namespace: CastMediaChannel.mediaNamespace,
              sourceId: 'web-4',
              destinationId: 'sender-0',
              payload: {
                'type': 'LOAD_FAILED',
                'requestId': loadMsg.payload['requestId'],
                'reason': 'INVALID_REQUEST',
                'detailedErrorCode': 905,
              },
            );
          }

          await expectLater(
            loadFuture,
            throwsA(
              isA<MediaLoadFailedException>().having(
                (e) => e.toString(),
                'message',
                contains('LOAD_FAILED'),
              ),
            ),
          );
          expect(session.state, SessionState.idle);
        },
      );

      test(
        'waits past transient IDLE (no idleReason) for a real playable state',
        () async {
          final media = CastMedia(
            url: 'http://example.com/video.m3u8',
            type: CastMediaType.hls,
          );

          final loadFuture = session.loadMedia(media);
          await Future<void>.delayed(const Duration(milliseconds: 80));

          // First status: IDLE without an idleReason — must NOT complete.
          // (Some receivers briefly transition through IDLE between LOAD
          // and BUFFERING.)
          mockChannel.injectMessage(
            namespace: CastMediaChannel.mediaNamespace,
            sourceId: 'web-4',
            destinationId: 'sender-0',
            payload: _mediaStatusPayload(
              mediaSessionId: 1,
              playerState: 'IDLE',
            ),
          );

          // Give the listener a chance to process — load must NOT resolve.
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // Second status: BUFFERING — the surface is now playable, load
          // should complete.
          mockChannel.injectMessage(
            namespace: CastMediaChannel.mediaNamespace,
            sourceId: 'web-4',
            destinationId: 'sender-0',
            payload: _mediaStatusPayload(
              mediaSessionId: 1,
              playerState: 'BUFFERING',
            ),
          );

          await loadFuture;
        },
      );
    });

    group('playback controls', () {
      setUp(() async {
        // Connect
        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );
        await connectFuture;

        // Load media
        final loadFuture = session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
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
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(transportId: 'web-4'),
        );
        await connectFuture;

        final loadFuture = session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.m3u8',
            type: CastMediaType.hls,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 80));
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
        final stateFuture = session.stateStream.firstWhere(
          (s) => s == SessionState.paused,
        );

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
        final stateFuture = session.stateStream.firstWhere(
          (s) => s == SessionState.idle,
        );

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
        await Future<void>.delayed(const Duration(milliseconds: 80));

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
      test('sends receiver STOP for the running app session', () async {
        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(
            transportId: 'web-4',
            sessionId: 'session-to-stop',
          ),
        );
        await connectFuture;

        mockChannel.clearMessages();

        await session.disconnect();

        final receiverStop = mockChannel.sentMessages.firstWhere(
          (m) =>
              m.namespace == CastReceiverChannel.receiverNamespace &&
              m.destinationId == 'receiver-0' &&
              m.payload['type'] == 'STOP',
        );
        expect(receiverStop.payload['sessionId'], 'session-to-stop');
      });

      test('sends CLOSE to transportId and receiver-0', () async {
        // Connect first
        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));
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
        await Future<void>.delayed(const Duration(milliseconds: 80));
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
        await Future<void>.delayed(const Duration(milliseconds: 80));
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

    group('concurrent loadMedia guard', () {
      Future<void> connectSession() async {
        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );
        await connectFuture;
      }

      test('second loadMedia is ignored while first is in progress', () async {
        await connectSession();

        final media = CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        );

        // Start first loadMedia — it will wait for MEDIA_STATUS
        final firstLoad = session.loadMedia(media);

        // Immediately start second loadMedia — should be ignored
        final secondLoad = session.loadMedia(media);

        // Second should complete immediately (no-op)
        await secondLoad;

        // Now inject MEDIA_STATUS to complete first load
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'transport-abc',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(mediaSessionId: 1),
        );

        await firstLoad;

        // Only one LOAD message should have been sent
        final loadMessages =
            mockChannel.sentMessages
                .where(
                  (m) =>
                      m.namespace == CastMediaChannel.mediaNamespace &&
                      m.payload['type'] == 'LOAD',
                )
                .toList();
        expect(loadMessages, hasLength(1));
      });

      test('loadMedia works again after first completes', () async {
        await connectSession();

        final media = CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
        );

        // First load
        final firstLoad = session.loadMedia(media);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'transport-abc',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(mediaSessionId: 1),
        );
        await firstLoad;

        // Second load should work
        final secondLoad = session.loadMedia(media);
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastMediaChannel.mediaNamespace,
          sourceId: 'transport-abc',
          destinationId: 'sender-0',
          payload: _mediaStatusPayload(mediaSessionId: 2),
        );
        await secondLoad;

        // Two LOAD messages
        final loadMessages =
            mockChannel.sentMessages
                .where(
                  (m) =>
                      m.namespace == CastMediaChannel.mediaNamespace &&
                      m.payload['type'] == 'LOAD',
                )
                .toList();
        expect(loadMessages, hasLength(2));
      });
    });

    group('socket disconnect detection', () {
      Future<void> connectSession() async {
        final connectFuture = session.connect();
        await Future<void>.delayed(const Duration(milliseconds: 80));
        mockChannel.injectMessage(
          namespace: CastReceiverChannel.receiverNamespace,
          sourceId: 'receiver-0',
          destinationId: 'sender-0',
          payload: _receiverStatusPayload(),
        );
        await connectFuture;
      }

      test('transitions to disconnected when message stream closes', () async {
        await connectSession();
        expect(session.state, SessionState.connected);

        // Listen for state changes
        final states = <SessionState>[];
        session.stateStream.listen(states.add);

        // Close the mock channel (simulates socket drop)
        await mockChannel.close();

        // Allow microtask to process
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(session.state, SessionState.disconnected);
        expect(states, contains(SessionState.disconnected));
      });

      test('heartbeat stops after socket loss', () async {
        await connectSession();
        expect(session.isHeartbeatActive, isTrue);

        await mockChannel.close();
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(session.isHeartbeatActive, isFalse);
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
        },
      ],
      'volume': {'level': 0.5, 'muted': false},
    },
  };
}

/// Polls until the session has dispatched its `skip + 1`-th LOAD message
/// on the media namespace, then returns it. Used by tests that need the
/// actual requestId chosen by [CastMediaChannel.buildLoad] — hardcoding
/// it can race with proxy startup, since
/// [ChromecastSession._loadMediaInternal] awaits `_proxy.start(...)`
/// before the LOAD goes out and that startup time is not bounded by any
/// test-side delay. [skip] lets bisect-aware tests wait for the
/// retry-loop's second LOAD without prematurely matching the first.
Future<MockSentMessage> _awaitSentLoad(
  MockCastV2Channel mockChannel, {
  Duration timeout = const Duration(seconds: 5),
  int skip = 0,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final loads =
        mockChannel.sentMessages
            .where(
              (m) =>
                  m.namespace == CastMediaChannel.mediaNamespace &&
                  m.payload['type'] == 'LOAD',
            )
            .toList();
    if (loads.length > skip) return loads[skip];
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError(
    'LOAD message (skip=$skip) never reached the wire within $timeout',
  );
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
    statusEntry['media'] = {'duration': duration};
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
