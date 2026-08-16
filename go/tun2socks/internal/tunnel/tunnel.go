// Package tunnel joins an SSH chain to a TUN device.
//
// It exists so that the cgo layer the iOS extension links against stays thin
// enough to read in one sitting: everything with a decision in it lives here,
// where it can be tested from an ordinary Go test.
package tunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"sync"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/engine"
	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
)

// Config is the whole description of a tunnel, and the exact JSON the iOS
// extension hands across from the app:
//
//	{
//	  "hops": [{"host": "1.2.3.4", "port": 22, "username": "root", ...}],
//	  "address": "10.0.0.2/30",
//	  "mtu": 1500
//	}
type Config struct {
	Hops []sshtun.Hop `json:"hops"`

	// Address is what the TUN device was configured with. It is metadata for
	// the packet stack, not something applied here — whoever opened the
	// device has already set it. Empty means 10.0.0.2/30, matching what
	// VzhukhVpnService uses on Android.
	Address string `json:"address,omitempty"`

	// MTU must agree with the device. Zero means 1500.
	MTU uint32 `json:"mtu,omitempty"`

	ConnectTimeoutSeconds int `json:"connectTimeoutSeconds,omitempty"`
	KeepAliveSeconds      int `json:"keepAliveSeconds,omitempty"`
	UDPTimeoutSeconds     int `json:"udpTimeoutSeconds,omitempty"`
}

const defaultAddress = "10.0.0.2/30"

// ParseConfig reads a Config and rejects the mistakes that would otherwise
// surface later as an unexplained dead tunnel.
func ParseConfig(raw []byte) (Config, error) {
	var cfg Config
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return Config{}, fmt.Errorf("tunnel: config is not valid JSON: %w", err)
	}
	if len(cfg.Hops) == 0 {
		return Config{}, errors.New("tunnel: config lists no hops")
	}
	for i, hop := range cfg.Hops {
		if hop.Host == "" {
			return Config{}, fmt.Errorf("tunnel: hop %d has no host", i)
		}
		if hop.Username == "" {
			return Config{}, fmt.Errorf("tunnel: hop %d has no username", i)
		}
		if hop.Password == "" && hop.PrivateKeyPEM == "" {
			return Config{}, fmt.Errorf("tunnel: hop %d has neither a password nor a key", i)
		}
	}
	if cfg.Address == "" {
		cfg.Address = defaultAddress
	}
	if _, err := netip.ParsePrefix(cfg.Address); err != nil {
		return Config{}, fmt.Errorf("tunnel: address %q: %w", cfg.Address, err)
	}
	return cfg, nil
}

// Logger receives everything both halves have to say.
type Logger interface {
	Debugf(format string, args ...any)
	Errorf(format string, args ...any)
}

// Tunnel is a live tunnel: an SSH chain with a packet engine feeding it.
type Tunnel struct {
	chain  *sshtun.Chain
	engine *engine.Engine

	closeOnce sync.Once
	closeErr  error
}

// Start brings up the chain first and the packet engine second.
//
// The order matters. Packets arriving before there is anywhere to send them
// would be dropped, and on a phone those first packets are usually the ones
// the user is waiting on.
//
// onDrop fires if the chain dies on its own — a hop hung up, or a keepalive
// went unanswered. It does not fire for Close. Reconnecting is the caller's
// business: that policy already lives in VpnController, and having two things
// retry independently would fight.
func Start(
	ctx context.Context,
	tunFD int,
	cfg Config,
	log Logger,
	onDrop func(error),
) (*Tunnel, error) {
	address, err := netip.ParsePrefix(cfg.Address)
	if err != nil {
		return nil, fmt.Errorf("tunnel: address %q: %w", cfg.Address, err)
	}

	chain, err := sshtun.Dial(ctx, sshtun.Config{
		Hops:              cfg.Hops,
		ConnectTimeout:    seconds(cfg.ConnectTimeoutSeconds),
		KeepAliveInterval: seconds(cfg.KeepAliveSeconds),
	})
	if err != nil {
		return nil, err
	}
	log.Debugf("tunnel: ssh chain up across %d hop(s)", len(cfg.Hops))

	packets, err := engine.Start(engine.Options{
		FileDescriptor: tunFD,
		MTU:            cfg.MTU,
		Inet4Address:   address,
		Dialer:         chain,
		UDPTimeout:     seconds(cfg.UDPTimeoutSeconds),
		// Addresses, routes and DNS come from NEPacketTunnelProvider on iOS
		// and from VpnService.Builder on Android. Either way sing-tun must
		// not try to apply them itself — on iOS the syscalls to do it are
		// not available to an app at all.
		ExternalConfiguration: true,
		Logger:                log,
	})
	if err != nil {
		chain.Close()
		return nil, err
	}

	t := &Tunnel{chain: chain, engine: packets}

	if onDrop != nil {
		go func() {
			<-chain.Done()
			if err := chain.Err(); err != nil {
				log.Errorf("tunnel: chain dropped: %v", err)
				onDrop(err)
			}
		}()
	}

	return t, nil
}

// Close stops the packet engine before the chain, so that nothing is still
// trying to dial through connections that are on their way out.
func (t *Tunnel) Close() error {
	t.closeOnce.Do(func() {
		if t.engine != nil {
			t.closeErr = t.engine.Close()
		}
		if t.chain != nil {
			if err := t.chain.Close(); err != nil && t.closeErr == nil {
				t.closeErr = err
			}
		}
	})
	return t.closeErr
}

func seconds(n int) time.Duration {
	if n <= 0 {
		return 0
	}
	return time.Duration(n) * time.Second
}
