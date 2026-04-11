import 'package:dart_cast/src/core/cast_device.dart';
import 'package:dart_cast/src/protocols/dlna/dlna_device.dart';
import 'package:test/test.dart';

void main() {
  const sampleXml = '''<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion>
    <major>1</major>
    <minor>0</minor>
  </specVersion>
  <URLBase>http://192.168.1.50:49152</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Living Room TV</friendlyName>
    <manufacturer>Samsung</manufacturer>
    <modelName>UE55</modelName>
    <UDN>uuid:12345678-1234-1234-1234-123456789abc</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <SCPDURL>/AVTransport/scpd.xml</SCPDURL>
        <controlURL>/AVTransport/control</controlURL>
        <eventSubURL>/AVTransport/event</eventSubURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <SCPDURL>/RenderingControl/scpd.xml</SCPDURL>
        <controlURL>/RenderingControl/control</controlURL>
        <eventSubURL>/RenderingControl/event</eventSubURL>
      </service>
    </serviceList>
  </device>
</root>''';

  const sampleXmlNoUrlBase = '''<?xml version="1.0" encoding="utf-8"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>Kitchen Speaker</friendlyName>
    <manufacturer>Sonos</manufacturer>
    <modelName>One</modelName>
    <UDN>uuid:aabbccdd-0000-1111-2222-334455667788</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/MediaRenderer/AVTransport/control</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/MediaRenderer/RenderingControl/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

  group('DlnaDeviceDescription', () {
    group('parse', () {
      test('parses friendly name, manufacturer, and UDN', () {
        final desc = DlnaDeviceDescription.parse(
          sampleXml,
          'http://192.168.1.50:49152/description.xml',
        );

        expect(desc.friendlyName, equals('Living Room TV'));
        expect(desc.manufacturer, equals('Samsung'));
        expect(desc.modelName, equals('UE55'));
        expect(desc.udn, equals('uuid:12345678-1234-1234-1234-123456789abc'));
      });

      test('extracts AVTransport control URL (absolute)', () {
        final desc = DlnaDeviceDescription.parse(
          sampleXml,
          'http://192.168.1.50:49152/description.xml',
        );

        expect(
          desc.avTransportControlUrl,
          equals('http://192.168.1.50:49152/AVTransport/control'),
        );
      });

      test('extracts RenderingControl control URL (absolute)', () {
        final desc = DlnaDeviceDescription.parse(
          sampleXml,
          'http://192.168.1.50:49152/description.xml',
        );

        expect(
          desc.renderingControlUrl,
          equals('http://192.168.1.50:49152/RenderingControl/control'),
        );
      });

      test('falls back to location URL when URLBase is absent', () {
        final desc = DlnaDeviceDescription.parse(
          sampleXmlNoUrlBase,
          'http://10.0.0.5:8080/device/description.xml',
        );

        expect(
          desc.avTransportControlUrl,
          equals('http://10.0.0.5:8080/MediaRenderer/AVTransport/control'),
        );
        expect(
          desc.renderingControlUrl,
          equals('http://10.0.0.5:8080/MediaRenderer/RenderingControl/control'),
        );
      });

      test('handles already-absolute control URLs', () {
        const xml = '''<?xml version="1.0"?>
<root>
  <device>
    <friendlyName>Test Device</friendlyName>
    <manufacturer>Test</manufacturer>
    <modelName>T1</modelName>
    <UDN>uuid:test-abs-url</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>http://10.0.0.1:9000/avt/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';

        final desc = DlnaDeviceDescription.parse(
          xml,
          'http://10.0.0.1:8080/desc.xml',
        );

        expect(
          desc.avTransportControlUrl,
          equals('http://10.0.0.1:9000/avt/control'),
        );
      });
    });

    group('toCastDevice', () {
      test('creates CastDevice with correct fields', () {
        final desc = DlnaDeviceDescription.parse(
          sampleXml,
          'http://192.168.1.50:49152/description.xml',
        );

        final device = desc.toCastDevice();

        expect(device.name, equals('Living Room TV'));
        expect(device.protocol, equals(CastProtocol.dlna));
        expect(device.address.address, equals('192.168.1.50'));
        expect(device.port, equals(49152));
        expect(device.id, equals('uuid:12345678-1234-1234-1234-123456789abc'));
        expect(
          device.metadata['avTransportControlUrl'],
          equals('http://192.168.1.50:49152/AVTransport/control'),
        );
        expect(
          device.metadata['renderingControlUrl'],
          equals('http://192.168.1.50:49152/RenderingControl/control'),
        );
        expect(device.metadata['manufacturer'], equals('Samsung'));
        expect(device.metadata['modelName'], equals('UE55'));
      });
    });
  });
}
