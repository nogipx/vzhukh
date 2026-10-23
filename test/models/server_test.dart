import 'package:flutter_test/flutter_test.dart';
import 'package:vzhukh/models/server.dart';
import 'package:vzhukh/models/ssh_identity.dart';
import 'package:vzhukh/models/tunnel_route.dart';
import 'package:vzhukh/vpn/ios_vpn_bridge.dart';

Server _server(String id, [List<String> dns = const []]) =>
    Server(id: id, host: '$id.example', port: 22, nickname: id, dnsServers: dns);

ResolvedHop _hop(Server s) => ResolvedHop(
      server: s,
      identity: SshIdentity(
        id: 'c-${s.id}',
        serverId: s.id,
        username: 'u',
        authType: SshAuthType.privateKey,
        isAdmin: false,
      ),
    );

void main() {
  test('dns servers survive json and are left out when empty', () {
    final withDns = _server('a', ['10.0.0.53', '10.0.1.53']);
    expect(Server.fromJson(withDns.toJson()).dnsServers, ['10.0.0.53', '10.0.1.53']);
    expect(_server('b').toJson().containsKey('dns'), isFalse);
    expect(Server.fromJson(_server('b').toJson()).dnsServers, isEmpty);
  });

  test('a chain uses the resolvers of its last hop, else the defaults', () {
    final first = _hop(_server('a', ['1.1.1.1']));
    final last = _hop(_server('b', ['10.0.0.53']));
    expect(IosVpnBridge.dnsServersFor([first, last]), ['10.0.0.53']);
    expect(IosVpnBridge.dnsServersFor([last, _hop(_server('c'))]), Server.defaultDnsServers);
  });
}
