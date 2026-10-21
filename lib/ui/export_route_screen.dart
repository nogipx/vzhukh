import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../models/tunnel_route.dart';
import '../ssh/connection_manager.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/server_repository.dart';
import '../sync/lan_sync.dart';
import 'admin_access.dart';
import 'common/widgets.dart';
import 'theme/app_theme.dart';

/// A route in a QR code for somebody else. Every server on it gets a new
/// user and key for them, made now with that server's admin password, so
/// their access shows on the Access screen under their name and can be
/// revoked without touching anyone else's. This device's own keys never
/// leave it.
class ExportRouteScreen extends StatefulWidget {
  final TunnelRoute route;

  const ExportRouteScreen({super.key, required this.route});

  @override
  State<ExportRouteScreen> createState() => _ExportRouteScreenState();
}

class _ExportRouteScreenState extends State<ExportRouteScreen> {
  final _repo = ServerRepository();
  final _codec = const RouteInviteCodec();
  final _passwordCtrl = TextEditingController();
  final _whoCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _obscurePass = true;
  bool _loading = true;
  String? _encoded;
  String? _error;

  List<Server>? _servers;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  @override
  void dispose() {
    _passwordCtrl.dispose();
    _whoCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadServers() async {
    try {
      final all = await _repo.getServers();
      final servers = [
        for (final hop in widget.route.hops)
          all.firstWhere(
            (s) => s.id == hop.serverId,
            orElse: () => throw Exception('Server not found: ${hop.serverId}'),
          ),
      ];
      if (mounted) {
        setState(() {
          _servers = servers;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  bool _generating = false;

  Future<void> _generate() async {
    if (!_formKey.currentState!.validate()) return;
    final servers = _servers;
    if (servers == null) return;
    setState(() {
      _error = null;
      _generating = true;
    });
    final who = _whoCtrl.text.trim();
    final made = <(Server, SshIdentity, Connection)>[];
    try {
      // One user per server, also when a route passes a server twice.
      final keys = <String, Connection>{};
      for (final server in servers) {
        if (keys.containsKey(server.id)) continue;
        if (!mounted) return;
        final admin = await obtainAdminIdentity(context, server);
        if (admin == null) {
          throw Exception(
            'No admin password for "${server.nickname}": nothing was shared.',
          );
        }
        final connection = await AddConnection(_repo)(
          server,
          admin,
          '$who (${widget.route.label})',
          createdBy: LanSync.instance.name,
        );
        made.add((server, admin, connection));
        keys[server.id] = connection;
      }
      final payload = RouteInvitePayload(
        label: widget.route.label,
        hops: [
          for (final server in servers)
            RouteHopData(
              host: server.host,
              port: server.port,
              nickname: server.nickname,
              username: keys[server.id]!.username,
              privateKeyPem: keys[server.id]!.privateKeyPem!,
            ),
        ],
      );
      final encoded = await _codec.encodeAsync(payload, _passwordCtrl.text);
      if (mounted) setState(() => _encoded = encoded);
    } catch (e) {
      // Half a route is no use to anyone: take back the users made so far.
      for (final (server, admin, connection) in made) {
        try {
          await RevokeConnection(_repo)(server, admin, connection);
        } catch (_) {}
      }
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = theme.colorScheme.error;
    return Scaffold(
      appBar: AppBar(title: Text('Export: ${widget.route.label}')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null && _servers == null) ...[
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: error.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: error),
                      ),
                      child: Text(_error!, style: TextStyle(color: error)),
                    ),
                  ] else ...[
                    Text(
                      'Each of the ${_servers!.length} server(s) gets a new user and key for this '
                      'person, so their access can be revoked on its own. The QR is encrypted '
                      'with a password: share the two separately.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: _whoCtrl,
                            enabled: _encoded == null,
                            decoration: const InputDecoration(
                              labelText: 'Who is it for?',
                              hintText: 'Alice',
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Required'
                                : null,
                          ),
                          const SizedBox(height: AppSpacing.md),
                          TextFormField(
                            controller: _passwordCtrl,
                            obscureText: _obscurePass,
                            decoration: InputDecoration(
                              labelText: 'Route password',
                              suffixIcon: IconButton(
                                icon: Icon(
                                  _obscurePass
                                      ? Icons.visibility
                                      : Icons.visibility_off,
                                ),
                                onPressed: () => setState(
                                  () => _obscurePass = !_obscurePass,
                                ),
                              ),
                            ),
                            validator: (v) =>
                                v == null || v.isEmpty ? 'Required' : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    FilledButton(
                      onPressed: _generating || _encoded != null
                          ? null
                          : _generate,
                      child: _generating
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Generate QR'),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(_error!, style: TextStyle(color: error)),
                    ],
                    if (_encoded != null) ...[
                      const SizedBox(height: AppSpacing.xl),
                      Center(
                        child: Container(
                          padding: const EdgeInsets.all(AppSpacing.md),
                          decoration: const BoxDecoration(
                            // Black on white whatever the theme: scanners expect it.
                            color: Color(0xFFFFFFFF),
                            borderRadius: BorderRadius.all(
                              Radius.circular(AppRadius.md),
                            ),
                          ),
                          child: QrImageView(
                            data: _encoded!,
                            version: QrVersions.auto,
                            size: 280,
                            errorCorrectionLevel: QrErrorCorrectLevel.L,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Color(0xFF000000),
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Color(0xFF000000),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      OutlinedButton.icon(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _encoded!));
                          showToast(context, 'Copied to clipboard');
                        },
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy route code'),
                      ),
                    ],
                  ],
                ],
              ),
            ),
    );
  }
}
