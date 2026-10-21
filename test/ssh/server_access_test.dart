import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/ssh/connection_manager.dart';
import 'package:vzhukh/ssh/server_access.dart';

void main() {
  test('a note survives the comment field: no colon or newline in it', () {
    final note = UserNote(
      kind: AccessKind.friend,
      label: "Alice's phone: new\nline",
      createdAt: DateTime.utc(2026, 10, 20, 12),
      createdBy: 'nogipx-macbook',
    );
    final encoded = note.encode();
    expect(encoded, isNot(contains(':')));
    expect(encoded, isNot(contains('\n')));
    final back = UserNote.decode(encoded)!;
    expect([back.kind, back.label, back.createdBy], [AccessKind.friend, note.label, 'nogipx-macbook']);
    expect(back.createdAt.toUtc(), note.createdAt);
    expect(UserNote.decode('Alice,,,'), isNull);
    expect(UserNote.decode(''), isNull);
  });

  test('the user list reads users and counts sessions by uid', () {
    final note = UserNote(kind: AccessKind.device, label: 'Pixel', createdAt: DateTime.utc(2026, 10, 1)).encode();
    final out = [
      'S\t0\t140',
      'S\t1001\t2',
      'U\tvzhukh_owner\t1001\tSHA256:abc\t${UserNote(kind: AccessKind.owner, label: 'Owner', createdAt: DateTime.utc(2026)).encode()}',
      'U\tvzhukh_pixel\t1002\tSHA256:def\t$note',
      'U\tvzhukh_old\t1003\t\t',
      '',
    ].join('\n');
    final users = ListServerUsers.parse(out);
    expect(users.map((u) => u.username), ['vzhukh_old', 'vzhukh_owner', 'vzhukh_pixel']);

    final old = users[0], owner = users[1], pixel = users[2];
    expect([old.note, old.fingerprint, old.sessions, old.lastLogin], [null, null, 0, null]);
    expect([owner.note!.kind, owner.sessions, owner.fingerprint], [AccessKind.owner, 2, 'SHA256:abc']);
    expect([pixel.note!.label, pixel.sessions], ['Pixel', 0]);
    expect(pixel.copyWith(lastLogin: DateTime(2026)).note!.label, 'Pixel');
  });

  test('last logins read the journal first, else an auth log in either date form', () {
    final now = DateTime(2026, 10, 21);
    final logins = FindLastLogins.parse(
      [
        'L\tvzhukh_owner\t1792531453.123456',
        'L\tvzhukh_owner\t1700000000.0',
        'A\tvzhukh_pixel\tOct 19 08:15:02',
        'A\tvzhukh_tv\t2026-10-20T12:00:01.123+03:00',
        'junk',
      ].join('\n'),
      now: now,
    );
    expect(logins['vzhukh_owner'], DateTime.fromMillisecondsSinceEpoch(1792531453123), reason: 'the newest, met first');
    expect(logins['vzhukh_pixel'], DateTime(2026, 10, 19, 8, 15, 2));
    expect(logins['vzhukh_tv'], DateTime.parse('2026-10-20T12:00:01.123+03:00').toLocal());
  });

  test('an auth log date later than now is last year', () {
    final logins = FindLastLogins.parse('A\tvzhukh_x\tDec 31 23:00:00', now: DateTime(2026, 1, 2));
    expect(logins['vzhukh_x'], DateTime(2025, 12, 31, 23));
  });

  test('usernames are vzhukh_ and a slug', () {
    expect(usernameFromLabel("Alice's phone"), 'vzhukh_alice_s_phone');
    expect(usernameFromLabel('!!!'), 'vzhukh_user');
  });
}
