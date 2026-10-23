# Vzhukh — Architecture & Design

## Core concept

Vzhukh is a personal tool that redirects a device's traffic through your
own SSH servers (Android, iOS, macOS). Traffic is routed through a SOCKS5
proxy opened over an SSH tunnel (`ssh -D` equivalent).

The owner provisions servers (creates dedicated Linux users, installs SSH
keys) and shares encrypted invite QR codes with friends. Each friend gets
their own Linux user and key — revocation deletes that user.

---

## Data model

### Server
Host + port + nickname. Many connections per server.

### Connection
One SSH key pair = one person. Stored per server.
- `canConnect = true` — private key is on this device (owner or imported invite)
- `canConnect = false` — only public key stored (friend's connection, for revocation)

Fixed Linux username format: `flume_<label_slug>` (e.g. `flume_alice`).
Owner gets `flume_owner`.

### Route (planned)
An ordered list of (Server, Connection) hops. 1 hop = plain tunnel.
N hops = chained tunnel: each hop forwards to the next via SSH port
forwarding, SOCKS5 proxy runs on the last hop.

```
Route
  id, label
  hops: [(Server, Connection), ...]   ordered, min 1
```

A single-server connect is just a Route with one hop — no special casing.

---

## Chain tunnels

### How it works

SSH `forwardLocal(host, port)` returns `SSHForwardChannel` which already
implements `SSHSocket`. This means we can feed it directly into a new
`SSHClient` without any adapters.

```
client1 = SSHClient(SSHSocket.connect(server1))
channel = client1.forwardLocal(server2.host, server2.port)
client2 = SSHClient(channel)          // channel is SSHSocket
channel2 = client2.forwardLocal(server3.host, server3.port)
client3 = SSHClient(channel2)
// SOCKS5 proxy on client3
```

### SshTunnel refactor

Current: `SshTunnel(Server, SshIdentity)`
Planned: `SshTunnel(List<RouteHop>)` where `RouteHop = (Server, Connection)`

The tunnel builds the chain, opens SOCKS5 on the last client, and holds
all intermediate clients for cleanup.

### Teardown

All clients must be closed in reverse order on disconnect.

### Latency

Each hop adds one RTT to the SSH handshake. For N hops, connection setup
is O(N) in RTTs. Steady-state throughput is limited by the slowest link.

---

## Security model

- Each Linux user has `-s /bin/false` — no interactive shell
- Each key has `restrict,port-forwarding` in `authorized_keys` — no
  command execution, no X11, no agent, no reverse tunnels exposed
- The admin password is kept only if the user asks, per server and on this
  device only: in the keychain / Keystore, read after the device owner
  unlocks it (fingerprint, face, Touch ID or the device PIN, `local_auth`).
  Sharing never sees it. Otherwise it is used once and discarded
- Private keys live in `flutter_secure_storage` (Keychain / Keystore)
- Friend private keys are never stored on admin device — only returned
  for export as encrypted invite
- Invite encryption: PBKDF2-SHA256 (100k iterations) + AES-256-GCM

---

## Provisioning flow

1. User enters host + admin credentials (password, used once)
2. App connects as admin via SSH (supports both `password` and
   `keyboard-interactive` auth methods)
3. App runs: `useradd -m -s /bin/false flume_owner`, sets up `.ssh/`
4. Generates Ed25519 key pair (pinenacl `SigningKey.generate()`)
5. Writes `restrict,port-forwarding <pubkey>` to `authorized_keys`
6. Saves `Connection(privateKeyPem=...)` to secure storage
7. Admin password is discarded

### Adding a friend

1. Admin re-enters admin credentials (not stored)
2. App generates new key pair for the friend
3. Creates Linux user `flume_<label>`, installs pubkey
4. Saves `Connection(privateKeyPem=null)` — only pubkey for revocation
5. Returns full connection (with private key) for export only

### Revoking

1. Admin re-enters admin credentials
2. `userdel -r flume_<label>` — removes user + home dir
3. Deletes Connection from local storage

---

## Reconnect strategy

The SOCKS listener (and on Android the TUN) lives for the whole session; only
the SSH chain under it is rebuilt. Apps keep their proxy port, and while the
chain is down their new connections wait up to 10s for it instead of leaking
around the tunnel.

How a dead chain is noticed:
- Any hop's transport closing (`SSHClient.done`) → reported at once
- Probe: a keepalive to the last hop with a 5s reply timeout, every 15s.
  dartssh2's own keepalive is off: its ping has no timeout and never fails on
  a connection that went silent, which is exactly what a sleep leaves behind
- Sleep: the heartbeat ticks every 5s and compares wall-clock time; a gap
  means the machine slept, and the chain is probed immediately on wake
- Network change: every path update after the first triggers a probe (not
  only a change of interface type: Wi-Fi to another Wi-Fi reports wifi twice)
- A SOCKS request whose channel open gets no answer in 15s triggers a probe;
  a refused open (`SSHChannelOpenError`) does not, the chain answered

Recovery:
- Lost chain → first redial at once, then backoff (2, 4, 8, 16, 30s)
- Network appears while waiting out a backoff → backoff reset, redial in 1s
- A tunnel that never came up is retried with a full `connect()`
- User press Cancel → stops everything, no auto reconnect
- `connect()` always tears down existing tunnel before starting a new one

## Android tunnel

The tunnel runs in Go inside `VzhukhVpnService` (`go/tun2socks/main.go`
over JNI, `internal/mobile`). It does not run in Dart inside the app's
window: closing the app, swiping it away or a long Doze leaves it running.

```
apps → TUN (VpnService) → engine (gVisor) → chains → SSH → server
                                              └→ udpgw on the server, for UDP
```

- vzhukh itself is excluded from the tunnel, so the SSH connections leave
  directly to any host, chains and host names included, with no route
  carving.
- Reconnects use the same `internal/chains` as the macOS helper:
  - keepalive with a reply timeout;
  - a wall-clock check that notices a sleep and redials at once;
  - quick retries while the network comes back.
- A `ConnectivityManager` default-network callback nudges the chain on every
  network change. It also keeps `setUnderlyingNetworks` current.
- DNS goes to the far end over TCP, to the resolvers set on the last hop's
  server (8.8.8.8 and 8.8.4.4 when none are), so a resolver only that
  server reaches works; the same on iOS. UDP goes through udpgw when the server
  has it.
- The app only starts, stops and polls the status (`vpnStatus`).
- Debug builds take
  `adb shell am start -n dev.nogipx.vzhukh/.MainActivity -a dev.nogipx.vzhukh.DEBUG_START --es config '{...}'`
  for testing without the UI.

Checked on an emulator (Android 11) against `cmd/sshtestserver`:
- route up 13 ms after start;
- server restart: redialed;
- airplane mode: up again 0.9 s after the network returned;
- 50 s of forced deep Doze: no drop.

## Sets

Rules and Android app lists are named sets, like servers and routes are
named: they are shared, copied, exported and imported on their own.

- **Rule sets** (macOS): several, one active. The active one is this Mac's
  choice and is not shared. A set another device shares can be made active
  while that device is on the network; when it leaves, the own set active
  before applies again. A rule in it naming a route this Mac does not have
  goes through the connected route.
- **App sets** (Android): a route or a server points at one, so one change
  reaches all of them. Lists kept inside routes and next to servers before
  sets were moved into sets once (`MigrateToSets`).
- **Archive.** `{"vzhukh": "ruleset" | "appset", "version": 1, "set": ...}`
  without the id: importing makes a new set. Saved to a file (a share sheet
  on Android) or copied as text.

## Sharing between your own devices

Paired devices on the same network can share servers (with their
connections, private keys included, and app set), routes (with the servers
and connections of their hops and their app set), rule sets and app sets.
Code: `lib/sync/`.

- **Discovery.** Bonjour/NSD service `_vzhukh._tcp`; TXT carries the device's
  public key (`k`), its name (`n`) and the protocol version (`v`). Transport
  is HTTP on a random port.
- **Identity.** One X25519 key per device, kept with the list of paired
  devices in the keychain.
- **Pairing.** Passkey entry, as with a Bluetooth keyboard. The device being
  asked shows a random six-digit passkey; the user types it on the device
  that asked. There is no "codes match" button to press without looking:
  pairing needs someone who saw the other screen. The passkey is never
  sent. Its 20 bits are proven one per round with commitments
  `H(role‖own key‖peer key‖nonce‖bit)`, each opened only after the other
  side has committed, so a key substituted in the middle survives with
  probability 2^-20 and a recorded exchange gives nothing to brute-force.
  One wrong bit ends the session; the next try gets a new passkey.
  Pairing shares nothing by itself.
- **Channel.** Every message is a NaCl box between the two long-term keys.
  A device answers only keys it paired with.
- **Sharing.** The owner picks, per item, the paired devices it goes to.
  Every exchange carries each side's offer: all of its own items shared
  with the other, whole.
- **Received is not stored.** What others share is kept in memory only
  (`ReceivedItems`) and shown in its own "On this network" section, apart
  from the device's own things. Each offer replaces it; it is dropped when
  the owner's Bonjour service goes away, an exchange with it fails, or the
  app starts or goes to the background. Keys of a server shared from
  elsewhere never touch this device's disk or keychain; a tunnel already up
  keeps running. Received items cannot be edited and are never offered
  onward.
- **Copies.** The receiver can ask for a copy of its own. The owner is asked
  to allow it. A copy never carries the owner's key: for every server in it
  the owner makes a new user with a key of its own (as for a friend, which
  needs admin access), keeps the public half among the server's
  connections, where it can be revoked on its own, and sends the copy with
  the new key. Copies wait to be sent in memory only. The receiver stores
  the copy as its own item, kept away from the owner and after unsharing,
  no longer updated by it. Rule sets and app sets are copied as they are.
- **When.** On discovering a paired device, 1.5 s after a local change, and
  every 30 s. Phones and TVs sync while the app is in the foreground.

Manual transfers are sealed too. A sender's QR carries a 16-character code
(80 bits; also typed by hand) the payload is sealed with, and delivery
counts only when the receiver proves it opened it. A waiting TV shows a
one-off public key and accepts only payloads sealed to it, so nobody who
has not seen its screen can push a route to it.
