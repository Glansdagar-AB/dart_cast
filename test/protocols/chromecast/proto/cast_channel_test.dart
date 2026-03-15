import 'dart:typed_data';

import 'package:dart_cast/src/protocols/chromecast/proto/cast_channel.dart';
import 'package:test/test.dart';

void main() {
  group('CastMessage_ProtocolVersion', () {
    test('CASTV2_1_0 has value 0', () {
      expect(CastMessage_ProtocolVersion.CASTV2_1_0.value, 0);
    });

    test('valueOf returns correct enum', () {
      expect(
        CastMessage_ProtocolVersion.valueOf(0),
        CastMessage_ProtocolVersion.CASTV2_1_0,
      );
    });

    test('valueOf returns null for unknown value', () {
      expect(CastMessage_ProtocolVersion.valueOf(99), isNull);
    });
  });

  group('CastMessage_PayloadType', () {
    test('STRING has value 0', () {
      expect(CastMessage_PayloadType.STRING.value, 0);
    });

    test('BINARY has value 1', () {
      expect(CastMessage_PayloadType.BINARY.value, 1);
    });

    test('valueOf works', () {
      expect(
        CastMessage_PayloadType.valueOf(0),
        CastMessage_PayloadType.STRING,
      );
      expect(
        CastMessage_PayloadType.valueOf(1),
        CastMessage_PayloadType.BINARY,
      );
    });
  });

  group('CastMessage', () {
    test('default field values', () {
      final msg = CastMessage();
      expect(msg.protocolVersion, CastMessage_ProtocolVersion.CASTV2_1_0);
      expect(msg.payloadType, CastMessage_PayloadType.STRING);
      expect(msg.sourceId, '');
      expect(msg.destinationId, '');
      expect(msg.namespace_, '');
      expect(msg.payloadUtf8, '');
    });

    test('set and get string payload fields', () {
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'urn:x-cast:com.google.cast.tp.heartbeat'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = '{"type":"PING"}';

      expect(msg.sourceId, 'sender-0');
      expect(msg.destinationId, 'receiver-0');
      expect(msg.namespace_, 'urn:x-cast:com.google.cast.tp.heartbeat');
      expect(msg.payloadType, CastMessage_PayloadType.STRING);
      expect(msg.payloadUtf8, '{"type":"PING"}');
    });

    test('set and get binary payload', () {
      final data = [0x01, 0x02, 0x03, 0xFF];
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'test'
        ..payloadType = CastMessage_PayloadType.BINARY
        ..payloadBinary = data;

      expect(msg.payloadType, CastMessage_PayloadType.BINARY);
      expect(msg.payloadBinary, data);
    });

    test('serialization/deserialization roundtrip with string payload', () {
      final original = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'urn:x-cast:com.google.cast.tp.heartbeat'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = '{"type":"PING"}';

      final bytes = original.writeToBuffer();
      expect(bytes, isNotEmpty);

      final decoded = CastMessage.fromBuffer(bytes);
      expect(decoded.protocolVersion, original.protocolVersion);
      expect(decoded.sourceId, original.sourceId);
      expect(decoded.destinationId, original.destinationId);
      expect(decoded.namespace_, original.namespace_);
      expect(decoded.payloadType, original.payloadType);
      expect(decoded.payloadUtf8, original.payloadUtf8);
    });

    test('serialization/deserialization roundtrip with binary payload', () {
      final binaryData = Uint8List.fromList([10, 20, 30, 40, 50]);
      final original = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'client-123'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'urn:x-cast:com.google.cast.auth'
        ..payloadType = CastMessage_PayloadType.BINARY
        ..payloadBinary = binaryData;

      final bytes = original.writeToBuffer();
      final decoded = CastMessage.fromBuffer(bytes);

      expect(decoded.payloadType, CastMessage_PayloadType.BINARY);
      expect(decoded.payloadBinary, binaryData);
      expect(decoded.sourceId, 'client-123');
    });

    test('clone produces independent copy', () {
      final original = CastMessage()
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'test'
        ..payloadUtf8 = 'hello';

      final copy = original.clone();
      copy.payloadUtf8 = 'world';

      expect(original.payloadUtf8, 'hello');
      expect(copy.payloadUtf8, 'world');
    });

    test('has* methods reflect field presence', () {
      final msg = CastMessage();
      expect(msg.hasSourceId(), isFalse);

      msg.sourceId = 'sender-0';
      expect(msg.hasSourceId(), isTrue);
    });
  });
}
