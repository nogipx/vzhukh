import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:pinenacl/x25519.dart';

import '../storage/plain_store.dart';
import '../storage/secure_store.dart';
import 'repository_synced_data.dart';
import 'sync_crypto.dart';
import '../models/connection.dart';
import '../models/server.dart';
import '../models/ssh_identity.dart';
import '../ssh/connection_manager.dart';
import '../storage/server_repository.dart';
import 'copy_bundle.dart';
import 'received_items.dart';
import 'share_engine.dart';
import 'sync_signal.dart';
import '../ssh/server_access.dart';

const _serviceType = '_vzhukh._tcp';
const _protocol = '1';

/// A device this one trusts with everything it syncs.
@immutable
class PairedDevice {
  const PairedDevice({required this.key, required this.name, required this.pairedAt});

  /// Its long-term public key, base64url. This is its identity.
  final String key;
  final String name;
  final DateTime pairedAt;

  Map<String, dynamic> toJson() =>
      {'key': key, 'name': name, 'pairedAt': pairedAt.toIso8601String()};

  factory PairedDevice.fromJson(Map<String, dynamic> j) => PairedDevice(
        key: j['key'] as String,
        name: j['name'] as String,
        pairedAt: DateTime.parse(j['pairedAt'] as String),
      );
}

/// A device running Vzhukh on this network right now.
@immutable
class NearbyDevice {
  const NearbyDevice({
    required this.key,
    required this.name,
    required this.host,
    required this.port,
  });

  final String key;
  final String name;
  final String host;
  final int port;

  Uri uri(String path) => Uri(scheme: 'http', host: host, port: port, path: path);
}

enum PairingState { waiting, paired, failed, cancelled }

/// A pairing another device started. This device shows the passkey; the
/// user types it on the other one.
class IncomingPairing {
  IncomingPairing._(this.name, this.passkey, this._cancel);

  final String name;
  final int passkey;
  final void Function() _cancel;

  final state = ValueNotifier(PairingState.waiting);

  String get code => Passkey.format(passkey);

  void cancel() => _cancel();
}

/// A pairing this device started, waiting for the passkey the other device
/// shows.
class OutgoingPairing {
  OutgoingPairing._(this.name, this._enter, this._cancel);

  final String name;
  final Future<void> Function(int passkey) _enter;
  final Future<void> Function() _cancel;

  /// Proves [passkey] to the other device and trusts it once both sides
  /// agree. Throws [PairingFailed] when they do not.
  Future<void> enter(int passkey) => _enter(passkey);

  Future<void> cancel() => _cancel();
}

/// A paired device asking to keep its own copy of something shared with it.
class CopyRequest {
  CopyRequest._(this.peer, this.peerName, this.item, this.title, this._allow, this._deny);

  final String peer;
  final String peerName;
  final String item;
  final String title;
  final Future<void> Function(AdminFor adminFor) _allow;
  final void Function() _deny;

  /// Makes the copy, with a key of its own on every server in it, and sends
  /// it. [adminFor] gives admin access to each such server. Throws when a
  /// server cannot be reached or refuses; the request then stays open.
  Future<void> allow(AdminFor adminFor) => _allow(adminFor);

  void deny() => _deny();
}

class PairingFailed implements Exception {
  const PairingFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The responder's side of a pairing in progress.
class _Session {
  _Session(this.id, this.key, this.prompt)
      : expires = DateTime.now().add(const Duration(minutes: 2));

  final String id;
  final String key;
  final IncomingPairing prompt;
  final DateTime expires;
  int round = 0;
  String? theirCommit;
  Uint8List? nonce;

  bool get live => DateTime.now().isBefore(expires);
}

class _Status implements Exception {
  const _Status(this.code);
  final int code;
  @override
  String toString() => 'HTTP $code';
}

/// Where the identity key and the paired devices are kept.
abstract class SyncIdentityStore {
  Future<String?> read();
  Future<void> write(String raw);
}

class _KeychainIdentity implements SyncIdentityStore {
  static const _key = 'sync_identity_v1';
  @override
  Future<String?> read() => secureStore.read(key: _key);
  @override
  Future<void> write(String raw) => secureStore.write(key: _key, value: raw);
}

class _KeychainReceived implements LedgerStore {
  static const _key = 'sync_received_v1';
  @override
  Future<String?> read() => secureStore.read(key: _key);
  @override
  Future<void> write(String raw) => secureStore.write(key: _key, value: raw);
}

class _PlainFile implements LedgerStore {
  const _PlainFile(this._key);
  final String _key;
  @override
  Future<String?> read() => plainStore.read(key: _key);
  @override
  Future<void> write(String raw) => plainStore.write(key: _key, value: raw);
}

/// Shares servers, routes and rules with the user's other devices on the
/// local network, item by item, with the devices the owner picks (see
/// [ShareEngine]).
///
/// Devices find each other over Bonjour/NSD and talk HTTP. Nothing passes
/// between two devices until they are paired: one asks, the other shows a
/// passkey, and the user types it on the one that asked (see [Passkey]).
/// From then on everything between them is sealed with NaCl box between
/// their long-term keys, and a device answers only devices it paired with.
///
/// The identity key and the list of paired devices are kept in the
/// keychain: whoever could add a key to that list could be shared private
/// keys with.
///
/// On a phone or a TV this runs while the app is in the foreground; a
/// change made on another device arrives when the app is next opened.
class LanSync extends ChangeNotifier {
  /// The arguments are for tests: two instances in one process, talking
  /// over loopback, with no Bonjour and no keychain.
  LanSync({
    SyncedData? data,
    LedgerStore? state,
    ReceivedItems? received,
    SyncIdentityStore? identity,
    bool mdns = true,
    ProvisionKey? provision,
    String name = '',
    LedgerStore? retained,
  })  : _data = data,
        _retained = retained,
        _keepReceived = retained != null,
        _state = state ?? const _PlainFile('sync_shares'),
        received = received ?? ReceivedItems.instance,
        _identityStore = identity ?? _KeychainIdentity(),
        _mdns = mdns,
        _provisionOverride = provision,
        _name = name;

  static final instance = LanSync();

  final LedgerStore? _retained;
  bool _keepReceived;

  final _ready = Completer<void>();

  /// Done once what this device kept from others is published, or there is
  /// nothing to wait for. Before that an empty list may only be not loaded.
  Future<void> get ready => _ready.future;

  final SyncedData? _data;
  final LedgerStore _state;

  /// Where what paired devices share is published for the rest of the app.
  final ReceivedItems received;
  final SyncIdentityStore _identityStore;
  final bool _mdns;
  final ProvisionKey? _provisionOverride;

  /// Makes a user and key for a copy on a server (AddConnection).
  Future<Connection> _provision(Server server, SshIdentity admin, String label) =>
      _provisionOverride?.call(server, admin, label) ??
      AddConnection(ServerRepository())(server, admin, label, kind: AccessKind.device, createdBy: _name);

  static const _nameKey = 'sync_device_name';
  static const _enabledKey = 'sync_enabled';

  PrivateKey? _identity;
  String _key = '';
  String _name;
  bool _enabled = true;
  bool _running = false;
  bool _initialized = false;
  String? _error;

  List<PairedDevice> _paired = [];
  final _nearby = <String, NearbyDevice>{};
  final _serviceKeys = <String, String>{};
  final _lastSync = <String, DateTime>{};
  final _lastError = <String, String>{};
  final _busy = <String>{};
  final _ciphers = <String, PeerCipher>{};

  /// The pairing waiting for an answer on this device, if any.
  final incoming = ValueNotifier<IncomingPairing?>(null);

  /// A request to keep a copy, waiting for this device's owner to answer.
  final copyRequest = ValueNotifier<CopyRequest?>(null);

  final _notices = StreamController<String>.broadcast();

  /// Things to tell the user that happened in the background.
  Stream<String> get notices => _notices.stream;

  /// Items this device asked their owners to keep a copy of.
  final _requested = <String>{};

  HttpServer? _server;
  BonsoirBroadcast? _broadcast;
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _discoverySub;
  Timer? _round;
  Timer? _debounce;
  ShareEngine? _engine;
  _Session? _session;

  bool get enabled => _enabled;
  bool get running => _running;
  String get name => _name;
  String? get error => _error;
  List<PairedDevice> get paired => List.unmodifiable(_paired);

  /// Devices on the network this one is not paired with.
  List<NearbyDevice> get nearby =>
      _nearby.values.where((d) => !_isPaired(d.key)).toList();

  bool isOnline(String key) => _nearby.containsKey(key);

  /// The paired devices this device's own [item] is shared with (keys as
  /// in RepositorySyncedData).
  Set<String> sharesOf(String item) => _engine?.sharesOf(item) ?? const {};

  List<String> sharedWith(String item) => [
        for (final p in _paired)
          if (sharesOf(item).contains(p.key)) p.name,
      ];

  /// The name of the device [key] was shared from, or null when it is this
  /// device's own.
  String? receivedFrom(String key) {
    final owner = _engine?.ownerOf(key);
    if (owner == null) return null;
    return _paired.where((p) => p.key == owner).firstOrNull?.name ?? 'another device';
  }

  bool copyRequested(String item) => _requested.contains(item);

  /// Asks the owner of the received [item] to let this device keep its own
  /// copy. The answer arrives with the owner's next offer.
  Future<void> requestCopy(String item) async {
    final owner = _engine?.ownerOf(item);
    final device = owner == null ? null : _nearby[owner];
    if (owner == null || device == null) {
      throw StateError('The owner is not on this network');
    }
    await _post(device.uri('/copy'), {
      'from': _key,
      'box': _cipher(owner).seal({'kind': 'copy', 'item': item}),
    });
    _requested.add(item);
    notifyListeners();
  }

  /// Shares [item] with exactly [peers]; the others lose it at their next
  /// sync.
  Future<void> share(String item, Set<String> peers) async {
    await _engine?.setShares(item, peers);
    notifyListeners();
    unawaited(syncNow());
  }
  DateTime? lastSync(String key) => _lastSync[key];
  String? lastError(String key) => _lastError[key];

  bool _isPaired(String key) => _paired.any((p) => p.key == key);

  @visibleForTesting
  String get key => _key;

  @visibleForTesting
  int? get port => _server?.port;

  @visibleForTesting
  Future<void> start() => _start();

  @visibleForTesting
  Future<void> stop() => _stop();

  /// Stands in for a device Bonjour would have found.
  @visibleForTesting
  void see(NearbyDevice device) => _seen(device);

  /// [keepReceived] keeps what paired devices share after they leave the
  /// network and across restarts (ShareEngine.retained). A TV needs it: it
  /// cannot add servers itself and is used when the phone is elsewhere.
  Future<void> init({bool keepReceived = false}) async {
    if (_initialized) return;
    _initialized = true;
    _keepReceived = keepReceived;
    _enabled = await plainStore.read(key: _enabledKey) != 'false';
    _name = await plainStore.read(key: _nameKey) ?? await _defaultName();
    SyncSignal.instance.localChanges.listen((_) => _onLocalChange());
    if (Platform.isAndroid || Platform.isIOS) {
      AppLifecycleListener(
        onResume: () {
          if (_enabled) _start();
        },
        onPause: _stop,
      );
    }
    if (_enabled) await _start();
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> setEnabled(bool on) async {
    _enabled = on;
    await plainStore.write(key: _enabledKey, value: '$on');
    on ? await _start() : await _stop();
  }

  Future<void> setName(String name) async {
    name = name.trim();
    if (name.isEmpty || name == _name) return;
    _name = name;
    await plainStore.write(key: _nameKey, value: name);
    if (_running) {
      try {
        await _broadcast?.stop();
      } catch (_) {}
      await _advertise();
    }
    notifyListeners();
  }

  Future<void> forget(String key) async {
    _paired = _paired.where((p) => p.key != key).toList();
    _ciphers.remove(key);
    _lastError.remove(key);
    await _saveIdentity();
    final engine = _engine;
    if (engine != null) {
      await engine.forgetPeer(key);
      _changed(true);
    }
    notifyListeners();
  }

  /// Syncs with every paired device that is on the network now.
  Future<void> syncNow() async {
    if (!_running) return;
    await Future.wait([
      for (final p in _paired)
        if (_nearby.containsKey(p.key)) _syncWith(p.key),
    ]);
  }

  // ---- Lifecycle ----

  Future<void> _start() async {
    if (_running) return;
    _running = true;
    try {
      await _loadIdentity();
      if (_engine == null) {
        final engine = ShareEngine(
          data: _data ?? RepositorySyncedData(),
          store: _state,
          retained: _keepReceived ? (_retained ?? _KeychainReceived()) : null,
        );
        final dropped = await engine.load();
        // Set before publishing: what is published is read from it.
        _engine = engine;
        _changed(dropped.isNotEmpty || engine.received.isNotEmpty);
        if (!_ready.isCompleted) _ready.complete();
        if (_data == null) await _dropOldSync(engine);
      }
      // Shared things show only while their owner is here to share them.
      await _suspendAll();
      _server = await _bind();
      _server!.listen(_handle, onError: (_) {}, cancelOnError: false);
      if (_mdns) {
        await _advertise();
        await _discover();
      }
      _round = Timer.periodic(const Duration(seconds: 30), (_) => syncNow());
      _error = null;
    } catch (e) {
      _error = '$e';
      await _stop();
    }
    notifyListeners();
  }

  Future<void> _stop() async {
    _running = false;
    _round?.cancel();
    _debounce?.cancel();
    await _discoverySub?.cancel();
    _discoverySub = null;
    try {
      await _discovery?.stop();
    } catch (_) {}
    try {
      await _broadcast?.stop();
    } catch (_) {}
    await _server?.close(force: true);
    _server = null;
    _discovery = null;
    _broadcast = null;
    _endSession(PairingState.cancelled);
    _nearby.clear();
    _serviceKeys.clear();
    await _suspendAll();
    notifyListeners();
  }

  Future<void> _suspendAll() async {
    final engine = _engine;
    if (engine == null) return;
    var any = false;
    for (final owner in engine.received.keys) {
      any |= engine.suspend(owner);
    }
    _changed(any);
  }

  /// [key] went away: what it shares goes away with it until it is back.
  Future<void> _gone(String key) async {
    _changed(_engine?.suspend(key) ?? false);
  }

  static Future<HttpServer> _bind() async {
    try {
      return await HttpServer.bind(InternetAddress.anyIPv6, 0, v6Only: false);
    } catch (_) {
      return HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
  }

  static Future<String> _defaultName() async {
    if (Platform.isAndroid) {
      try {
        final name = await const MethodChannel('dev.nogipx.vzhukh/vpn')
            .invokeMethod<String>('deviceName');
        if (name != null && name.isNotEmpty) return name;
      } catch (_) {}
      return 'Android';
    }
    final host = Platform.localHostname.replaceAll(RegExp(r'\.local$'), '');
    return host.isEmpty ? Platform.operatingSystem : host;
  }

  // ---- Identity and trust ----

  Future<void> _loadIdentity() async {
    if (_identity != null) return;
    final raw = await _identityStore.read();
    if (raw != null) {
      final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      _identity = PrivateKey(unb64(json['private'] as String));
      _paired = [
        for (final p in json['paired'] as List? ?? const [])
          PairedDevice.fromJson(Map<String, dynamic>.from(p as Map)),
      ];
    } else {
      _identity = PrivateKey.generate();
      await _saveIdentity();
    }
    _key = b64(_identity!.publicKey.asTypedList);
  }

  Future<void> _saveIdentity() => _identityStore.write(jsonEncode({
          'private': b64(_identity!.asTypedList),
          'paired': _paired.map((p) => p.toJson()).toList(),
        }));

  Future<void> _trust(String key, String name) async {
    _paired = [
      ..._paired.where((p) => p.key != key),
      PairedDevice(key: key, name: name, pairedAt: DateTime.now()),
    ];
    await _saveIdentity();
    notifyListeners();
    unawaited(_syncWith(key));
  }

  PeerCipher _cipher(String key) =>
      _ciphers[key] ??= PeerCipher(_identity!, unb64(key));

  // ---- Discovery ----

  Future<void> _advertise() async {
    final short = _key.replaceAll(RegExp('[^A-Za-z0-9]'), '').substring(0, 8);
    final broadcast = BonsoirBroadcast(
      service: BonsoirService(
        name: 'vzhukh-$short',
        type: _serviceType,
        port: _server!.port,
        attributes: {'k': _key, 'n': _name, 'v': _protocol},
      ),
    );
    _broadcast = broadcast;
    await broadcast.initialize();
    await broadcast.start();
  }

  Future<void> _discover() async {
    final discovery = BonsoirDiscovery(type: _serviceType);
    _discovery = discovery;
    await discovery.initialize();
    _discoverySub = discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent():
          discovery.serviceResolver.resolveService(event.service);
        case BonsoirDiscoveryServiceResolvedEvent():
          _found(event.service);
        case BonsoirDiscoveryServiceUpdatedEvent():
          _found(event.service);
        case BonsoirDiscoveryServiceLostEvent():
          final key = _serviceKeys.remove(event.service.name);
          if (key != null && _nearby.remove(key) != null) {
            notifyListeners();
            unawaited(_gone(key));
          }
        default:
          break;
      }
    });
    await discovery.start();
  }

  void _found(BonsoirService service) {
    final key = service.attributes['k'];
    if (key == null || key == _key || service.attributes['v'] != _protocol) return;
    final host = _pickHost(service.hostAddresses) ?? service.hostname;
    if (host == null) return;
    _serviceKeys[service.name] = key;
    _seen(NearbyDevice(
      key: key,
      name: service.attributes['n'] ?? service.name,
      host: host,
      port: service.port,
    ));
  }

  void _seen(NearbyDevice device) {
    final wasOnline = _nearby.containsKey(device.key);
    _nearby[device.key] = device;
    notifyListeners();
    if (!wasOnline && _isPaired(device.key)) unawaited(_syncWith(device.key));
  }

  /// IPv4 where there is one: a link-local IPv6 address is useless without
  /// its interface, which the platforms do not report.
  static String? _pickHost(List<String> addresses) =>
      addresses.where((a) => !a.contains(':')).firstOrNull ??
      addresses.where((a) => !a.toLowerCase().startsWith('fe80')).firstOrNull;

  // ---- Pairing ----

  /// Asks [device] to pair. It shows a passkey; the user types it into
  /// [OutgoingPairing.enter] here.
  Future<OutgoingPairing> pair(NearbyDevice device) async {
    await _loadIdentity();
    final start = await _post(device.uri('/pair/start'), {'key': _key, 'name': _name});
    final theirs = start['key'] as String;
    if (theirs != device.key) {
      throw PairingFailed('${device.name} answered with a key it does not advertise');
    }
    final session = start['session'] as String;
    final mine = _identity!.publicKey.asTypedList;
    final peer = unb64(theirs);

    Future<void> enter(int passkey) async {
      for (var round = 0; round < Passkey.rounds; round++) {
        final bit = Passkey.bit(passkey, round);
        final nonce = randomBytes(16);
        final Map<String, dynamic> committed;
        final Map<String, dynamic> opened;
        try {
          committed = await _post(device.uri('/pair/commit'), {
            'session': session,
            'round': round,
            'commit': b64(Passkey.commit(role: 'i', own: mine, peer: peer, nonce: nonce, bit: bit)),
          });
          opened = await _post(device.uri('/pair/open'), {
            'session': session,
            'round': round,
            'nonce': b64(nonce),
          });
        } on _Status catch (e) {
          throw PairingFailed(e.code == HttpStatus.forbidden
              ? 'Wrong code'
              : 'Pairing with ${device.name} ended (${e.code})');
        }
        final expected = Passkey.commit(
          role: 'r',
          own: peer,
          peer: mine,
          nonce: unb64(opened['nonce'] as String),
          bit: bit,
        );
        if (b64(expected) != committed['commit']) {
          throw PairingFailed('${device.name} does not know this code');
        }
      }
      await _trust(theirs, device.name);
    }

    Future<void> cancel() async {
      try {
        await _post(device.uri('/pair/cancel'), {'session': session});
      } catch (_) {}
    }

    return OutgoingPairing._(device.name, enter, cancel);
  }

  void _endSession(PairingState state) {
    final s = _session;
    if (s == null) return;
    _session = null;
    s.prompt.state.value = state;
    if (incoming.value == s.prompt) incoming.value = null;
  }

  _Session _live(Map<String, dynamic> body) {
    final s = _session;
    if (s == null || s.id != body['session']) throw const _Status(410);
    if (!s.live) {
      _endSession(PairingState.cancelled);
      throw const _Status(410);
    }
    return s;
  }

  Map<String, dynamic> _pairStart(Map<String, dynamic> body) {
    if (_session?.live ?? false) throw const _Status(409);
    _endSession(PairingState.cancelled);
    final key = body['key'] as String;
    if (unb64(key).length != 32) throw const _Status(400);
    final id = b64(randomBytes(16));
    final prompt = IncomingPairing._(
      (body['name'] as String?) ?? 'Unknown device',
      Passkey.generate(),
      () {
        if (_session?.id == id) _endSession(PairingState.cancelled);
      },
    );
    _session = _Session(id, key, prompt);
    incoming.value = prompt;
    return {'session': id, 'key': _key, 'name': _name};
  }

  Map<String, dynamic> _pairCommit(Map<String, dynamic> body) {
    final s = _live(body);
    if (body['round'] != s.round || s.theirCommit != null) throw const _Status(409);
    s.theirCommit = body['commit'] as String;
    s.nonce = randomBytes(16);
    return {
      'commit': b64(Passkey.commit(
        role: 'r',
        own: _identity!.publicKey.asTypedList,
        peer: unb64(s.key),
        nonce: s.nonce!,
        bit: Passkey.bit(s.prompt.passkey, s.round),
      )),
    };
  }

  Map<String, dynamic> _pairOpen(Map<String, dynamic> body) {
    final s = _live(body);
    if (body['round'] != s.round || s.theirCommit == null) throw const _Status(409);
    final expected = Passkey.commit(
      role: 'i',
      own: unb64(s.key),
      peer: _identity!.publicKey.asTypedList,
      nonce: unb64(body['nonce'] as String),
      bit: Passkey.bit(s.prompt.passkey, s.round),
    );
    if (b64(expected) != s.theirCommit) {
      // One wrong bit ends it: the next try gets a new passkey.
      _endSession(PairingState.failed);
      throw const _Status(HttpStatus.forbidden);
    }
    final nonce = s.nonce!;
    s.round++;
    s.theirCommit = null;
    s.nonce = null;
    if (s.round == Passkey.rounds) {
      _endSession(PairingState.paired);
      unawaited(_trust(s.key, s.prompt.name));
    }
    return {'nonce': b64(nonce)};
  }

  Map<String, dynamic> _pairCancel(Map<String, dynamic> body) {
    _live(body);
    _endSession(PairingState.cancelled);
    return {'ok': true};
  }

  // ---- Sync ----

  /// The first version synced everything with every paired device. What it
  /// brought in is removed once: from now on things arrive only when their
  /// owner shares them.
  Future<void> _dropOldSync(ShareEngine engine) async {
    final ledger = await plainStore.read(key: 'sync_ledger');
    if (ledger == null) return;
    try {
      _changed((await engine.dropSyncedFromOthers(ledger, _key)).isNotEmpty);
    } catch (_) {}
    await plainStore.delete(key: 'sync_ledger');
    await plainStore.delete(key: 'sync_acks');
  }

  /// Sends fresh offers shortly after an edit here.
  void _onLocalChange() {
    if (!_running) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), syncNow);
  }

  /// Publishes what is received now, and tells the screens when something
  /// they show changed.
  void _changed(bool changed) {
    if (!changed) return;
    received.set(
      _engine?.received ?? {},
      {for (final p in _paired) p.key: p.name},
    );
    SyncSignal.instance.remote.value++;
    notifyListeners();
  }

  /// Takes [owner]'s offer, then its answers to copy requests: a granted
  /// copy becomes this device's own.
  Future<void> _received(String owner, Map<String, dynamic> message) async {
    final engine = _engine!;
    _changed(engine.accept(owner, _entries(message['offer'])));
    final name = _paired.where((p) => p.key == owner).firstOrNull?.name ?? 'The owner';
    final grants = message['grants'];
    if (grants is Map) {
      for (final MapEntry(key: item, value: bundle) in grants.entries) {
        // Only what this device asked for: a copy is not pushed on anyone.
        if (!_requested.remove(item)) continue;
        await engine.keep(_entries(bundle));
        _changed(true);
        _notices.add('$name let this device keep its copy.');
      }
    }
    for (final item in (message['denials'] as List? ?? const []).cast<String>()) {
      if (_requested.remove(item)) {
        _notices.add('$name did not let this device keep a copy.');
        notifyListeners();
      }
    }
  }

  Future<Map<String, dynamic>> _serveCopy(Map<String, dynamic> body) async {
    final from = body['from'] as String;
    final engine = _engine;
    if (!_isPaired(from) || engine == null) throw const _Status(403);
    final Map<String, dynamic> message;
    try {
      message = _cipher(from).open(body['box'] as String);
    } catch (_) {
      throw const _Status(400);
    }
    final item = message['item'];
    if (message['kind'] != 'copy' || item is! String) throw const _Status(400);
    if (!engine.sharesOf(item).contains(from)) throw const _Status(403);
    if (copyRequest.value != null) throw const _Status(409);

    final value = (await (_data ?? RepositorySyncedData()).snapshot())[item];
    final title = value is Map
        ? (value['nickname'] ?? value['label'] ?? item) as String
        : item == 'rules'
            ? 'the rules'
            : item;
    final name = _paired.firstWhere((p) => p.key == from).name;
    final data = _data ?? RepositorySyncedData();
    late final CopyRequest request;
    request = CopyRequest._(
      from,
      name,
      item,
      title,
      (adminFor) async {
        final bundle = await BuildCopyBundle(data: data, provision: _provision)(
          item,
          peerName: name,
          adminFor: adminFor,
        );
        if (copyRequest.value == request) copyRequest.value = null;
        engine.answer(from, item, bundle);
        unawaited(_syncWith(from));
      },
      () {
        if (copyRequest.value == request) copyRequest.value = null;
        engine.answer(from, item, null);
        unawaited(_syncWith(from));
      },
    );
    copyRequest.value = request;
    return {'ok': true};
  }

  static List<Map<String, dynamic>> _entries(Object? raw) => [
        for (final e in raw as List) Map<String, dynamic>.from(e as Map),
      ];

  Future<void> _syncWith(String key) async {
    final device = _nearby[key];
    if (device == null || _engine == null || !_busy.add(key)) return;
    try {
      final cipher = _cipher(key);
      final offer = await _engine!.offerFor(key);
      final answers = _engine!.answersFor(key);
      final reply = await _post(device.uri('/sync'), {
        'from': _key,
        'box': cipher.seal({
          'kind': 'req',
          'offer': offer,
          'grants': answers.grants,
          'denials': answers.denials.toList(),
        }),
      });
      final message = cipher.open(reply['box'] as String);
      if (message['kind'] != 'resp') throw const FormatException('Not a sync reply');
      _engine!.delivered(key, answers.grants.keys, answers.denials);
      await _received(key, message);
      _lastSync[key] = DateTime.now();
      _lastError.remove(key);
    } on _Status catch (e) {
      _lastError[key] = e.code == HttpStatus.forbidden
          ? 'Not paired on ${device.name}'
          : 'Failed: $e';
      await _gone(key);
    } catch (e) {
      _lastError[key] = 'Failed: $e';
      await _gone(key);
    } finally {
      _busy.remove(key);
      notifyListeners();
    }
  }

  Future<Map<String, dynamic>> _serveSync(Map<String, dynamic> body) async {
    final from = body['from'] as String;
    if (!_isPaired(from) || _engine == null) throw const _Status(403);
    final cipher = _cipher(from);
    final Map<String, dynamic> message;
    try {
      message = cipher.open(body['box'] as String);
    } catch (_) {
      throw const _Status(400);
    }
    if (message['kind'] != 'req') throw const _Status(400);
    await _received(from, message);
    final answers = _engine!.answersFor(from);
    final reply = cipher.seal({
      'kind': 'resp',
      'offer': await _engine!.offerFor(from),
      'grants': answers.grants,
      'denials': answers.denials.toList(),
    });
    _engine!.delivered(from, answers.grants.keys, answers.denials);
    _lastSync[from] = DateTime.now();
    _lastError.remove(from);
    notifyListeners();
    return {'box': reply};
  }

  // ---- HTTP ----

  static const _maxBody = 4 << 20;

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.method != 'POST') throw const _Status(404);
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > _maxBody) throw const _Status(413);
      }
      final body = Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      final reply = switch (request.uri.path) {
        '/pair/start' => _pairStart(body),
        '/pair/commit' => _pairCommit(body),
        '/pair/open' => _pairOpen(body),
        '/pair/cancel' => _pairCancel(body),
        '/sync' => await _serveSync(body),
        '/copy' => await _serveCopy(body),
        _ => throw const _Status(404),
      };
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(reply));
    } on _Status catch (e) {
      response.statusCode = e.code;
    } catch (_) {
      response.statusCode = HttpStatus.badRequest;
    }
    try {
      await response.close();
    } catch (_) {}
  }

  static Future<Map<String, dynamic>> _post(Uri uri, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
      final response = await request.close().timeout(const Duration(seconds: 20));
      final text = await utf8.decodeStream(response).timeout(const Duration(seconds: 20));
      if (response.statusCode != HttpStatus.ok) throw _Status(response.statusCode);
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    } finally {
      client.close(force: true);
    }
  }
}
