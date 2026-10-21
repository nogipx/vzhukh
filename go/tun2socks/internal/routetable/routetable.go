// Package routetable answers "which interface would this address leave
// through if the tunnel's routes were not there".
//
// The daemon binds every socket it opens past the tunnel to an interface.
// Binding them all to the default one (Wi-Fi) breaks other VPNs: a
// corporate VPN routes its networks into its own interface with routes more
// specific than the tunnel's, and a socket bound to Wi-Fi would ignore them.
// Looking the destination up in the kernel's table, minus the tunnel's own
// routes, sends corporate addresses into the corporate VPN and everything
// else out of Wi-Fi, as macOS would without vzhukh.
package routetable

import "net/netip"

// Route is one entry of the routing table.
type Route struct {
	Prefix netip.Prefix
	Index  int
}

// Table is a snapshot of the unscoped routes.
type Table struct {
	Routes []Route
}

// Entry is any route, scoped ones included, with its gateway when it has
// an address for one. It answers "is this exact route there".
type Entry struct {
	Prefix  netip.Prefix
	Index   int
	Gateway netip.Addr
	Scoped  bool
}

// Has reports whether an entry for prefix exists that goes through gateway
// or, when gateway is invalid, through interface index.
func Has(entries []Entry, prefix netip.Prefix, scoped bool, gateway netip.Addr, index int) bool {
	prefix = prefix.Masked()
	for _, e := range entries {
		if e.Prefix != prefix || e.Scoped != scoped {
			continue
		}
		if gateway.IsValid() {
			if e.Gateway == gateway {
				return true
			}
		} else if e.Index == index {
			return true
		}
	}
	return false
}

// Lookup returns the longest-prefix route for dst among those whose
// interface skip does not reject.
func (t Table) Lookup(dst netip.Addr, skip func(index int) bool) (Route, bool) {
	dst = dst.Unmap()
	best := Route{}
	found := false
	for _, r := range t.Routes {
		if r.Prefix.Addr().Is4() != dst.Is4() || !r.Prefix.Contains(dst) {
			continue
		}
		if skip != nil && skip(r.Index) {
			continue
		}
		if !found || r.Prefix.Bits() > best.Prefix.Bits() {
			best, found = r, true
		}
	}
	return best, found
}
