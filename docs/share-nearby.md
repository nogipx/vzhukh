# Share VPN with someone nearby

> **Status: rejected, will not be implemented (2026-10-21).** Invites plus a
> regular hotspot already cover sharing with friends; the work-VPN case is
> covered by adding the laptop as an SSH server (Remote Login). The cost
> (Wi-Fi Direct quirks, a relay, two modes) is not worth it. Kept for
> reference only.

A device with vzhukh (the host) lends an upstream to other devices with
vzhukh nearby (clients). The client chooses which of its apps go through, as
with any route. No root anywhere.

## Modes

- **One-off (anyone).** The host presses "Share" and shows a six-digit
  passkey; whoever types it is in for this session only. Nothing is
  remembered on either side: stopping the share forgets everything, and
  meeting again means a new passkey.
- **Own devices (paired).** Devices already paired for sync (DESIGN.md,
  "Sharing between your own devices") use their long-term keys, no passkey.
  The host turns on "Gateway for my devices" once; its paired devices see it
  whenever it is on the same network.

## Hosts, clients, links

| Host    | Links                              | Upstreams it can share   |
|---------|------------------------------------|--------------------------|
| Android | Wi-Fi Direct group, shared Wi-Fi   | a route                  |
| macOS   | shared Wi-Fi (no Wi-Fi Direct)     | a route, system network  |

- Clients: Android and Android TV.
- Up to 5 clients per host at once.
- Bluetooth is out of scope for now (see Later).

## Upstreams

- **Route.** One of the host's routes, picked for the share; not
  necessarily the one the host uses itself, and the host's own VPN does not
  have to be on. Goes through the host's chains as usual.
- **System network (macOS).** Whatever the Mac's own routing does, e.g. a
  work VPN running on it. Case: laptop on the work VPN, phone sends chosen
  apps through the laptop.
  - Relay dials are not bound to the physical interface (unlike the
    helper's direct dials), so the work VPN's routes catch them.
  - DNS is resolved on the Mac by the system resolver, so split DNS of the
    work VPN (`*.corp` only on its servers) works.

## Flow

### One-off

1. Host presses "Share", picks the upstream. It makes a one-off key for the
   session; an Android host also creates a Wi-Fi Direct group with a random
   name and passphrase. The share is announced over NSD on the current
   network and, on Android, over Wi-Fi Direct service discovery.
2. Client opens "Connect to someone nearby" and picks a share. For Wi-Fi
   Direct it joins the group with `WifiP2pConfig.Builder` (API 29+, no
   system dialog).
3. Host shows a six-digit passkey; the client types it (D-pad on a TV). It
   proves the two one-off keys as in device pairing.
4. Client starts its VPN with the host as upstream.
5. Host sees the clients and can drop any. Stopping the share drops all,
   destroys the session key and removes the group.

### Own devices

1. Host turns on "Gateway for my devices" and picks the upstream. Its sync
   NSD record says it is a gateway.
2. A paired client sees it among its upstreams and picks it; the channel is
   between the two long-term keys.
3. Host sees the clients and can drop any; turning the gateway off drops
   all.

## Security

- The relay serves only keys proven with the passkey in this session
  (one-off) or keys it is paired with (own devices).
- One-off: a wrong passkey ends the attempt, the next try gets a new one.
  Within a session a client keeps its key in memory and reconnects after a
  dropped link without a new passkey; a dropped client needs a new one.
- The Wi-Fi Direct passphrase is not a boundary: it is announced in the
  service record so the client can join without a QR. The group gives no
  internet (local-only, no NAT); only the relay does.

## Data path

```
client apps → TUN → gVisor → [Wi-Fi Direct / Wi-Fi] → relay on host
            → route: host's chains → SSH → server
            → system network (macOS): host's routing → e.g. work VPN
```

- TCP and UDP. UDP rides a udpgw stream to the host; for a route the host
  passes it to the route's udpgw, for the system network it sends it itself.
- Relay protocol: open. Leading option: an SSH server inside the host
  (`x/crypto/ssh`) keyed with the session or long-term keys, so the host is
  one more hop to the client's chains and the client side barely changes.
- On macOS the relay lives in the helper (`vzhukhd`), next to the chains.

## Open risks (prototype first)

- Client's socket to the host while the client's VPN is up. vzhukh is
  excluded from its own tunnel and Android keeps the Wi-Fi Direct subnet in
  the local network table, so this should hold.
- Work VPNs that block the local network (AnyConnect, GlobalProtect,
  Zscaler policies): the phone cannot reach the Mac over Wi-Fi at all. Check
  first: with the work VPN up, reach the Mac from the phone.
- System network on a Mac whose own vzhukh tunnel is up: the utun's routes
  would catch the relay's dials. Either the system network upstream needs
  the Mac's vzhukh tunnel off, or the relay routes around the utun.
- Android host: Wi-Fi Direct group while connected to Wi-Fi itself depends
  on the chip (same-channel concurrency).
- Screen off and Doze: hosts and clients on Android need a foreground
  service.
- Permissions: `NEARBY_WIFI_DEVICES` on Android 13+, location below; local
  network access prompt on macOS.

## Prototype

1. Android host creates a group, client joins with name and passphrase;
   with the client's VPN on, a TCP echo between them works both ways.
2. Same over a shared Wi-Fi network.
3. Mac on a work VPN: the phone reaches a listener on the Mac, and a dial
   from that listener reaches a host only the work VPN can.

## Later

- Bluetooth (RFCOMM / L2CAP) for hosts whose work VPN blocks the local
  network; 1-2 Mbit/s.
- Devices without vzhukh through an HTTP proxy or PAC.
