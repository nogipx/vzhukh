package daemon

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/chains"
	"github.com/nogipx/vzhukh/tun2socks/internal/flows"
	"github.com/nogipx/vzhukh/tun2socks/internal/procinfo"
	"github.com/nogipx/vzhukh/tun2socks/internal/router"
	"github.com/nogipx/vzhukh/tun2socks/internal/sshtest"
	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
)

// fakePlatform records Up and Down and dials directly.
type fakePlatform struct {
	mu       sync.Mutex
	up       int
	down     int
	upErr    error
	handler  *Handler
	callback func(string)
}

func (p *fakePlatform) Up(h *Handler, capture *Capture, bypass []string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.upErr != nil {
		return p.upErr
	}
	p.up++
	p.handler = h
	return nil
}

func (p *fakePlatform) Down() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.down++
	return nil
}

func (p *fakePlatform) Direct() DirectNet                { return &fakeDirect{} }
func (p *fakePlatform) BaseDialer() sshtun.ContextDialer { return &net.Dialer{} }
func (p *fakePlatform) VPNs() []VPN                      { return nil }
func (p *fakePlatform) Lookup() ProcessLookup {
	return func(string, netip.AddrPort) (procinfo.Process, error) {
		return procinfo.Process{}, procinfo.ErrNotFound
	}
}
func (p *fakePlatform) OnNetworkChange(cb func(string)) { p.callback = cb }
func (p *fakePlatform) Info() PlatformInfo              { return PlatformInfo{Interface: "en0", Tunnel: "utun9"} }

// newDaemon stops the daemon when the test ends, so its routes do not keep
// redialing and logging into a finished test.
func newDaemon(t *testing.T, p Platform) *Daemon {
	t.Helper()
	d, err := New(p, t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Stop() })
	return d
}

func startSSH(t *testing.T) *sshtest.Server {
	t.Helper()
	s, err := sshtest.Start("u", "p")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

func configFor(servers ...*sshtest.Server) Config {
	var cfg Config
	for i, s := range servers {
		cfg.Routes = append(cfg.Routes, chains.RouteConfig{
			ID:   []string{"main", "work"}[i],
			Hops: []sshtun.Hop{{Host: s.Host, Port: s.Port, Username: s.User(), Password: s.Password()}},
		})
	}
	cfg.Rules = router.Config{Default: router.Decision{Action: router.ActionRoute, Route: "main"}}
	return cfg
}

func waitRoutesUp(t *testing.T, d *Daemon) Status {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		s := d.Status()
		allUp := len(s.Routes) > 0
		for _, r := range s.Routes {
			allUp = allUp && r.State == chains.StateUp
		}
		if allUp {
			return s
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("routes never came up: %+v", d.Status())
	return Status{}
}

func TestStartRunsAndStopForgets(t *testing.T) {
	p := &fakePlatform{}
	d := newDaemon(t, p)
	if s := d.Status(); s.State != StateIdle {
		t.Fatalf("new daemon is %s", s.State)
	}

	if err := d.Start(configFor(startSSH(t))); err != nil {
		t.Fatal(err)
	}
	s := waitRoutesUp(t, d)
	if s.State != StateRunning || s.Platform.Tunnel != "utun9" || p.up != 1 {
		t.Fatalf("status %+v up=%d", s, p.up)
	}

	if err := d.Stop(); err != nil {
		t.Fatal(err)
	}
	if s := d.Status(); s.State != StateIdle || len(s.Routes) != 0 || p.down != 1 {
		t.Fatalf("after stop %+v down=%d", s, p.down)
	}
}

func TestStartRejectsBadConfigsWithoutTouchingTheSystem(t *testing.T) {
	p := &fakePlatform{}
	d := newDaemon(t, p)
	bad := configFor(startSSH(t))
	bad.Rules.Default = router.Decision{Action: router.ActionRoute, Route: "missing"}
	if err := d.Start(bad); err == nil {
		t.Fatal("bad default accepted")
	}
	if err := d.Start(Config{}); err == nil {
		t.Fatal("empty config accepted")
	}
	if p.up != 0 {
		t.Fatal("platform brought up for a bad config")
	}
}

func TestFailedUpIsReportedAndCleanedUp(t *testing.T) {
	p := &fakePlatform{upErr: errors.New("no utun for you")}
	d := newDaemon(t, p)
	if err := d.Start(configFor(startSSH(t))); err == nil {
		t.Fatal("start succeeded")
	}
	s := d.Status()
	if s.State != StateError || !strings.Contains(s.Error, "no utun") || p.down != 1 {
		t.Fatalf("status %+v down=%d", s, p.down)
	}
}

func TestRestartWithNewRulesKeepsTheRoutes(t *testing.T) {
	p := &fakePlatform{}
	d := newDaemon(t, p)
	cfg := configFor(startSSH(t))
	if err := d.Start(cfg); err != nil {
		t.Fatal(err)
	}
	before := waitRoutesUp(t, d).Routes[0].Since

	cfg.Rules.Rules = []router.Rule{{ID: "r", Domains: []string{"example.com"}, Action: router.ActionDirect}}
	if err := d.Start(cfg); err != nil {
		t.Fatal(err)
	}
	s := d.Status()
	if p.up != 1 || s.Rules != 1 || !s.Routes[0].Since.Equal(before) {
		t.Fatalf("rules change redialed or re-upped: up=%d %+v", p.up, s)
	}
}

func TestRestartWithNewRoutesRedials(t *testing.T) {
	p := &fakePlatform{}
	d := newDaemon(t, p)
	a, b := startSSH(t), startSSH(t)
	if err := d.Start(configFor(a)); err != nil {
		t.Fatal(err)
	}
	waitRoutesUp(t, d)
	cfg := configFor(a, b)
	cfg.Rules.Rules = []router.Rule{{ID: "w", Apps: []string{"Slack"}, Action: router.ActionRoute, Route: "work"}}
	if err := d.Start(cfg); err != nil {
		t.Fatal(err)
	}
	s := waitRoutesUp(t, d)
	if len(s.Routes) != 2 || p.up != 1 {
		t.Fatalf("status %+v up=%d", s, p.up)
	}
}

func TestConnectionsGoThroughTheRouteEndToEnd(t *testing.T) {
	p := &fakePlatform{}
	d := newDaemon(t, p)
	server := startSSH(t)
	if err := d.Start(configFor(server)); err != nil {
		t.Fatal(err)
	}
	waitRoutesUp(t, d)
	d.RecordFlows(true)

	echo, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		for {
			c, err := echo.Accept()
			if err != nil {
				return
			}
			go func() { buf := make([]byte, 5); c.Read(buf); c.Write(buf); c.Close() }()
		}
	}()

	app, stack := net.Pipe()
	go p.handler.handleTCP(context.Background(), stack, netip.MustParseAddrPort("172.19.0.1:1"), echo.Addr().(*net.TCPAddr).AddrPort())
	app.SetDeadline(time.Now().Add(5 * time.Second))
	app.Write([]byte("hello"))
	buf := make([]byte, 5)
	if _, err := app.Read(buf); err != nil || string(buf) != "hello" {
		t.Fatalf("echo %q %v", buf, err)
	}
	app.Close()

	if got := server.Targets(); len(got) != 1 || got[0] != echo.Addr().String() {
		t.Fatalf("server forwarded %v", got)
	}
	deadline := time.Now().Add(2 * time.Second)
	var snap flows.Snapshot
	for time.Now().Before(deadline) {
		if snap = d.Flows(0); len(snap.Closed) == 1 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if len(snap.Closed) != 1 || snap.Closed[0].Route != "main" || snap.Closed[0].Download != 5 {
		t.Fatalf("flows %+v", snap)
	}
}

func TestIPCRoundTrip(t *testing.T) {
	p := &fakePlatform{}
	d := newDaemon(t, p)
	path := filepath.Join(t.TempDir(), "d.sock")
	ln, err := ListenUnix(path, -1)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	server := &IPCServer{Daemon: d, AllowedUID: -1, Logf: t.Logf}
	go server.Serve(ln)

	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	reader := bufio.NewReader(conn)
	call := func(id int, method string, params any) map[string]any {
		t.Helper()
		req := map[string]any{"id": id, "method": method}
		if params != nil {
			req["params"] = params
		}
		line, _ := json.Marshal(req)
		conn.Write(append(line, '\n'))
		raw, err := reader.ReadBytes('\n')
		if err != nil {
			t.Fatal(err)
		}
		var resp map[string]any
		json.Unmarshal(raw, &resp)
		if int(resp["id"].(float64)) != id {
			t.Fatalf("reply id %v, want %d", resp["id"], id)
		}
		return resp
	}

	if r := call(1, "hello", nil); r["result"].(map[string]any)["version"] != Version {
		t.Fatalf("hello %v", r)
	}
	if r := call(2, "start", configFor(startSSH(t))); r["error"] != nil {
		t.Fatalf("start %v", r)
	}
	waitRoutesUp(t, d)
	status := call(3, "status", nil)["result"].(map[string]any)
	if status["state"] != "running" {
		t.Fatalf("status %v", status)
	}
	if r := call(4, "flows", map[string]any{"since": 0}); r["error"] != nil {
		t.Fatalf("flows %v", r)
	}
	if r := call(41, "stats", map[string]any{"window": 15}); r["error"] != nil ||
		len(r["result"].(map[string]any)["timeline"].([]any)) != 60 {
		t.Fatalf("stats %v", r)
	}
	if r := call(42, "clearFlows", nil); r["error"] != nil {
		t.Fatalf("clearFlows %v", r)
	}
	if r := call(43, "record", map[string]any{"on": true}); r["error"] != nil ||
		r["result"].(map[string]any)["recording"] != true {
		t.Fatalf("record %v", r)
	}
	if r := call(5, "teleport", nil); r["error"] == nil {
		t.Fatal("unknown method accepted")
	}
	if r := call(6, "stop", nil); r["result"].(map[string]any)["state"] != "idle" {
		t.Fatalf("stop %v", r)
	}
}

func TestIPCRefusesOtherUsers(t *testing.T) {
	d := newDaemon(t, &fakePlatform{})
	path := filepath.Join(t.TempDir(), "d.sock")
	ln, err := ListenUnix(path, -1)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	server := &IPCServer{
		Daemon:     d,
		AllowedUID: 4242,
		PeerUID:    func(net.Conn) (int, error) { return 501, nil },
		Logf:       t.Logf,
	}
	go server.Serve(ln)

	conn, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.Write([]byte(`{"id":1,"method":"status"}` + "\n"))
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := bufio.NewReader(conn).ReadBytes('\n'); err == nil {
		t.Fatal("a stranger got an answer")
	}
}

func TestRedactHidesSecrets(t *testing.T) {
	cfg := Config{Routes: []chains.RouteConfig{{ID: "a", Hops: []sshtun.Hop{{Host: "h", Username: "u", Password: "hunter2", PrivateKeyPEM: "-----BEGIN", Passphrase: "pp"}}}}}
	out := redact(cfg)
	for _, secret := range []string{"hunter2", "BEGIN", `"pp"`} {
		if strings.Contains(out, secret) {
			t.Fatalf("%q leaked: %s", secret, out)
		}
	}
	if cfg.Routes[0].Hops[0].Password != "hunter2" {
		t.Fatal("redact changed the original")
	}
}

// stuckPlatform can report that its connections stay unreachable.
type stuckPlatform struct {
	fakePlatform
	stuck func(string)
}

func (p *stuckPlatform) OnStuck(cb func(string)) { p.stuck = cb }

func TestStuckPlatformRestartsTheTunnelWithTheSameConfig(t *testing.T) {
	p := &stuckPlatform{}
	d := newDaemon(t, p)
	server := startSSH(t)
	if err := d.Start(configFor(server)); err != nil {
		t.Fatal(err)
	}
	before := waitRoutesUp(t, d).Routes[0].Since

	// The route goes down, the way it does after a wake.
	server.DropConnections()
	server.Stall()
	deadline0 := time.Now().Add(3 * time.Second)
	for d.routesUp() && time.Now().Before(deadline0) {
		time.Sleep(10 * time.Millisecond)
	}
	server.Resume()
	p.stuck("test")
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		p.mu.Lock()
		up, down := p.up, p.down
		p.mu.Unlock()
		s := d.Status()
		if up == 2 && down == 1 && s.State == StateRunning && len(s.Routes) == 1 &&
			s.Routes[0].State == chains.StateUp && s.Routes[0].Since.After(before) {
			// A second report right away is ignored: one restart per 30s.
			p.stuck("again")
			time.Sleep(200 * time.Millisecond)
			p.mu.Lock()
			defer p.mu.Unlock()
			if p.up != 2 {
				t.Fatalf("restarted again within the cooldown: up=%d", p.up)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("no restart: up=%d down=%d status=%+v", p.up, p.down, d.Status())
}

func TestStuckDialWithRoutesUpDoesNotRestart(t *testing.T) {
	p := &stuckPlatform{}
	d := newDaemon(t, p)
	if err := d.Start(configFor(startSSH(t))); err != nil {
		t.Fatal(err)
	}
	waitRoutesUp(t, d)
	p.stuck("one destination")
	time.Sleep(300 * time.Millisecond)
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.up != 1 || p.down != 0 {
		t.Fatalf("restarted with routes up: up=%d down=%d", p.up, p.down)
	}
}

func TestSetRulesOnARunningTunnel(t *testing.T) {
	d := newDaemon(t, &fakePlatform{})
	if err := d.SetRules(router.Config{Default: router.Decision{Action: router.ActionDirect}}); err == nil {
		t.Fatal("rules applied with no tunnel")
	}
	if err := d.Start(configFor(startSSH(t))); err != nil {
		t.Fatal(err)
	}
	rules := router.Config{
		Rules:   []router.Rule{{ID: "r", Domains: []string{"example.com"}, Action: router.ActionDirect, Disabled: true}},
		Default: router.Decision{Action: router.ActionRoute, Route: "main"},
	}
	if err := d.SetRules(rules); err != nil {
		t.Fatal(err)
	}
	if got := d.handler.router.Load().Decide(router.Meta{Domain: "example.com"}); got.RuleID != "" {
		t.Fatalf("disabled rule matched: %+v", got)
	}
	rules.Rules[0].Disabled = false
	if err := d.SetRules(rules); err != nil {
		t.Fatal(err)
	}
	if got := d.handler.router.Load().Decide(router.Meta{Domain: "example.com"}); got.RuleID != "r" {
		t.Fatalf("enabled rule did not match: %+v", got)
	}
	bad := router.Config{Default: router.Decision{Action: router.ActionRoute, Route: "nope"}}
	if err := d.SetRules(bad); err == nil {
		t.Fatal("rules naming an unknown route accepted")
	}
}

// "restart" answers first and only then ends the daemon, so the app hears
// that it is coming; without a way to restart, it is refused.
func TestIPCRestartAnswersThenRestarts(t *testing.T) {
	d := newDaemon(t, &fakePlatform{})
	restarted := make(chan struct{})
	server := &IPCServer{Daemon: d, AllowedUID: -1, Logf: t.Logf, Restart: func() { close(restarted) }}

	result, err := server.call(request{Method: "restart"})
	if err != nil || result.(map[string]any)["restarting"] != true {
		t.Fatalf("restart: %v %v", result, err)
	}
	select {
	case <-restarted:
		t.Fatal("restarted before the reply")
	default:
	}
	select {
	case <-restarted:
	case <-time.After(2 * time.Second):
		t.Fatal("never restarted")
	}

	plain := &IPCServer{Daemon: d, AllowedUID: -1, Logf: t.Logf}
	if _, err := plain.call(request{Method: "restart"}); err == nil {
		t.Fatal("a daemon that cannot restart said it would")
	}
}
