// Package daemon is vzhukhd: the root process that owns the tunnel
// interface on macOS and decides, connection by connection, where traffic
// goes.
//
// The app tells it what to do over a Unix socket (ipc.go). Everything with
// a decision in it is in this package and below; the operating system is
// behind Platform, which tests replace.
package daemon

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"reflect"
	"sync"
	"sync/atomic"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/chains"
	"github.com/nogipx/vzhukh/tun2socks/internal/fakedns"
	"github.com/nogipx/vzhukh/tun2socks/internal/flows"
	"github.com/nogipx/vzhukh/tun2socks/internal/router"
	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
)

// Version is reported to the app, which offers to update an older helper.
// Bump it with any change to the protocol or behaviour.
const Version = "38"

// Config is everything the app sends to start the tunnel. Private keys
// travel in Routes and stay in memory only.
type Config struct {
	Routes []chains.RouteConfig `json:"routes"`
	Rules  router.Config        `json:"rules"`

	// RemoteDNS answers the queries that get a real answer through a route.
	RemoteDNS string `json:"remoteDns,omitempty"`

	// Capture narrows what the tunnel takes. Nil takes everything.
	Capture *Capture `json:"capture,omitempty"`

	// Bypass are addresses, prefixes or host names kept out of the tunnel
	// altogether, by the routing table rather than by a rule: another
	// VPN's gateway, whose own connection must never pass through here.
	Bypass []string `json:"bypass,omitempty"`
}

// Capture limits the tunnel to some destinations and can leave the system's
// DNS alone. Everything outside Routes never reaches the daemon, so it keeps
// working however it worked before: through another proxy tool, for
// instance, while moving off it one app or network at a time.
type Capture struct {
	// Routes are the prefixes sent into the tunnel. Empty means all.
	Routes []string `json:"routes,omitempty"`

	// KeepSystemDNS leaves DNS settings untouched. Names are then resolved
	// as before, so connections arrive by address and domain rules see only
	// what the first bytes reveal (TLS SNI, HTTP Host).
	KeepSystemDNS bool `json:"keepSystemDns,omitempty"`

	// LeaveVPNs leaves other VPNs' networks to them. By default the tunnel
	// takes them first, so their traffic is seen and follows the rules; a
	// VPN client that restores its routes when anything is in front of them
	// needs this instead. A capture narrowed by Routes leaves them anyway.
	LeaveVPNs bool `json:"leaveVpns,omitempty"`
}

// parse checks the prefixes.
func (c *Capture) parse() ([]netip.Prefix, error) {
	if c == nil {
		return nil, nil
	}
	var out []netip.Prefix
	for _, raw := range c.Routes {
		prefix, err := netip.ParsePrefix(raw)
		if err != nil {
			addr, addrErr := netip.ParseAddr(raw)
			if addrErr != nil {
				return nil, fmt.Errorf("daemon: capture route %q is not a prefix", raw)
			}
			prefix = netip.PrefixFrom(addr, addr.BitLen())
		}
		out = append(out, prefix.Masked())
	}
	return out, nil
}

// Platform is the part that touches the operating system.
type Platform interface {
	// Up creates the tunnel interface, routes traffic into it, starts the
	// packet stack with handler, and points the system's DNS at the tunnel.
	// capture, when not nil, narrows both. bypass are hosts kept out of the
	// tunnel whatever capture says: the routes' first hops.
	Up(handler *Handler, capture *Capture, bypass []string) error
	// Down undoes Up. It must be safe to call when Up failed halfway.
	Down() error

	// Direct reaches the internet past the tunnel.
	Direct() DirectNet
	// BaseDialer reaches the first hop of each route past the tunnel.
	BaseDialer() sshtun.ContextDialer
	// Lookup names the process behind a local socket.
	Lookup() ProcessLookup
	// VPNs lists the other VPNs connected now.
	VPNs() []VPN

	// OnNetworkChange registers a callback for changes of the default
	// interface or its addresses.
	OnNetworkChange(func(reason string))

	Info() PlatformInfo
}

// PlatformInfo is shown in the app.
type PlatformInfo struct {
	Interface string   `json:"interface,omitempty"`
	Tunnel    string   `json:"tunnel,omitempty"`
	Upstream  []string `json:"upstreamDns,omitempty"`
}

// State of the daemon.
type State string

const (
	StateIdle    State = "idle"
	StateRunning State = "running"
	StateError   State = "error"
)

// Status is the reply to the app's status poll.
type Status struct {
	Version  string          `json:"version"`
	State    State           `json:"state"`
	Error    string          `json:"error,omitempty"`
	Since    time.Time       `json:"since"`
	Routes   []chains.Status `json:"routes"`
	Platform PlatformInfo    `json:"platform"`
	Rules    int             `json:"rules"`

	// Recording is whether traffic history is being kept, so the app can
	// say so on every screen, not only on Traffic.
	Recording bool `json:"recording"`
}

// Daemon is the running service.
type Daemon struct {
	platform Platform
	logf     func(string, ...any)

	mu      sync.Mutex
	state   State
	err     error
	since   time.Time
	cfg     Config
	chains  *chains.Manager
	handler *Handler
	flows   *flows.Table
	pool    *fakedns.Pool

	// routes lets the handler keep its RouteDialer while the manager under
	// it is replaced.
	routes routeSwitch

	bypass      []string
	lastRestart time.Time
	wokeAt      time.Time
}

// stuckNotifier is a Platform that can tell when its connections past the
// tunnel keep failing however its routes are repaired.
type stuckNotifier interface {
	OnStuck(func(reason string))
}

// New makes an idle daemon.
func New(platform Platform, logf func(string, ...any)) (*Daemon, error) {
	if logf == nil {
		logf = func(string, ...any) {}
	}
	// One pool for the daemon's whole life: names handed out before a
	// restart of the tunnel still map back afterwards.
	pool, err := fakedns.NewPool(fakedns.DefaultPrefix)
	if err != nil {
		return nil, err
	}
	d := &Daemon{
		platform: platform,
		logf:     logf,
		state:    StateIdle,
		since:    time.Now(),
		pool:     pool,
		flows:    flows.New(2000),
	}
	// Nothing about traffic is kept until the app asks: the history of
	// where every app went is the user's to start.
	d.flows.SetRecording(false)
	// The daemon lives as long as the process, so the accounting does too.
	d.flows.Account(10 * time.Second)
	platform.OnNetworkChange(d.networkChanged)
	if s, ok := platform.(stuckNotifier); ok {
		s.OnStuck(func(reason string) {
			// One destination still unreachable while every route is up
			// is that destination's trouble, often a network that is a
			// second from settling; restarting would cut the routes for
			// nothing.
			if d.routesUp() {
				d.logf("daemon: a direct dial stays unreachable, routes are up: not restarting")
				return
			}
			go d.restart(reason)
		})
	}
	return d, nil
}

// SetRules replaces the rules of a running tunnel, from the next
// connection on. The routes they name must be ones the tunnel already has.
// VPNs lists the other VPNs connected now, for rules to name. It works
// whether the tunnel is up or not.
func (d *Daemon) VPNs() []VPN {
	vpns := d.platform.VPNs()
	if vpns == nil {
		vpns = []VPN{}
	}
	return vpns
}

func (d *Daemon) SetRules(rules router.Config) error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.state != StateRunning {
		return errors.New("daemon: the tunnel is not running")
	}
	compiled, err := router.Compile(rules, routeIDs(d.cfg.Routes))
	if err != nil {
		return err
	}
	d.handler.SetRouter(compiled)
	d.cfg.Rules = rules
	active := 0
	for _, r := range rules.Rules {
		if !r.Disabled {
			active++
		}
	}
	d.logf("daemon: rules applied (%d of %d enabled)", active, len(rules.Rules))
	return nil
}

// routesUp is true when the tunnel runs and every route is up.
func (d *Daemon) routesUp() bool {
	d.mu.Lock()
	m := d.chains
	d.mu.Unlock()
	if m == nil {
		return false
	}
	statuses := m.Status()
	if len(statuses) == 0 {
		return false
	}
	for _, s := range statuses {
		if s.State != chains.StateUp {
			return false
		}
	}
	return true
}

// restart takes the tunnel down and brings it up again with the config it
// has, keys included, as a reconnect from the app would. It is the cure
// for the state macOS leaves the network in after some sleeps, where
// sockets bound to Wi-Fi fail with "network is unreachable" although every
// route checks out, and only a fresh tunnel brings them back.
func (d *Daemon) restart(reason string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	// Right after a wake Wi-Fi is often still joining and the first
	// restart comes too early; another few seconds later is what works.
	// Otherwise once in 30s is plenty.
	cooldown := 30 * time.Second
	if time.Since(d.wokeAt) < 90*time.Second {
		cooldown = 3 * time.Second
	}
	if d.state != StateRunning || time.Since(d.lastRestart) < cooldown {
		return
	}
	d.lastRestart = time.Now()
	d.logf("daemon: restarting the tunnel (%s)", reason)

	cfg, h := d.cfg, d.handler
	if err := d.platform.Down(); err != nil {
		d.logf("daemon: restart: down: %v", err)
	}
	d.chains.Close()
	m, err := d.newChains(cfg.Routes)
	if err != nil {
		d.setState(StateError, err)
		return
	}
	d.chains = m
	d.routes.set(m)
	// Right after a wake Wi-Fi may still be joining, and Up refuses to
	// start without a network. Give it some seconds before giving up.
	var upErr error
	for attempt := 0; attempt < 15; attempt++ {
		if upErr = d.platform.Up(h, cfg.Capture, d.bypass); upErr == nil {
			d.logf("daemon: tunnel restarted")
			return
		}
		d.platform.Down()
		d.mu.Unlock()
		time.Sleep(time.Second)
		d.mu.Lock()
		if d.state != StateRunning || d.chains != m {
			return // stopped or replaced meanwhile
		}
	}
	d.logf("daemon: restart: up: %v", upErr)
	m.Close()
	d.routes.set(nil)
	d.setState(StateError, upErr)
}

func (d *Daemon) networkChanged(reason string) {
	d.mu.Lock()
	m := d.chains
	d.mu.Unlock()
	if m != nil {
		m.Nudge(reason)
	}
}

// firstHops are the servers the daemon itself connects to. Their traffic
// must never enter the tunnel, or the tunnel would carry itself.
func firstHops(routes []chains.RouteConfig) []string {
	var hosts []string
	for _, r := range routes {
		if len(r.Hops) > 0 {
			hosts = append(hosts, r.Hops[0].Host)
		}
	}
	return hosts
}

func routeIDs(routes []chains.RouteConfig) []string {
	ids := make([]string, len(routes))
	for i, r := range routes {
		ids[i] = r.ID
	}
	return ids
}

// Start brings the tunnel up with cfg, or, if it is up, applies cfg to it:
// new rules take effect for the next connection, and the routes are
// redialed only if they changed.
func (d *Daemon) Start(cfg Config) error {
	if len(cfg.Routes) == 0 {
		return errors.New("daemon: no routes")
	}
	compiled, err := router.Compile(cfg.Rules, routeIDs(cfg.Routes))
	if err != nil {
		return err
	}
	if _, err := cfg.Capture.parse(); err != nil {
		return err
	}

	d.mu.Lock()
	defer d.mu.Unlock()

	if d.state == StateRunning {
		if !reflect.DeepEqual(d.cfg.Capture, cfg.Capture) || !reflect.DeepEqual(d.cfg.Bypass, cfg.Bypass) {
			return errors.New("daemon: reconnect to change what the tunnel captures or bypasses")
		}
		if !reflect.DeepEqual(d.cfg.Routes, cfg.Routes) {
			m, err := d.newChains(cfg.Routes)
			if err != nil {
				return err
			}
			old := d.chains
			d.chains = m
			d.routes.set(m)
			go old.Close()
		}
		d.handler.SetRouter(compiled)
		d.cfg = cfg
		d.logf("daemon: config applied (%d routes, %d rules)", len(cfg.Routes), len(cfg.Rules.Rules))
		return nil
	}

	m, err := d.newChains(cfg.Routes)
	if err != nil {
		return err
	}
	d.routes.set(m)
	h := NewHandler(HandlerOptions{
		Routes:    &d.routes,
		Direct:    d.platform.Direct(),
		Lookup:    d.platform.Lookup(),
		VPNs:      d.platform.VPNs,
		Pool:      d.pool,
		Flows:     d.flows,
		RemoteDNS: cfg.RemoteDNS,
		Logf:      d.logf,
	})
	h.SetRouter(compiled)

	bypass := append(firstHops(cfg.Routes), cfg.Bypass...)
	for _, prefix := range compiled.BypassPrefixes() {
		bypass = append(bypass, prefix.String())
	}
	d.bypass = bypass
	if err := d.platform.Up(h, cfg.Capture, bypass); err != nil {
		m.Close()
		d.routes.set(nil)
		if downErr := d.platform.Down(); downErr != nil {
			d.logf("daemon: cleanup after failed start: %v", downErr)
		}
		d.setState(StateError, err)
		return err
	}

	d.chains = m
	d.handler = h
	d.cfg = cfg
	d.setState(StateRunning, nil)
	d.logf("daemon: running (%d routes, %d rules)", len(cfg.Routes), len(cfg.Rules.Rules))
	return nil
}

func (d *Daemon) newChains(routes []chains.RouteConfig) (*chains.Manager, error) {
	return chains.New(chains.Options{
		BaseDialer: d.platform.BaseDialer(),
		// Short: right after a wake the first SYN is often lost to a
		// network that is not up yet, and the next try is better than a
		// long wait on this one.
		ConnectTimeout:    6 * time.Second,
		KeepAliveInterval: 15 * time.Second,
		KeepAliveTimeout:  5 * time.Second,
		// After a sleep the tunnel is restarted outright. Neither probing
		// the old chains nor repairing routes brings bound sockets back on
		// macOS; a fresh tunnel does, in about a second. It runs apart from
		// the manager calling this, which the restart replaces.
		OnWake: func(reason string) {
			d.mu.Lock()
			d.wokeAt = time.Now()
			d.mu.Unlock()
			if healer, ok := d.platform.(interface{ HealRoutes() bool }); ok {
				healer.HealRoutes()
			}
			go d.restart(reason)
		},
		Logf: d.logf,
	}, routes)
}

// Stop takes the tunnel down and forgets the config, keys included.
func (d *Daemon) Stop() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.state != StateRunning {
		d.setState(StateIdle, nil)
		return nil
	}
	err := d.platform.Down()
	d.chains.Close()
	d.chains = nil
	d.routes.set(nil)
	d.handler = nil
	d.cfg = Config{}
	d.setState(StateIdle, nil)
	d.logf("daemon: stopped")
	return err
}

func (d *Daemon) setState(s State, err error) {
	d.state = s
	d.err = err
	d.since = time.Now()
}

// Status reports the daemon and its routes.
func (d *Daemon) Status() Status {
	d.mu.Lock()
	defer d.mu.Unlock()
	s := Status{
		Version:  Version,
		State:    d.state,
		Since:    d.since,
		Platform: d.platform.Info(),
		Routes:   []chains.Status{},
		Rules:    len(d.cfg.Rules.Rules),
	}
	s.Recording, _ = d.flows.Recording()
	if d.err != nil {
		s.Error = d.err.Error()
	}
	if d.chains != nil {
		s.Routes = d.chains.Status()
	}
	return s
}

// Flows returns the connection list since a previous poll.
func (d *Daemon) Flows(since uint64) flows.Snapshot { return d.flows.Snapshot(since) }

// FlowStats sums connections by app, host, port and decision over the last
// minutes, or since the last clear for 0.
func (d *Daemon) FlowStats(minutes int) flows.Stats { return d.flows.Stats(minutes) }

// RecordFlows starts or stops keeping closed connections and statistics.
func (d *Daemon) RecordFlows(on bool) { d.flows.SetRecording(on) }

// ClearFlows empties the connection list the app shows, and its totals.
func (d *Daemon) ClearFlows() { d.flows.Clear() }

// Nudge probes every route now.
func (d *Daemon) Nudge(reason string) { d.networkChanged(reason) }

// routeSwitch is a RouteDialer whose manager can be replaced underneath.
type routeSwitch struct {
	m atomic.Pointer[chains.Manager]
}

func (s *routeSwitch) set(m *chains.Manager) { s.m.Store(m) }

func (s *routeSwitch) DialContext(ctx context.Context, route, network, address string) (net.Conn, error) {
	m := s.m.Load()
	if m == nil {
		return nil, errors.New("daemon: tunnel is stopped")
	}
	return m.DialContext(ctx, route, network, address)
}

// summarize describes cfg for the log: routes by name and server, rules by
// count. The rules themselves say which sites the user visits, and keys
// have no business in a log at all.
func summarize(cfg Config) string {
	var routes []string
	for _, r := range cfg.Routes {
		last := r.Hops[len(r.Hops)-1]
		routes = append(routes, fmt.Sprintf("%s=%s@%s (%d hops)", r.ID, last.Username, last.Host, len(r.Hops)))
	}
	return fmt.Sprintf("routes %v, %d rules, default %s %s", routes, len(cfg.Rules.Rules), cfg.Rules.Default.Action, cfg.Rules.Default.Route)
}

// redact returns cfg as JSON with secrets removed, for the log.
func redact(cfg Config) string {
	copyCfg := cfg
	copyCfg.Routes = make([]chains.RouteConfig, len(cfg.Routes))
	for i, r := range cfg.Routes {
		r.Hops = append([]sshtun.Hop(nil), r.Hops...)
		for j := range r.Hops {
			if r.Hops[j].Password != "" {
				r.Hops[j].Password = "***"
			}
			if r.Hops[j].PrivateKeyPEM != "" {
				r.Hops[j].PrivateKeyPEM = "***"
			}
			if r.Hops[j].Passphrase != "" {
				r.Hops[j].Passphrase = "***"
			}
		}
		copyCfg.Routes[i] = r
	}
	b, err := json.Marshal(copyCfg)
	if err != nil {
		return fmt.Sprintf("<%v>", err)
	}
	return string(b)
}
