// Package mobile is the tunnel the Android app runs inside its VpnService:
// a TUN descriptor in, an SSH route out, nothing in between that depends on
// the app's window being open.
//
// It is the same machinery the macOS helper uses: internal/chains keeps the
// route up, notices sleep by the clock and redials with quick retries;
// internal/engine moves packets; DNS goes to the far end over TCP, and UDP
// through udpgw when the server has it.
package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/chains"
	"github.com/nogipx/vzhukh/tun2socks/internal/engine"
	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
	"github.com/nogipx/vzhukh/tun2socks/internal/udpgw"
)

// routeID is the one route a phone has.
const routeID = "connected"

// Config is what the app sends. Address and MTU must match what
// VpnService.Builder was given.
type Config struct {
	Name    string       `json:"name,omitempty"`
	Hops    []sshtun.Hop `json:"hops"`
	Address string       `json:"address,omitempty"`
	MTU     uint32       `json:"mtu,omitempty"`

	// UDPGateway is the udpgw server on the far end. Empty means the
	// default, "-" turns UDP through the tunnel off.
	UDPGateway string `json:"udpGateway,omitempty"`
}

// ParseConfig reads and checks a Config.
func ParseConfig(raw []byte) (Config, error) {
	var cfg Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return Config{}, fmt.Errorf("mobile: config: %w", err)
	}
	if len(cfg.Hops) == 0 {
		return Config{}, errors.New("mobile: config lists no hops")
	}
	if cfg.Address == "" {
		cfg.Address = "10.0.0.2/32"
	}
	if _, err := netip.ParsePrefix(cfg.Address); err != nil {
		return Config{}, fmt.Errorf("mobile: address %q: %w", cfg.Address, err)
	}
	switch cfg.UDPGateway {
	case "":
		cfg.UDPGateway = udpgw.DefaultAddr
	case "-":
		cfg.UDPGateway = ""
	}
	return cfg, nil
}

// Logger is where the tunnel's messages go.
type Logger interface {
	Debugf(format string, args ...any)
	Errorf(format string, args ...any)
}

// Tunnel is a running tunnel.
type Tunnel struct {
	chains *chains.Manager
	engine *engine.Engine
	log    Logger

	mu     sync.Mutex
	closed bool
}

// Start dials the route in the background and starts moving packets at
// once; connections made before the route is up wait for it.
func Start(tunFD int, cfg Config, log Logger) (*Tunnel, error) {
	address, err := netip.ParsePrefix(cfg.Address)
	if err != nil {
		return nil, err
	}
	m, err := chains.New(chains.Options{
		ConnectTimeout:    8 * time.Second,
		KeepAliveInterval: 20 * time.Second,
		KeepAliveTimeout:  8 * time.Second,
		Logf:              log.Debugf,
	}, []chains.RouteConfig{{ID: routeID, Name: cfg.Name, Hops: cfg.Hops}})
	if err != nil {
		return nil, err
	}
	e, err := engine.Start(engine.Options{
		FileDescriptor: tunFD,
		MTU:            cfg.MTU,
		Inet4Address:   address,
		Dialer:         routeDialer{m},
		UDPGateway:     cfg.UDPGateway,
		// VpnService.Builder already applied addresses, routes and DNS.
		ExternalConfiguration: true,
		Logger:                log,
	})
	if err != nil {
		m.Close()
		return nil, err
	}
	return &Tunnel{chains: m, engine: e, log: log}, nil
}

type routeDialer struct{ m *chains.Manager }

func (d routeDialer) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	return d.m.DialContext(ctx, routeID, network, address)
}

// Status is the route as the app shows it.
type Status struct {
	State   chains.State `json:"state"`
	Error   string       `json:"error,omitempty"`
	Since   time.Time    `json:"since"`
	Retries int          `json:"retries"`
}

// Status reports the route.
func (t *Tunnel) Status() Status {
	for _, s := range t.chains.Status() {
		if s.ID == routeID {
			return Status{State: s.State, Error: s.Error, Since: s.Since, Retries: s.Retries}
		}
	}
	return Status{State: chains.StateDown}
}

// Nudge tells the tunnel the network changed: the chain is probed now, and
// a route waiting out a backoff retries now.
func (t *Tunnel) Nudge(reason string) { t.chains.Nudge(reason) }

// Close stops packets first, then the route.
func (t *Tunnel) Close() {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.closed {
		return
	}
	t.closed = true
	t.engine.Close()
	t.chains.Close()
}
