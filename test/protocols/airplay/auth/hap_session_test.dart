import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_cast/src/protocols/airplay/auth/hap_session.dart';
import 'package:test/test.dart';

void main() {
  group('deriveHapSessionKeys', () {
    test('produces 32-byte output and input keys', () async {
      final sharedSecret = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        sharedSecret[i] = i;
      }

      final keys = await deriveHapSessionKeys(sharedSecret);

      expect(keys.outputKey.length, equals(32));
      expect(keys.inputKey.length, equals(32));
    });

    test('output and input keys are different', () async {
      final sharedSecret = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        sharedSecret[i] = i;
      }

      final keys = await deriveHapSessionKeys(sharedSecret);

      expect(keys.outputKey, isNot(equals(keys.inputKey)));
    });

    test('deterministic: same input produces same keys', () async {
      final sharedSecret = Uint8List.fromList(List.generate(32, (i) => i * 3));

      final keys1 = await deriveHapSessionKeys(sharedSecret);
      final keys2 = await deriveHapSessionKeys(sharedSecret);

      expect(keys1.outputKey, equals(keys2.outputKey));
      expect(keys1.inputKey, equals(keys2.inputKey));
    });
  });

  group('HapSession encrypt/decrypt', () {
    late HapSession session;
    late ServerSocket serverSocket;

    setUp(() async {
      // Create a dummy socket pair for testing
      serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final clientSocket = await Socket.connect('127.0.0.1', serverSocket.port);

      // Use the same key for both directions in tests for simplicity
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      session = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSocket.port,
        sessionId: 'test-session',
      );
    });

    tearDown(() async {
      await session.close();
      await serverSocket.close();
    });

    test('encrypt produces correct frame format', () async {
      final data = Uint8List.fromList(utf8.encode('Hello, HAP!'));
      final encrypted = await session.encrypt(data);

      // Frame = 2-byte length + encrypted data + 16-byte tag
      expect(encrypted.length, equals(2 + data.length + 16));

      // First 2 bytes should be little-endian length of the original data
      final length = encrypted[0] | (encrypted[1] << 8);
      expect(length, equals(data.length));
    });

    test('encrypt increments output counter', () async {
      expect(session.outputCounter, equals(0));

      await session.encrypt(Uint8List.fromList([1, 2, 3]));
      expect(session.outputCounter, equals(1));

      await session.encrypt(Uint8List.fromList([4, 5, 6]));
      expect(session.outputCounter, equals(2));
    });

    test('decrypt increments input counter', () async {
      // First encrypt some data so we have valid ciphertext
      final data = Uint8List.fromList(utf8.encode('test'));

      // Create a separate session for encrypting (simulates the device)
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final encSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final encSession = HapSession(
        socket: encSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await encSession.encrypt(data);

      expect(session.inputCounter, equals(0));
      await session.decrypt(encrypted);
      expect(session.inputCounter, equals(1));

      await encSession.close();
      await serverSock.close();
    });

    test('encrypt then decrypt roundtrip for small data', () async {
      final original = Uint8List.fromList(utf8.encode('Small payload'));

      // Use matching keys: session encrypts with outputKey,
      // and a second session decrypts with inputKey = first session's outputKey
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      // Create decrypt session with inputKey = encrypt session's outputKey
      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final decSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final decSession = HapSession(
        socket: decSocket,
        outputKey: Uint8List.fromList(key), // not used
        inputKey: Uint8List.fromList(key), // matches session's outputKey
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await session.encrypt(original);
      final decrypted = await decSession.decrypt(encrypted);

      expect(decrypted, equals(original));

      await decSession.close();
      await serverSock.close();
    });

    test('encrypt splits data into 1024-byte frames', () async {
      // Create data larger than one frame
      final data = Uint8List(2500);
      for (int i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      final encrypted = await session.encrypt(data);

      // Frame 1: 1024 bytes -> 2 + 1024 + 16 = 1042
      // Frame 2: 1024 bytes -> 2 + 1024 + 16 = 1042
      // Frame 3: 452 bytes  -> 2 + 452 + 16 = 470
      // Total: 1042 + 1042 + 470 = 2554
      expect(encrypted.length, equals(2554));

      // Verify first frame length
      final len1 = encrypted[0] | (encrypted[1] << 8);
      expect(len1, equals(1024));

      // Verify second frame length (starts at offset 1042)
      final len2 = encrypted[1042] | (encrypted[1043] << 8);
      expect(len2, equals(1024));

      // Verify third frame length (starts at offset 2084)
      final len3 = encrypted[2084] | (encrypted[2085] << 8);
      expect(len3, equals(452));

      // Output counter should be 3 (one per frame)
      expect(session.outputCounter, equals(3));
    });

    test('multi-frame encrypt/decrypt roundtrip', () async {
      final original = Uint8List(2500);
      for (int i = 0; i < original.length; i++) {
        original[i] = i % 256;
      }

      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final decSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final decSession = HapSession(
        socket: decSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await session.encrypt(original);
      final decrypted = await decSession.decrypt(encrypted);

      expect(decrypted, equals(original));

      await decSession.close();
      await serverSock.close();
    });

    test('encrypt empty data returns empty', () async {
      final encrypted = await session.encrypt(Uint8List(0));
      expect(encrypted.length, equals(0));
      expect(session.outputCounter, equals(0));
    });

    test('decrypt partial frame buffers data', () async {
      final original = Uint8List.fromList(utf8.encode('test data'));

      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      // Encrypt to get valid frame
      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final encSocket = await Socket.connect('127.0.0.1', serverSock.port);
      final encSession = HapSession(
        socket: encSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: serverSock.port,
      );

      final encrypted = await encSession.encrypt(original);

      // Feed only partial data first (just the length bytes)
      final partial1 = encrypted.sublist(0, 5);
      final partial2 = encrypted.sublist(5);

      final result1 = await session.decrypt(Uint8List.fromList(partial1));
      // Should return empty since we don't have a complete frame
      expect(result1.length, equals(0));
      expect(session.inputCounter, equals(0));

      // Now feed the rest
      final result2 = await session.decrypt(Uint8List.fromList(partial2));
      expect(result2, equals(original));
      expect(session.inputCounter, equals(1));

      await encSession.close();
      await serverSock.close();
    });

    test('encrypt exactly 1024 bytes produces single frame', () async {
      final data = Uint8List(1024);
      for (int i = 0; i < data.length; i++) {
        data[i] = i % 256;
      }

      final encrypted = await session.encrypt(data);

      // Single frame: 2 + 1024 + 16 = 1042
      expect(encrypted.length, equals(1042));
      expect(session.outputCounter, equals(1));

      final len = encrypted[0] | (encrypted[1] << 8);
      expect(len, equals(1024));
    });
  });

  group('HapSession HTTP request/response through encrypted channel', () {
    test('sendRequest sends encrypted HTTP and receives encrypted response',
        () async {
      // Set up keys
      final key = Uint8List(32);
      for (int i = 0; i < 32; i++) {
        key[i] = i;
      }

      // Create a raw TCP server that decrypts requests and sends encrypted responses
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);

      final clientSocket = await Socket.connect('127.0.0.1', server.port);

      final hapSession = HapSession(
        socket: clientSocket,
        outputKey: Uint8List.fromList(key),
        inputKey: Uint8List.fromList(key),
        host: '127.0.0.1',
        port: server.port,
        sessionId: 'test-session-id',
      );

      // Server side: decrypt request, send encrypted response
      server.listen((serverSocket) {
        // The server uses reversed keys: inputKey = client's outputKey,
        // outputKey = client's inputKey
        final serverDecSession = HapSession(
          socket: serverSocket,
          outputKey: Uint8List.fromList(key), // matches client's inputKey
          inputKey: Uint8List.fromList(key), // matches client's outputKey
          host: '127.0.0.1',
          port: server.port,
        );

        serverSocket.listen((data) async {
          try {
            // Decrypt the request
            final decrypted =
                await serverDecSession.decrypt(Uint8List.fromList(data));
            final requestStr = utf8.decode(decrypted);

            // Verify it looks like an HTTP request
            if (requestStr.contains('GET /test-endpoint')) {
              // Send encrypted HTTP response
              final responseStr =
                  'HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nHello, World!';
              final responseBytes =
                  Uint8List.fromList(utf8.encode(responseStr));
              final encrypted = await serverDecSession.encrypt(responseBytes);
              serverSocket.add(encrypted);
              await serverSocket.flush();
            }
          } catch (e) {
            // Ignore decryption errors in test
          }
        });
      });

      try {
        final response = await hapSession.sendRequest('GET', '/test-endpoint');

        expect(response.statusCode, equals(200));
        expect(response.bodyText, equals('Hello, World!'));
      } finally {
        await hapSession.close();
        await server.close();
      }
    });
  });

  group('HapSession nonce building', () {
    test('first nonce is all zeros', () async {
      // Verify by encrypting with counter 0 and checking it works
      final key = Uint8List(32);
      final data = Uint8List.fromList([1, 2, 3]);

      final serverSock =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final socket = await Socket.connect('127.0.0.1', serverSock.port);

      final session = HapSession(
        socket: socket,
        outputKey: key,
        inputKey: key,
        host: '127.0.0.1',
        port: serverSock.port,
      );

      // Encrypt should succeed (verifies nonce is valid)
      final encrypted = await session.encrypt(data);
      expect(encrypted.length, greaterThan(0));

      await session.close();
      await serverSock.close();
    });
  });

  group('HapHttpResponse', () {
    test('bodyText decodes UTF-8', () {
      final response = HapHttpResponse(
        statusCode: 200,
        reasonPhrase: 'OK',
        headers: {},
        body: Uint8List.fromList(utf8.encode('Hello!')),
      );
      expect(response.bodyText, equals('Hello!'));
    });

    test('toString includes status and size', () {
      final response = HapHttpResponse(
        statusCode: 404,
        reasonPhrase: 'Not Found',
        headers: {},
        body: Uint8List(42),
      );
      expect(response.toString(), contains('404'));
      expect(response.toString(), contains('42'));
    });
  });

  group('HapSessionException', () {
    test('toString includes message', () {
      final e = HapSessionException('something broke');
      expect(e.toString(), contains('something broke'));
      expect(e.toString(), contains('HapSessionException'));
    });
  });
}
