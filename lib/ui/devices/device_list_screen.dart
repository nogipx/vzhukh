import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/remote_device.dart';
import '../../remote/device_discovery.dart';
import '../../storage/device_repository.dart';
import 'remote_control_screen.dart';

/// Televisions this phone can drive.
class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  final _repo = DeviceRepository();

  List<RemoteDevice> _devices = [];
  final _found = <DiscoveredDevice>[];
  StreamSubscription<DiscoveredDevice>? _scan;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scan?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final devices = await _repo.getDevices();
    if (mounted) setState(() => _devices = devices);
  }

  void _startScan() {
    _scan?.cancel();
    setState(() {
      _scanning = true;
      _found.clear();
    });

    _scan = const DiscoverDevices()().listen(
      (device) {
        final known = _devices.any((d) => d.host == device.host);
        if (!known && mounted) setState(() => _found.add(device));
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      onError: (_) {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  Future<void> _save(String host, String name) async {
    final device = RemoteDevice(
      id: 'dev_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      host: host,
    );
    await _repo.saveDevice(device);
    _found.removeWhere((f) => f.host == host);
    await _load();
  }

  Future<void> _addManually() async {
    final hostCtrl = TextEditingController();
    final nameCtrl = TextEditingController(text: 'TV');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add device'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: hostCtrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '192.168.0.168',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (ok == true && hostCtrl.text.trim().isNotEmpty) {
      await _save(hostCtrl.text.trim(), nameCtrl.text.trim());
    }
  }

  Future<void> _open(RemoteDevice device) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => RemoteControlScreen(device: device)),
    );
    await _load();
  }

  Future<void> _delete(RemoteDevice device) async {
    await _repo.deleteDevice(device.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.radar),
            tooltip: 'Scan the network',
            onPressed: _scanning ? null : _startScan,
          ),
        ],
      ),
      body: ListView(
        children: [
          if (_devices.isEmpty && _found.isEmpty && !_scanning)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.tv_outlined,
                    size: 56,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No devices yet.\n\nTurn on network debugging on the TV, '
                    'then scan.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),

          for (final device in _devices)
            ListTile(
              leading: const Icon(Icons.tv),
              title: Text(device.name),
              subtitle: Text(
                '${device.host}:${device.port}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(device),
              ),
              onTap: () => _open(device),
            ),

          if (_found.isNotEmpty) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text(
                'Found on the network',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            for (final device in _found)
              ListTile(
                leading: const Icon(Icons.add_circle_outline),
                title: Text(
                  device.host,
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
                subtitle: const Text('ADB port open'),
                onTap: () => _save(device.host, device.host),
              ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addManually,
        child: const Icon(Icons.add),
      ),
    );
  }
}
