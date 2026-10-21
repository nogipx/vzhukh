package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/control"
	singlogger "github.com/sagernet/sing/common/logger"

	"github.com/nogipx/vzhukh/tun2socks/internal/procinfo"
	"github.com/nogipx/vzhukh/tun2socks/internal/routetable"
	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
)

// The tunnel's addresses, in the benchmarking range (RFC 2544) that no
// network uses: 172.19.0.0/30, what sing-box picks, sits inside the
// 172.16.0.0/12 a corporate VPN here routes, and lost its DNS address to it.
// 198.19.0.1 is the interface; 198.19.0.2, inside the same /30 and so routed
// into it, is where the system is told its DNS server is. The IPv6 pair
// exists so that IPv6 traffic, too, lands in the tunnel instead of going
// around every rule.
var (
	tunAddress4 = netip.MustParsePrefix("198.19.0.1/30")
	tunAddress6 = netip.MustParsePrefix("fdfe:dcba:9876::1/126")
	tunDNS      = netip.MustParseAddr("198.19.0.2")
	tunRoutes4  = []netip.Prefix{netip.MustParsePrefix("0.0.0.0/1"), netip.MustParsePrefix("128.0.0.0/1")}
	tunRoutes6  = []netip.Prefix{netip.MustParsePrefix("::/1"), netip.MustParsePrefix("8000::/1")}
	fallbackDNS = []string{"1.1.1.1", "8.8.8.8"}
)

// DarwinPlatform is the macOS side: utun, routes, DNS settings, and the
// physical interface everything past the tunnel goes out of.
type DarwinPlatform struct {
	logf   func(string, ...any)
	finder *control.DefaultInterfaceFinder
	netMon tun.NetworkUpdateMonitor
	ifMon  tun.DefaultInterfaceMonitor
	dns    *dnsOverride
	dnsCap *dnsState
	direct *directNet

	mu        sync.Mutex
	scoped    *scopedDefault
	device    tun.Tun
	stack     tun.Stack
	cancel    context.CancelFunc
	tunName   string
	tunIndex  int
	callbacks []func(string)

	routesMu sync.Mutex
	routes   routetable.Table
	routesAt time.Time

	scopedMu     sync.Mutex
	scopedIfaces map[string]bool

	healMu   sync.Mutex
	lastHeal time.Time

	// pins are routes added here rather than through sing-tun, which merges
	// its route list into the fewest prefixes and so swallows a /32 inside
	// 128.0.0.0/1. A route only wins over another VPN's when it is the more
	// specific one. hijacked are the foreign DNS servers pinned.
	pins       *pinnedRoutes
	hijacked   []netip.Addr
	captureDNS bool
	bypass4    []netip.Prefix
}

// NewDarwinPlatform starts watching the network. stateDir keeps the DNS
// backup; a leftover one is restored here, before anything else happens.
func NewDarwinPlatform(stateDir string, logf func(string, ...any)) (*DarwinPlatform, error) {
	p := &DarwinPlatform{
		logf:   logf,
		finder: control.NewDefaultInterfaceFinder(),
		dns:    &dnsOverride{backupPath: filepath.Join(stateDir, "dns-backup.json"), logf: logf},
		dnsCap: &dnsState{backupPath: filepath.Join(stateDir, "dns-state-backup.json"), logf: logf},
	}
	p.dnsCap.RestoreLeftOver()
	if err := p.dns.RestoreIfLeftOver(); err != nil {
		logf("dns: restore: %v", err)
	}
	if err := p.finder.Update(); err != nil {
		return nil, err
	}

	logger := &singLogger{logf: logf}
	netMon, err := tun.NewNetworkUpdateMonitor(logger)
	if err != nil {
		return nil, err
	}
	ifMon, err := tun.NewDefaultInterfaceMonitor(netMon, logger, tun.DefaultInterfaceMonitorOptions{InterfaceFinder: p.finder})
	if err != nil {
		return nil, err
	}
	p.netMon, p.ifMon = netMon, ifMon
	p.direct = &directNet{iface: p.interfaceFor, heal: p.healRoutes, logf: logf}
	var debounce *time.Timer
	netMon.RegisterCallback(func() {
		p.invalidateRoutes()
		// Another VPN coming up changes routes first and DNS a moment
		// later; look once things settle.
		p.mu.Lock()
		if debounce == nil {
			debounce = time.AfterFunc(2*time.Second, func() {
				p.reassertRoutes()
				p.refreshSystemDNS()
			})
		} else {
			debounce.Reset(2 * time.Second)
		}
		p.mu.Unlock()
	})

	ifMon.RegisterCallback(func(iface *control.Interface, flags int) {
		name := "none"
		if iface != nil {
			name = iface.Name
		}
		p.refreshUpstream()
		p.mu.Lock()
		p.pinBypassLocked()
		callbacks := append([]func(string){}, p.callbacks...)
		p.mu.Unlock()
		for _, cb := range callbacks {
			cb("default interface is now " + name)
		}
	})
	if err := netMon.Start(); err != nil {
		return nil, err
	}
	if err := ifMon.Start(); err != nil {
		return nil, err
	}
	p.refreshUpstream()
	p.refreshSystemDNS()
	go func() {
		// Not every DNS change comes with a routing change to announce it.
		for range time.Tick(30 * time.Second) {
			p.refreshSystemDNS()
		}
	}()
	return p, nil
}

// refreshSystemDNS rereads macOS's resolvers. While the tunnel is up and
// captures everything, any other general resolver (a VPN that made itself
// the primary one) gets its servers routed into the tunnel: their queries
// are then answered here, and only names a rule leaves to the system go on
// to them.
func (p *DarwinPlatform) refreshSystemDNS() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.device != nil && p.captureDNS {
		if _, err := p.dns.Reassert(tunDNS); err != nil {
			p.logf("dns: reassert: %v", err)
		}
	}

	// Who answers names left to the system: the servers the services had
	// before the tunnel, with the search domains and supplemental resolvers
	// macOS reports now.
	var resolvers []sysResolver
	if out, err := exec.Command("/usr/sbin/scutil", "--dns").Output(); err == nil {
		resolvers = parseScutilDNS(string(out))
	}
	if originals := p.dns.Originals(); len(originals) > 0 {
		var search []string
		for _, r := range resolvers {
			if r.Domain == "" {
				search = append(search, r.Search...)
			}
		}
		resolvers = append([]sysResolver{{Search: search, Servers: originals}}, resolvers...)
	}
	p.direct.setSystem(resolvers)
}

// healRoutes deletes and re-adds the routes the daemon keeps through the
// physical interface. It runs when a bound dial finds no route: after a
// sleep those routes can still be in the table yet lead nowhere, which no
// look at the table reveals. At most once every few seconds, so a network
// that is really down does not turn this into a loop of route changes.
func (p *DarwinPlatform) healRoutes() bool {
	p.healMu.Lock()
	if time.Since(p.lastHeal) < 3*time.Second {
		p.healMu.Unlock()
		return false
	}
	p.lastHeal = time.Now()
	p.healMu.Unlock()

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.device == nil || p.pins == nil {
		return false
	}
	if p.scoped != nil {
		p.scoped.remove()
	}
	p.scoped = addScopedDefault(p.logf)
	p.pins.refreshVia()
	p.pinBypassLocked()
	p.invalidateRoutes()
	p.logf("platform: routes through %s re-added after an unreachable dial", p.scopedName())
	return true
}

func (p *DarwinPlatform) scopedName() string {
	if p.scoped == nil {
		return "the default interface"
	}
	return p.scoped.iface
}

// reassertRoutes puts back the routes the daemon added that the system has
// since dropped. Every route through an interface goes when the interface
// does; after a sleep Wi-Fi comes back with the system's own routes and
// none of these, and a socket bound to Wi-Fi then has nothing to leave by.
// Anything restored is announced, so routes waiting out a backoff retry now
// instead of half a minute later.
func (p *DarwinPlatform) reassertRoutes() {
	p.mu.Lock()
	if p.device == nil || p.pins == nil {
		p.mu.Unlock()
		return
	}
	restored := false
	gateway, iface := defaultGateway()
	switch {
	case p.scoped != nil && (p.scoped.gateway != gateway || p.scoped.iface != iface):
		// A different network: the old route is gone or wrong.
		p.scoped.remove()
		p.scoped = addScopedDefault(p.logf)
		restored = true
	case p.scoped != nil:
		restored = p.scoped.ensure() || restored
	default:
		if p.scoped = addScopedDefault(p.logf); p.scoped != nil {
			restored = true
		}
	}
	if p.pins.ensureAll() {
		restored = true
	}
	p.pinBypassLocked()
	callbacks := append([]func(string){}, p.callbacks...)
	p.mu.Unlock()

	if restored {
		for _, cb := range callbacks {
			cb("routes restored after a network change")
		}
	}
}

// pinBypassLocked routes the bypassed addresses through the physical
// gateway with host routes, which beat the tunnel's /1s. An address some
// other route already claims more specifically than a default route, a
// corporate VPN's network, is left alone: it never reaches the tunnel, and
// pinning it to Wi-Fi would take it away from that VPN.
func (p *DarwinPlatform) pinBypassLocked() {
	if p.pins == nil {
		return
	}
	gateway, iface := defaultGateway()
	if gateway == "" || strings.HasPrefix(iface, "utun") {
		p.logf("platform: no gateway to keep %v out of the tunnel", p.bypass4)
		return
	}
	table, err := routetable.Load()
	tunIndex := p.tunIndex
	defaultIndex, _ := p.defaultInterface()
	var pins []netip.Prefix
	for _, prefix := range p.bypass4 {
		if err == nil {
			// Claimed by another interface: a corporate VPN's network. The
			// pins themselves go through the default interface and do not
			// count, or each round would take back what the last one added.
			r, ok := table.Lookup(prefix.Addr(), func(i int) bool { return i == tunIndex })
			if ok && r.Index != defaultIndex {
				continue
			}
		}
		pins = append(pins, prefix)
	}
	unchanged := same(p.pins.groups["bypass"], pins, gateway)
	p.pins.setVia("bypass", pins, gateway)
	if len(pins) > 0 && !unchanged {
		p.logf("platform: kept out of the tunnel via %s: %v", gateway, pins)
	}
}

// systemResolvesToPlaceholder looks a fresh name up through the system
// resolver and reports whether a placeholder came back.
func systemResolvesToPlaceholder() (bool, string) {
	name := fmt.Sprintf("selftest-%d.vzhukh-check.com", time.Now().UnixNano())
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "/usr/bin/dscacheutil", "-q", "host", "-a", "name", name).Output()
	if err != nil {
		return false, err.Error()
	}
	for _, line := range strings.Split(string(out), "\n") {
		if v, found := strings.CutPrefix(strings.TrimSpace(line), "ip_address:"); found {
			addr, err := netip.ParseAddr(strings.TrimSpace(v))
			if err == nil {
				return fakeRange.Contains(addr), addr.String()
			}
		}
	}
	return false, "no answer"
}

// fakeRange is where placeholders come from (fakedns.DefaultPrefix).
var fakeRange = netip.MustParsePrefix("198.18.0.0/16")

func sameAddrs(a, b []netip.Addr) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// interfaceFor is the interface dst leaves through with the tunnel's routes
// left out. The table is cached for a few seconds and dropped on every
// routing change.
func (p *DarwinPlatform) interfaceFor(dst netip.Addr) (int, string) {
	if !dst.IsValid() {
		return p.defaultInterface()
	}
	p.mu.Lock()
	tunIndex := p.tunIndex
	p.mu.Unlock()

	p.routesMu.Lock()
	if time.Since(p.routesAt) > 5*time.Second {
		if table, err := routetable.Load(); err == nil {
			p.routes, p.routesAt = table, time.Now()
		}
	}
	table := p.routes
	p.routesMu.Unlock()

	r, ok := table.Lookup(dst, func(index int) bool { return index == tunIndex && tunIndex != 0 })
	if !ok {
		return p.defaultInterface()
	}
	name := ""
	if iface, err := p.finder.ByIndex(r.Index); err == nil {
		name = iface.Name
	} else if iface, err := net.InterfaceByIndex(r.Index); err == nil {
		name = iface.Name
	} else {
		return p.defaultInterface()
	}
	if defaultIndex, _ := p.defaultInterface(); r.Index != defaultIndex {
		p.ensureScopedRoute(name)
	}
	return r.Index, name
}

// ensureScopedRoute gives an interface other than the default one, a
// corporate VPN's, a default route of its own scope.
//
// A socket bound with IP_BOUND_IF is routed only by routes scoped to its
// interface; for the primary interface macOS falls back to the unscoped
// ones, for any other it does not, and the connect fails with "network is
// unreachable". VPN clients add plain routes, so without this the daemon
// could not reach a corporate DNS server through the corporate VPN. The
// route applies to bound sockets only, which means the daemon's, and goes
// away with the interface.
func (p *DarwinPlatform) ensureScopedRoute(iface string) {
	p.scopedMu.Lock()
	defer p.scopedMu.Unlock()
	if p.scopedIfaces[iface] {
		return
	}
	out, err := exec.Command("/sbin/route", "-n", "add", "-ifscope", iface, "default", "-interface", iface).CombinedOutput()
	exists := err != nil && strings.Contains(string(out), "File exists")
	if err != nil && !exists {
		p.logf("platform: scoped default on %s: %v: %s", iface, err, strings.TrimSpace(string(out)))
		return
	}
	if p.scopedIfaces == nil {
		p.scopedIfaces = map[string]bool{}
	}
	p.scopedIfaces[iface] = true
	if !exists {
		p.logf("platform: scoped default on %s", iface)
	}
}

func (p *DarwinPlatform) invalidateRoutes() {
	p.routesMu.Lock()
	p.routesAt = time.Time{}
	p.routesMu.Unlock()
	// An interface that went away took its scoped route with it, and one
	// that comes back under the same name needs it again.
	p.scopedMu.Lock()
	p.scopedIfaces = nil
	p.scopedMu.Unlock()
}

func (p *DarwinPlatform) defaultInterface() (int, string) {
	iface := p.ifMon.DefaultInterface()
	if iface == nil {
		return 0, ""
	}
	return iface.Index, iface.Name
}

// refreshUpstream picks the DNS servers direct lookups go to: what the user
// set by hand, else what DHCP gave this network, else what the system used
// before the tunnel came up, and public resolvers last.
func (p *DarwinPlatform) refreshUpstream() {
	_, iface := p.defaultInterface()
	p.mu.Lock()
	p.mu.Unlock()

	// What DHCP gave this network first, then whatever else the system
	// resolves with, as long as it is reached through the same physical
	// interface: a corporate VPN's servers are in resolv.conf too while it
	// is connected, and names going direct are none of its business. Names
	// a rule leaves to the system go to it through ExchangeSystemDNS.
	candidates := dhcpDNS(iface)
	defaultIndex, _ := p.defaultInterface()
	for _, c := range resolvConf() {
		if addr, err := netip.ParseAddr(c); err == nil {
			if index, _ := p.interfaceFor(addr); index == defaultIndex {
				candidates = append(candidates, c)
			}
		}
	}
	candidates = append(candidates, fallbackDNS...)

	seen := map[netip.AddrPort]bool{}
	var servers []netip.AddrPort
	for _, c := range candidates {
		server, ok := parseNameserver(c)
		if !ok || seen[server] || server.Addr() == tunDNS {
			continue
		}
		seen[server] = true
		servers = append(servers, server)
	}
	p.direct.setUpstream(servers)
}

// Up creates the utun, routes everything into it, starts the stack and
// points DNS at it.
func (p *DarwinPlatform) Up(handler *Handler, capture *Capture, bypass []string) error {
	if err := refuseOtherInterceptors(); err != nil {
		return err
	}
	exclude4, exclude6, err := p.resolveBypass(bypass)
	if err != nil {
		return err
	}
	scoped, err := capture.parse()
	if err != nil {
		return err
	}
	routes4, routes6 := tunRoutes4, tunRoutes6
	if len(scoped) > 0 {
		routes4, routes6 = nil, nil
		for _, prefix := range scoped {
			if prefix.Addr().Is4() {
				routes4 = append(routes4, prefix)
			} else {
				routes6 = append(routes6, prefix)
			}
		}
		// An empty list would mean "everything" to sing-tun. The tunnel's
		// own subnet keeps a family that is not captured out of it.
		if len(routes4) == 0 {
			routes4 = []netip.Prefix{tunAddress4.Masked()}
		}
		if len(routes6) == 0 {
			routes6 = []netip.Prefix{tunAddress6.Masked()}
		}
	}
	setDNS := capture == nil || !capture.KeepSystemDNS

	p.mu.Lock()
	defer p.mu.Unlock()
	if p.device != nil {
		return errors.New("tunnel is already up")
	}
	if idx, _ := p.defaultInterface(); idx == 0 {
		return errors.New("no network connection")
	}

	name := tun.CalculateInterfaceName("")
	opts := tun.Options{
		Name:              name,
		Inet4Address:      []netip.Prefix{tunAddress4},
		Inet6Address:      []netip.Prefix{tunAddress6},
		MTU:               1500,
		AutoRoute:         true,
		Inet4RouteAddress: routes4,
		Inet6RouteAddress: routes6,
		// IPv4 bypasses are host routes through the gateway instead (see
		// pinBypass); cutting a hole into 128.0.0.0/1 splits it into dozens
		// of prefixes, the ones next to the hole narrow enough to steal a
		// corporate VPN's neighbouring addresses.
		Inet6RouteExcludeAddress: exclude6,
		InterfaceFinder:          p.finder,
		InterfaceMonitor:         p.ifMon,
		Logger:                   &singLogger{logf: p.logf},
	}
	device, err := tun.New(opts)
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	stack, err := tun.NewStack("gvisor", tun.StackOptions{
		Context:    ctx,
		Tun:        device,
		TunOptions: opts,
		Handler:    handler,
		Logger:     &singLogger{logf: p.logf},
		UDPTimeout: time.Minute,
	})
	if err != nil {
		cancel()
		device.Close()
		return err
	}
	if err := device.Start(); err != nil {
		cancel()
		stack.Close()
		device.Close()
		return fmt.Errorf("routes: %w", err)
	}
	if err := stack.Start(); err != nil {
		cancel()
		stack.Close()
		device.Close()
		return err
	}
	p.device, p.stack, p.cancel, p.tunName = device, stack, cancel, name
	p.hijacked = nil
	// The tunnel's index first: everything below looks routes up with the
	// tunnel's own left out.
	if iface, err := net.InterfaceByName(name); err == nil {
		p.tunIndex = iface.Index
	}
	p.invalidateRoutes()
	p.scoped = addScopedDefault(p.logf)
	p.pins = &pinnedRoutes{iface: name, index: p.tunIndex, logf: p.logf}
	p.pins.set("tunnel", []netip.Prefix{tunAddress4.Masked()})
	p.bypass4 = exclude4
	p.pinBypassLocked()

	p.captureDNS = setDNS
	if !setDNS {
		p.logf("platform: %s up for %v, system DNS left alone", name, scoped)
		return nil
	}
	// Every network service's DNS setting points at the tunnel. Rewriting
	// the dynamic store's entries instead left macOS scoping the resolver to
	// Wi-Fi, and its queries went to the router: no DNS at all. A VPN client
	// that rewrites the setting is pointed back on the next refresh.
	if _, err := p.dns.Apply(tunDNS); err != nil {
		p.downLocked()
		return fmt.Errorf("dns: %w", err)
	}
	p.logf("platform: %s up, DNS goes through it", name)
	go p.refreshSystemDNS()
	go func() {
		time.Sleep(time.Second)
		ok, answer := systemResolvesToPlaceholder()
		p.logf("dns: self-test: the system resolver gave %s (placeholder: %v)", answer, ok)
	}()
	go p.refreshUpstream()
	return nil
}

// resolveBypass turns the first hops into host routes to keep out of the
// tunnel. Names are resolved now, while DNS still works the usual way.
func (p *DarwinPlatform) resolveBypass(hosts []string) (v4, v6 []netip.Prefix, err error) {
	for _, host := range hosts {
		if prefix, perr := netip.ParsePrefix(host); perr == nil {
			if prefix.Addr().Is4() {
				v4 = append(v4, prefix.Masked())
			} else {
				v6 = append(v6, prefix.Masked())
			}
			continue
		}
		addr, parseErr := netip.ParseAddr(host)
		if parseErr != nil {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			addr, err = p.direct.LookupIPv4(ctx, host)
			cancel()
			if err != nil {
				return nil, nil, fmt.Errorf("resolve server %s: %w", host, err)
			}
		}
		addr = addr.Unmap()
		prefix := netip.PrefixFrom(addr, addr.BitLen())
		if addr.Is4() {
			v4 = append(v4, prefix)
		} else {
			v6 = append(v6, prefix)
		}
	}
	return v4, v6, nil
}

// refuseOtherInterceptors stops the tunnel from coming up under another
// tool that takes connections at the socket layer.
//
// Proxifier is the one met so far. Its network extension takes every
// connection it has a rule for before routing happens, this daemon's own
// included, and a "Direct" rule makes it open a new connection itself, which
// routing then sends into this tunnel. The daemon dials that out, Proxifier
// takes it again, and its loop detection ends it with "network is
// unreachable". The result is a route that never connects and, with
// Proxifier's own proxy usually going through the same server, no internet.
func refuseOtherInterceptors() error {
	if exec.Command("/usr/bin/pgrep", "-x", "Proxifier").Run() == nil {
		return errors.New("Proxifier is running. It takes connections before the tunnel sees them, " +
			"the helper's own included, and the two loop. Quit Proxifier, then connect")
	}
	return nil
}

// Down restores DNS first, so names resolve again the moment the tunnel is
// gone, then removes the interface and its routes.
func (p *DarwinPlatform) Down() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.downLocked()
}

func (p *DarwinPlatform) downLocked() error {
	p.dnsCap.Release()
	err := p.dns.Restore()
	if p.scoped != nil {
		p.scoped.remove()
		p.scoped = nil
	}
	if p.pins != nil {
		p.pins.clear()
		p.pins = nil
	}
	p.hijacked = nil
	if p.cancel != nil {
		p.cancel()
	}
	if p.stack != nil {
		p.stack.Close()
	}
	if p.device != nil {
		if closeErr := p.device.Close(); closeErr != nil && err == nil {
			err = closeErr
		}
	}
	p.device, p.stack, p.cancel, p.tunName, p.tunIndex = nil, nil, nil, "", 0
	return err
}

// Shutdown is Down for the daemon's exit.
func (p *DarwinPlatform) Shutdown() {
	p.Down()
	p.ifMon.Close()
	p.netMon.Close()
}

func (p *DarwinPlatform) Direct() DirectNet                { return p.direct }
func (p *DarwinPlatform) BaseDialer() sshtun.ContextDialer { return p.direct }
func (p *DarwinPlatform) Lookup() ProcessLookup            { return procinfo.Lookup }

func (p *DarwinPlatform) OnNetworkChange(cb func(string)) {
	p.mu.Lock()
	p.callbacks = append(p.callbacks, cb)
	p.mu.Unlock()
}

func (p *DarwinPlatform) Info() PlatformInfo {
	_, iface := p.defaultInterface()
	p.mu.Lock()
	tunName := p.tunName
	p.mu.Unlock()
	var upstream []string
	for _, s := range p.direct.upstreamServers() {
		upstream = append(upstream, s.Addr().String())
	}
	return PlatformInfo{Interface: iface, Tunnel: tunName, Upstream: upstream}
}

// singLogger adapts sing's logger onto logf. sing-tun is chatty at debug
// level, so only warnings and worse are kept.
type singLogger struct{ logf func(string, ...any) }

var _ singlogger.Logger = (*singLogger)(nil)

func (l *singLogger) Trace(args ...any) {}
func (l *singLogger) Debug(args ...any) {}
func (l *singLogger) Info(args ...any)  {}
func (l *singLogger) Warn(args ...any)  { l.logf("tun: %v", fmt.Sprint(args...)) }
func (l *singLogger) Error(args ...any) { l.logf("tun: %v", fmt.Sprint(args...)) }
func (l *singLogger) Fatal(args ...any) { l.logf("tun: %v", fmt.Sprint(args...)) }
func (l *singLogger) Panic(args ...any) { l.logf("tun: %v", fmt.Sprint(args...)) }

// OnStuck registers what to do when repairing routes does not help.
func (p *DarwinPlatform) OnStuck(cb func(reason string)) { p.direct.stuck = cb }

// HealRoutes is for the daemon to call on waking from a long sleep.
func (p *DarwinPlatform) HealRoutes() bool {
	p.direct.woke()
	return p.healRoutes()
}
