import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/remote_device.dart';
import '../../remote/adb_identity.dart';
import '../../remote/own_apk.dart';
import '../../remote/tv_remote.dart';
import '../../remote/uhid.dart';
import '../common/widgets.dart';
import '../theme/app_theme.dart';
import 'remote_buttons.dart';

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
      if (mounted) showToast(context, '$e', error: true);
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
                    style: Theme.of(ctx).textTheme.bodyMedium,
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (apps != null) return;
  }

  /// Sends text to the focused field on the TV.
  ///
  /// Pre-filled from the clipboard, which is the common case: a password or a
  /// link copied on the phone, going somewhere typing it with a remote would
  /// be miserable.
  Future<void> _sendText() async {
    final remote = _remote;
    if (remote == null) return;

    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final controller = TextEditingController(text: clip?.text ?? '');

    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send text'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: null,
              decoration: InputDecoration(
                hintText: 'Text to type on the TV',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste),
                  tooltip: 'Paste',
                  onPressed: () async {
                    final data =
                        await Clipboard.getData(Clipboard.kTextPlain);
                    if (data?.text != null) controller.text = data!.text!;
                  },
                ),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Goes to whatever field is focused on the TV.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (text == null || text.isEmpty) return;
    await _guard(() => remote.typeText(text));
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
        showToast(context, result.isEmpty ? 'Installed' : result);
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
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
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
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Network debugging has to be on, and the prompt on the TV '
                'accepted once.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: AppSpacing.lg),
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
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              Icon(
                connected ? Icons.circle : Icons.circle_outlined,
                size: 12,
                color: connected ? AppColors.of(context).success : AppColors.of(context).warning,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(_status),
            ],
          ),
        ),
        // Above the touchpad: these open something rather than steer it, and
        // keeping them clear of the thumb's working area stops a stray press
        // from launching an app mid-drag.
        _buildSystemRow(connected),
        Expanded(child: _buildTouchpad(connected)),
        _buildControls(connected),
        const SizedBox(height: AppSpacing.lg),
      ],
    );
  }

  /// The cross and the volume column side by side: both are held with the
  /// thumb, and volume is adjusted while looking at the screen, not the phone.
  Widget _buildControls(bool connected) {
    final remote = _remote;
    void key(Future<void> Function() action) {
      if (remote != null) action().catchError((_) {});
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          DirectionPad(
            enabled: connected,
            onUp: () => key(() => remote!.tapKey(HidKey.up)),
            onDown: () => key(() => remote!.tapKey(HidKey.down)),
            onLeft: () => key(() => remote!.tapKey(HidKey.left)),
            onRight: () => key(() => remote!.tapKey(HidKey.right)),
            onSelect: () => key(() => remote!.tapKey(HidKey.enter)),
            onBack: () => key(() => remote!.back()),
            onHome: () => key(() => remote!.home()),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RemoteKey(
                icon: Icons.volume_up,
                enabled: connected,
                onPressed: () => key(() => remote!.volumeUp()),
              ),
              const SizedBox(height: AppSpacing.sm),
              RemoteKey(
                icon: Icons.volume_off,
                enabled: connected,
                repeats: false,
                onPressed: () => key(() => remote!.mute()),
              ),
              const SizedBox(height: AppSpacing.sm),
              RemoteKey(
                icon: Icons.volume_down,
                enabled: connected,
                onPressed: () => key(() => remote!.volumeDown()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemRow(bool connected) {
    final remote = _remote;
    void act(Future<void> Function() action) {
      if (remote != null) _guard(action);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          RemoteKey(
            icon: Icons.keyboard_outlined,
            size: 56,
            repeats: false,
            enabled: connected,
            onPressed: connected ? _sendText : null,
          ),
          RemoteKey(
            icon: Icons.settings_outlined,
            size: 56,
            repeats: false,
            enabled: connected,
            onPressed: () => act(() => remote!.openSettings()),
          ),
          RemoteKey(
            icon: Icons.apps,
            size: 56,
            repeats: false,
            enabled: connected,
            onPressed: connected ? _showApps : null,
          ),
          // Sending Vzhukh to a TV means having an Android package to send,
          // which only the Android build does.
          if (Platform.isAndroid)
            RemoteKey(
              icon: Icons.download,
              size: 56,
              repeats: false,
              enabled: connected,
              onPressed: connected ? _installVzhukh : null,
            ),
        ],
      ),
    );
  }

  Widget _buildTouchpad(bool connected) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: GestureDetector(
        onPanUpdate: connected ? _onPan : null,
        onTap: connected ? () => _guard(() => _remote!.click()) : null,
        onLongPress:
            connected ? () => _guard(() => _remote!.click(mask: 2)) : null,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppRadius.lg),
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

}
