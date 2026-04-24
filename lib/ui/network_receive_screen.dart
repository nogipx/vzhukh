import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../network/local_http_server.dart';

class NetworkReceiveScreen extends StatefulWidget {
  const NetworkReceiveScreen({super.key});

  @override
  State<NetworkReceiveScreen> createState() => _NetworkReceiveScreenState();
}

class _NetworkReceiveScreenState extends State<NetworkReceiveScreen> {
  bool _fetching = false;
  bool _scanned = false;
  bool _manualMode = false;
  String? _error;
  String? _subnet; // e.g. "192.168.1."

  final _octetCtrl = TextEditingController();
  final _portCtrl = TextEditingController();
  final _octetFocus = FocusNode();
  final _portFocus = FocusNode();
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _resolveSubnet();
  }

  Future<void> _resolveSubnet() async {
    final ip = await LocalHttpServer.localIp();
    if (ip != null && mounted) {
      final parts = ip.split('.');
      if (parts.length == 4) {
        setState(() => _subnet = '${parts[0]}.${parts[1]}.${parts[2]}.');
      }
    }
  }

  @override
  void dispose() {
    _octetCtrl.dispose();
    _portCtrl.dispose();
    _octetFocus.dispose();
    _portFocus.dispose();
    super.dispose();
  }

  void _onBarcodeDetected(BarcodeCapture capture) {
    if (_fetching || _scanned) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final ip = json['ip'] as String;
      final port = json['port'] as int;
      setState(() => _scanned = true);
      _fetch(ip, port);
    } catch (_) {}
  }

  Future<void> _fetchManual() async {
    if (!_formKey.currentState!.validate()) return;
    final octet = _octetCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (port == null) return;
    final ip = _subnet != null ? '$_subnet$octet' : octet;
    await _fetch(ip, port);
  }

  Future<void> _fetch(String ip, int port) async {
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      final request =
          await client.getUrl(Uri.parse('http://$ip:$port/payload'));
      final response = await request.close();
      final body = await utf8.decodeStream(response);
      client.close();

      final json = jsonDecode(body) as Map<String, dynamic>;
      final type = json['type'] as String;
      final payload = json['payload'] as String;

      if (mounted) {
        Navigator.pop(context, ReceivedPayload(type: type, data: payload));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _fetching = false;
          _scanned = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Receive from device'),
        actions: [
          if (!_fetching)
            TextButton(
              onPressed: () => setState(() {
                _manualMode = !_manualMode;
                _error = null;
                _scanned = false;
              }),
              child: Text(_manualMode ? 'Scan QR' : 'Enter manually'),
            ),
        ],
      ),
      body: _fetching
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Receiving...'),
                ],
              ),
            )
          : _manualMode
              ? _buildManualForm()
              : _buildScanner(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(onDetect: _onBarcodeDetected),
        if (_error != null)
          Positioned(
            bottom: 80,
            left: 24,
            right: 24,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        const Positioned(
          bottom: 40,
          left: 0,
          right: 0,
          child: Center(
            child: Text(
              'Scan the QR on the sending device',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildManualForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _subnet != null
                  ? 'Subnet detected: $_subnet\nEnter the last octet and port shown on the sending device.'
                  : 'Enter the full IP and port shown on the sending device.',
              style: const TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_subnet != null) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _subnet!,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
                    ),
                  ),
                ],
                Expanded(
                  child: TextFormField(
                    controller: _octetCtrl,
                    focusNode: _octetFocus,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: _subnet != null ? 'Last octet' : 'IP address',
                      hintText: _subnet != null ? '100' : '192.168.1.100',
                      border: const OutlineInputBorder(),
                    ),
                    onFieldSubmitted: (_) => _portFocus.requestFocus(),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 16),
                  child: Text(':', style: TextStyle(fontSize: 20)),
                ),
                SizedBox(
                  width: 110,
                  child: TextFormField(
                    controller: _portCtrl,
                    focusNode: _portFocus,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      hintText: '54321',
                      border: OutlineInputBorder(),
                    ),
                    onFieldSubmitted: (_) => _fetchManual(),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      if (int.tryParse(v.trim()) == null) return 'Invalid';
                      return null;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _fetchManual,
              child: const Text('Connect'),
            ),
          ],
        ),
      ),
    );
  }
}
