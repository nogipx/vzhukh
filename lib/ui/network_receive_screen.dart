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
  String? _error;

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
    } catch (_) {
      // not a valid QR — keep scanning
    }
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
      appBar: AppBar(title: const Text('Receive from device')),
      body: Stack(
        children: [
          if (!_fetching)
            MobileScanner(onDetect: _onBarcodeDetected),
          if (_fetching)
            const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Receiving...'),
                ],
              ),
            ),
          if (_error != null)
            Positioned(
              bottom: 40,
              left: 24,
              right: 24,
              child: Column(
                children: [
                  Container(
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
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: () => setState(() => _error = null),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: Colors.black54,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            )
          else if (!_fetching)
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
      ),
    );
  }
}
