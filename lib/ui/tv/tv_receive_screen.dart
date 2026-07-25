import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../network/payload_transfer.dart';
import '../theme/app_theme.dart';

/// Waits for a phone to push a route to this television.
///
/// Deliberately not the handheld receive screen: that one opens the camera to
/// scan a QR code, or asks for an IP address and port, and a TV can do neither
/// comfortably. Here the set simply displays who it is and waits.
class TvReceiveScreen extends StatefulWidget {
  const TvReceiveScreen({super.key});

  @override
  State<TvReceiveScreen> createState() => _TvReceiveScreenState();
}

class _TvReceiveScreenState extends State<TvReceiveScreen> {
  // Announcing the kind lets the phone send something this set can open
  // instead of a password protected invite it could never unlock.
  final _receiver = PayloadReceiver(deviceKind: 'tv');

  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  Future<void> _listen() async {
    try {
      await _receiver.start();
      if (!mounted) return;
      setState(() => _ready = true);

      final payload = await _receiver.received;
      if (mounted) Navigator.pop(context, payload);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _receiver.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: TvInsets.overscan,
        child: Center(child: _body(context)),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final theme = Theme.of(context);

    if (_error != null) {
      return Text(
        _error!,
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyLarge
            ?.copyWith(color: theme.colorScheme.error),
      );
    }

    if (!_ready) {
      return const CircularProgressIndicator();
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: QrImageView(
            data: _receiver.handshake,
            version: QrVersions.auto,
            size: 320,
            errorCorrectionLevel: QrErrorCorrectLevel.L,
          ),
        ),
        const SizedBox(width: AppSpacing.xxl),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Scan with your phone', style: theme.textTheme.displaySmall),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'On the phone open Vzhukh, pick a route, choose Send to TV, '
                'and point the camera at this code.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _AddressChip(ip: _receiver.ip, port: _receiver.port),
              const SizedBox(height: AppSpacing.xl),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Text('Waiting…', style: theme.textTheme.bodyLarge),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Fallback for a phone that cannot scan: the address, big enough to read
/// from the sofa.
class _AddressChip extends StatelessWidget {
  const _AddressChip({required this.ip, required this.port});

  final String? ip;
  final int? port;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (ip == null) {
      return Text(
        'No network connection',
        style: theme.textTheme.bodyLarge
            ?.copyWith(color: theme.colorScheme.error),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
      ),
      child: Text(
        '$ip:$port',
        style: theme.textTheme.headlineSmall?.copyWith(
          fontFamily: 'monospace',
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
