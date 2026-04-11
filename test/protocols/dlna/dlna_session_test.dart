import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/core/cast_media.dart';
import 'package:dart_cast/src/core/cast_session.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_controller.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_device.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_session.dart';
import 'package:test/test.dart';

/// Mock DLNA device HTTP server that captures SOAP requests and returns
/// appropriate responses.
class MockDlnaServer {
  late HttpServer _server;
  String get baseUrl => 'http://127.0.0.1:${_server.port}';
  String get avTransportUrl => '$baseUrl/AVTransport/control';
  String get renderingControlUrl => '$baseUrl/RenderingControl/control';
  String get connectionManagerUrl => '$baseUrl/ConnectionManager/control';

  /// Supported protocol info entries for GetProtocolInfo Sink response.
  /// Set this to control what supportsMediaType() will see.
  List<String> supportedProtocols = [];

  final List<_CapturedSoapAction> capturedActions = [];

  String _transportState = 'STOPPED';
  String _relTime = '00:00:00';
  String _trackDuration = '00:00:00';
  int _volume = 50;

  set transportState(String value) => _transportState = value;
  set relTime(String value) => _relTime = value;
  set trackDuration(String value) => _trackDuration = value;
  set volume(int value) => _volume = value;

  Future<void> start() async {
    _server = await HttpServer.bind('127.0.0.1', 0);
    _server.listen(_handleRequest);
  }

  Future<void> stop() async {
    await _server.close(force: true);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final soapAction = request.headers.value('SOAPAction') ?? '';

    // Extract action name from SOAPAction header
    final actionMatch = RegExp(r'#(\w+)"').firstMatch(soapAction);
    final action = actionMatch?.group(1) ?? 'Unknown';

    capturedActions.add(_CapturedSoapAction(action: action, body: body));

    request.response.headers.contentType = ContentType('text', 'xml');

    switch (action) {
      case 'SetAVTransportURI':
        request.response.write(
          _soapResponse(
            'SetAVTransportURIResponse',
            DlnaServiceType.avTransport,
            '',
          ),
        );
        break;
      case 'Play':
        _transportState = 'PLAYING';
        request.response.write(
          _soapResponse('PlayResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'Pause':
        _transportState = 'PAUSED_PLAYBACK';
        request.response.write(
          _soapResponse('PauseResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'Stop':
        _transportState = 'STOPPED';
        request.response.write(
          _soapResponse('StopResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'Seek':
        request.response.write(
          _soapResponse('SeekResponse', DlnaServiceType.avTransport, ''),
        );
        break;
      case 'GetPositionInfo':
        request.response.write(
          _soapResponse(
            'GetPositionInfoResponse',
            DlnaServiceType.avTransport,
            '<Track>1</Track>'
                '<TrackDuration>$_trackDuration</TrackDuration>'
                '<RelTime>$_relTime</RelTime>',
          ),
        );
        break;
      case 'GetTransportInfo':
        request.response.write(
          _soapResponse(
            'GetTransportInfoResponse',
            DlnaServiceType.avTransport,
            '<CurrentTransportState>$_transportState</CurrentTransportState>'
                '<CurrentTransportStatus>OK</CurrentTransportStatus>'
                '<CurrentSpeed>1</CurrentSpeed>',
          ),
        );
        break;
      case 'SetVolume':
        request.response.write(
          _soapResponse(
            'SetVolumeResponse',
            DlnaServiceType.renderingControl,
            '',
          ),
        );
        break;
      case 'GetVolume':
        request.response.write(
          _soapResponse(
            'GetVolumeResponse',
            DlnaServiceType.renderingControl,
            '<CurrentVolume>$_volume</CurrentVolume>',
          ),
        );
        break;
      case 'GetProtocolInfo':
        final sink = supportedProtocols.join(',');
        request.response.write(
          _soapResponse(
            'GetProtocolInfoResponse',
            DlnaServiceType.connectionManager,
            '<Source></Source><Sink>$sink</Sink>',
          ),
        );
        break;
      default:
        request.response.statusCode = 500;
        request.response.write('Unknown action: $action');
    }

    await request.response.close();
  }

  String _soapResponse(String action, String serviceType, String body) {
    return '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"'
        ' s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="$serviceType">'
        '$body'
        '</u:$action>'
        '</s:Body>'
        '</s:Envelope>';
  }
}

class _CapturedSoapAction {
  final String action;
  final String body;

  _CapturedSoapAction({required this.action, required this.body});
}

void main() {
  late MockDlnaServer mockServer;
  late CastDevice device;
  late DlnaDeviceDescription description;
  late DlnaSession session;

  setUp(() async {
    mockServer = MockDlnaServer();
    await mockServer.start();

    device = CastDevice(
      id: 'uuid:test-device',
      name: 'Test TV',
      protocol: CastProtocol.dlna,
      address: InternetAddress('127.0.0.1'),
      port: 8080,
    );

    description = DlnaDeviceDescription(
      friendlyName: 'Test TV',
      udn: 'uuid:test-device',
      avTransportControlUrl: mockServer.avTransportUrl,
      renderingControlUrl: mockServer.renderingControlUrl,
      locationUrl: mockServer.baseUrl,
    );

    session = DlnaSession(device: device, description: description);
  });

  tearDown(() async {
    session.dispose();
    await mockServer.stop();
  });

  group('DlnaSession', () {
    group('connect', () {
      test('transitions to connected state', () async {
        await session.connect();
        expect(session.state, equals(SessionState.connected));
      });
    });

    group('loadMedia', () {
      test('calls SetAVTransportURI then Play', () async {
        await session.connect();

        final media = CastMedia(
          url: 'http://example.com/video.mp4',
          type: CastMediaType.mp4,
          title: 'Test Video',
        );

        mockServer.transportState = 'PLAYING';
        mockServer.trackDuration = '01:30:00';

        await session.loadMedia(media);

        // Verify SetAVTransportURI was called
        final setUriActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetAVTransportURI')
                .toList();
        expect(setUriActions, hasLength(1));

        // Verify Play was called after SetAVTransportURI
        final playActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Play')
                .toList();
        expect(playActions, hasLength(1));

        // SetAVTransportURI should come before Play
        final setUriIndex = mockServer.capturedActions.indexWhere(
          (a) => a.action == 'SetAVTransportURI',
        );
        final playIndex = mockServer.capturedActions.indexWhere(
          (a) => a.action == 'Play',
        );
        expect(setUriIndex, lessThan(playIndex));
      });

      test('transitions through loading to playing', () async {
        await session.connect();

        final states = <SessionState>[];
        session.stateStream.listen(states.add);

        mockServer.transportState = 'PLAYING';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Should have gone through loading state
        expect(states, contains(SessionState.loading));
      });
    });

    group('play', () {
      test('calls Play SOAP action', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();

        // Simulate paused state first
        session.stateMachine.forceState(SessionState.paused);
        await session.play();

        final playActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Play')
                .toList();
        expect(playActions, hasLength(1));
      });
    });

    group('pause', () {
      test('calls Pause SOAP action', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.pause();

        final pauseActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Pause')
                .toList();
        expect(pauseActions, hasLength(1));
      });
    });

    group('stop', () {
      test('calls Stop SOAP action', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.stop();

        final stopActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Stop')
                .toList();
        expect(stopActions, hasLength(1));
      });

      test('transitions to idle state', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        await session.stop();

        expect(session.state, equals(SessionState.idle));
      });
    });

    group('seek', () {
      test('converts Duration to HH:MM:SS and calls Seek', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.seek(const Duration(hours: 1, minutes: 23, seconds: 45));

        final seekActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Seek')
                .toList();
        expect(seekActions, hasLength(1));
        expect(seekActions.first.body, contains('01:23:45'));
      });
    });

    group('setVolume', () {
      test('normalizes 0.0-1.0 to 0-100 and calls SetVolume', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.setVolume(0.75);

        final volumeActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetVolume')
                .toList();
        expect(volumeActions, hasLength(1));
        expect(
          volumeActions.first.body,
          contains('<DesiredVolume>75</DesiredVolume>'),
        );
      });

      test('handles volume 0.0', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.setVolume(0.0);

        final volumeActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetVolume')
                .toList();
        expect(
          volumeActions.first.body,
          contains('<DesiredVolume>0</DesiredVolume>'),
        );
      });

      test('handles volume 1.0', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.setVolume(1.0);

        final volumeActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetVolume')
                .toList();
        expect(
          volumeActions.first.body,
          contains('<DesiredVolume>100</DesiredVolume>'),
        );
      });
    });

    group('position polling', () {
      test('emits position updates on positionStream', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        mockServer.relTime = '00:05:30';
        mockServer.trackDuration = '01:00:00';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Wait for at least one poll
        final position = await session.positionStream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(position, isA<Duration>());
      });

      test('emits duration updates on durationStream', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        mockServer.relTime = '00:05:30';
        mockServer.trackDuration = '01:00:00';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Wait for at least one poll
        final duration = await session.durationStream.first.timeout(
          const Duration(seconds: 5),
        );

        expect(duration, isA<Duration>());
      });
    });

    group('state transitions', () {
      test('playing to paused', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Should be in playing state
        expect(session.state, equals(SessionState.playing));

        mockServer.transportState = 'PAUSED_PLAYBACK';
        await session.pause();

        expect(session.state, equals(SessionState.paused));
      });

      test('paused to playing', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Pause first
        mockServer.transportState = 'PAUSED_PLAYBACK';
        await session.pause();
        expect(session.state, equals(SessionState.paused));

        // Resume
        mockServer.transportState = 'PLAYING';
        await session.play();
        expect(session.state, equals(SessionState.playing));
      });
    });

    group('disconnect', () {
      test('sends Stop and transitions to disconnected', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        mockServer.capturedActions.clear();
        await session.disconnect();

        // Should have sent Stop
        final stopActions =
            mockServer.capturedActions
                .where((a) => a.action == 'Stop')
                .toList();
        expect(stopActions, hasLength(1));

        expect(session.state, equals(SessionState.disconnected));
      });

      test('stops position polling', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        mockServer.relTime = '00:05:30';
        mockServer.trackDuration = '01:00:00';

        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
          ),
        );

        // Wait for polling to start
        await session.positionStream.first.timeout(const Duration(seconds: 5));

        await session.disconnect();

        // Record actions after disconnect
        mockServer.capturedActions.clear();

        // Wait a bit to confirm no more polling
        await Future.delayed(const Duration(seconds: 2));

        // Should not have any GetPositionInfo after disconnect
        final positionPolls =
            mockServer.capturedActions
                .where((a) => a.action == 'GetPositionInfo')
                .toList();
        expect(positionPolls, isEmpty);
      });
    });

    group('setSubtitle', () {
      test('re-loads media with subtitle in DIDL-Lite', () async {
        await session.connect();

        mockServer.transportState = 'PLAYING';
        await session.loadMedia(
          CastMedia(
            url: 'http://example.com/video.mp4',
            type: CastMediaType.mp4,
            title: 'Test Video',
          ),
        );

        mockServer.capturedActions.clear();

        await session.setSubtitle(
          const CastSubtitle(
            url: 'http://example.com/subs.srt',
            label: 'English',
            language: 'en',
            format: 'srt',
          ),
        );

        // Should have called SetAVTransportURI again with proxied subtitle
        final setUriActions =
            mockServer.capturedActions
                .where((a) => a.action == 'SetAVTransportURI')
                .toList();
        expect(setUriActions, hasLength(1));
        // Subtitle URL should be proxied (not raw), so it should contain /stream/
        expect(setUriActions.first.body, contains('/stream/'));
        // Raw subtitle URL should NOT appear (it's proxied)
        expect(setUriActions.first.body, isNot(contains('subs.srt')));
      });
    });
  });

  group('DlnaSession.fromDevice()', () {
    test('creates session from device with valid metadata', () {
      final device = CastDevice(
        id: 'uuid:test',
        name: 'My TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.100'),
        port: 49152,
        metadata: {
          'avTransportControlUrl':
              'http://192.168.1.100:49152/AVTransport/control',
          'renderingControlUrl':
              'http://192.168.1.100:49152/RenderingControl/control',
          'manufacturer': 'Samsung',
          'modelName': 'UE55',
        },
      );

      final session = DlnaSession.fromDevice(device);
      expect(session.device.name, 'My TV');
      expect(
        session.description.avTransportControlUrl,
        'http://192.168.1.100:49152/AVTransport/control',
      );
      expect(
        session.description.renderingControlUrl,
        'http://192.168.1.100:49152/RenderingControl/control',
      );
      expect(session.description.manufacturer, 'Samsung');
    });

    test('throws ArgumentError when avTransportControlUrl is missing', () {
      final device = CastDevice(
        id: 'uuid:test',
        name: 'My TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.100'),
        port: 49152,
        metadata: {
          'renderingControlUrl':
              'http://192.168.1.100:49152/RenderingControl/control',
        },
      );

      expect(
        () => DlnaSession.fromDevice(device),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('missing the DLNA AVTransport control URL'),
          ),
        ),
      );
    });

    test('throws ArgumentError with available metadata keys listed', () {
      final device = CastDevice(
        id: 'uuid:test',
        name: 'My TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('192.168.1.100'),
        port: 49152,
        metadata: {'someOtherKey': 'value'},
      );

      expect(
        () => DlnaSession.fromDevice(device),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('someOtherKey'),
          ),
        ),
      );
    });

    test('loadMedia uses proxy URL not raw URL', () async {
      final mockServer = MockDlnaServer();
      await mockServer.start();

      final device = CastDevice(
        id: 'uuid:proxy-test',
        name: 'Proxy TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
        metadata: {
          'avTransportControlUrl': mockServer.avTransportUrl,
          'renderingControlUrl': mockServer.renderingControlUrl,
        },
      );

      final session = DlnaSession.fromDevice(device);
      mockServer.transportState = 'PLAYING';
      await session.connect();
      await session.loadMedia(
        const CastMedia(
          url: 'https://secret-cdn.example.com/video.m3u8',
          type: CastMediaType.hls,
          httpHeaders: {'Referer': 'https://megacloud.blog/'},
        ),
      );

      final setUri = mockServer.capturedActions.firstWhere(
        (a) => a.action == 'SetAVTransportURI',
      );
      // Should contain proxy URL, NOT the raw CDN URL
      expect(setUri.body, isNot(contains('secret-cdn.example.com')));
      expect(setUri.body, contains('/ts-stream/')); // HLS uses ts-stream route

      await session.disconnect();
      session.dispose();
      await mockServer.stop();
    });
  });

  group('supportsMediaType', () {
    test('returns false when connectionManagerControlUrl is null', () async {
      final mockServer = MockDlnaServer();
      await mockServer.start();

      final device = CastDevice(
        id: 'uuid:no-cm',
        name: 'No CM TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'No CM TV',
        udn: 'uuid:no-cm',
        avTransportControlUrl: mockServer.avTransportUrl,
        renderingControlUrl: mockServer.renderingControlUrl,
        connectionManagerControlUrl: null,
        locationUrl: mockServer.baseUrl,
      );

      final session = DlnaSession(device: device, description: description);

      final result = await session.supportsMediaType('video/mp4');
      expect(result, isFalse);

      session.dispose();
      await mockServer.stop();
    });

    test('returns true when Sink contains the queried MIME type', () async {
      final mockServer = MockDlnaServer();
      await mockServer.start();
      mockServer.supportedProtocols = [
        'http-get:*:video/mp4:*',
        'http-get:*:video/mp2t:*',
        'http-get:*:audio/mpeg:*',
      ];

      final device = CastDevice(
        id: 'uuid:cm-test',
        name: 'CM TV',
        protocol: CastProtocol.dlna,
        address: InternetAddress('127.0.0.1'),
        port: 8080,
      );

      final description = DlnaDeviceDescription(
        friendlyName: 'CM TV',
        udn: 'uuid:cm-test',
        avTransportControlUrl: mockServer.avTransportUrl,
        renderingControlUrl: mockServer.renderingControlUrl,
        connectionManagerControlUrl: mockServer.connectionManagerUrl,
        locationUrl: mockServer.baseUrl,
      );

      final session = DlnaSession(device: device, description: description);

      final result = await session.supportsMediaType('video/mp4');
      expect(result, isTrue);

      session.dispose();
      await mockServer.stop();
    });

    test(
      'returns false when Sink does not contain the queried MIME type',
      () async {
        final mockServer = MockDlnaServer();
        await mockServer.start();
        mockServer.supportedProtocols = [
          'http-get:*:video/mp4:*',
          'http-get:*:audio/mpeg:*',
        ];

        final device = CastDevice(
          id: 'uuid:cm-test2',
          name: 'CM TV 2',
          protocol: CastProtocol.dlna,
          address: InternetAddress('127.0.0.1'),
          port: 8080,
        );

        final description = DlnaDeviceDescription(
          friendlyName: 'CM TV 2',
          udn: 'uuid:cm-test2',
          avTransportControlUrl: mockServer.avTransportUrl,
          renderingControlUrl: mockServer.renderingControlUrl,
          connectionManagerControlUrl: mockServer.connectionManagerUrl,
          locationUrl: mockServer.baseUrl,
        );

        final session = DlnaSession(device: device, description: description);

        final result = await session.supportsMediaType('video/webm');
        expect(result, isFalse);

        session.dispose();
        await mockServer.stop();
      },
    );
  });
}
