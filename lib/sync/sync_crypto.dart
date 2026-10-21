import 'dart:convert';
import 'dart:math';

import 'package:pinenacl/digests.dart';
import 'package:pinenacl/x25519.dart';

String b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

Uint8List unb64(String s) => base64Url.decode(base64Url.normalize(s));

Uint8List randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

Uint8List _concat(List<List<int>> parts) =>
    Uint8List.fromList([for (final p in parts) ...p]);

/// Pairing by passkey entry, the way a Bluetooth keyboard pairs.
///
/// The device being asked shows a random six-digit passkey; the user types
/// it on the device that asked. Nothing else is confirmed by hand, so there
/// is no button to press without looking: pairing needs someone who saw
/// the other screen.
///
/// The passkey is never sent. Its 20 bits are proven one per round: each
/// side commits to its key, the peer's key, a fresh nonce and the bit, and
/// opens the commitment only after the other side has committed. Someone in
/// the middle has to commit to each bit before learning it, so they pass
/// all 20 rounds with probability 2^-20 and are caught on the first wrong
/// guess. A recorded exchange gives nothing to brute-force offline: every
/// bit is already in it, and none of it is any use for another pairing.
class Passkey {
  const Passkey._();

  static const rounds = 20;

  static int generate() {
    while (true) {
      final b = randomBytes(3);
      final n = ((b[0] << 16) | (b[1] << 8) | b[2]) & 0xFFFFF;
      if (n < 1000000) return n;
    }
  }

  static String format(int passkey) {
    final s = passkey.toString().padLeft(6, '0');
    return '${s.substring(0, 3)} ${s.substring(3)}';
  }

  /// The passkey in [typed], or null when it is not six digits.
  static int? parse(String typed) {
    final digits = typed.replaceAll(RegExp(r'\D'), '');
    return digits.length == 6 ? int.parse(digits) : null;
  }

  static int bit(int passkey, int round) => (passkey >> round) & 1;

  /// [role] is 'i' for the initiator and 'r' for the responder, so neither
  /// side's commitment can be reflected back as the other's.
  static Uint8List commit({
    required String role,
    required Uint8List own,
    required Uint8List peer,
    required Uint8List nonce,
    required int bit,
  }) =>
      Hash.sha256(_concat([
        utf8.encode('vzhukh-passkey-$role'),
        own,
        peer,
        nonce,
        [bit],
      ]));
}

/// Messages between two paired devices: NaCl box between their long-term
/// keys, so only the two of them can read a message and each knows the
/// other wrote it.
class PeerCipher {
  PeerCipher(PrivateKey mine, Uint8List theirs)
      : _box = Box(myPrivateKey: mine, theirPublicKey: PublicKey(theirs));

  final Box _box;

  String seal(Map<String, dynamic> message) =>
      b64(_box.encrypt(Uint8List.fromList(utf8.encode(jsonEncode(message)))));

  /// Throws when the message was not sealed by the peer for this device.
  Map<String, dynamic> open(String sealed) {
    final plain = _box.decrypt(EncryptedMessage.fromList(unb64(sealed)));
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
  }
}
