package daemon

import (
	"net"
	"net/netip"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/procinfo"
	"github.com/nogipx/vzhukh/tun2socks/internal/routetable"
)

// vpnOwner is who a tunnel interface belongs to, remembered with the
// addresses it had: a new owner of the same utun number gets new ones.
type vpnOwner struct {
	id, name string
	addrs    string
}

// VPNs lists the other VPNs connected now. The list is rebuilt at most every
// few seconds and on every routing change; finding an interface's owner,
// the expensive part, only happens for interfaces not seen before.
func (p *DarwinPlatform) VPNs() []VPN {
	p.vpnMu.Lock()
	defer p.vpnMu.Unlock()
	if p.vpnAt.IsZero() || time.Since(p.vpnAt) > 5*time.Second {
		p.vpns = p.findVPNs()
		p.vpnAt = time.Now()
	}
	return slices.Clone(p.vpns)
}

// vpn finds a connected VPN by ID and makes sure sockets bound to it can
// reach any address, not only the networks it routes.
func (p *DarwinPlatform) vpn(id string) (VPN, bool) {
	for _, v := range p.VPNs() {
		if v.ID == id {
			p.ensureScopedRoute(v.Interface)
			return v, true
		}
	}
	return VPN{}, false
}

// frontOfVPNs routes every network another VPN claims into the tunnel
// first, so that its traffic, too, is seen and follows the rules. For each
// route into a VPN the tunnel gets the two halves of it: one bit more
// specific, they win over the VPN's route and over nothing else, so a LAN or
// a host route inside the network keeps its way. Host routes cannot be
// beaten and stay with the VPN; those are its gateway and its own
// addresses. Without a rule, a VPN's traffic goes back into it (see
// VPN.claims), the way it went before.
//
// It runs after every routing change: a VPN that connects or adds a network
// is followed, one that goes away is let go. When the tunnel goes, its
// routes go with it and every VPN has its networks back.
func (p *DarwinPlatform) frontOfVPNs() {
	p.mu.Lock()
	on := p.frontVPNs && p.pins != nil
	p.mu.Unlock()
	var want []netip.Prefix
	if on {
		for _, v := range p.VPNs() {
			for _, n := range v.Nets {
				if !n.Addr().Is4() || n.Bits() == 0 || n.Bits() >= 32 {
					continue
				}
				lo, hi := halves(n)
				want = append(want, lo, hi)
			}
		}
	}

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.pins == nil {
		return
	}
	if same(p.pins.groups["vpns"], want, "") {
		p.pins.set("vpns", want)
		return
	}
	p.pins.set("vpns", want)
	if len(want) == 0 {
		p.logf("vpn: no other VPN's networks taken")
	} else {
		p.logf("vpn: in front of other VPNs for %v", want)
	}
}

func (p *DarwinPlatform) invalidateVPNs() {
	p.vpnMu.Lock()
	p.vpnAt = time.Time{}
	p.vpnMu.Unlock()
}

func (p *DarwinPlatform) findVPNs() []VPN {
	p.mu.Lock()
	tunIndex := p.tunIndex
	p.mu.Unlock()

	ifaces, err := net.Interfaces()
	if err != nil {
		p.logf("vpn: interfaces: %v", err)
		return nil
	}
	type candidate struct {
		iface net.Interface
		addrs string
	}
	var found []candidate
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagPointToPoint == 0 ||
			iface.Flags&net.FlagLoopback != 0 || iface.Index == tunIndex {
			continue
		}
		// The system keeps utuns of its own (iCloud Private Relay, Back to
		// My Mac, Handoff) with IPv6 link-local addresses only.
		if addrs := ipv4Addrs(iface); addrs != "" {
			found = append(found, candidate{iface, addrs})
		}
	}
	if len(found) == 0 {
		return nil
	}

	if p.vpnOwners == nil {
		p.vpnOwners = map[string]vpnOwner{}
	}
	var services map[string]vpnOwner
	var processes map[int]procinfo.Process
	for _, c := range found {
		if o, ok := p.vpnOwners[c.iface.Name]; ok && o.addrs == c.addrs {
			continue
		}
		if services == nil {
			services = vpnServices()
		}
		owner, ok := services[c.iface.Name]
		if !ok {
			if unit, isUtun := strings.CutPrefix(c.iface.Name, "utun"); isUtun {
				if processes == nil {
					if processes, err = procinfo.TunnelOwners(); err != nil {
						p.logf("vpn: owners: %v", err)
					}
				}
				n, _ := strconv.Atoi(unit)
				if proc, known := processes[n]; known && proc.Path != "" {
					owner, ok = processOwner(proc), true
				}
			}
		}
		if !ok {
			owner = vpnOwner{id: "if:" + c.iface.Name, name: c.iface.Name}
		}
		owner.addrs = c.addrs
		p.vpnOwners[c.iface.Name] = owner
		p.logf("vpn: %s belongs to %s (%s)", c.iface.Name, owner.name, owner.id)
	}

	table, _ := routetable.Load()
	p.direct.mu.Lock()
	resolvers := slices.Clone(p.direct.system)
	p.direct.mu.Unlock()

	out := make([]VPN, 0, len(found))
	for _, c := range found {
		owner := p.vpnOwners[c.iface.Name]
		v := VPN{ID: owner.id, Name: owner.name, Interface: c.iface.Name, Index: c.iface.Index}
		for _, r := range table.Routes {
			if r.Index == c.iface.Index && r.Prefix.Addr().Is4() {
				v.Prefixes = append(v.Prefixes, r.Prefix.String())
				v.Nets = append(v.Nets, r.Prefix)
			}
		}
		for _, r := range resolvers {
			var mine []netip.Addr
			for _, server := range r.Servers {
				if index, _ := p.interfaceFor(server); index == c.iface.Index && !slices.Contains(v.DNS, server) {
					mine = append(mine, server)
				}
			}
			if len(mine) == 0 {
				continue
			}
			v.DNS = append(v.DNS, mine...)
			for _, d := range append([]string{r.Domain}, r.Search...) {
				if d != "" && !slices.Contains(v.Domains, d) {
					v.Domains = append(v.Domains, d)
				}
			}
		}
		v.Split = !v.CarriesAll()
		out = append(out, v)
	}
	return out
}

func ipv4Addrs(iface net.Interface) string {
	addrs, err := iface.Addrs()
	if err != nil {
		return ""
	}
	var out []string
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok && n.IP.To4() != nil {
			out = append(out, n.IP.String())
		}
	}
	return strings.Join(out, ",")
}

// vpnServices maps the interfaces of the system's connected VPN services
// (WireGuard, Outline, IKEv2: whatever `scutil --nc list` shows) to them.
// Their names are the ones the user gave them.
func vpnServices() map[string]vpnOwner {
	out := map[string]vpnOwner{}
	list, err := exec.Command("/usr/sbin/scutil", "--nc", "list").Output()
	if err != nil {
		return out
	}
	for _, line := range strings.Split(string(list), "\n") {
		if !strings.Contains(line, "(Connected)") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		id := fields[2]
		name := id
		if first := strings.Index(line, `"`); first >= 0 {
			if last := strings.LastIndex(line, `"`); last > first {
				name = line[first+1 : last]
			}
		}
		status, err := exec.Command("/usr/sbin/scutil", "--nc", "status", id).Output()
		if err != nil {
			continue
		}
		for _, l := range strings.Split(string(status), "\n") {
			if key, value, ok := strings.Cut(strings.TrimSpace(l), ":"); ok && strings.TrimSpace(key) == "InterfaceName" {
				out[strings.TrimSpace(value)] = vpnOwner{id: "service:" + id, name: name}
				break
			}
		}
	}
	return out
}

// processOwner names a VPN after the program behind it: its app, its
// system extension, or its executable.
func processOwner(proc procinfo.Process) vpnOwner {
	if proc.AppPath != "" {
		return vpnOwner{id: "app:" + proc.AppPath, name: proc.Name}
	}
	// /Library/SystemExtensions/<uuid>/com.example.vpn.systemextension/...:
	// the uuid changes with every update, the bundle does not.
	if i := strings.Index(proc.Path, ".systemextension/"); i >= 0 {
		bundle := filepath.Base(proc.Path[:i])
		return vpnOwner{id: "sysext:" + bundle, name: bundle}
	}
	return vpnOwner{id: "exe:" + proc.Path, name: proc.Name}
}
