import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The plaintext payload embedded in an invite QR.
class InvitePayload {
  final String host;
  final int port;
  final String nickname;
  final String username;
  final String privateKeyPem;

  const InvitePayload({
    required this.host,
    required this.port,
    required this.nickname,
    required this.username,
    required this.privateKeyPem,
  });

  Map<String, dynamic> toJson() => {
        'v': 1,
        'host': host,
        'port': port,
        'nickname': nickname,
        'username': username,
        'privateKeyPem': privateKeyPem,
      };

  factory InvitePayload.fromJson(Map<String, dynamic> json) => InvitePayload(
        host: json['host'] as String,
        port: json['port'] as int,
        nickname: json['nickname'] as String,
        username: json['username'] as String,
        privateKeyPem: json['privateKeyPem'] as String,
      );
}

/// Encrypts and decrypts [InvitePayload] using PBKDF2-SHA256 + AES-256-GCM.
///
/// Wire format (all concatenated, then base64url-encoded):
///   [16 bytes salt][12 bytes nonce][ciphertext + 16 bytes GCM tag]
class InviteCodec {
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _keyLength = 32; // AES-256
  static const _tagLength = 128; // bits
  static const _pbkdf2Iterations = 100000;

  const InviteCodec();

  /// Returns a base64url string suitable for embedding in a QR code.
  String encode(InvitePayload payload, String password) {
    final salt = _randomBytes(_saltLength);
    final nonce = _randomBytes(_nonceLength);
    final key = _deriveKey(password, salt);

    final plaintext = Uint8List.fromList(
      utf8.encode(jsonEncode(payload.toJson())),
    );

    final cipher = GCMBlockCipher(AESEngine())
      ..init(
        true,
        AEADParameters(KeyParameter(key), _tagLength, nonce, Uint8List(0)),
      );
    final ciphertext = cipher.process(plaintext);

    final out = BytesBuilder()
      ..add(salt)
      ..add(nonce)
      ..add(ciphertext);

    return base64Url.encode(out.takeBytes());
  }

  /// Throws [FormatException] on bad password or corrupted data.
  InvitePayload decode(String encoded, String password) {
    final bytes = base64Url.decode(encoded);

    if (bytes.length < _saltLength + _nonceLength + _tagLength ~/ 8) {
      throw const FormatException('Invite data is too short');
    }

    final salt = bytes.sublist(0, _saltLength);
    final nonce = bytes.sublist(_saltLength, _saltLength + _nonceLength);
    final ciphertext = bytes.sublist(_saltLength + _nonceLength);
    final key = _deriveKey(password, salt);

    final Uint8List plaintext;
    try {
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(KeyParameter(key), _tagLength, nonce, Uint8List(0)),
        );
      plaintext = cipher.process(Uint8List.fromList(ciphertext));
    } catch (_) {
      throw const FormatException('Wrong password or corrupted invite');
    }

    final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    return InvitePayload.fromJson(json);
  }

  Future<String> encodeAsync(InvitePayload payload, String password) =>
      Isolate.run(() => encode(payload, password));

  Future<InvitePayload> decodeAsync(String encoded, String password) =>
      Isolate.run(() => decode(encoded, password));

  Uint8List _deriveKey(String password, Uint8List salt) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(salt, _pbkdf2Iterations, _keyLength));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(
      List.generate(length, (_) => rng.nextInt(256)),
    );
  }
}
