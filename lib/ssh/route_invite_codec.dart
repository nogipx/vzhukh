import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class RouteHopData {
  final String host;
  final int port;
  final String nickname;
  final String username;
  final String privateKeyPem;

  const RouteHopData({
    required this.host,
    required this.port,
    required this.nickname,
    required this.username,
    required this.privateKeyPem,
  });

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'nickname': nickname,
        'username': username,
        'privateKeyPem': privateKeyPem,
      };

  factory RouteHopData.fromJson(Map<String, dynamic> json) => RouteHopData(
        host: json['host'] as String,
        port: json['port'] as int,
        nickname: json['nickname'] as String,
        username: json['username'] as String,
        privateKeyPem: json['privateKeyPem'] as String,
      );
}

class RouteInvitePayload {
  final String label;
  final List<RouteHopData> hops;

  const RouteInvitePayload({required this.label, required this.hops});

  Map<String, dynamic> toJson() => {
        'v': 1,
        'label': label,
        'hops': hops.map((h) => h.toJson()).toList(),
      };

  factory RouteInvitePayload.fromJson(Map<String, dynamic> json) =>
      RouteInvitePayload(
        label: json['label'] as String,
        hops: (json['hops'] as List)
            .map((h) => RouteHopData.fromJson(Map<String, dynamic>.from(h as Map)))
            .toList(),
      );
}

/// Same PBKDF2-SHA256 + AES-256-GCM encryption as [InviteCodec],
/// but payload is a full [RouteInvitePayload] (multi-hop route).
///
/// Wire format: base64url(salt16 + nonce12 + ciphertext+GCM_tag)
class RouteInviteCodec {
  static const _saltLength = 16;
  static const _nonceLength = 12;
  static const _keyLength = 32;
  static const _tagLength = 128;
  static const _pbkdf2Iterations = 100000;

  const RouteInviteCodec();

  String encode(RouteInvitePayload payload, String password) {
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

  RouteInvitePayload decode(String encoded, String password) {
    final bytes = base64Url.decode(encoded);

    if (bytes.length < _saltLength + _nonceLength + _tagLength ~/ 8) {
      throw const FormatException('Route invite data is too short');
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
      throw const FormatException('Wrong password or corrupted route invite');
    }

    final json = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    return RouteInvitePayload.fromJson(json);
  }

  Future<String> encodeAsync(RouteInvitePayload payload, String password) =>
      Isolate.run(() => encode(payload, password));

  Future<RouteInvitePayload> decodeAsync(String encoded, String password) =>
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
