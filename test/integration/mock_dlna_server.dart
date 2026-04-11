import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/src/protocols/dlna/dlna_controller.dart';

/// A mock DLNA device for integration testing.
///
/// Listens on UDP for SSDP M-SEARCH, serves device description XML over HTTP,
/// and accepts SOAP actions on AVTransport and RenderingControl control URLs.
/// Tracks playback state, position, and volume internally.
class MockDlnaServer {
  HttpServer? _httpServer;
  RawDatagramSocket? _ssdpSocket;

  /// The port the HTTP server is listening on.
  int get httpPort => _httpServer!.port;

  /// Base URL for the HTTP server.
  String get baseUrl => 'http://127.0.0.1:$httpPort';

  /// AVTransport control URL.
  String get avTransportUrl => '$baseUrl/AVTransport/control';

  /// RenderingControl control URL.
  String get renderingControlUrl => '$baseUrl/RenderingControl/control';

  /// Device description URL.
  String get descriptionUrl => '$baseUrl/description.xml';

  /// The friendly name of the mock device.
  final String friendlyName;

  /// The UDN of the mock device.
  final String udn;

  // -- Playback state --

  /// Current transport state: STOPPED, PLAYING, PAUSED_PLAYBACK.
  String transportState = 'STOPPED';

  /// Current playback position in seconds.
  double positionSeconds = 0.0;

  /// Total duration of the media in seconds.
  double durationSeconds = 0.0;

  /// Current volume (0-100).
  int volume = 50;

  /// Captured SOAP actions for verification.
  final List<CapturedSoapAction> capturedActions = [];

  /// Creates a mock DLNA server with the given device identity.
  MockDlnaServer({
    this.friendlyName = 'Mock DLNA TV',
    this.udn = 'uuid:mock-dlna-device-001',
  });

  /// Starts the HTTP server and optionally the SSDP responder.
  ///
  /// If [enableSsdp] is true, listens on the SSDP multicast port for
  /// M-SEARCH queries and responds with a LOCATION header pointing to the
  /// device description URL.
  Future<void> start({bool enableSsdp = false}) async {
    _httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _httpServer!.listen(_handleHttpRequest);

    if (enableSsdp) {
      await _startSsdpResponder();
    }
  }

  /// Stops the mock server.
  Future<void> stop() async {
    _ssdpSocket?.close();
    _ssdpSocket = null;
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  /// Clears all captured actions.
  void clearCapturedActions() => capturedActions.clear();

  /// Returns a device description XML string for this mock device.
  String get deviceDescriptionXml => '''<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>$friendlyName</friendlyName>
    <manufacturer>MockCorp</manufacturer>
    <modelName>MockRenderer</modelName>
    <UDN>$udn</UDN>
    <serviceList>
      <service>
        <serviceType>${DlnaServiceType.avTransport}</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/AVTransport/control</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>${DlnaServiceType.renderingControl}</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/RenderingControl/control</controlURL>
        <eventSubURL>/RenderingControl/event</eventSubURL>
        <SCPDURL>/RenderingControl/scpd.xml</SCPDURL>
      </service>
    </serviceList>
  </device>
</root>''';

  // -- Private --

  Future<void> _startSsdpResponder() async {
    try {
      _ssdpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );

      _ssdpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _ssdpSocket!.receive();
          if (datagram == null) return;

          final message = utf8.decode(datagram.data);
          if (message.contains('M-SEARCH') &&
              message.contains('ssdp:discover')) {
            final response =
                'HTTP/1.1 200 OK\r\n'
                'CACHE-CONTROL: max-age=1800\r\n'
                'LOCATION: $descriptionUrl\r\n'
                'SERVER: Mock/1.0 UPnP/1.0 MockDLNA/1.0\r\n'
                'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
                'USN: $udn::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
                '\r\n';
            _ssdpSocket!.send(
              utf8.encode(response),
              datagram.address,
              datagram.port,
            );
          }
        }
      });
    } catch (_) {
      // SSDP binding may fail in test environments; that is acceptable.
    }
  }

  Future<void> _handleHttpRequest(HttpRequest request) async {
    final path = request.uri.path;

    if (path == '/description.xml' && request.method == 'GET') {
      request.response.headers.contentType = ContentType('text', 'xml');
      request.response.write(deviceDescriptionXml);
      await request.response.close();
      return;
    }

    if (path == '/AVTransport/control' || path == '/RenderingControl/control') {
      await _handleSoapRequest(request);
      return;
    }

    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _handleSoapRequest(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final soapAction = request.headers.value('SOAPAction') ?? '';

    final actionMatch = RegExp(r'#(\w+)"').firstMatch(soapAction);
    final action = actionMatch?.group(1) ?? 'Unknown';

    capturedActions.add(CapturedSoapAction(action: action, body: body));

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
      case 'Play':
        transportState = 'PLAYING';
        request.response.write(
          _soapResponse('PlayResponse', DlnaServiceType.avTransport, ''),
        );
      case 'Pause':
        transportState = 'PAUSED_PLAYBACK';
        request.response.write(
          _soapResponse('PauseResponse', DlnaServiceType.avTransport, ''),
        );
      case 'Stop':
        transportState = 'STOPPED';
        positionSeconds = 0.0;
        request.response.write(
          _soapResponse('StopResponse', DlnaServiceType.avTransport, ''),
        );
      case 'Seek':
        // Parse the target time from the body
        final targetMatch = RegExp(
          r'<Target>(\d{2}):(\d{2}):(\d{2})</Target>',
        ).firstMatch(body);
        if (targetMatch != null) {
          final h = int.parse(targetMatch.group(1)!);
          final m = int.parse(targetMatch.group(2)!);
          final s = int.parse(targetMatch.group(3)!);
          positionSeconds = (h * 3600 + m * 60 + s).toDouble();
        }
        request.response.write(
          _soapResponse('SeekResponse', DlnaServiceType.avTransport, ''),
        );
      case 'GetPositionInfo':
        request.response.write(
          _soapResponse(
            'GetPositionInfoResponse',
            DlnaServiceType.avTransport,
            '<Track>1</Track>'
                '<TrackDuration>${_formatTime(durationSeconds)}</TrackDuration>'
                '<RelTime>${_formatTime(positionSeconds)}</RelTime>',
          ),
        );
      case 'GetTransportInfo':
        request.response.write(
          _soapResponse(
            'GetTransportInfoResponse',
            DlnaServiceType.avTransport,
            '<CurrentTransportState>$transportState</CurrentTransportState>'
                '<CurrentTransportStatus>OK</CurrentTransportStatus>'
                '<CurrentSpeed>1</CurrentSpeed>',
          ),
        );
      case 'SetVolume':
        final volMatch = RegExp(
          r'<DesiredVolume>(\d+)</DesiredVolume>',
        ).firstMatch(body);
        if (volMatch != null) {
          volume = int.parse(volMatch.group(1)!);
        }
        request.response.write(
          _soapResponse(
            'SetVolumeResponse',
            DlnaServiceType.renderingControl,
            '',
          ),
        );
      case 'GetVolume':
        request.response.write(
          _soapResponse(
            'GetVolumeResponse',
            DlnaServiceType.renderingControl,
            '<CurrentVolume>$volume</CurrentVolume>',
          ),
        );
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

  String _formatTime(double seconds) {
    final totalSeconds = seconds.round();
    final h = (totalSeconds ~/ 3600).toString().padLeft(2, '0');
    final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
    final s = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

/// A captured SOAP action with its XML body.
class CapturedSoapAction {
  /// The action name extracted from the SOAPAction header.
  final String action;

  /// The raw XML body of the request.
  final String body;

  CapturedSoapAction({required this.action, required this.body});

  @override
  String toString() => 'CapturedSoapAction($action)';
}
