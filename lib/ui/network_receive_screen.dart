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

  final _ipCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _ipCtrl.dispose();
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
    final parts = _ipCtrl.text.trim().split(':');
    if (parts.length != 2) return;
    final ip = parts[0];
    final port = int.tryParse(parts[1]);
    if (port == null) return;
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
            const Text(
              'Enter the address shown on the sending device.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _ipCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: '192.168.1.x:port',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'Required';
                final parts = v.trim().split(':');
                if (parts.length != 2 || int.tryParse(parts[1]) == null) {
                  return 'Format: ip:port';
                }
                return null;
              },
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
