import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../../../utils/logger.dart';
import 'hap_credentials.dart';
import 'hap_srp.dart';
import 'tlv8.dart';

/// Orchestrates the AirPlay HAP pair-setup flow (4 HTTP requests).
///
/// This is the one-time PIN-based pairing that produces persistent
/// [HapCredentials] for future pair-verify sessions.
class AirPlayPairSetup {
  final String host;
  final int port;
  final http.Client _httpClient;

  AirPlayPairSetup({
    required this.host,
    required this.port,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Triggers the device to display a PIN on screen.
  ///
  /// This is fire-and-forget — the HTTP request triggers the PIN display
  /// but the device may not respond (connection stays open). We don't wait
  /// for the response to avoid blocking the PIN dialog.
  void startPinDisplay() {
    CastLogger.info('AirPlay auth: requesting PIN display (fire-and-forget)');
    _httpClient
        .post(
      _uri('/pair-pin-start'),
      headers: _defaultHeaders,
      body: '',
    )
        .then((response) {
      CastLogger.info(
          'AirPlay auth: pair-pin-start response: ${response.statusCode}');
    }).catchError((Object e) {
      CastLogger.debug('AirPlay auth: pair-pin-start error (expected): $e');
    });
  }

  /// Runs the full pair-setup flow with the given [pin].
  ///
  /// [clientId] is the pairing identifier for this client (e.g., a UUID).
  /// Returns [HapCredentials] on success.
  Future<HapCredentials> pairSetup({
    required String pin,
    required String clientId,
  }) async {
    final srp = HapSrp();

    // -- M1: Send PairSetup method + SeqNo 1 --
    CastLogger.info('AirPlay auth: pair-setup M1');
    final m1 = Tlv8.encode([
      (Tlv8.tagMethod, [0x00]), // PairSetup
      (Tlv8.tagSeqNo, [0x01]),
    ]);

    final m2Response = await _postPairSetup(m1);
    final m2 = Tlv8.decode(m2Response);
    _checkError(m2, 'M2');

    final salt = Uint8List.fromList(m2[Tlv8.tagSalt]!);
    final serverPublicKey = Uint8List.fromList(m2[Tlv8.tagPublicKey]!);
    CastLogger.info(
        'AirPlay auth: M2 received salt(${salt.length}B) pubkey(${serverPublicKey.length}B)');

    // -- M3: SRP client public key + proof --
    CastLogger.info('AirPlay auth: pair-setup M3 (SRP exchange)');
    final clientPublicKey = await srp.step1();
    final proof = await srp.step2(
      serverPublicKey: serverPublicKey,
      salt: salt,
      pin: pin,
    );

    final m3 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x03]),
      (Tlv8.tagPublicKey, clientPublicKey),
      (Tlv8.tagProof, proof),
    ]);

    final m4Response = await _postPairSetup(m3);
    final m4 = Tlv8.decode(m4Response);
    _checkError(m4, 'M4');
    CastLogger.info('AirPlay auth: M4 received (SRP proof accepted)');

    // -- M5: Encrypted credentials --
    CastLogger.info('AirPlay auth: pair-setup M5 (credential exchange)');
    final encryptedCredentials = await srp.step3(clientId);

    final m5 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x05]),
      (Tlv8.tagEncryptedData, encryptedCredentials),
    ]);

    final m6Response = await _postPairSetup(m5);
    final m6 = Tlv8.decode(m6Response);
    _checkError(m6, 'M6');

    // -- Process M6: Decrypt device credentials --
    final deviceEncryptedData = Uint8List.fromList(m6[Tlv8.tagEncryptedData]!);
    CastLogger.info(
        'AirPlay auth: M6 received (${deviceEncryptedData.length}B encrypted)');

    final credentials = await srp.step4(
      encryptedData: deviceEncryptedData,
      clientId: clientId,
    );

    CastLogger.info(
        'AirPlay auth: pair-setup complete for device ${credentials.deviceId}');
    return credentials;
  }

  Future<Uint8List> _postPairSetup(Uint8List body) async {
    final response = await _httpClient.post(
      _uri('/pair-setup'),
      headers: {
        ..._defaultHeaders,
        'Content-Type': 'application/octet-stream',
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw AirPlayAuthException(
        'pair-setup failed with HTTP ${response.statusCode}',
      );
    }
    return Uint8List.fromList(response.bodyBytes);
  }

  void _checkError(Map<int, List<int>> tlv, String step) {
    if (tlv.containsKey(Tlv8.tagError)) {
      final errorCode = tlv[Tlv8.tagError]!.first;
      throw AirPlayAuthException(
        'pair-setup $step error: ${_errorCodeToString(errorCode)} ($errorCode)',
      );
    }
  }

  Uri _uri(String path) => Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
      );

  Map<String, String> get _defaultHeaders => {
        'User-Agent': 'AirPlay/320.20',
        'Connection': 'keep-alive',
        'X-Apple-HKP': '3',
      };

  /// Closes the underlying HTTP client.
  void close() => _httpClient.close();

  static String _errorCodeToString(int code) {
    switch (code) {
      case 1:
        return 'kTLVError_Unknown';
      case 2:
        return 'kTLVError_Authentication';
      case 3:
        return 'kTLVError_Backoff';
      case 4:
        return 'kTLVError_MaxPeers';
      case 5:
        return 'kTLVError_MaxTries';
      case 6:
        return 'kTLVError_Unavailable';
      case 7:
        return 'kTLVError_Busy';
      default:
        return 'Unknown';
    }
  }
}

/// Orchestrates the AirPlay HAP pair-verify flow (2 HTTP requests).
///
/// Uses stored [HapCredentials] to establish an authenticated session
/// without requiring a PIN.
class AirPlayPairVerify {
  final String host;
  final int port;
  final http.Client _httpClient;

  AirPlayPairVerify({
    required this.host,
    required this.port,
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// Runs the complete pair-verify flow using stored [credentials].
  ///
  /// Returns the X25519 shared secret for session encryption.
  Future<Uint8List> execute(HapCredentials credentials) async {
    // Generate ephemeral X25519 key pair
    final x25519 = X25519();
    final ephemeralKeyPair = await x25519.newKeyPair();
    final ephemeralPublicKey = await ephemeralKeyPair.extractPublicKey();
    final ephemeralPubBytes = Uint8List.fromList(ephemeralPublicKey.bytes);

    // -- M1: Send ephemeral X25519 public key --
    CastLogger.info('AirPlay auth: pair-verify M1');
    final m1 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x01]),
      (Tlv8.tagPublicKey, ephemeralPubBytes),
    ]);

    final m2Response = await _postPairVerify(m1);
    final m2 = Tlv8.decode(m2Response);
    _checkError(m2, 'M2');

    final deviceX25519PublicKey = Uint8List.fromList(m2[Tlv8.tagPublicKey]!);
    final encryptedData = Uint8List.fromList(m2[Tlv8.tagEncryptedData]!);
    CastLogger.info('AirPlay auth: pair-verify M2 received '
        '(pubkey ${deviceX25519PublicKey.length}B, '
        'encrypted ${encryptedData.length}B)');

    // -- Compute shared secret --
    final sharedSecret = await x25519.sharedSecretKey(
      keyPair: ephemeralKeyPair,
      remotePublicKey: SimplePublicKey(
        deviceX25519PublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final sharedSecretBytes =
        Uint8List.fromList(await sharedSecret.extractBytes());

    // Derive session key via HKDF
    final hkdf = Hkdf(hmac: Hmac(Sha512()), outputLength: 32);
    final sessionKeyObj = await hkdf.deriveKey(
      secretKey: SecretKey(sharedSecretBytes),
      nonce: utf8.encode('Pair-Verify-Encrypt-Salt'),
      info: utf8.encode('Pair-Verify-Encrypt-Info'),
    );
    final sessionKey = Uint8List.fromList(await sessionKeyObj.extractBytes());

    // Decrypt M2 challenge
    final decryptNonce = HapSrp.padNonce('PV-Msg02');
    final decrypted = await _chachaDecrypt(
      key: sessionKey,
      nonce: decryptNonce,
      ciphertext: encryptedData,
    );

    // Parse the sub-TLV from the decrypted challenge
    final subTlv = Tlv8.decode(decrypted);
    final deviceId = utf8.decode(subTlv[Tlv8.tagIdentifier]!);
    final deviceSignature = subTlv[Tlv8.tagSignature]!;

    // Verify device signature
    // deviceInfo = deviceX25519PublicKey | deviceId | ephemeralPublicKey
    final deviceIdBytes = utf8.encode(deviceId);
    final deviceInfo = Uint8List.fromList([
      ...deviceX25519PublicKey,
      ...deviceIdBytes,
      ...ephemeralPubBytes,
    ]);

    final ed25519 = Ed25519();
    final devicePubKey = SimplePublicKey(
      credentials.devicePublicKey,
      type: KeyPairType.ed25519,
    );
    final sig = Signature(deviceSignature, publicKey: devicePubKey);
    final valid = await ed25519.verify(deviceInfo, signature: sig);
    if (!valid) {
      throw AirPlayAuthException(
          'pair-verify: device signature verification failed');
    }
    CastLogger.info('AirPlay auth: pair-verify device signature verified');

    // -- Build M3: Sign our response --
    final clientIdBytes = utf8.encode(credentials.clientId);
    final clientInfo = Uint8List.fromList([
      ...ephemeralPubBytes,
      ...clientIdBytes,
      ...deviceX25519PublicKey,
    ]);

    // Sign with our stored Ed25519 private key
    final signingKeyPair = SimpleKeyPairData(
      credentials.clientPrivateKey,
      publicKey: SimplePublicKey(
        credentials.clientPublicKey,
        type: KeyPairType.ed25519,
      ),
      type: KeyPairType.ed25519,
    );
    final clientSignature = await ed25519.sign(
      clientInfo,
      keyPair: signingKeyPair,
    );

    // Build response sub-TLV
    final responseTlv = Tlv8.encode([
      (Tlv8.tagIdentifier, clientIdBytes),
      (Tlv8.tagSignature, clientSignature.bytes),
    ]);

    // Encrypt response
    final encryptNonce = HapSrp.padNonce('PV-Msg03');
    final encryptedResponse = await _chachaEncrypt(
      key: sessionKey,
      nonce: encryptNonce,
      plaintext: responseTlv,
    );

    // -- Send M3 --
    CastLogger.info('AirPlay auth: pair-verify M3');
    final m3 = Tlv8.encode([
      (Tlv8.tagSeqNo, [0x03]),
      (Tlv8.tagEncryptedData, encryptedResponse),
    ]);

    final m4Response = await _postPairVerify(m3);
    final m4 = Tlv8.decode(m4Response);
    _checkError(m4, 'M4');

    CastLogger.info('AirPlay auth: pair-verify complete');
    return sharedSecretBytes;
  }

  Future<Uint8List> _postPairVerify(Uint8List body) async {
    final response = await _httpClient.post(
      _uri('/pair-verify'),
      headers: {
        ..._defaultHeaders,
        'Content-Type': 'application/octet-stream',
      },
      body: body,
    );
    if (response.statusCode != 200) {
      throw AirPlayAuthException(
        'pair-verify failed with HTTP ${response.statusCode}',
      );
    }
    return Uint8List.fromList(response.bodyBytes);
  }

  void _checkError(Map<int, List<int>> tlv, String step) {
    if (tlv.containsKey(Tlv8.tagError)) {
      final errorCode = tlv[Tlv8.tagError]!.first;
      throw AirPlayAuthException(
        'pair-verify $step error: code $errorCode',
      );
    }
  }

  Future<Uint8List> _chachaEncrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List plaintext,
  }) async {
    final algorithm = Chacha20.poly1305Aead();
    final secretBox = await algorithm.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    return Uint8List.fromList([
      ...secretBox.cipherText,
      ...secretBox.mac.bytes,
    ]);
  }

  Future<Uint8List> _chachaDecrypt({
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List ciphertext,
  }) async {
    if (ciphertext.length < 16) {
      throw AirPlayAuthException('Ciphertext too short for ChaCha20-Poly1305');
    }
    final algorithm = Chacha20.poly1305Aead();
    final mac = Mac(ciphertext.sublist(ciphertext.length - 16));
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final secretBox = SecretBox(ct, nonce: nonce, mac: mac);
    final plaintext = await algorithm.decrypt(
      secretBox,
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(plaintext);
  }

  Uri _uri(String path) => Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
      );

  /// Closes the underlying HTTP client.
  void close() => _httpClient.close();

  Map<String, String> get _defaultHeaders => {
        'User-Agent': 'AirPlay/320.20',
        'Connection': 'keep-alive',
        'X-Apple-HKP': '3',
      };
}

/// Exception thrown during AirPlay HAP authentication.
class AirPlayAuthException implements Exception {
  final String message;
  AirPlayAuthException(this.message);

  @override
  String toString() => 'AirPlayAuthException: $message';
}
