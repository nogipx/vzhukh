package daemon

import (
	"net/netip"
	"os/exec"
	"strings"

	"github.com/nogipx/vzhukh/tun2socks/internal/routetable"
)

// scopedDefault is a default route bound to the physical interface
// (route add -ifscope), present while the tunnel is up.
//
// The daemon binds its own sockets to that interface with IP_BOUND_IF, and a
// bound socket is routed by the routes scoped to its interface. macOS keeps
// a scoped default only for interfaces that are not the primary one; for the
// primary it falls back to the unscoped default. That fallback is not
// something to stake every direct connection on once 0/1 and 128/1 point
// into the tunnel, so the route is added explicitly.
type scopedDefault struct {
	iface   string
	gateway string
	logf    func(string, ...any)
}

// addScopedDefault adds the route for the current default interface. It
// returns nil when there is nothing to add or the route already existed, so
// that remove never deletes a route the system put there.
func addScopedDefault(logf func(string, ...any)) *scopedDefault {
	gateway, iface := defaultGateway()
	if gateway == "" || iface == "" || strings.HasPrefix(iface, "utun") {
		return nil
	}
	out, err := exec.Command("/sbin/route", "-n", "add", "-ifscope", iface, "default", gateway).CombinedOutput()
	if err != nil {
		if !strings.Contains(string(out), "File exists") {
			logf("platform: scoped default via %s on %s: %v: %s", gateway, iface, err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	logf("platform: scoped default via %s on %s", gateway, iface)
	return &scopedDefault{iface: iface, gateway: gateway, logf: logf}
}

// defaultGateway is the gateway and interface of the default route.
func defaultGateway() (gateway, iface string) {
	out, err := exec.Command("/sbin/route", "-n", "get", "default").Output()
	if err != nil {
		return "", ""
	}
	for _, line := range strings.Split(string(out), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		switch key {
		case "gateway":
			gateway = strings.TrimSpace(value)
		case "interface":
			iface = strings.TrimSpace(value)
		}
	}
	return gateway, iface
}

// ensure re-adds the route if the system dropped it, and reports whether it
// had to.
func (s *scopedDefault) ensure() bool {
	if entries, err := routetable.Entries(); err == nil {
		gw, _ := netip.ParseAddr(s.gateway)
		if routetable.Has(entries, netip.MustParsePrefix("0.0.0.0/0"), true, gw, 0) {
			return false
		}
	}
	out, err := exec.Command("/sbin/route", "-n", "add", "-ifscope", s.iface, "default", s.gateway).CombinedOutput()
	if err == nil {
		s.logf("platform: scoped default via %s on %s restored", s.gateway, s.iface)
		return true
	}
	if !strings.Contains(string(out), "File exists") {
		s.logf("platform: restore scoped default: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return false
}

func (s *scopedDefault) remove() {
	out, err := exec.Command("/sbin/route", "-n", "delete", "-ifscope", s.iface, "default", s.gateway).CombinedOutput()
	if err != nil {
		s.logf("platform: remove scoped default: %v: %s", err, strings.TrimSpace(string(out)))
	}
}
