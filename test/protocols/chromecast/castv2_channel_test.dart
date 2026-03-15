import 'dart:async';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/chromecast/castv2_channel.dart';
import 'package:dart_cast/src/protocols/chromecast/proto/cast_channel.dart';
import 'package:test/test.dart';

void main() {
  group('CastV2Channel framing helpers', () {
    test('writeLength encodes integer as 4-byte big-endian', () {
      // 256 = 0x00000100
      final bytes = CastV2Channel.writeLength(256);
      expect(bytes.length, 4);
      expect(bytes[0], 0x00);
      expect(bytes[1], 0x00);
      expect(bytes[2], 0x01);
      expect(bytes[3], 0x00);
    });

    test('readLength decodes 4-byte big-endian to integer', () {
      final bytes = Uint8List.fromList([0x00, 0x00, 0x01, 0x00]);
      expect(CastV2Channel.readLength(bytes), 256);
    });

    test('writeLength/readLength roundtrip for various values', () {
      for (final value in [0, 1, 255, 256, 65535, 1000000]) {
        final encoded = CastV2Channel.writeLength(value);
        final decoded = CastV2Channel.readLength(encoded);
        expect(decoded, value, reason: 'roundtrip failed for $value');
      }
    });

    test('readLength with max uint32', () {
      final bytes = Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF]);
      expect(CastV2Channel.readLength(bytes), 0xFFFFFFFF);
    });
  });

  group('CastMessage protobuf serialization roundtrip', () {
    test('string payload message roundtrip', () {
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'urn:x-cast:com.google.cast.tp.heartbeat'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = '{"type":"PING"}';

      final bytes = msg.writeToBuffer();
      final decoded = CastMessage.fromBuffer(bytes);

      expect(decoded.sourceId, 'sender-0');
      expect(decoded.destinationId, 'receiver-0');
      expect(decoded.namespace_, 'urn:x-cast:com.google.cast.tp.heartbeat');
      expect(decoded.payloadUtf8, '{"type":"PING"}');
    });
  });

  group('Full message framing', () {
    test('frameMessage produces length prefix + protobuf bytes', () {
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'test'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = 'hello';

      final framed = CastV2Channel.frameMessage(msg);
      final protobufBytes = msg.writeToBuffer();

      // First 4 bytes should be the length of the protobuf portion
      final lengthPrefix = framed.sublist(0, 4);
      final decodedLength = CastV2Channel.readLength(
        Uint8List.fromList(lengthPrefix),
      );
      expect(decodedLength, protobufBytes.length);

      // Remaining bytes should be the protobuf
      final payload = framed.sublist(4);
      expect(payload, protobufBytes);
    });
  });

  group('Message stream parsing', () {
    test('parseMessages extracts single message from complete frame', () async {
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'urn:x-cast:com.google.cast.tp.heartbeat'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = '{"type":"PING"}';

      final framed = CastV2Channel.frameMessage(msg);

      final controller = StreamController<List<int>>();
      final messages =
          CastV2Channel.parseMessages(controller.stream).toList();

      controller.add(framed);
      await controller.close();

      final result = await messages;
      expect(result.length, 1);
      expect(result[0].sourceId, 'sender-0');
      expect(result[0].payloadUtf8, '{"type":"PING"}');
    });

    test('parseMessages handles message split across chunks', () async {
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'urn:x-cast:com.google.cast.tp.heartbeat'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = '{"type":"PING"}';

      final framed = CastV2Channel.frameMessage(msg);

      // Split the framed message into multiple chunks
      final splitPoint = framed.length ~/ 2;
      final chunk1 = framed.sublist(0, splitPoint);
      final chunk2 = framed.sublist(splitPoint);

      final controller = StreamController<List<int>>();
      final messages =
          CastV2Channel.parseMessages(controller.stream).toList();

      controller.add(chunk1);
      controller.add(chunk2);
      await controller.close();

      final result = await messages;
      expect(result.length, 1);
      expect(result[0].sourceId, 'sender-0');
      expect(result[0].payloadUtf8, '{"type":"PING"}');
    });

    test('parseMessages handles multiple messages in one chunk', () async {
      final msg1 = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'test'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = 'first';

      final msg2 = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-1'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'test'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = 'second';

      final framed1 = CastV2Channel.frameMessage(msg1);
      final framed2 = CastV2Channel.frameMessage(msg2);

      final combined = <int>[...framed1, ...framed2];

      final controller = StreamController<List<int>>();
      final messages =
          CastV2Channel.parseMessages(controller.stream).toList();

      controller.add(combined);
      await controller.close();

      final result = await messages;
      expect(result.length, 2);
      expect(result[0].payloadUtf8, 'first');
      expect(result[1].payloadUtf8, 'second');
    });

    test('parseMessages handles length header split across chunks', () async {
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 'sender-0'
        ..destinationId = 'receiver-0'
        ..namespace_ = 'test'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = 'hello';

      final framed = CastV2Channel.frameMessage(msg);

      // Split within the 4-byte length header
      final chunk1 = framed.sublist(0, 2); // first 2 bytes of header
      final chunk2 = framed.sublist(2); // rest of header + body

      final controller = StreamController<List<int>>();
      final messages =
          CastV2Channel.parseMessages(controller.stream).toList();

      controller.add(chunk1);
      controller.add(chunk2);
      await controller.close();

      final result = await messages;
      expect(result.length, 1);
      expect(result[0].payloadUtf8, 'hello');
    });

    test('parseMessages handles byte-by-byte delivery', () async {
      final msg = CastMessage()
        ..protocolVersion = CastMessage_ProtocolVersion.CASTV2_1_0
        ..sourceId = 's'
        ..destinationId = 'd'
        ..namespace_ = 'n'
        ..payloadType = CastMessage_PayloadType.STRING
        ..payloadUtf8 = 'x';

      final framed = CastV2Channel.frameMessage(msg);

      final controller = StreamController<List<int>>();
      final messages =
          CastV2Channel.parseMessages(controller.stream).toList();

      // Send one byte at a time
      for (final byte in framed) {
        controller.add([byte]);
      }
      await controller.close();

      final result = await messages;
      expect(result.length, 1);
      expect(result[0].payloadUtf8, 'x');
    });
  });
}
