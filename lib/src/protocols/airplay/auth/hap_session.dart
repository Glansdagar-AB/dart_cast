import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../../utils/logger.dart';
import '../plist_codec.dart';

/// Derives the HAP session encryption keys from an X25519 shared secret.
///
/// Returns `(outputKey, inputKey)` — the output key encrypts data sent to the
/// device, and the input key decrypts data received from it.
Future<({Uint8List outputKey, Uint8List inputKey})> deriveHapSessionKeys(
  Uint8List sharedSecret,
) async {
  final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);

  final outputKeyObj = await hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: utf8.encode('Control-Salt'),
    info: utf8.encode('Control-Write-Encryption-Key'),
  );

  final inputKeyObj = await hkdf.deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: utf8.encode('Control-Salt'),
    info: utf8.encode('Control-Read-Encryption-Key'),
  );

  return (
    outputKey: Uint8List.fromList(await outputKeyObj.extractBytes()),
    inputKey: Uint8List.fromList(await inputKeyObj.extractBytes()),
  );
}

/// A parsed HTTP response from the HAP encrypted channel.
class HapHttpResponse {
  /// HTTP status code.
  final int statusCode;

  /// HTTP reason phrase (e.g. "OK").
  final String reasonPhrase;

  /// Response headers (lowercased keys).
  final Map<String, String> headers;

  /// Response body bytes.
  final Uint8List body;

  HapHttpResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
  });

  /// Returns the body decoded as UTF-8 text.
  String get bodyText => utf8.decode(body);

  @override
  String toString() => 'HapHttpResponse($statusCode $reasonPhrase, '
      '${body.length} bytes)';
}

/// HAP encrypted session layer for AirPlay.
///
/// After pair-verify succeeds, all subsequent HTTP traffic must be encrypted
/// using HAP's framing protocol (HomeKit Accessory Protocol, section 5.2.2).
///
/// Data is split into max 1024-byte frames. Each frame is:
/// ```
/// [2-byte LE length][ChaCha20-Poly1305(payload) + 16-byte auth tag]
/// ```
/// The 2-byte length serves as AAD (Additional Authenticated Data).
/// Nonces are 12 bytes: 4 zero bytes followed by an 8-byte LE counter.
class HapSession {
  /// Maximum frame payload size as specified by HAP section 5.2.2.
  static const int frameLength = 1024;

  /// ChaCha20-Poly1305 authentication tag length.
  static const int authTagLength = 16;

  final Socket _socket;
  final Uint8List _outputKey;
  final Uint8List _inputKey;
  int _outputCounter = 0;
  int _inputCounter = 0;

  /// Buffer for incomplete encrypted data received from the device.
  final BytesBuilder _receiveBuffer = BytesBuilder(copy: false);

  /// The host used in HTTP Host headers.
  final String host;

  /// The port used in HTTP Host headers.
  final int port;

  /// Session ID for X-Apple-Session-ID header.
  String _sessionId;

  /// Creates a [HapSession] wrapping a raw TCP [socket].
  ///
  /// [outputKey] encrypts data sent to the device.
  /// [inputKey] decrypts data received from the device.
  HapSession({
    required Socket socket,
    required Uint8List outputKey,
    required Uint8List inputKey,
    required this.host,
    required this.port,
    String? sessionId,
  })  : _socket = socket,
        _outputKey = outputKey,
        _inputKey = inputKey,
        _sessionId = sessionId ?? _generateUuid();

  /// The current session ID.
  String get sessionId => _sessionId;

  /// Visible for testing: the current output (encrypt) nonce counter.
  int get outputCounter => _outputCounter;

  /// Visible for testing: the current input (decrypt) nonce counter.
  int get inputCounter => _inputCounter;

  /// Encrypts [data] into HAP framed format.
  ///
  /// Data is split into max [frameLength]-byte chunks. Each chunk is encrypted
  /// with ChaCha20-Poly1305, producing:
  /// `[2-byte LE length][ciphertext + 16-byte tag]`
  Future<Uint8List> encrypt(Uint8List data) async {
    final result = BytesBuilder(copy: false);
    int offset = 0;

    while (offset < data.length) {
      final end = (offset + frameLength < data.length)
          ? offset + frameLength
          : data.length;
      final chunk = data.sublist(offset, end);

      // 2-byte little-endian length as AAD
      final lengthBytes = Uint8List(2);
      lengthBytes[0] = chunk.length & 0xFF;
      lengthBytes[1] = (chunk.length >> 8) & 0xFF;

      // Build 12-byte nonce: 4 zero bytes + 8-byte LE counter
      final nonce = _buildNonce(_outputCounter);
      _outputCounter++;

      // Encrypt with ChaCha20-Poly1305
      final algorithm = Chacha20.poly1305Aead();
      final secretBox = await algorithm.encrypt(
        chunk,
        secretKey: SecretKey(_outputKey),
        nonce: nonce,
        aad: lengthBytes,
      );

      // Frame = lengthBytes + ciphertext + mac
      result.add(lengthBytes);
      result.add(secretBox.cipherText);
      result.add(secretBox.mac.bytes);

      offset = end;
    }

    return result.toBytes();
  }

  /// Decrypts HAP framed [data] received from the device.
  ///
  /// Each frame is: `[2-byte LE length][ciphertext(length bytes) + 16-byte tag]`
  /// Returns the decrypted plaintext.
  ///
  /// May return fewer bytes than expected if the data is incomplete (partial
  /// frame). Unconsumed bytes are buffered internally.
  Future<Uint8List> decrypt(Uint8List data) async {
    _receiveBuffer.add(data);
    final buffered = _receiveBuffer.toBytes();
    _receiveBuffer.clear();

    final result = BytesBuilder(copy: false);
    int offset = 0;

    while (offset < buffered.length) {
      // Need at least 2 bytes for length
      if (offset + 2 > buffered.length) {
        break;
      }

      final blockLength = buffered[offset] | (buffered[offset + 1] << 8);
      final totalFrameLength = 2 + blockLength + authTagLength;

      // Not enough data for this frame yet
      if (offset + totalFrameLength > buffered.length) {
        break;
      }

      final lengthBytes = buffered.sublist(offset, offset + 2);
      final encrypted = buffered.sublist(
          offset + 2, offset + 2 + blockLength + authTagLength);

      // Split into ciphertext and mac
      final ciphertext = encrypted.sublist(0, blockLength);
      final mac =
          Mac(encrypted.sublist(blockLength, blockLength + authTagLength));

      // Build nonce
      final nonce = _buildNonce(_inputCounter);
      _inputCounter++;

      // Decrypt
      final algorithm = Chacha20.poly1305Aead();
      final secretBox = SecretBox(
        ciphertext,
        nonce: nonce,
        mac: mac,
      );
      final plaintext = await algorithm.decrypt(
        secretBox,
        secretKey: SecretKey(_inputKey),
        aad: lengthBytes,
      );
      result.add(plaintext);

      offset += totalFrameLength;
    }

    // Buffer any remaining incomplete data
    if (offset < buffered.length) {
      _receiveBuffer.add(buffered.sublist(offset));
    }

    return Uint8List.fromList(result.toBytes());
  }

  /// Sends an HTTP request through the encrypted channel and returns the response.
  Future<HapHttpResponse> sendRequest(
    String method,
    String path, {
    Map<String, String>? headers,
    List<int>? body,
    Map<String, String>? queryParameters,
  }) async {
    // Build the URI path with query parameters
    String fullPath = path;
    if (queryParameters != null && queryParameters.isNotEmpty) {
      final queryString = queryParameters.entries
          .map((e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
          .join('&');
      fullPath = '$path?$queryString';
    }

    // Build raw HTTP request
    final requestHeaders = <String, String>{
      'User-Agent': 'MediaControl/1.0',
      'X-Apple-Session-ID': _sessionId,
      'Host': '$host:$port',
      'Connection': 'keep-alive',
      ...?headers,
    };

    if (body != null && body.isNotEmpty) {
      requestHeaders['Content-Length'] = '${body.length}';
    }

    final buffer = StringBuffer();
    buffer.write('$method $fullPath HTTP/1.1\r\n');
    for (final entry in requestHeaders.entries) {
      buffer.write('${entry.key}: ${entry.value}\r\n');
    }
    buffer.write('\r\n');

    final headerBytes = utf8.encode(buffer.toString());
    final requestBytes = body != null && body.isNotEmpty
        ? Uint8List.fromList([...headerBytes, ...body])
        : Uint8List.fromList(headerBytes);

    // Encrypt and send
    final encrypted = await encrypt(requestBytes);
    _socket.add(encrypted);
    await _socket.flush();

    // Read response
    final responseBytes = await _readEncryptedResponse();
    return _parseHttpResponse(responseBytes);
  }

  /// Reads encrypted frames from the socket until a complete HTTP response
  /// is received.
  Future<Uint8List> _readEncryptedResponse() async {
    final completer = Completer<Uint8List>();
    final decryptedBuffer = BytesBuilder(copy: false);
    StreamSubscription<Uint8List>? subscription;

    // Timeout after 30 seconds
    final timer = Timer(const Duration(seconds: 30), () {
      if (!completer.isCompleted) {
        subscription?.cancel();
        completer.completeError(
          HapSessionException('Timed out waiting for response'),
        );
      }
    });

    subscription = _socket.listen(
      (data) async {
        try {
          final decrypted = await decrypt(Uint8List.fromList(data));
          if (decrypted.isNotEmpty) {
            decryptedBuffer.add(decrypted);
          }

          // Check if we have a complete HTTP response
          final accumulated = decryptedBuffer.toBytes();
          if (_isCompleteHttpResponse(accumulated)) {
            timer.cancel();
            subscription?.cancel();
            if (!completer.isCompleted) {
              completer.complete(Uint8List.fromList(accumulated));
            }
          }
        } catch (e) {
          timer.cancel();
          subscription?.cancel();
          if (!completer.isCompleted) {
            completer.completeError(e);
          }
        }
      },
      onError: (Object error) {
        timer.cancel();
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
      onDone: () {
        timer.cancel();
        if (!completer.isCompleted) {
          // Socket closed — return whatever we have
          completer.complete(Uint8List.fromList(decryptedBuffer.toBytes()));
        }
      },
    );

    return completer.future;
  }

  /// Checks if the accumulated bytes form a complete HTTP response.
  bool _isCompleteHttpResponse(Uint8List data) {
    // Find the end of headers (\r\n\r\n)
    final headerEnd = _findHeaderEnd(data);
    if (headerEnd == -1) return false;

    final headerStr = utf8.decode(data.sublist(0, headerEnd));
    final bodyStart = headerEnd + 4; // Skip \r\n\r\n

    // Check for Content-Length
    final contentLengthMatch =
        RegExp(r'content-length:\s*(\d+)', caseSensitive: false)
            .firstMatch(headerStr);
    if (contentLengthMatch != null) {
      final contentLength = int.parse(contentLengthMatch.group(1)!);
      return data.length >= bodyStart + contentLength;
    }

    // Check for Transfer-Encoding: chunked
    if (headerStr.toLowerCase().contains('transfer-encoding: chunked')) {
      // Look for the terminal chunk (0\r\n\r\n)
      final bodyBytes = data.sublist(bodyStart);
      final bodyStr = utf8.decode(bodyBytes, allowMalformed: true);
      return bodyStr.contains('0\r\n\r\n');
    }

    // No Content-Length and not chunked — assume complete if we have headers
    // This handles responses like "HTTP/1.1 200 OK\r\n\r\n"
    return true;
  }

  /// Finds the index of the first \r\n\r\n sequence in [data].
  /// Returns -1 if not found.
  int _findHeaderEnd(Uint8List data) {
    for (int i = 0; i < data.length - 3; i++) {
      if (data[i] == 0x0D &&
          data[i + 1] == 0x0A &&
          data[i + 2] == 0x0D &&
          data[i + 3] == 0x0A) {
        return i;
      }
    }
    return -1;
  }

  /// Parses raw HTTP response bytes into a [HapHttpResponse].
  HapHttpResponse _parseHttpResponse(Uint8List data) {
    final headerEnd = _findHeaderEnd(data);
    if (headerEnd == -1) {
      throw HapSessionException('Invalid HTTP response: no header terminator');
    }

    final headerStr = utf8.decode(data.sublist(0, headerEnd));
    final bodyStart = headerEnd + 4;

    // Parse status line
    final lines = headerStr.split('\r\n');
    if (lines.isEmpty) {
      throw HapSessionException('Invalid HTTP response: empty headers');
    }

    final statusLine = lines.first;
    final statusMatch =
        RegExp(r'HTTP/\d+\.\d+\s+(\d+)\s*(.*)').firstMatch(statusLine);
    if (statusMatch == null) {
      throw HapSessionException(
          'Invalid HTTP response status line: $statusLine');
    }

    final statusCode = int.parse(statusMatch.group(1)!);
    final reasonPhrase = statusMatch.group(2) ?? '';

    // Parse headers
    final headers = <String, String>{};
    for (int i = 1; i < lines.length; i++) {
      final colonIndex = lines[i].indexOf(':');
      if (colonIndex > 0) {
        final key = lines[i].substring(0, colonIndex).trim().toLowerCase();
        final value = lines[i].substring(colonIndex + 1).trim();
        headers[key] = value;
      }
    }

    // Extract body
    final body = bodyStart < data.length
        ? Uint8List.fromList(data.sublist(bodyStart))
        : Uint8List(0);

    return HapHttpResponse(
      statusCode: statusCode,
      reasonPhrase: reasonPhrase,
      headers: headers,
      body: body,
    );
  }

  // -- AirPlay media command convenience methods --

  /// Common headers for AirPlay requests.
  Map<String, String> get _defaultHeaders => {
        'User-Agent': 'MediaControl/1.0',
        'X-Apple-Session-ID': _sessionId,
      };

  /// Starts playback of a video URL on the AirPlay device.
  Future<void> play(String url, {double startPosition = 0.0}) async {
    final body = 'Content-Location: $url\nStart-Position: $startPosition\n';
    final response = await sendRequest('POST', '/play',
        headers: {
          ..._defaultHeaders,
          'Content-Type': 'text/parameters',
        },
        body: utf8.encode(body));
    _checkResponse(response, 'play');
  }

  /// Seeks to an absolute position in seconds.
  Future<void> scrub(double positionSeconds) async {
    final response = await sendRequest(
      'POST',
      '/scrub',
      headers: _defaultHeaders,
      queryParameters: {'position': '$positionSeconds'},
    );
    _checkResponse(response, 'scrub');
  }

  /// Sets the playback rate (0 = pause, 1 = play).
  Future<void> rate(num value) async {
    final response = await sendRequest(
      'POST',
      '/rate',
      headers: _defaultHeaders,
      queryParameters: {'value': '${value.toDouble()}'},
    );
    _checkResponse(response, 'rate');
  }

  /// Stops playback and generates a new session ID.
  Future<void> stop() async {
    final response = await sendRequest(
      'POST',
      '/stop',
      headers: _defaultHeaders,
    );
    _checkResponse(response, 'stop');
    _sessionId = _generateUuid();
  }

  /// Gets detailed playback state as a [PlaybackInfo].
  Future<PlaybackInfo> getPlaybackInfo() async {
    final response = await sendRequest(
      'GET',
      '/playback-info',
      headers: _defaultHeaders,
    );
    _checkResponse(response, 'playback-info');
    return PlistCodec.parsePlaybackInfo(response.bodyText);
  }

  /// Gets device information as a [ServerInfo].
  Future<ServerInfo> getServerInfo() async {
    final response = await sendRequest(
      'GET',
      '/server-info',
      headers: _defaultHeaders,
    );
    _checkResponse(response, 'server-info');
    return PlistCodec.parseServerInfo(response.bodyText);
  }

  void _checkResponse(HapHttpResponse response, String endpoint) {
    if (response.statusCode != 200) {
      throw HapSessionException(
        'AirPlay $endpoint failed with status ${response.statusCode}',
      );
    }
  }

  /// Closes the underlying socket.
  Future<void> close() async {
    try {
      _socket.destroy();
    } catch (_) {
      // Ignore errors during close
    }
  }

  /// Builds a 12-byte nonce: 4 zero bytes + 8-byte little-endian counter.
  static Uint8List _buildNonce(int counter) {
    final nonce = Uint8List(12);
    // First 4 bytes are zero (already initialized)
    // Bytes 4-11 are the 8-byte LE counter
    nonce[4] = counter & 0xFF;
    nonce[5] = (counter >> 8) & 0xFF;
    nonce[6] = (counter >> 16) & 0xFF;
    nonce[7] = (counter >> 24) & 0xFF;
    nonce[8] = (counter >> 32) & 0xFF;
    nonce[9] = (counter >> 40) & 0xFF;
    nonce[10] = (counter >> 48) & 0xFF;
    nonce[11] = (counter >> 56) & 0xFF;
    return nonce;
  }

  /// Generates a UUID v4-like string.
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  /// Creates a [HapSession] by connecting a raw TCP socket to the AirPlay
  /// device and deriving encryption keys from the shared secret.
  static Future<HapSession> connect({
    required String host,
    required int port,
    required Uint8List sharedSecret,
    String? sessionId,
  }) async {
    CastLogger.info('HAP session: deriving encryption keys');
    final keys = await deriveHapSessionKeys(sharedSecret);

    CastLogger.info('HAP session: connecting raw socket to $host:$port');
    final socket = await Socket.connect(host, port);

    CastLogger.info('HAP session: encrypted session established');
    return HapSession(
      socket: socket,
      outputKey: keys.outputKey,
      inputKey: keys.inputKey,
      host: host,
      port: port,
      sessionId: sessionId,
    );
  }
}

/// Exception thrown when the HAP encrypted session encounters an error.
class HapSessionException implements Exception {
  /// Description of the error.
  final String message;

  HapSessionException(this.message);

  @override
  String toString() => 'HapSessionException: $message';
}
