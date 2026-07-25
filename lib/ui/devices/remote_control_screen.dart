import 'package:flutter/material.dart';

import '../../models/remote_device.dart';
import '../../remote/adb_identity.dart';
import '../../remote/own_apk.dart';
import '../../remote/tv_remote.dart';
import '../../remote/uhid.dart';

/// Touchpad, buttons and app launcher for one television.
class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key, required this.device});

  final RemoteDevice device;

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  TvRemote? _remote;
  String _status = 'Connecting…';
  String? _error;
  bool _busy = false;

  // Pointer deltas are accumulated and flushed at whatever rate the link
  // sustains, rather than queueing a message per touch event.
  double _pendingX = 0;
  double _pendingY = 0;
  bool _flushing = false;

  static const double _sensitivity = 1.6;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  @override
  void dispose() {
    _remote?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    try {
      setState(() {
        _status = 'Preparing the key…';
        _error = null;
      });
      final key = await const LoadAdbIdentity()();

      setState(() => _status = 'Connecting to ${widget.device.host}…');
      final remote = await TvRemote.connect(
        host: widget.device.host,
        port: widget.device.port,
        key: key,
        onWaitingForAuth: () {
          if (mounted) {
            setState(() => _status = 'Confirm the prompt on the TV');
          }
        },
      );

      if (!mounted) {
        await remote.close();
        return;
      }
      setState(() {
        _remote = remote;
        _status = 'Connected';
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onPan(DragUpdateDetails details) {
    _pendingX += details.delta.dx * _sensitivity;
    _pendingY += details.delta.dy * _sensitivity;
    _flush();
  }

  Future<void> _flush() async {
    final remote = _remote;
    if (remote == null || _flushing) return;

    final dx = _pendingX.truncate();
    final dy = _pendingY.truncate();
    if (dx == 0 && dy == 0) return;

    _pendingX -= dx;
    _pendingY -= dy;
    _flushing = true;
    try {
      await remote.moveBy(dx, dy);
    } catch (_) {
      // A dropped move is not worth surfacing; the next one will land.
    }
    _flushing = false;
    if (_pendingX.abs() >= 1 || _pendingY.abs() >= 1) _flush();
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_remote == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showApps() async {
    final remote = _remote;
    if (remote == null) return;

    final apps = await showDialog<List<InstalledApp>>(
      context: context,
      builder: (ctx) => FutureBuilder<List<InstalledApp>>(
        future: remote.listApps(),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const AlertDialog(
              content: SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              ),
            );
          }
          return SimpleDialog(
            title: const Text('Launch an app'),
            children: [
              for (final app in snap.data!)
                SimpleDialogOption(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _guard(() => remote.launch(app.packageName));
                  },
                  child: Text(
                    app.label,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (apps != null) return;
  }

  Future<void> _installVzhukh() async {
    final remote = _remote;
    if (remote == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Install Vzhukh on the TV?'),
        content: const Text(
          'Sends the copy installed on this phone. It is a large file, so '
          'expect this to take a minute or two.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Install'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _guard(() async {
      setState(() => _status = 'Reading the package…');
      final apk = await const ReadOwnApk()();
      setState(() => _status = 'Sending ${(apk.length / 1048576).round()} MB…');
      final result = await remote.installApk(apk);
      if (mounted) {
        setState(() => _status = 'Connected');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.isEmpty ? 'Installed' : result)),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: _error != null ? _buildError() : _buildBody(),
    );
  }

  Widget _buildError() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 16),
              const Text(
                'Network debugging has to be on, and the prompt on the TV '
                'accepted once.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 24),
              FilledButton(onPressed: _connect, child: const Text('Retry')),
            ],
          ),
        ),
      );

  Widget _buildBody() {
    final connected = _remote != null;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(
                connected ? Icons.circle : Icons.circle_outlined,
                size: 12,
                color: connected ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 8),
              Text(_status),
            ],
          ),
        ),
        Expanded(child: _buildTouchpad(connected)),
        _buildDpad(connected),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: connected ? _showApps : null,
                  icon: const Icon(Icons.apps),
                  label: const Text('Apps'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: connected ? _installVzhukh : null,
                  icon: const Icon(Icons.download),
                  label: const Text('Install'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildTouchpad(bool connected) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: GestureDetector(
        onPanUpdate: connected ? _onPan : null,
        onTap: connected ? () => _guard(() => _remote!.click()) : null,
        onLongPress:
            connected ? () => _guard(() => _remote!.click(mask: 2)) : null,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Center(
            child: Text(
              connected
                  ? 'Drag to move\nTap to click · hold for right click'
                  : 'Not connected',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDpad(bool connected) {
    Widget key(IconData icon, int usage, {double size = 48}) => IconButton(
          iconSize: size * 0.5,
          icon: Icon(icon),
          onPressed:
              connected ? () => _guard(() => _remote!.tapKey(usage)) : null,
        );

    return Column(
      children: [
        key(Icons.keyboard_arrow_up, HidKey.up),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            key(Icons.keyboard_arrow_left, HidKey.left),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: connected
                  ? () => _guard(() => _remote!.tapKey(HidKey.enter))
                  : null,
              child: const Text('OK'),
            ),
            const SizedBox(width: 8),
            key(Icons.keyboard_arrow_right, HidKey.right),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            key(Icons.keyboard_arrow_down, HidKey.down),
            const SizedBox(width: 24),
            key(Icons.arrow_back, HidKey.escape),
          ],
        ),
      ],
    );
  }
}
