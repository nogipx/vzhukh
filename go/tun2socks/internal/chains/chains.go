// Package chains keeps one SSH chain per route up for as long as the daemon
// runs, and rebuilds it whenever it drops.
//
// A route is dialed as soon as it is configured, so the first connection
// through it does not wait for a handshake. When its chain drops — the
// server hung up, a keepalive went unanswered, the machine slept — the
// route redials at once and then backs off, and connections that arrive in
// the meantime wait a little for it rather than failing on the spot.
package chains

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sort"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
)

// RouteConfig is one route: an ID rules refer to, and its hops.
type RouteConfig struct {
	ID   string       `json:"id"`
	Name string       `json:"name,omitempty"`
	Hops []sshtun.Hop `json:"hops"`
}

// State of a route.
type State string

const (
	StateConnecting State = "connecting"
	StateUp         State = "up"
	StateDown       State = "down"
)

// Status is a route as the app sees it.
type Status struct {
	ID      string    `json:"id"`
	Name    string    `json:"name,omitempty"`
	State   State     `json:"state"`
	Error   string    `json:"error,omitempty"`
	Since   time.Time `json:"since"`
	Server  string    `json:"server"`
	Hops    int       `json:"hops"`
	Retries int       `json:"retries"`
}

// Options tune every route the same way.
type Options struct {
	// BaseDialer reaches the first hop. The daemon binds it to the physical
	// interface, so the SSH connection does not loop back into the tunnel.
	BaseDialer sshtun.ContextDialer

	ConnectTimeout    time.Duration
	KeepAliveInterval time.Duration
	KeepAliveTimeout  time.Duration

	// WaitForRoute is how long a connection waits for a route that is
	// reconnecting. Zero means 10s.
	WaitForRoute time.Duration

	// SleepCheck is how often the clock is looked at to notice a sleep.
	// Zero means 1s: the sooner a wake is noticed, the sooner routes come
	// back, and a look at the clock costs nothing.
	SleepCheck time.Duration

	// LongSleep is how long a sleep has to be for the chains to be dropped
	// and redialed on waking without probing them first. After that long
	// the server or a NAT on the way has forgotten the connection, and a
	// probe would only spend its timeout finding out. Zero means 20s.
	LongSleep time.Duration

	// OnChange is called after any route changes state. It must not block.
	OnChange func()

	// OnWake, when set, takes over waking from any sleep: the manager does
	// nothing more itself, on the assumption that the caller replaces it.
	// Without it, a long sleep resets the chains and a short one probes
	// them.
	OnWake func(reason string)

	Logf func(format string, args ...any)
}

// Manager owns the routes.
type Manager struct {
	opts   Options
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	mu     sync.Mutex
	routes map[string]*route
}

// ErrUnknownRoute is returned when dialing a route that is not configured.
var ErrUnknownRoute = errors.New("chains: unknown route")

// New starts dialing every route in the background.
func New(opts Options, routes []RouteConfig) (*Manager, error) {
	if opts.WaitForRoute <= 0 {
		opts.WaitForRoute = 10 * time.Second
	}
	if opts.SleepCheck <= 0 {
		opts.SleepCheck = time.Second
	}
	if opts.LongSleep <= 0 {
		opts.LongSleep = 20 * time.Second
	}
	if opts.Logf == nil {
		opts.Logf = func(string, ...any) {}
	}

	ctx, cancel := context.WithCancel(context.Background())
	m := &Manager{opts: opts, ctx: ctx, cancel: cancel, routes: make(map[string]*route)}
	for _, cfg := range routes {
		if cfg.ID == "" {
			cancel()
			return nil, errors.New("chains: route without id")
		}
		if len(cfg.Hops) == 0 {
			cancel()
			return nil, fmt.Errorf("chains: route %s has no hops", cfg.ID)
		}
		if _, dup := m.routes[cfg.ID]; dup {
			cancel()
			return nil, fmt.Errorf("chains: route %s twice", cfg.ID)
		}
		m.routes[cfg.ID] = newRoute(m, cfg)
	}
	for _, r := range m.routes {
		m.wg.Add(1)
		go r.run()
	}
	m.wg.Add(1)
	go m.watchClock()
	return m, nil
}

// Close stops every route and waits for them.
func (m *Manager) Close() {
	m.cancel()
	m.wg.Wait()
}

// IDs lists the configured routes.
func (m *Manager) IDs() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	ids := make([]string, 0, len(m.routes))
	for id := range m.routes {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// Status reports every route, sorted by ID.
func (m *Manager) Status() []Status {
	m.mu.Lock()
	routes := make([]*route, 0, len(m.routes))
	for _, r := range m.routes {
		routes = append(routes, r)
	}
	m.mu.Unlock()

	out := make([]Status, 0, len(routes))
	for _, r := range routes {
		out = append(out, r.status())
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// DialContext opens a connection through route id.
func (m *Manager) DialContext(ctx context.Context, id, network, address string) (net.Conn, error) {
	m.mu.Lock()
	r := m.routes[id]
	m.mu.Unlock()
	if r == nil {
		return nil, fmt.Errorf("%w %q", ErrUnknownRoute, id)
	}
	return r.dial(ctx, network, address)
}

// Nudge says the chains may have died unnoticed: the network changed or
// the machine woke up. Live chains are probed now instead of at their next
// keepalive, and routes waiting out a backoff retry now.
func (m *Manager) Nudge(reason string) {
	m.opts.Logf("chains: nudge (%s)", reason)
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, r := range m.routes {
		r.nudge()
	}
}

// Reset drops every live chain and redials it at once, with quick retries
// while the network comes back. For waking from a long sleep.
func (m *Manager) Reset(reason string) {
	m.opts.Logf("chains: reset (%s)", reason)
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, r := range m.routes {
		r.reset()
	}
}

// watchClock notices sleep. Go's monotonic clock on macOS stops while the
// machine sleeps and the wall clock does not, so after a sleep the two
// disagree by about as long as it lasted.
func (m *Manager) watchClock() {
	defer m.wg.Done()
	ticker := time.NewTicker(m.opts.SleepCheck)
	defer ticker.Stop()
	last := time.Now()
	for {
		select {
		case <-m.ctx.Done():
			return
		case now := <-ticker.C:
			now = time.Now()
			wall := now.Round(0).Sub(last.Round(0))
			mono := now.Sub(last)
			last = now
			slept := wall - mono
			reason := fmt.Sprintf("woke after %s", slept.Round(time.Second))
			switch {
			case slept <= 3*time.Second:
			case m.opts.OnWake != nil:
				m.opts.Logf("chains: %s", reason)
				m.opts.OnWake(reason)
			case slept >= m.opts.LongSleep:
				m.Reset(reason)
			default:
				m.Nudge(reason)
			}
		}
	}
}

// route is one RouteConfig and the chain currently serving it.
type route struct {
	m   *Manager
	cfg RouteConfig

	mu      sync.Mutex
	chain   *sshtun.Chain
	state   State
	err     error
	since   time.Time
	retries int
	up      chan struct{} // closed while state is up
	kick    chan struct{}

	// quick counts retries left at fastRetry instead of the backoff: after
	// a wake or a network change the network is usually seconds from being
	// back, and a doubling backoff would overshoot it.
	quick int
}

func newRoute(m *Manager, cfg RouteConfig) *route {
	return &route{
		m:     m,
		cfg:   cfg,
		state: StateConnecting,
		since: time.Now(),
		up:    make(chan struct{}),
		kick:  make(chan struct{}, 1),
		// A new chain is most often a restart after a wake, with the
		// network seconds from being back: retry quickly at first.
		quick: quickRetries,
	}
}

func (r *route) status() Status {
	r.mu.Lock()
	defer r.mu.Unlock()
	s := Status{
		ID:      r.cfg.ID,
		Name:    r.cfg.Name,
		State:   r.state,
		Since:   r.since,
		Server:  r.cfg.Hops[len(r.cfg.Hops)-1].Host,
		Hops:    len(r.cfg.Hops),
		Retries: r.retries,
	}
	if r.err != nil {
		s.Error = r.err.Error()
	}
	return s
}

func (r *route) setState(state State, chain *sshtun.Chain, err error) {
	r.mu.Lock()
	wasUp := r.state == StateUp
	r.state = state
	r.chain = chain
	r.err = err
	r.since = time.Now()
	switch {
	case state == StateUp && !wasUp:
		close(r.up)
	case state != StateUp && wasUp:
		r.up = make(chan struct{})
	}
	r.mu.Unlock()
	if r.m.opts.OnChange != nil {
		r.m.opts.OnChange()
	}
}

// fastRetry is the wait between retries right after a wake or a network
// change.
const fastRetry = 500 * time.Millisecond

// quickRetries is how many of those there are before the backoff resumes.
const quickRetries = 6

// backoff is the wait before attempt n after a failure: the first retry is
// immediate, because the most common drop is a sleep and the network is
// usually back by the time anyone notices.
func backoff(n int) time.Duration {
	if n <= 0 {
		return 0
	}
	d := time.Second << (n - 1)
	if d > 30*time.Second {
		d = 30 * time.Second
	}
	return d
}

func (r *route) run() {
	defer r.m.wg.Done()
	ctx := r.m.ctx
	failures := 0

	for {
		r.setState(StateConnecting, nil, r.lastErr())
		chain, err := sshtun.Dial(ctx, sshtun.Config{
			Hops:              r.cfg.Hops,
			ConnectTimeout:    r.m.opts.ConnectTimeout,
			KeepAliveInterval: r.m.opts.KeepAliveInterval,
			KeepAliveTimeout:  r.m.opts.KeepAliveTimeout,
			BaseDialer:        r.m.opts.BaseDialer,
		})
		if ctx.Err() != nil {
			if chain != nil {
				chain.Close()
			}
			return
		}

		if err != nil {
			failures++
			r.mu.Lock()
			r.retries++
			r.mu.Unlock()
			r.m.opts.Logf("chains: route %s: %v", r.cfg.ID, err)
			r.setState(StateDown, nil, err)
			wait := backoff(failures)
			r.mu.Lock()
			if r.quick > 0 {
				// A quick retry does not count towards the backoff: once
				// they run out it starts from its beginning, not at 30s.
				r.quick--
				wait = fastRetry
				failures--
			}
			r.mu.Unlock()
			if !r.wait(ctx, wait) {
				return
			}
			continue
		}

		failures = 0
		r.m.opts.Logf("chains: route %s up", r.cfg.ID)
		r.setState(StateUp, chain, nil)

		select {
		case <-ctx.Done():
			chain.Close()
			return
		case <-chain.Done():
			dropErr := chain.Err()
			chain.Close()
			if dropErr == nil {
				dropErr = errors.New("chain closed")
			}
			r.m.opts.Logf("chains: route %s dropped: %v", r.cfg.ID, dropErr)
			r.setState(StateDown, nil, dropErr)
			// Straight back to dialing: failures is 0, so no wait.
		}
	}
}

func (r *route) lastErr() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.err
}

// wait sleeps d, cut short by a nudge. It reports false when the manager is
// closing.
func (r *route) wait(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return ctx.Err() == nil
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
	case <-r.kick:
	}
	return true
}

// reset drops the live chain so the run loop redials straight away.
func (r *route) reset() {
	r.mu.Lock()
	chain, state := r.chain, r.state
	r.quick = quickRetries
	r.mu.Unlock()
	if state == StateUp && chain != nil {
		chain.Close()
		return
	}
	select {
	case r.kick <- struct{}{}:
	default:
	}
}

func (r *route) nudge() {
	r.mu.Lock()
	chain, state := r.chain, r.state
	r.quick = quickRetries
	r.mu.Unlock()

	if state == StateUp && chain != nil {
		go func() {
			ctx, cancel := context.WithTimeout(r.m.ctx, time.Minute)
			defer cancel()
			if err := chain.Probe(ctx); err != nil {
				r.m.opts.Logf("chains: route %s: probe: %v", r.cfg.ID, err)
			}
		}()
		return
	}
	select {
	case r.kick <- struct{}{}:
	default:
	}
}

func (r *route) dial(ctx context.Context, network, address string) (net.Conn, error) {
	chain, err := r.waitUp(ctx)
	if err != nil {
		return nil, err
	}
	conn, err := chain.DialContext(ctx, network, address)
	if err == nil {
		return conn, nil
	}
	var refused *ssh.OpenChannelError
	if !errors.As(err, &refused) && ctx.Err() == nil {
		// Not the target refusing: the chain itself may be dead. Find out
		// now rather than at the next keepalive.
		go func() {
			probeCtx, cancel := context.WithTimeout(r.m.ctx, time.Minute)
			defer cancel()
			chain.Probe(probeCtx)
		}()
	}
	return nil, err
}

// waitUp returns the live chain, waiting up to WaitForRoute for one.
func (r *route) waitUp(ctx context.Context) (*sshtun.Chain, error) {
	timer := time.NewTimer(r.m.opts.WaitForRoute)
	defer timer.Stop()
	for {
		r.mu.Lock()
		chain, state, err, up := r.chain, r.state, r.err, r.up
		r.mu.Unlock()
		if state == StateUp && chain != nil {
			return chain, nil
		}
		select {
		case <-up:
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-r.m.ctx.Done():
			return nil, errors.New("chains: stopped")
		case <-timer.C:
			if err == nil {
				err = errors.New("still connecting")
			}
			return nil, fmt.Errorf("route %s is %s: %w", r.cfg.ID, state, err)
		}
	}
}
