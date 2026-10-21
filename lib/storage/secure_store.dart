import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// The single keychain handle everything in the app stores through.
///
/// macOS asks for the file-based keychain rather than the data protection one.
/// The latter is reachable only to a binary carrying a team-derived
/// application-identifier, and the portable build is signed ad-hoc with no team
/// to derive it from: there, every read and write comes back as
/// errSecMissingEntitlement (-34018) and saved servers never reappear.
///
/// The signed build is unaffected — its entitlements name a keychain access
/// group, which is what the file keychain wants as well.
const secureStore = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
