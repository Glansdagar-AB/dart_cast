import 'package:test/test.dart';
import 'package:dart_cast/dart_cast.dart';

void main() {
  group('CastException hierarchy', () {
    test('CastException has message', () {
      final e = CastException('something failed');
      expect(e.message, 'something failed');
      expect(e.cause, isNull);
      expect(e.toString(), contains('something failed'));
    });

    test('CastException with cause', () {
      final cause = Exception('root cause');
      final e = CastException('wrapper', cause);
      expect(e.cause, cause);
    });

    test('DeviceUnreachableException is a CastException', () {
      final e = DeviceUnreachableException('cannot reach');
      expect(e, isA<CastException>());
      expect(e.message, 'cannot reach');
    });

    test('ConnectionLostException is a CastException', () {
      final e = ConnectionLostException('lost');
      expect(e, isA<CastException>());
      expect(e.message, 'lost');
    });

    test('MediaLoadFailedException is a CastException', () {
      final e = MediaLoadFailedException('load failed');
      expect(e, isA<CastException>());
      expect(e.message, 'load failed');
    });

    test('ProxyUpstreamException is a CastException', () {
      final e = ProxyUpstreamException('upstream error');
      expect(e, isA<CastException>());
      expect(e.message, 'upstream error');
    });

    test('DiscoveryException is a CastException', () {
      final e = DiscoveryException('discovery failed');
      expect(e, isA<CastException>());
      expect(e.message, 'discovery failed');
    });

    test('ProtocolException includes protocol field', () {
      final e = ProtocolException(
        'protocol error',
        CastProtocol.chromecast,
      );
      expect(e, isA<CastException>());
      expect(e.message, 'protocol error');
      expect(e.protocol, CastProtocol.chromecast);
      expect(e.toString(), contains('chromecast'));
    });
  });
}
