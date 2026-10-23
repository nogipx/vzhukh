import 'plain_store.dart';

/// How the macOS helper treats this Mac, apart from the rules. Not shared:
/// it is about the Mac, not about where traffic should go.
class HelperSettings {
  const HelperSettings();

  static const _leaveOtherVpns = 'helper_leave_other_vpns';

  /// Whether other VPNs keep their networks to themselves. By default the
  /// tunnel takes them first, so their traffic shows in Traffic and follows
  /// the rules; a VPN client that fights over its routes needs this on.
  Future<bool> leaveOtherVpns() async => await plainStore.read(key: _leaveOtherVpns) == 'true';

  Future<void> setLeaveOtherVpns(bool on) => plainStore.write(key: _leaveOtherVpns, value: '$on');
}
