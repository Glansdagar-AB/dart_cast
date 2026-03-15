import 'package:dart_cast/src/protocols/dlna/ssdp_discovery.dart';
import 'package:test/test.dart';

void main() {
  group('SsdpMessage', () {
    group('mSearch', () {
      test('formats a valid M-SEARCH request', () {
        final result = SsdpMessage.mSearch(
          'urn:schemas-upnp-org:device:MediaRenderer:1',
          3,
        );

        expect(result, contains('M-SEARCH * HTTP/1.1\r\n'));
        expect(result, contains('HOST: 239.255.255.250:1900\r\n'));
        expect(result, contains('MAN: "ssdp:discover"\r\n'));
        expect(
          result,
          contains(
            'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n',
          ),
        );
        expect(result, contains('MX: 3\r\n'));
        expect(result, endsWith('\r\n\r\n'));
      });

      test('uses custom MX value', () {
        final result = SsdpMessage.mSearch('ssdp:all', 5);
        expect(result, contains('MX: 5\r\n'));
        expect(result, contains('ST: ssdp:all\r\n'));
      });
    });

    group('parseResponse', () {
      test('parses SSDP 200 OK response extracting LOCATION', () {
        const data = 'HTTP/1.1 200 OK\r\n'
            'CACHE-CONTROL: max-age=1800\r\n'
            'LOCATION: http://192.168.1.50:49152/description.xml\r\n'
            'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
            'USN: uuid:12345678-1234-1234-1234-123456789abc::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
            '\r\n';

        final response = SsdpMessage.parseResponse(data);

        expect(
          response.location,
          equals('http://192.168.1.50:49152/description.xml'),
        );
        expect(
          response.st,
          equals('urn:schemas-upnp-org:device:MediaRenderer:1'),
        );
        expect(
          response.usn,
          equals(
            'uuid:12345678-1234-1234-1234-123456789abc::urn:schemas-upnp-org:device:MediaRenderer:1',
          ),
        );
      });

      test('parses NOTIFY message extracting LOCATION', () {
        const data = 'NOTIFY * HTTP/1.1\r\n'
            'HOST: 239.255.255.250:1900\r\n'
            'CACHE-CONTROL: max-age=1800\r\n'
            'LOCATION: http://192.168.1.50:49152/description.xml\r\n'
            'NT: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
            'NTS: ssdp:alive\r\n'
            'USN: uuid:abcdef00-0000-0000-0000-000000000000::urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
            '\r\n';

        final response = SsdpMessage.parseResponse(data);

        expect(
          response.location,
          equals('http://192.168.1.50:49152/description.xml'),
        );
        expect(response.headers['nts'], equals('ssdp:alive'));
      });

      test('returns null location for invalid response', () {
        const data = 'INVALID DATA WITHOUT HEADERS\r\n\r\n';

        final response = SsdpMessage.parseResponse(data);

        expect(response.location, isNull);
        expect(response.usn, isNull);
        expect(response.st, isNull);
      });

      test('handles case-insensitive headers', () {
        const data = 'HTTP/1.1 200 OK\r\n'
            'location: http://10.0.0.1:8080/desc.xml\r\n'
            'usn: uuid:test-uuid\r\n'
            'st: ssdp:all\r\n'
            '\r\n';

        final response = SsdpMessage.parseResponse(data);

        expect(response.location, equals('http://10.0.0.1:8080/desc.xml'));
        expect(response.usn, equals('uuid:test-uuid'));
        expect(response.st, equals('ssdp:all'));
      });
    });

    group('extractUuid', () {
      test('extracts UUID from composite USN', () {
        const usn =
            'uuid:12345678-1234-1234-1234-123456789abc::urn:schemas-upnp-org:device:MediaRenderer:1';

        final uuid = SsdpMessage.extractUuid(usn);

        expect(uuid, equals('uuid:12345678-1234-1234-1234-123456789abc'));
      });

      test('returns full string when USN is just a UUID', () {
        const usn = 'uuid:simple-uuid-value';

        final uuid = SsdpMessage.extractUuid(usn);

        expect(uuid, equals('uuid:simple-uuid-value'));
      });

      test('returns null for null USN', () {
        expect(SsdpMessage.extractUuid(null), isNull);
      });
    });
  });

  group('SsdpResponse', () {
    test('stores all fields correctly', () {
      final response = SsdpResponse(
        location: 'http://192.168.1.1:1234/desc.xml',
        usn: 'uuid:test',
        st: 'ssdp:all',
        headers: {'cache-control': 'max-age=1800'},
      );

      expect(response.location, equals('http://192.168.1.1:1234/desc.xml'));
      expect(response.usn, equals('uuid:test'));
      expect(response.st, equals('ssdp:all'));
      expect(response.headers['cache-control'], equals('max-age=1800'));
    });
  });

  group('SSDP Constants', () {
    test('multicast address is correct', () {
      expect(SsdpConstants.multicastAddress, equals('239.255.255.250'));
    });

    test('multicast port is correct', () {
      expect(SsdpConstants.multicastPort, equals(1900));
    });

    test('search targets list is non-empty', () {
      expect(SsdpConstants.searchTargets, isNotEmpty);
      expect(
        SsdpConstants.searchTargets,
        contains('urn:schemas-upnp-org:device:MediaRenderer:1'),
      );
    });
  });
}
