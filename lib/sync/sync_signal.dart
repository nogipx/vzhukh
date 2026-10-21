import 'dart:async';

import 'package:flutter/foundation.dart';

/// The two directions synced data changes in.
///
/// Repositories call [localChanged] after they write, so paired devices
/// hear about an edit within a second or two instead of at the next
/// periodic round. Screens showing synced data listen to [remote] and
/// reload when another device's change has been stored here.
class SyncSignal {
  SyncSignal._();

  static final instance = SyncSignal._();

  final _local = StreamController<void>.broadcast();

  Stream<void> get localChanges => _local.stream;

  void localChanged() => _local.add(null);

  /// Bumped after a merge stored something from another device.
  final remote = ValueNotifier<int>(0);
}
