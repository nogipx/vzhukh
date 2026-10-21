import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The RSA identity this device presents to an ADB daemon.
///
/// The daemon challenges with a 20 byte token; signing it proves we hold the
/// key it was told to trust. On the first connection it has no such key, so it
/// asks for the public one and shows the "Allow debugging" dialog — after
/// which the fingerprint is remembered and the prompt never returns.
class AdbKey {
  AdbKey(this._private, this._public);

  final RSAPrivateKey _private;
  final RSAPublicKey _public;

  static const int _modulusBytes = 256; // RSA-2048

  /// PKCS#1 v1.5 DigestInfo for SHA-1. The token is already a digest, so it is
  /// wrapped rather than hashed again.
  static const List<int> _sha1DigestInfo = [
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e,
    0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
  ];

  static AdbKey generate() {
    final random = FortunaRandom();
    final seed = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    random.seed(KeyParameter(seed));

    final generator = RSAKeyGenerator()
      ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
        random,
      ));

    final pair = generator.generateKeyPair();
    return AdbKey(pair.privateKey, pair.publicKey);
  }

  String toJson() => jsonEncode({
        'n': _private.modulus!.toRadixString(16),
        'e': _public.exponent!.toRadixString(16),
        'd': _private.privateExponent!.toRadixString(16),
        'p': _private.p!.toRadixString(16),
        'q': _private.q!.toRadixString(16),
      });

  static AdbKey fromJson(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    BigInt read(String k) => BigInt.parse(json[k] as String, radix: 16);
    final n = read('n');
    return AdbKey(
      RSAPrivateKey(n, read('d'), read('p'), read('q')),
      RSAPublicKey(n, read('e')),
    );
  }

  /// Signs the daemon's challenge token.
  Uint8List sign(Uint8List token) {
    final digestInfo = Uint8List.fromList([..._sha1DigestInfo, ...token]);

    // EM = 0x00 || 0x01 || 0xFF padding || 0x00 || DigestInfo
    final em = Uint8List(_modulusBytes);
    em[0] = 0x00;
    em[1] = 0x01;
    final padLength = _modulusBytes - digestInfo.length - 3;
    for (var i = 0; i < padLength; i++) {
      em[2 + i] = 0xff;
    }
    em[2 + padLength] = 0x00;
    em.setRange(3 + padLength, _modulusBytes, digestInfo);

    final signature = _bytesToBigInt(em)
        .modPow(_private.privateExponent!, _private.modulus!);
    return _bigIntToBytes(signature, _modulusBytes);
  }

  /// The public key in the layout adb expects: a packed RSAPublicKey struct,
  /// base64 encoded, followed by an identifying comment.
  String publicKeyBlob({String comment = 'vzhukh@android'}) {
    final n = _public.modulus!;
    final e = _public.exponent!;

    // n0inv = -1 / n[0] mod 2^32, used by the bootloader's Montgomery maths.
    final r32 = BigInt.one << 32;
    final n0inv = r32 - (n % r32).modInverse(r32);

    // rr = (2^2048)^2 mod n
    final rr = ((BigInt.one << (_modulusBytes * 8)).pow(2)) % n;

    final blob = BytesBuilder();
    final head = ByteData(8);
    head.setUint32(0, _modulusBytes ~/ 4, Endian.little); // size in words
    head.setUint32(4, n0inv.toInt(), Endian.little);
    blob.add(head.buffer.asUint8List());
    blob.add(_bigIntToBytesLE(n, _modulusBytes));
    blob.add(_bigIntToBytesLE(rr, _modulusBytes));
    final tail = ByteData(4)..setUint32(0, e.toInt(), Endian.little);
    blob.add(tail.buffer.asUint8List());

    return '${base64.encode(blob.takeBytes())} $comment';
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static Uint8List _bigIntToBytesLE(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    for (var i = 0; i < length; i++) {
      out[i] = (v & BigInt.from(0xff)).toInt();
      v = v >> 8;
    }
    return out;
  }
}
