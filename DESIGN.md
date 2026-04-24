# Vzhukh — Architecture & Design

## Core concept

Vzhukh is a personal SSH-based VPN for Android/iOS. Traffic is routed
through a SOCKS5 proxy opened over an SSH tunnel (`ssh -D` equivalent).

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
- Admin password is never stored — used once during provisioning
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

- Tunnel disconnect → exponential backoff reconnect (1, 2, 4, 8, 16, 30s)
- Network change (WiFi ↔ LTE) → immediate reconnect after 1s settle delay
  (detected via `connectivity_plus`, first emission ignored as it is the
  current state not a change)
- User press Cancel → stops everything, no auto reconnect
- `connect()` always tears down existing tunnel before starting a new one
