package daemon

import (
	"net/netip"
	"os/exec"
	"strings"

	"github.com/nogipx/vzhukh/tun2socks/internal/routetable"
)

// pinnedRoutes are routes added with route(8), grouped by purpose so each
// group can be replaced on its own. They go into the tunnel unless a group
// names a gateway.
type pinnedRoutes struct {
	iface  string
	index  int
	logf   func(string, ...any)
	groups map[string][]pin
}

type pin struct {
	prefix  netip.Prefix
	gateway string
}

func (p *pinnedRoutes) set(group string, prefixes []netip.Prefix) {
	p.setVia(group, prefixes, "")
}

// setVia replaces a group with routes through gateway, or into the tunnel
// when gateway is empty. Setting what is already set only re-adds what has
// gone missing: deleting and re-adding would itself be a routing change,
// and routing changes are what triggers this.
func (p *pinnedRoutes) setVia(group string, prefixes []netip.Prefix, gateway string) {
	if p.groups == nil {
		p.groups = map[string][]pin{}
	}
	if same(p.groups[group], prefixes, gateway) {
		for _, pn := range p.groups[group] {
			p.ensure(pn)
		}
		return
	}
	for _, old := range p.groups[group] {
		p.route("delete", old)
	}
	p.groups[group] = nil
	for _, prefix := range prefixes {
		if pn := (pin{prefix, gateway}); p.route("add", pn) {
			p.groups[group] = append(p.groups[group], pn)
		}
	}
}

// ensureAll re-adds every pin the system dropped, as it does with every
// route through an interface that went down: Wi-Fi during sleep. It reports
// whether anything was missing.
func (p *pinnedRoutes) ensureAll() bool {
	restored := false
	for _, pins := range p.groups {
		for _, pn := range pins {
			if p.ensure(pn) {
				restored = true
			}
		}
	}
	return restored
}

// present looks the exact route up in the table. route(8) is no judge of
// that: adding an interface route that exists succeeds again.
func (p *pinnedRoutes) present(pn pin) bool {
	if pn.prefix.Addr().Is6() {
		return true // IPv6 is never pinned; nothing to look after
	}
	entries, err := routetable.Entries()
	if err != nil {
		return true // cannot tell; adding blindly would loop
	}
	var gateway netip.Addr
	if pn.gateway != "" {
		gateway, _ = netip.ParseAddr(pn.gateway)
	}
	return routetable.Has(entries, pn.prefix, false, gateway, p.index)
}

// ensure adds pn unless it is there, and reports whether it was missing.
func (p *pinnedRoutes) ensure(pn pin) bool {
	if p.present(pn) {
		return false
	}
	out, err := exec.Command("/sbin/route", p.args("add", pn)...).CombinedOutput()
	if err == nil {
		p.logf("platform: route %s restored", pn.prefix)
		return true
	}
	if !strings.Contains(string(out), "File exists") {
		p.logf("platform: restore route %s: %v: %s", pn.prefix, err, strings.TrimSpace(string(out)))
	}
	return false
}

// refreshVia deletes and re-adds every pin through a gateway: those are the
// ones a Wi-Fi drop leaves behind dead.
func (p *pinnedRoutes) refreshVia() {
	for _, pins := range p.groups {
		for _, pn := range pins {
			if pn.gateway == "" {
				continue
			}
			exec.Command("/sbin/route", p.args("delete", pn)[:5]...).Run()
			p.route("add", pn)
		}
	}
}

func same(pins []pin, prefixes []netip.Prefix, gateway string) bool {
	if len(pins) != len(prefixes) {
		return false
	}
	for i := range pins {
		if pins[i].prefix != prefixes[i] || pins[i].gateway != gateway {
			return false
		}
	}
	return true
}

func (p *pinnedRoutes) clear() {
	for group := range p.groups {
		p.set(group, nil)
	}
}

func (p *pinnedRoutes) args(op string, pn pin) []string {
	family := "-inet"
	if pn.prefix.Addr().Is6() {
		family = "-inet6"
	}
	kind, dst := "-net", pn.prefix.String()
	if pn.prefix.IsSingleIP() {
		kind, dst = "-host", pn.prefix.Addr().String()
	}
	if pn.gateway != "" {
		return []string{"-n", op, family, kind, dst, pn.gateway}
	}
	return []string{"-n", op, family, kind, dst, "-interface", p.iface}
}

func (p *pinnedRoutes) route(op string, pn pin) bool {
	prefix := pn.prefix
	args := p.args(op, pn)
	out, err := exec.Command("/sbin/route", args...).CombinedOutput()
	if err != nil && op == "add" && strings.Contains(string(out), "File exists") {
		// Replace whatever was there: the point is that this one wins.
		exec.Command("/sbin/route", p.args("delete", pn)[:5]...).Run()
		out, err = exec.Command("/sbin/route", args...).CombinedOutput()
	}
	if err != nil {
		p.logf("platform: route %s %s: %v: %s", op, prefix, err, strings.TrimSpace(string(out)))
		return false
	}
	return true
}
