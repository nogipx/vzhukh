package daemon

import (
	"net/netip"
	"time"
)

// deadHosts remembers addresses that stayed unreachable after the routes
// were repaired. That is the host's doing, not the routes': a device on
// another network that an app keeps dialing every few seconds. Without the
// memory every such dial would repair the routes again, and a network that
// works would see them torn down and re-added around the clock.
type deadHosts struct {
	ttl time.Duration
	m   map[netip.Addr]time.Time
}

// has reports whether addr failed after a repair within the last ttl.
func (h *deadHosts) has(addr netip.Addr, now time.Time) bool {
	at, ok := h.m[addr]
	return ok && now.Sub(at) < h.ttl
}

func (h *deadHosts) add(addr netip.Addr, now time.Time) {
	if !addr.IsValid() {
		return
	}
	if h.m == nil {
		h.m = map[netip.Addr]time.Time{}
	}
	for a, at := range h.m {
		if now.Sub(at) >= h.ttl {
			delete(h.m, a)
		}
	}
	h.m[addr] = now
}

// forget is for an address that answered after all.
func (h *deadHosts) forget(addr netip.Addr) { delete(h.m, addr) }
