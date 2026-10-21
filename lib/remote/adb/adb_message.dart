import 'dart:typed_data';

/// Wire format of the ADB protocol: a 24 byte header followed by a payload.
///
/// Every field is little-endian. The checksum is a plain sum of the payload
/// bytes rather than a real CRC, and magic is the command with every bit
/// flipped — both are sanity checks the daemon rejects the connection over.
class AdbMessage {
  const AdbMessage(this.command, this.arg0, this.arg1, this.payload);

  static const int headerSize = 24;

  // Commands, spelled as the four characters they read as on the wire.
  static const int cnxn = 0x4e584e43; // CNXN
  static const int auth = 0x48545541; // AUTH
  static const int open = 0x4e45504f; // OPEN
  static const int okay = 0x59414b4f; // OKAY
  static const int clse = 0x45534c43; // CLSE
  static const int wrte = 0x45545257; // WRTE

  // AUTH subtypes.
  static const int authToken = 1;
  static const int authSignature = 2;
  static const int authRsaPublicKey = 3;

  final int command;
  final int arg0;
  final int arg1;
  final Uint8List payload;

  Uint8List encode() {
    final out = BytesBuilder(copy: false);
    final header = ByteData(headerSize);
    header.setUint32(0, command, Endian.little);
    header.setUint32(4, arg0, Endian.little);
    header.setUint32(8, arg1, Endian.little);
    header.setUint32(12, payload.length, Endian.little);
    header.setUint32(16, _checksum(payload), Endian.little);
    header.setUint32(20, (command ^ 0xffffffff) & 0xffffffff, Endian.little);
    out.add(header.buffer.asUint8List());
    out.add(payload);
    return out.takeBytes();
  }

  static int _checksum(Uint8List data) {
    var sum = 0;
    for (final byte in data) {
      sum = (sum + byte) & 0xffffffff;
    }
    return sum;
  }

  @override
  String toString() {
    final name = String.fromCharCodes([
      command & 0xff,
      (command >> 8) & 0xff,
      (command >> 16) & 0xff,
      (command >> 24) & 0xff,
    ]);
    return '$name(arg0=$arg0, arg1=$arg1, len=${payload.length})';
  }
}

/// Reassembles messages from a byte stream that arrives in arbitrary chunks.
class AdbMessageReader {
  final _buffer = BytesBuilder();
  Uint8List _pending = Uint8List(0);

  void add(List<int> chunk) {
    _buffer.add(chunk);
    _pending = Uint8List.fromList(_pending + _buffer.takeBytes());
  }

  /// Returns the next complete message, or null while one is still arriving.
  AdbMessage? next() {
    if (_pending.length < AdbMessage.headerSize) return null;

    final header = ByteData.sublistView(_pending, 0, AdbMessage.headerSize);
    final command = header.getUint32(0, Endian.little);
    final arg0 = header.getUint32(4, Endian.little);
    final arg1 = header.getUint32(8, Endian.little);
    final length = header.getUint32(12, Endian.little);

    final total = AdbMessage.headerSize + length;
    if (_pending.length < total) return null;

    final payload =
        Uint8List.sublistView(_pending, AdbMessage.headerSize, total);
    _pending = Uint8List.fromList(_pending.sublist(total));
    return AdbMessage(command, arg0, arg1, Uint8List.fromList(payload));
  }
}
