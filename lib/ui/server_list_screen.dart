import 'package:flutter/material.dart';
import '../models/server.dart';
import '../network/local_http_server.dart';
import '../storage/server_repository.dart';
import '../vpn/vpn_controller.dart';
import 'add_server_screen.dart';
import 'import_invite_screen.dart';
import 'server_detail_screen.dart';

class ServerListScreen extends StatefulWidget {
  final VpnController vpn;
  final LocalHttpServer server;

  const ServerListScreen({super.key, required this.vpn, required this.server});

  @override
  State<ServerListScreen> createState() => _ServerListScreenState();
}

class _ServerListScreenState extends State<ServerListScreen> {
  final _repo = ServerRepository();
  List<Server> _servers = [];
  String? _localIp;

  @override
  void initState() {
    super.initState();
    _load();
    _resolveIp();
  }

  Future<void> _resolveIp() async {
    final ip = await LocalHttpServer.localIp();
    if (mounted) setState(() => _localIp = ip);
  }

  Future<void> _load() async {
    final servers = await _repo.getServers();
    if (mounted) setState(() => _servers = servers);
  }

  Future<void> _openAdd() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddServerScreen()),
    );
    await _load();
  }

  Future<void> _openDetail(Server server) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ServerDetailScreen(server: server, vpn: widget.vpn)),
    );
    await _load();
  }

  Future<void> _delete(Server server) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete server?'),
        content: Text('Remove "${server.nickname}" and all its keys?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _repo.deleteServer(server.id);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vzhukh'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: 'Import invite',
            onPressed: () async {
              final imported = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const ImportInviteScreen()),
              );
              if (imported == true) await _load();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_localIp != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Row(
                children: [
                  const Icon(Icons.wifi, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    'Receiving on $_localIp:${LocalHttpServer.port}',
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _servers.isEmpty
          ? const Center(
              child: Text(
                'No servers yet.\nTap + to add one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            )
          : ListView.builder(
              itemCount: _servers.length,
              itemBuilder: (_, i) {
                final server = _servers[i];
                return ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(server.nickname),
                  subtitle: Text('${server.host}:${server.port}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(server),
                  ),
                  onTap: () => _openDetail(server),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openAdd,
        child: const Icon(Icons.add),
      ),
    );
  }
}
