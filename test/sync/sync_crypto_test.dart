import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/sync/sync_crypto.dart';

void main() {
  group('passkey', () {
    test('six digits, read back the way they were shown', () {
      for (var i = 0; i < 200; i++) {
        final p = Passkey.generate();
        expect(p, inInclusiveRange(0, 999999));
        expect(Passkey.parse(Passkey.format(p)), p);
      }
      expect(Passkey.parse('12345'), isNull);
    });

    test('a commitment depends on the role, the keys and the bit', () {
      final a = randomBytes(32), b = randomBytes(32), n = randomBytes(16);
      final c = Passkey.commit(role: 'i', own: a, peer: b, nonce: n, bit: 1);
      expect(Passkey.commit(role: 'i', own: a, peer: b, nonce: n, bit: 1), c);
      expect(Passkey.commit(role: 'i', own: a, peer: b, nonce: n, bit: 0), isNot(c));
      expect(Passkey.commit(role: 'r', own: a, peer: b, nonce: n, bit: 1), isNot(c));
      expect(Passkey.commit(role: 'i', own: b, peer: a, nonce: n, bit: 1), isNot(c));
    });
  });

}
