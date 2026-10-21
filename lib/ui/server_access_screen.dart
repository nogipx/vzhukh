import 'package:flutter/material.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../ssh/admin_session.dart';
import '../ssh/connection_manager.dart';
import '../ssh/server_access.dart';
import '../storage/server_repository.dart';
import '../sync/lan_sync.dart';
import 'action_sheet.dart';
import 'admin_access.dart';
import 'common/widgets.dart';
import 'export_invite_screen.dart';
import 'theme/app_theme.dart';

/// Who can use a server, read from the server itself: every vzhukh user on
/// it, whose it is, whether it is connected now and when it last was. Here
/// access is given and taken away.
class ServerAccessScreen extends StatefulWidget {
  const ServerAccessScreen({super.key, required this.server});

  final Server server;

  @override
  State<ServerAccessScreen> createState() => _ServerAccessScreenState();
}

class _ServerAccessScreenState extends State<ServerAccessScreen> {
  final _repo = ServerRepository();

  /// Asked once per visit to this screen.
  SshIdentity? _admin;

  /// One login for the whole visit, closed when the screen goes.
  AdminShell? _shell;
  List<ServerUser>? _users;
  List<Connection> _local = [];
  String? _error;
  bool _busy = false;

  /// Still reading the server's log for last logins.
  bool _findingLogins = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _shell?.close();
    super.dispose();
  }

  /// The open shell, logging in when there is none or it dropped. Null
  /// when the admin password is not given.
  Future<AdminShell?> _connect() async {
    final open = _shell;
    if (open != null && !open.isClosed) return open;
    final admin = _admin ??= await obtainAdminIdentity(context, widget.server);
    if (admin == null) return null;
    try {
      return _shell = await AdminShell.open(widget.server, admin);
    } catch (_) {
      // A wrong password stays wrong: ask again next time.
      _admin = null;
      rethrow;
    }
  }

  /// Reads the users, shows them, then fills in last logins as the log
  /// gives them up: the list does not wait on the slow part.
  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final shell = await _connect();
      if (shell == null) {
        if (mounted) setState(() => _error = 'The list is read from the server and needs its admin password.');
        return;
      }
      final users = await const ListServerUsers()(shell);
      final local = await _repo.getConnections(widget.server.id);
      if (!mounted) return;
      setState(() {
        _users = users;
        _local = local;
        _busy = false;
        _findingLogins = true;
      });
      final logins = await const FindLastLogins()(shell, users.length);
      if (!mounted) return;
      setState(() {
        _users = [for (final u in _users ?? users) u.copyWith(lastLogin: logins[u.username])];
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _findingLogins = false;
        });
      }
    }
  }

  /// Runs [action] on the open shell. The list is changed by the caller,
  /// not read again: reading is what is slow.
  Future<bool> _run(String done, Future<void> Function(AdminShell shell) action) async {
    setState(() => _busy = true);
    try {
      final shell = await _connect();
      if (shell == null) return false;
      await action(shell);
      if (mounted) showToast(context, done);
      return true;
    } catch (e) {
      if (mounted) showToast(context, '$e', error: true);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _replace(ServerUser u, ServerUser? by) => setState(() {
        _users = [
          for (final x in _users ?? const <ServerUser>[])
            if (x.username != u.username) x else if (by != null) by,
        ];
      });

  Connection? _localOf(ServerUser u) => _local.where((c) => c.username == u.username).firstOrNull;

  bool _onThisDevice(ServerUser u) => _localOf(u)?.canConnect ?? false;

  String _label(ServerUser u) => u.note?.label ?? _localOf(u)?.label ?? u.username;

  Future<String?> _askLabel(String title, {String initial = '', String hint = "Alice's phone"}) async {
    final ctrl = TextEditingController(text: initial);
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    final trimmed = label?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _invite() async {
    final label = await _askLabel('Invite someone', hint: "Alice, or Alice's phone");
    if (label == null || !mounted) return;
    Connection? made;
    await _run('Access made for $label', (shell) async {
      made = await AddConnection(_repo)(widget.server, _admin!, label, createdBy: LanSync.instance.name, shell: shell);
      // Only the quick part is read again; last logins stay as they were.
      final users = await const ListServerUsers()(shell);
      final logins = {for (final u in _users ?? const <ServerUser>[]) u.username: u.lastLogin};
      final local = await _repo.getConnections(widget.server.id);
      if (mounted) {
        setState(() {
          _users = [for (final u in users) u.copyWith(lastLogin: logins[u.username])];
          _local = local;
        });
      }
    });
    final connection = made;
    if (connection == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ExportInviteScreen(server: widget.server, connection: connection)),
    );
  }

  /// Writes a name and kind on the server, and on the local record if any.
  Future<void> _note(ServerUser u, {String? label, AccessKind? kind}) async {
    final old = u.note;
    final note = UserNote(
      kind: kind ?? old?.kind ?? AccessKind.friend,
      label: label ?? _label(u),
      createdAt: old?.createdAt ?? DateTime.now(),
      createdBy: old?.createdBy ?? '',
    );
    final saved = await _run('Saved', (shell) async {
      await const NoteServerUser()(shell, u.username, note);
      final local = _localOf(u);
      if (local != null && local.label != note.label) {
        await _repo.saveConnection(Connection(
          id: local.id,
          serverId: local.serverId,
          label: note.label,
          username: local.username,
          publicKeyOpenSSH: local.publicKeyOpenSSH,
          privateKeyPem: local.privateKeyPem,
          createdAt: local.createdAt,
        ));
        _local = await _repo.getConnections(widget.server.id);
      }
    });
    if (saved && mounted) _replace(u, u.copyWith(note: note));
  }

  Future<void> _revoke(ServerUser u) async {
    final mine = _onThisDevice(u);
    final ok = await confirmDestructive(
      context,
      title: 'Revoke ${_label(u)}?',
      message: mine
          ? 'This is the key this device connects with. It stops working at once, '
              'and this device can no longer use the server.'
          : '${u.username} is deleted from the server and its open connections are cut now.',
      confirmLabel: 'Revoke',
    );
    if (!ok) return;
    final local = _localOf(u);
    final revoked = await _run('Revoked ${_label(u)}', (shell) async {
      await const RemoveServerUser()(shell, u.username);
      if (local != null) await _repo.deleteConnection(local);
    });
    if (revoked && mounted) {
      _replace(u, null);
      if (local != null) setState(() => _local = [for (final c in _local) if (c.id != local.id) c]);
    }
  }

  Future<void> _actions(ServerUser u) => showActionSheet(
        context,
        title: _label(u),
        actions: [
          SheetAction('Rename', () async {
            final label = await _askLabel('Rename', initial: _label(u));
            if (label != null) await _note(u, label: label);
          }, icon: Icons.edit_outlined),
          for (final k in AccessKind.values)
            SheetAction(
              switch (k) {
                AccessKind.owner => 'Mark as the owner',
                AccessKind.device => 'Mark as one of my devices',
                AccessKind.friend => 'Mark as someone I invited',
              },
              () => _note(u, kind: k),
              checked: u.note?.kind == k,
            ),
          SheetAction('Revoke', () => _revoke(u), icon: Icons.person_remove_outlined, destructive: true),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final users = _users;
    final groups = <(String, List<ServerUser>)>[
      ('This device', [...?users?.where(_onThisDevice)]),
      ('Yours', [
        ...?users?.where((u) =>
            !_onThisDevice(u) && (u.note?.kind == AccessKind.owner || u.note?.kind == AccessKind.device)),
      ]),
      ('Invited', [...?users?.where((u) => !_onThisDevice(u) && u.note?.kind == AccessKind.friend)]),
      ('Unknown', [...?users?.where((u) => !_onThisDevice(u) && u.note == null)]),
    ];
    final online = users?.where((u) => u.sessions > 0).length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text('Access to ${widget.server.nickname}'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), tooltip: 'Read again', onPressed: _busy ? null : _load),
        ],
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      floatingActionButton: users == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _busy ? null : _invite,
              icon: const Icon(Icons.person_add_alt),
              label: const Text('Invite'),
            ),
      body: users == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    EmptyState(icon: Icons.lock_outline, title: 'Could not read the users', message: _error),
                    FilledButton(onPressed: _load, child: const Text('Try again')),
                  ],
                ))
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                  child: Text(
                    '${users.length} with access · $online connected now',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
                for (final (title, list) in groups)
                  if (list.isNotEmpty) ...[
                    SectionHeader(title),
                    for (final u in list)
                      _UserTile(user: u, label: _label(u), findingLogins: _findingLogins, onTap: () => _actions(u)),
                  ],
              ],
            ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.label, required this.findingLogins, required this.onTap});

  final ServerUser user;
  final String label;

  /// Last logins are still being read from the server's log.
  final bool findingLogins;
  final VoidCallback onTap;

  static String _date(DateTime t) =>
      '${t.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][t.month - 1]} ${t.year}';

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final note = user.note;
    final fp = user.fingerprint;
    final (status, color) = user.sessions > 0
        ? ('connected', colors.success)
        : user.lastLogin != null
            ? ('seen ${_ago(user.lastLogin!)}', colors.muted)
            : findingLogins
                ? ('…', colors.muted)
                : ('not seen in 14 days', colors.muted);
    return ListTile(
      onTap: onTap,
      leading: Icon(switch (note?.kind) {
        AccessKind.owner => Icons.key_outlined,
        AccessKind.device => Icons.devices,
        AccessKind.friend => Icons.person_outline,
        null => Icons.help_outline,
      }),
      title: Text(label),
      subtitle: Text(
        [
          user.username + (fp == null ? '' : ' · ${fp.replaceFirst('SHA256:', '').characters.take(8)}'),
          if (note != null) 'made ${_date(note.createdAt)}${note.createdBy.isEmpty ? '' : ' on ${note.createdBy}'}',
        ].join('\n'),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      isThreeLine: note != null,
      trailing: Text(status, style: theme.textTheme.bodySmall?.copyWith(color: color)),
    );
  }
}
