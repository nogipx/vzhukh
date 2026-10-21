import 'dart:convert';

import 'admin_session.dart';

/// Whose a user on a server is.
enum AccessKind {
  /// The person who set the server up.
  owner('owner'),

  /// One of the owner's devices, with its own key (a kept copy).
  device('device'),

  /// Somebody the owner invited.
  friend('friend');

  const AccessKind(this.code);
  final String code;

  static AccessKind? byCode(String? code) => values.where((k) => k.code == code).firstOrNull;
}

/// What a user is, written on the server itself in the user's comment
/// field, so every device with admin access reads the same. The field
/// cannot hold a colon or a newline; names go in base64url.
class UserNote {
  const UserNote({required this.kind, required this.label, required this.createdAt, this.createdBy = ''});

  final AccessKind kind;
  final String label;
  final DateTime createdAt;

  /// The device that made the user.
  final String createdBy;

  static const _magic = 'vzhukh1';

  static String _b64(String s) => base64Url.encode(utf8.encode(s)).replaceAll('=', '');
  static String _unb64(String s) => utf8.decode(base64Url.decode(base64Url.normalize(s)));

  String encode() => [
        _magic,
        'k=${kind.code}',
        't=${createdAt.toUtc().millisecondsSinceEpoch ~/ 1000}',
        'l=${_b64(label)}',
        if (createdBy.isNotEmpty) 'b=${_b64(createdBy)}',
      ].join(';');

  /// Null for a comment vzhukh did not write.
  static UserNote? decode(String comment) {
    final parts = comment.trim().split(';');
    if (parts.isEmpty || parts.first != _magic) return null;
    final f = {
      for (final p in parts.skip(1))
        if (p.indexOf('=') case final i when i > 0) p.substring(0, i): p.substring(i + 1),
    };
    final kind = AccessKind.byCode(f['k']);
    final t = int.tryParse(f['t'] ?? '');
    if (kind == null || t == null) return null;
    try {
      return UserNote(
        kind: kind,
        label: _unb64(f['l'] ?? ''),
        createdAt: DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: true).toLocal(),
        createdBy: f['b'] == null ? '' : _unb64(f['b']!),
      );
    } on FormatException {
      return null;
    }
  }
}

/// A vzhukh user as the server has it.
class ServerUser {
  const ServerUser({
    required this.username,
    required this.note,
    required this.fingerprint,
    required this.sessions,
    this.lastLogin,
  });

  final String username;

  /// Null for a user made before notes were written, or by hand.
  final UserNote? note;

  /// SHA256 fingerprint of its key, as `ssh-keygen -l` prints it.
  final String? fingerprint;

  /// Processes running as the user: its open SSH sessions.
  final int sessions;

  /// The last key login the server's log remembers (FindLastLogins).
  final DateTime? lastLogin;

  ServerUser copyWith({UserNote? note, DateTime? lastLogin}) => ServerUser(
        username: username,
        note: note ?? this.note,
        fingerprint: fingerprint,
        sessions: sessions,
        lastLogin: lastLogin ?? this.lastLogin,
      );
}

/// Every vzhukh user on a server, with who it is and whether it is
/// connected. One quick command: the server's log, which is slow to read,
/// is left to [FindLastLogins].
class ListServerUsers {
  const ListServerUsers();

  // U: user, uid, key fingerprint, comment. S: uid, processes. One ps for
  // all users, counted by uid: names longer than ps's column get cut.
  static const _script = r'''
ps -eo uid= | awk '{n[$1]++} END {for (u in n) printf "S\t%s\t%d\n", u, n[u]}'
getent passwd | while IFS=: read -r u _ id _ c h _; do
  case "$u" in vzhukh_*) ;; *) continue ;; esac
  fp=$(ssh-keygen -lf "$h/.ssh/authorized_keys" 2>/dev/null | awk 'NR == 1 {print $2}')
  printf 'U\t%s\t%s\t%s\t%s\n' "$u" "$id" "$fp" "$c"
done
''';

  Future<List<ServerUser>> call(AdminShell shell) async => parse(await shell.run(_script));

  /// Reads what [_script] printed. Public for tests.
  static List<ServerUser> parse(String out) {
    final users = <List<String>>[];
    final processes = <String, int>{};
    for (final line in const LineSplitter().convert(out)) {
      final f = line.split('\t');
      switch (f.first) {
        case 'U' when f.length >= 5:
          users.add(f);
        case 'S' when f.length >= 3:
          processes[f[1]] = int.tryParse(f[2]) ?? 0;
      }
    }
    return [
      for (final f in users)
        ServerUser(
          username: f[1],
          note: UserNote.decode(f.sublist(4).join('\t')),
          fingerprint: f[3].isEmpty ? null : f[3],
          sessions: processes[f[2]] ?? 0,
        ),
    ]..sort((a, b) => a.username.compareTo(b.username));
  }
}

/// When each of some users last logged in with its key, from the server's
/// log of the last two weeks. The log is read newest first and reading
/// stops once every user is found, so it is quick while they are active;
/// a public server's log is mostly bots knocking, and reading all of it
/// takes seconds.
class FindLastLogins {
  const FindLastLogins();

  static String _script(int want) => '''
out=\$(journalctl -r --since "14 days ago" -t sshd -t sshd-session -o short-unix --no-pager 2>/dev/null |
  awk -v want=$want '/Accepted publickey for vzhukh_/ {
    for (i = 1; i <= NF; i++) if (\$i == "for") { u = \$(i+1); if (!(u in seen)) { seen[u] = 1; printf "L\\t%s\\t%s\\n", u, \$1; if (++n >= want) exit } }
  }')
if [ -n "\$out" ]; then printf '%s\\n' "\$out"; exit 0; fi
for f in /var/log/auth.log /var/log/secure; do
  [ -r "\$f" ] && tac "\$f" | awk -v want=$want '/Accepted publickey for vzhukh_/ {
    for (i = 1; i <= NF; i++) if (\$i == "for") { u = \$(i+1); if (!(u in seen)) { seen[u] = 1; printf "A\\t%s\\t%s\\n", u, (\$1 ~ /^[0-9][0-9][0-9][0-9]-/ ? \$1 : \$1" "\$2" "\$3); if (++n >= want) exit } }
  }'
done
true
''';

  Future<Map<String, DateTime>> call(AdminShell shell, int users) async =>
      users == 0 ? const {} : parse(await shell.run(_script(users)), now: DateTime.now());

  /// Reads what the script printed. Public for tests.
  static Map<String, DateTime> parse(String out, {required DateTime now}) {
    final last = <String, DateTime>{};
    for (final line in const LineSplitter().convert(out)) {
      final f = line.split('\t');
      if (f.length < 3 || last.containsKey(f[1])) continue;
      final t = switch (f.first) {
        'L' => switch (double.tryParse(f[2])) {
            final secs? => DateTime.fromMillisecondsSinceEpoch((secs * 1000).round()),
            null => null,
          },
        'A' => _authLogTime(f[2], now),
        _ => null,
      };
      if (t != null) last[f[1]] = t;
    }
    return last;
  }

  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// "2026-10-20T12:00:01.123+03:00" from newer syslogs, "Oct 20 12:00:01"
  /// (no year: this one or the last) from older.
  static DateTime? _authLogTime(String s, DateTime now) {
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso.toLocal();
    final p = s.split(RegExp(r'\s+'));
    if (p.length < 3) return null;
    final month = _months.indexOf(p[0]) + 1;
    final day = int.tryParse(p[1]);
    final hms = p[2].split(':').map(int.tryParse).toList();
    if (month == 0 || day == null || hms.length != 3 || hms.contains(null)) return null;
    var t = DateTime(now.year, month, day, hms[0]!, hms[1]!, hms[2]!);
    if (t.isAfter(now.add(const Duration(days: 1)))) t = DateTime(now.year - 1, month, day, hms[0]!, hms[1]!, hms[2]!);
    return t;
  }
}

/// Writes [note] on a user, for one made before notes were, or renamed.
class NoteServerUser {
  const NoteServerUser();

  Future<void> call(AdminShell shell, String username, UserNote note) =>
      shell.run('usermod -c ${AdminShell.quote(note.encode())} ${AdminShell.quote(username)}');
}

/// Ends a user's sessions and deletes it. Its open tunnels drop at once
/// rather than whenever they next reconnect.
class RemoveServerUser {
  const RemoveServerUser();

  Future<void> call(AdminShell shell, String username) async {
    if (!username.startsWith('vzhukh_')) {
      throw ArgumentError('Only vzhukh users are removed here, not "$username"');
    }
    final u = AdminShell.quote(username);
    // userdel refuses a user that still runs anything: kill, then wait for
    // the processes to be gone rather than for a fixed time.
    await shell.run('pkill -KILL -u $u; for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -u $u >/dev/null || break; sleep 0.1; done; userdel -r $u');
  }
}
