import 'dart:typed_data';

/// Builds the byte stream that turns `/dev/uhid` into a virtual input device.
///
/// Writing to `/dev/input/*` is refused by SELinux for the adb shell, and the
/// `input` command starts a JVM for every single event — on a modest TV box
/// that is well over a second each. A uhid device is created once and then fed
/// raw HID reports, which the kernel delivers as if a real mouse or keyboard
/// were plugged in.
abstract final class Uhid {
  // Event types from linux/uhid.h.
  static const int _create2 = 11;
  static const int _input2 = 12;
  static const int _destroy = 1;

  static const int _busUsb = 0x03;

  /// Relative pointer with three buttons and a wheel. Report: buttons, dx, dy,
  /// wheel.
  static const List<int> mouseDescriptor = [
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, //  Mouse
    0x09, 0x01, 0xa1, 0x00, //              Pointer
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
    0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02, // 3 buttons
    0x95, 0x01, 0x75, 0x05, 0x81, 0x03, //   padding
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38,
    0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x03, 0x81, 0x06, // x, y, wheel
    0xc0, 0xc0,
  ];

  /// Boot keyboard. Report: modifiers, reserved, then six key slots.
  static const List<int> keyboardDescriptor = [
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01,
    0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7,
    0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, // modifiers
    0x95, 0x01, 0x75, 0x08, 0x81, 0x03, //                          reserved
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
    0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, //              six keys
    0xc0,
  ];

  /// The command that keeps the device alive: one process holding the
  /// descriptor open and piping whatever arrives straight into the kernel, so
  /// no process is spawned per event.
  ///
  /// Written for adb's `exec:` service, which already runs what it is given
  /// through a shell — wrapping it in another `sh -c` breaks on the quoting.
  static const String pipeCommand = 'exec 3>/dev/uhid; cat >&3';

  /// A UHID_CREATE2 event. Only the bytes up to the descriptor are written —
  /// the kernel zeroes the rest of the structure itself.
  static Uint8List create(String name, List<int> descriptor) {
    final out = BytesBuilder();
    out.add(_u32(_create2));
    out.add(_fixed(name, 128)); // name
    out.add(Uint8List(64)); //     phys
    out.add(Uint8List(64)); //     uniq

    final meta = ByteData(20);
    meta.setUint16(0, descriptor.length, Endian.little);
    meta.setUint16(2, _busUsb, Endian.little);
    meta.setUint32(4, 0x18d1, Endian.little); // vendor
    meta.setUint32(8, 0x4ee7, Endian.little); // product
    meta.setUint32(12, 1, Endian.little); //     version
    meta.setUint32(16, 0, Endian.little); //     country
    out.add(meta.buffer.asUint8List());
    out.add(Uint8List.fromList(descriptor));
    return out.takeBytes();
  }

  /// A UHID_INPUT2 event carrying one HID report.
  static Uint8List input(List<int> report) {
    final out = BytesBuilder();
    out.add(_u32(_input2));
    final size = ByteData(2)..setUint16(0, report.length, Endian.little);
    out.add(size.buffer.asUint8List());
    out.add(Uint8List.fromList(report));
    return out.takeBytes();
  }

  static Uint8List destroy() => _u32(_destroy);

  static Uint8List _u32(int value) {
    final data = ByteData(4)..setUint32(0, value, Endian.little);
    return data.buffer.asUint8List();
  }

  static Uint8List _fixed(String value, int length) {
    final out = Uint8List(length);
    final bytes = value.codeUnits.take(length - 1).toList();
    out.setRange(0, bytes.length, bytes);
    return out;
  }
}

/// HID usage codes, as the keyboard descriptor above reports them.
abstract final class HidKey {
  static const int enter = 0x28;
  static const int escape = 0x29;
  static const int backspace = 0x2a;
  static const int tab = 0x2b;
  static const int space = 0x2c;
  static const int right = 0x4f;
  static const int left = 0x50;
  static const int down = 0x51;
  static const int up = 0x52;
}
