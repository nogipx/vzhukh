import 'dart:async';

import 'package:flutter/material.dart';

import '../sync/lan_sync.dart';
import '../sync/sync_crypto.dart';
import 'admin_access.dart';
import 'common/widgets.dart';
import 'theme/app_theme.dart';

/// Pairing with the user's other devices and what sync is doing with them.
class LanSyncScreen extends StatelessWidget {
  const LanSyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = LanSync.instance;
    return Scaffold(
      appBar: AppBar(
        title: const Text('My devices'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync now',
            onPressed: sync.syncNow,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: sync,
        builder: (context, _) => ListView(
          children: [
            SwitchListTile(
              title: const Text('Sync over the local network'),
              subtitle: const Text(
                'Find your devices on this network and share servers, routes '
                'and rules with them. Devices on the same network see that '
                'Vzhukh runs here.',
              ),
              value: sync.enabled,
              onChanged: sync.setEnabled,
            ),
            ListTile(
              leading: const Icon(Icons.badge_outlined),
              title: const Text('This device'),
              subtitle: Text(sync.name),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _rename(context),
            ),
            if (sync.error != null)
              ListTile(
                leading: Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
                title: Text(
                  sync.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SectionHeader('Paired'),
            if (sync.paired.isEmpty)
              const _Hint('Nothing paired yet. Pair with a device below.'),
            for (final p in sync.paired) _PairedTile(p),
            const SectionHeader('On this network'),
            if (!sync.running)
              const _Hint('Sync is off.')
            else if (sync.nearby.isEmpty)
              const _Hint(
                'Looking for other devices. Open Vzhukh on them, on the same '
                'network.',
              ),
            for (final d in sync.nearby)
              ListTile(
                leading: const Icon(Icons.devices_other),
                title: Text(d.name),
                trailing: FilledButton.tonal(
                  onPressed: () => pairWithDevice(context, d),
                  child: const Text('Pair'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _rename(BuildContext context) async {
    final ctrl = TextEditingController(text: LanSync.instance.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name != null) await LanSync.instance.setName(name);
  }

}

/// Pairs with [device]: asks it, then takes the passkey it shows. Shared by
/// the phone's and the TV's device screens.
Future<void> pairWithDevice(BuildContext context, NearbyDevice device) async {
  final OutgoingPairing pairing;
  try {
    pairing = await LanSync.instance.pair(device);
  } catch (e) {
    if (context.mounted) showToast(context, 'Could not pair with ${device.name}: $e', error: true);
    return;
  }
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _EnterPasskeyDialog(pairing),
  );
  if (ok == true) {
    if (context.mounted) showToast(context, 'Paired with ${pairing.name}.');
  } else {
    await pairing.cancel();
  }
}

/// Where the user types the passkey the other device shows.
class _EnterPasskeyDialog extends StatefulWidget {
  const _EnterPasskeyDialog(this.pairing);

  final OutgoingPairing pairing;

  @override
  State<_EnterPasskeyDialog> createState() => _EnterPasskeyDialogState();
}

class _EnterPasskeyDialogState extends State<_EnterPasskeyDialog> {
  final _ctrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final passkey = Passkey.parse(_ctrl.text);
    if (passkey == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.pairing.enter(passkey);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // A failed attempt ends the session on the other side; it needs a
      // new pairing and shows a new code.
      if (mounted) {
        setState(() {
          _busy = false;
          _error = '$e. Start pairing again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.pairing.name;
    return AlertDialog(
      title: Text('Pair with $name'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Enter the code $name shows now.'),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _ctrl,
            autofocus: true,
            enabled: !_busy && _error == null,
            keyboardType: TextInputType.number,
            maxLength: 7,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 4,
                ),
            decoration: const InputDecoration(hintText: '000 000', counterText: ''),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          if (_busy) ...[
            const SizedBox(height: AppSpacing.md),
            const LinearProgressIndicator(),
          ],
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: Text(_error == null ? 'Cancel' : 'Close'),
        ),
        if (_error == null)
          FilledButton(
            onPressed: !_busy && Passkey.parse(_ctrl.text) != null ? _submit : null,
            child: const Text('Pair'),
          ),
      ],
    );
  }
}

/// Shows the passkey when another device asks to pair, wherever the user
/// is in the app.
class IncomingPairingListener extends StatefulWidget {
  const IncomingPairingListener({super.key, required this.child});

  final Widget child;

  @override
  State<IncomingPairingListener> createState() => _IncomingPairingListenerState();
}

class _IncomingPairingListenerState extends State<IncomingPairingListener> {
  final _incoming = LanSync.instance.incoming;
  final _copy = LanSync.instance.copyRequest;
  StreamSubscription<String>? _notices;

  @override
  void initState() {
    super.initState();
    _incoming.addListener(_show);
    _copy.addListener(_showCopy);
    _notices = LanSync.instance.notices.listen((text) {
      if (mounted) showToast(context, text);
    });
  }

  @override
  void dispose() {
    _incoming.removeListener(_show);
    _copy.removeListener(_showCopy);
    _notices?.cancel();
    super.dispose();
  }

  Future<void> _showCopy() async {
    final request = _copy.value;
    if (request == null || !mounted) return;
    final withKeys = request.item.startsWith('server/') || request.item.startsWith('route/');
    while (true) {
      if (!mounted) return;
      final allow = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text('${request.peerName} asks to keep ${request.title}'),
          content: Text(
            'With a copy of its own, ${request.peerName} can use ${request.title} '
            'away from this network, and keeps it even if you stop sharing. '
            'Your later changes no longer reach it.'
            '${withKeys ? '\n\nThe copy gets a key of its own: a new user is made on each '
                'server in it, which needs admin access. It shows among the '
                "server's connections, where you can revoke it." : ''}',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Deny')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow')),
          ],
        ),
      );
      if (allow != true) {
        request.deny();
        return;
      }
      if (!mounted) return;
      try {
        await request.allow((server) => obtainAdminIdentity(context, server));
        if (mounted) showToast(context, 'Copy sent to ${request.peerName}.');
        return;
      } catch (e) {
        // A wrong password or an unreachable server: the question is asked
        // again, so the user can try once more or deny.
        if (mounted) showToast(context, 'Could not make the copy: $e', error: true);
      }
    }
  }

  Future<void> _show() async {
    final pairing = _incoming.value;
    if (pairing == null || !mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ShowPasskeyDialog(pairing),
    );
    pairing.cancel();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ShowPasskeyDialog extends StatefulWidget {
  const _ShowPasskeyDialog(this.pairing);

  final IncomingPairing pairing;

  @override
  State<_ShowPasskeyDialog> createState() => _ShowPasskeyDialogState();
}

class _ShowPasskeyDialogState extends State<_ShowPasskeyDialog> {
  @override
  void initState() {
    super.initState();
    widget.pairing.state.addListener(_changed);
  }

  @override
  void dispose() {
    widget.pairing.state.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (widget.pairing.state.value == PairingState.cancelled && mounted) {
      Navigator.pop(context);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.pairing;
    final state = p.state.value;
    return AlertDialog(
      title: Text(switch (state) {
        PairingState.paired => 'Paired with ${p.name}',
        PairingState.failed => 'Pairing failed',
        _ => '${p.name} wants to pair',
      }),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(switch (state) {
            PairingState.paired =>
              'Nothing is shared yet. Choose what to share with ${p.name} '
                  'from a server, a route or the rules.',
            PairingState.failed => 'A wrong code was entered on ${p.name}.',
            _ => 'To pair, enter this code on ${p.name}. Pairing shares '
                'nothing by itself. If you did not start this, cancel.',
          }),
          if (state == PairingState.waiting) ...[
            const SizedBox(height: AppSpacing.lg),
            Text(
              p.code,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                    letterSpacing: 4,
                  ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.pop(context),
          child: Text(state == PairingState.waiting ? 'Cancel' : 'OK'),
        ),
      ],
    );
  }
}

/// Under a server, a route or the rules: where it came from, or whom it is
/// shared with.
class ShareStatusLabel extends StatelessWidget {
  /// Under one of this device's own things: whom it is shared with.
  const ShareStatusLabel(this.item, {super.key}) : received = false;

  /// Under something another device shares: whose it is, and a way to ask
  /// for a copy.
  const ShareStatusLabel.received(this.item, {super.key}) : received = true;

  final String item;
  final bool received;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LanSync.instance,
      builder: (context, _) {
        final sync = LanSync.instance;
        final from = received ? sync.receivedFrom(item) : null;
        final names = received ? const <String>[] : sync.sharedWith(item);
        if (from == null && names.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final color = theme.colorScheme.primary;
        final small = theme.textTheme.bodySmall;
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              Icon(from != null ? Icons.download_outlined : Icons.devices,
                  size: 14, color: color),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  from != null ? 'From $from' : 'Shared with ${names.join(', ')}',
                  overflow: TextOverflow.ellipsis,
                  style: small?.copyWith(color: color),
                ),
              ),
              if (from != null) ...[
                const SizedBox(width: AppSpacing.sm),
                if (sync.copyRequested(item))
                  Text('· asked for a copy',
                      style: small?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                else
                  InkWell(
                    onTap: () => _requestCopy(context, from),
                    child: Text(
                      '· Keep a copy',
                      style: small?.copyWith(
                        color: color,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }
}

extension on ShareStatusLabel {
  Future<void> _requestCopy(BuildContext context, String owner) async {
    try {
      await LanSync.instance.requestCopy(item);
      if (context.mounted) showToast(context, 'Asked $owner. Allow it there.');
    } catch (e) {
      if (context.mounted) showToast(context, 'Could not ask $owner: $e', error: true);
    }
  }
}

/// Lets the owner pick the paired devices [item] is shared with.
Future<void> showShareDialog(BuildContext context, String item, String title) async {
  final sync = LanSync.instance;
  if (sync.paired.isEmpty) {
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('No paired devices'),
        content: const Text('Pair one of your devices first.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('My devices')),
        ],
      ),
    );
    if (open == true && context.mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const LanSyncScreen()),
      );
    }
    return;
  }
  final chosen = await showDialog<Set<String>>(
    context: context,
    builder: (_) => _ShareDialog(item: item, title: title),
  );
  if (chosen != null) await sync.share(item, chosen);
}

class _ShareDialog extends StatefulWidget {
  const _ShareDialog({required this.item, required this.title});

  final String item;
  final String title;

  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  late final _chosen = {...LanSync.instance.sharesOf(widget.item)};

  @override
  Widget build(BuildContext context) {
    final paired = LanSync.instance.paired;
    return AlertDialog(
      title: Text('Share ${widget.title}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.item == 'rules'
                ? 'The rules replace the ones on the chosen devices.'
                : 'The chosen devices get it with its private keys and can '
                    'connect. Changes you make reach them; unticking a device '
                    'removes it from there.',
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final p in paired)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _chosen.contains(p.key),
              title: Text(p.name),
              onChanged: (on) => setState(
                  () => on == true ? _chosen.add(p.key) : _chosen.remove(p.key)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _chosen),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _PairedTile extends StatelessWidget {
  const _PairedTile(this.device);

  final PairedDevice device;

  @override
  Widget build(BuildContext context) {
    final sync = LanSync.instance;
    final online = sync.isOnline(device.key);
    final error = sync.lastError(device.key);
    final last = sync.lastSync(device.key);
    final status = !online
        ? 'Not on this network'
        : error ?? (last == null ? 'Online' : 'Synced at ${_time(last)}');
    return ListTile(
      leading: Icon(
        Icons.devices,
        color: online ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(device.name),
      subtitle: Text(
        status,
        style: error != null && online ? TextStyle(color: AppColors.of(context).warning) : null,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.link_off),
        tooltip: 'Unpair',
        onPressed: () => _forget(context),
      ),
    );
  }

  static String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _forget(BuildContext context) async {
    final ok = await confirmDestructive(
      context,
      title: 'Unpair ${device.name}?',
      message: 'It keeps what it already has, but gets no further changes from '
          'this device.',
      confirmLabel: 'Unpair',
    );
    if (ok) await LanSync.instance.forget(device.key);
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Text(
          text,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
}
