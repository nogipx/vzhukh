import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as nacl;

class SshKeyPairResult {
  final String privateKeyPem;
  final String publicKeyOpenSSH;

  const SshKeyPairResult({
    required this.privateKeyPem,
    required this.publicKeyOpenSSH,
  });
}

/// Generates an Ed25519 SSH key pair ready for use with dartssh2.
///
/// Returns [SshKeyPairResult] with:
///   - [privateKeyPem]: OpenSSH PEM private key (store in secure storage)
///   - [publicKeyOpenSSH]: authorized_keys line format
class GenerateSshKeyPair {
  const GenerateSshKeyPair();

  SshKeyPairResult call({String comment = 'flume'}) {
    final signingKey = nacl.SigningKey.generate();

    // pinenacl Ed25519:
    //   signingKey.asTypedList       → 64 bytes (seed 32 + pubkey 32)
    //   signingKey.verifyKey.asTypedList → 32 bytes (pubkey)
    final privateKeyBytes = Uint8List.fromList(signingKey.asTypedList);
    final publicKeyBytes = Uint8List.fromList(signingKey.verifyKey.asTypedList);

    final keyPair = OpenSSHEd25519KeyPair(publicKeyBytes, privateKeyBytes, comment);

    final privateKeyPem = keyPair.toPem();

    // toPublicKey().encode() returns SSH wire format:
    //   [4 bytes len]["ssh-ed25519"][4 bytes len][32 bytes pubkey]
    final wireFormat = keyPair.toPublicKey().encode();
    final publicKeyOpenSSH = 'ssh-ed25519 ${base64.encode(wireFormat)} $comment';

    return SshKeyPairResult(
      privateKeyPem: privateKeyPem,
      publicKeyOpenSSH: publicKeyOpenSSH,
    );
  }
}
