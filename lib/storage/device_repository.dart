import 'dart:convert';

import '../models/remote_device.dart';
import 'secure_store.dart';

class DeviceRepository {
  static const _key = 'remote_devices';

  Future<List<RemoteDevice>> getDevices() async {
    final raw = await secureStore.read(key: _key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => RemoteDevice.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> saveDevice(RemoteDevice device) async {
    final devices = await getDevices();
    final idx = devices.indexWhere((d) => d.id == device.id);
    if (idx >= 0) {
      devices[idx] = device;
    } else {
      devices.add(device);
    }
    await _write(devices);
  }

  Future<void> deleteDevice(String id) async {
    final devices = await getDevices();
    devices.removeWhere((d) => d.id == id);
    await _write(devices);
  }

  Future<void> _write(List<RemoteDevice> devices) => secureStore.write(
        key: _key,
        value: jsonEncode(devices.map((d) => d.toJson()).toList()),
      );
}
