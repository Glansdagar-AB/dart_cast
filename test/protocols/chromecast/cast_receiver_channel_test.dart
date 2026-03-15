import 'dart:convert';

import 'package:dart_cast/src/protocols/chromecast/cast_receiver_channel.dart';
import 'package:test/test.dart';

void main() {
  group('CastReceiverChannel', () {
    group('constants', () {
      test('connectionNamespace is correct', () {
        expect(
          CastReceiverChannel.connectionNamespace,
          'urn:x-cast:com.google.cast.tp.connection',
        );
      });

      test('heartbeatNamespace is correct', () {
        expect(
          CastReceiverChannel.heartbeatNamespace,
          'urn:x-cast:com.google.cast.tp.heartbeat',
        );
      });

      test('receiverNamespace is correct', () {
        expect(
          CastReceiverChannel.receiverNamespace,
          'urn:x-cast:com.google.cast.receiver',
        );
      });

      test('defaultMediaReceiverAppId is CC1AD845', () {
        expect(CastReceiverChannel.defaultMediaReceiverAppId, 'CC1AD845');
      });
    });

    group('buildConnect', () {
      test('produces correct JSON with type and origin', () {
        final json = CastReceiverChannel.buildConnect();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'CONNECT');
        expect(decoded['origin'], isA<Map>());
        expect((decoded['origin'] as Map).isEmpty, isTrue);
      });
    });

    group('buildClose', () {
      test('produces correct JSON with type CLOSE', () {
        final json = CastReceiverChannel.buildClose();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'CLOSE');
      });
    });

    group('buildPing', () {
      test('produces correct JSON with type PING', () {
        final json = CastReceiverChannel.buildPing();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'PING');
      });
    });

    group('buildLaunch', () {
      test('produces correct JSON with appId', () {
        final json = CastReceiverChannel.buildLaunch('CC1AD845');
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'LAUNCH');
        expect(decoded['appId'], 'CC1AD845');
        expect(decoded['requestId'], isA<int>());
      });

      test('uses default appId when not specified', () {
        final json = CastReceiverChannel.buildLaunch();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['appId'], 'CC1AD845');
      });

      test('requestId auto-increments', () {
        final channel = CastReceiverChannel();
        final json1 = channel.buildLaunchWithId('CC1AD845');
        final json2 = channel.buildLaunchWithId('CC1AD845');
        final decoded1 = jsonDecode(json1) as Map<String, dynamic>;
        final decoded2 = jsonDecode(json2) as Map<String, dynamic>;
        expect(decoded2['requestId'], decoded1['requestId'] + 1);
      });
    });

    group('buildGetStatus', () {
      test('produces correct JSON with type GET_STATUS', () {
        final json = CastReceiverChannel.buildGetStatus();
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'GET_STATUS');
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildStop', () {
      test('produces correct JSON with sessionId', () {
        final json = CastReceiverChannel.buildStop('session-123');
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'STOP');
        expect(decoded['sessionId'], 'session-123');
        expect(decoded['requestId'], isA<int>());
      });
    });

    group('buildSetVolume', () {
      test('produces correct JSON with volume level and muted', () {
        final json =
            CastReceiverChannel.buildSetVolume(level: 0.5, muted: false);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['type'], 'SET_VOLUME');
        expect(decoded['volume']['level'], 0.5);
        expect(decoded['volume']['muted'], false);
        expect(decoded['requestId'], isA<int>());
      });

      test('allows setting only level', () {
        final json = CastReceiverChannel.buildSetVolume(level: 0.8);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['volume']['level'], 0.8);
      });

      test('allows setting only muted', () {
        final json = CastReceiverChannel.buildSetVolume(muted: true);
        final decoded = jsonDecode(json) as Map<String, dynamic>;
        expect(decoded['volume']['muted'], true);
      });
    });

    group('parseReceiverStatus', () {
      test('extracts transportId, sessionId, appId, and volume', () {
        final payload = {
          'type': 'RECEIVER_STATUS',
          'requestId': 1,
          'status': {
            'applications': [
              {
                'appId': 'CC1AD845',
                'displayName': 'Default Media Receiver',
                'sessionId': 'abc-123',
                'transportId': 'transport-456',
              }
            ],
            'volume': {
              'level': 0.48,
              'muted': false,
            },
          },
        };

        final status = CastReceiverChannel.parseReceiverStatus(payload);
        expect(status, isNotNull);
        expect(status!.transportId, 'transport-456');
        expect(status.sessionId, 'abc-123');
        expect(status.appId, 'CC1AD845');
        expect(status.volumeLevel, closeTo(0.48, 0.001));
        expect(status.isMuted, false);
      });

      test('returns null when no applications present', () {
        final payload = {
          'type': 'RECEIVER_STATUS',
          'status': {
            'applications': [],
            'volume': {'level': 0.5, 'muted': false},
          },
        };

        final status = CastReceiverChannel.parseReceiverStatus(payload);
        expect(status, isNull);
      });

      test('returns null when status is missing', () {
        final payload = {'type': 'RECEIVER_STATUS'};
        final status = CastReceiverChannel.parseReceiverStatus(payload);
        expect(status, isNull);
      });
    });

    group('isPong', () {
      test('returns true for PONG message', () {
        expect(
          CastReceiverChannel.isPong({'type': 'PONG'}),
          isTrue,
        );
      });

      test('returns false for non-PONG message', () {
        expect(
          CastReceiverChannel.isPong({'type': 'PING'}),
          isFalse,
        );
      });

      test('returns false for message without type', () {
        expect(
          CastReceiverChannel.isPong({'data': 'test'}),
          isFalse,
        );
      });
    });
  });
}
