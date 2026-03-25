import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// C signatures
typedef Tun2SocksStartC = Int32 Function(Int32 tunFd, Pointer<Utf8> socksAddr);
typedef Tun2SocksStartDart = int Function(int tunFd, Pointer<Utf8> socksAddr);

typedef Tun2SocksStopC = Void Function();
typedef Tun2SocksStopDart = void Function();

// Dart strings as UTF-8 pointers
final class Utf8 extends Opaque {}

extension StringToNative on String {
  Pointer<Utf8> toNativeUtf8() {
    final units = codeUnits;
    final ptr = calloc<Uint8>(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr.cast<Utf8>();
  }
}

class Tun2SocksBindings {
  static Tun2SocksBindings? _instance;

  late final Tun2SocksStartDart _start;
  late final Tun2SocksStopDart _stop;

  Tun2SocksBindings._() {
    final lib = DynamicLibrary.open('libtun2socks.so');
    _start = lib
        .lookup<NativeFunction<Tun2SocksStartC>>('tun2socks_start')
        .asFunction();
    _stop = lib
        .lookup<NativeFunction<Tun2SocksStopC>>('tun2socks_stop')
        .asFunction();
  }

  static Tun2SocksBindings get instance {
    _instance ??= Tun2SocksBindings._();
    return _instance!;
  }

  /// Returns 0 on success, non-zero on error.
  int start(int tunFd, String socksAddr) {
    final ptr = StringToNative(socksAddr).toNativeUtf8();
    final result = _start(tunFd, ptr);
    calloc.free(ptr);
    return result;
  }

  void stop() => _stop();
}

// Simple allocator for native memory
final calloc = _Calloc();

class _Calloc {
  Pointer<T> call<T extends NativeType>(int count) {
    return malloc.allocate<T>(count);
  }

  void free(Pointer pointer) {
    malloc.free(pointer);
  }
}
