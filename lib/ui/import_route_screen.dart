import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../models/connection.dart';
import '../models/server.dart';
import '../models/tunnel_route.dart';
import '../ssh/route_invite_codec.dart';
import '../storage/route_repository.dart';
import '../storage/server_repository.dart';

class ImportRouteScreen extends StatefulWidget {
  /// Pre-filled encoded payload (e.g. received via local network push).
  final String? prefilled;

  const ImportRouteScreen({super.key, this.prefilled});

  @override
  State<ImportRouteScreen> createState() => _ImportRouteScreenState();
}

class _ImportRouteScreenState extends State<ImportRouteScreen> {
  final _serverRepo = ServerRepository();
  final _routeRepo = RouteRepository();
  final _codec = const RouteInviteCodec();

  final _pasteCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _passwordFocus = FocusNode();
  final _formKey = GlobalKey<FormState>();

  bool _scanning = false;
  bool _obscurePass = true;
  bool _importing = false;
  String? _error;
  String? _scannedData;

  bool get _isPrefilled => widget.prefilled != null;

  @override
  void initState() {
    super.initState();
    if (widget.prefilled != null) {
      _pasteCtrl.text = widget.prefilled!;
      _scannedData = widget.prefilled;
    }
  }

  @override
  void dispose() {
    _pasteCtrl.dispose();
    _passwordCtrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw != null && raw.isNotEmpty) {
      setState(() {
        _scannedData = raw;
        _pasteCtrl.text = raw;
        _scanning = false;
      });
    }
  }

  Future<void> _import() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _importing = true;
      _error = null;
    });

    try {
      final payload =
          await _codec.decodeAsync(_pasteCtrl.text.trim(), _passwordCtrl.text);

      final existingServers = await _serverRepo.getServers();
      final hops = <RouteHop>[];

      for (final hopData in payload.hops) {
        // Match server by host:port, create if not found.
        var server = existingServers.firstWhere(
          (s) => s.host == hopData.host && s.port == hopData.port,
          orElse: () => Server(
            id: '${hopData.host}_${DateTime.now().microsecondsSinceEpoch}',
            host: hopData.host,
            port: hopData.port,
            nickname: hopData.nickname,
          ),
        );
        await _serverRepo.saveServer(server);

        // Match connection by username, create if not found.
        final connections = await _serverRepo.getConnections(server.id);
        var conn = connections.firstWhereOrNull(
          (c) => c.username == hopData.username,
        );

        if (conn == null) {
          conn = Connection(
            id: '${server.id}_${hopData.username}',
            serverId: server.id,
            label: hopData.username,
            username: hopData.username,
            publicKeyOpenSSH: '',
            privateKeyPem: hopData.privateKeyPem,
            createdAt: DateTime.now(),
          );
          await _serverRepo.saveConnection(conn);
        } else if (conn.privateKeyPem == null) {
          // Update with the received private key.
          conn = Connection(
            id: conn.id,
            serverId: conn.serverId,
            label: conn.label,
            username: conn.username,
            publicKeyOpenSSH: conn.publicKeyOpenSSH,
            privateKeyPem: hopData.privateKeyPem,
            createdAt: conn.createdAt,
          );
          await _serverRepo.saveConnection(conn);
        }

        hops.add(RouteHop(serverId: server.id, connectionId: conn.id));
      }

      final route = TunnelRoute(
        id: 'route_${DateTime.now().millisecondsSinceEpoch}',
        label: payload.label,
        hops: hops,
      );
      await _routeRepo.saveRoute(route);

      if (mounted) Navigator.pop(context, true);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Import route')),
      body: _scanning ? _buildScanner() : _buildForm(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(onDetect: _onBarcodeDetected),
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Center(
            child: OutlinedButton(
              onPressed: () => setState(() => _scanning = false),
              style: OutlinedButton.styleFrom(
                backgroundColor: Colors.black54,
                foregroundColor: Colors.white,
              ),
              child: const Text('Cancel'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_isPrefilled) ...[
              if (_scannedData != null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: Colors.green),
                      SizedBox(width: 8),
                      Text('QR code scanned'),
                    ],
                  ),
                ),
              TextFormField(
                controller: _pasteCtrl,
                maxLines: 4,
                textInputAction: TextInputAction.next,
                onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
                decoration: const InputDecoration(
                  labelText: 'Route code',
                  hintText: 'Paste or scan QR code',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                validator: (v) =>
                    v == null || v.trim().isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => setState(() => _scanning = true),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('Scan QR code'),
              ),
              const SizedBox(height: 16),
            ] else ...[
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green),
                    SizedBox(width: 8),
                    Text('Route received. Enter the password.'),
                  ],
                ),
              ),
            ],
            TextFormField(
              controller: _passwordCtrl,
              focusNode: _passwordFocus,
              autofocus: _isPrefilled,
              obscureText: _obscurePass,
              decoration: InputDecoration(
                labelText: 'Route password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscurePass ? Icons.visibility : Icons.visibility_off),
                  onPressed: () =>
                      setState(() => _obscurePass = !_obscurePass),
                ),
              ),
              validator: (v) =>
                  v == null || v.isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _importing ? null : _import,
              child: _importing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
