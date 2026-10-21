package chains

import (
	"context"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/sshtest"
	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
)

func hop(s *sshtest.Server) sshtun.Hop {
	return sshtun.Hop{Host: s.Host, Port: s.Port, Username: s.User(), Password: s.Password()}
}

func startEcho(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(c, c); c.Close() }()
		}
	}()
	return ln.Addr().String()
}

func newManager(t *testing.T, servers ...*sshtest.Server) (*Manager, *atomic.Int32) {
	t.Helper()
	var changes atomic.Int32
	var routes []RouteConfig
	for i, s := range servers {
		routes = append(routes, RouteConfig{ID: string(rune('a' + i)), Hops: []sshtun.Hop{hop(s)}})
	}
	m, err := New(Options{
		KeepAliveInterval: time.Hour,
		KeepAliveTimeout:  300 * time.Millisecond,
		WaitForRoute:      3 * time.Second,
		OnChange:          func() { changes.Add(1) },
		Logf:              t.Logf,
	}, routes)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(m.Close)
	return m, &changes
}

func waitState(t *testing.T, m *Manager, id string, want State) Status {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		for _, s := range m.Status() {
			if s.ID == id && s.State == want {
				return s
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("route %s never reached %s: %+v", id, want, m.Status())
	return Status{}
}

func roundTrip(t *testing.T, m *Manager, id, addr string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := m.DialContext(ctx, id, "tcp", addr)
	if err != nil {
		t.Fatalf("dial through %s: %v", id, err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := conn.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 4)
	if _, err := io.ReadFull(conn, buf); err != nil || string(buf) != "ping" {
		t.Fatalf("echo: %q %v", buf, err)
	}
}

func startServer(t *testing.T) *sshtest.Server {
	t.Helper()
	s, err := sshtest.Start("u", "p")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Close)
	return s
}

func TestRoutesComeUpAndCarryConnections(t *testing.T) {
	echo := startEcho(t)
	a, b := startServer(t), startServer(t)
	m, _ := newManager(t, a, b)
	waitState(t, m, "a", StateUp)
	waitState(t, m, "b", StateUp)
	roundTrip(t, m, "a", echo)
	roundTrip(t, m, "b", echo)

	if len(a.Targets()) != 1 || len(b.Targets()) != 1 {
		t.Fatalf("each route should have carried one connection: %v %v", a.Targets(), b.Targets())
	}
}

func TestUnknownRoute(t *testing.T) {
	m, _ := newManager(t, startServer(t))
	if _, err := m.DialContext(context.Background(), "zzz", "tcp", "127.0.0.1:1"); err == nil {
		t.Fatal("dial through an unknown route succeeded")
	}
}

func TestNudgeAfterStallRebuildsTheChain(t *testing.T) {
	echo := startEcho(t)
	server := startServer(t)
	m, _ := newManager(t, server)
	waitState(t, m, "a", StateUp)

	server.Stall()
	m.Nudge("test")
	down := waitState(t, m, "a", StateConnecting)
	if down.Error == "" {
		t.Fatalf("no error recorded for the drop: %+v", down)
	}

	server.Resume()
	waitState(t, m, "a", StateUp)
	roundTrip(t, m, "a", echo)
}

func TestHangUpIsNoticedWithoutANudge(t *testing.T) {
	echo := startEcho(t)
	server := startServer(t)
	m, _ := newManager(t, server)
	waitState(t, m, "a", StateUp)
	before := m.Status()[0].Since

	server.DropConnections()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		s := m.Status()[0]
		if s.State == StateUp && s.Since.After(before) {
			roundTrip(t, m, "a", echo)
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("route did not come back after a hang-up: %+v", m.Status())
}

func TestDialWaitsForAReconnectingRoute(t *testing.T) {
	echo := startEcho(t)
	server := startServer(t)
	m, _ := newManager(t, server)
	waitState(t, m, "a", StateUp)

	server.Stall()
	m.Nudge("test")
	waitState(t, m, "a", StateConnecting)

	done := make(chan error, 1)
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		conn, err := m.DialContext(ctx, "a", "tcp", echo)
		if conn != nil {
			conn.Close()
		}
		done <- err
	}()
	time.Sleep(200 * time.Millisecond)
	server.Resume()
	if err := <-done; err != nil {
		t.Fatalf("dial during reconnect: %v", err)
	}
}

func TestDialGivesUpOnARouteThatStaysDown(t *testing.T) {
	server := startServer(t)
	server.Close() // nothing listens
	m, err := New(Options{WaitForRoute: 300 * time.Millisecond, ConnectTimeout: time.Second}, []RouteConfig{
		{ID: "dead", Hops: []sshtun.Hop{hop(server)}},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer m.Close()

	started := time.Now()
	_, err = m.DialContext(context.Background(), "dead", "tcp", "127.0.0.1:1")
	if err == nil {
		t.Fatal("dial through a dead route succeeded")
	}
	if time.Since(started) > 2*time.Second {
		t.Fatalf("gave up after %s, want about 300ms", time.Since(started))
	}
	// The failed dial is recorded once the connect attempt itself gives up,
	// which can be later than the dial above stopped waiting for it.
	deadline := time.Now().Add(3 * time.Second)
	for {
		s := m.Status()[0]
		if s.Retries > 0 && s.Error != "" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("status %+v", s)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestBackoff(t *testing.T) {
	want := []time.Duration{0, time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second}
	for n, w := range want {
		if got := backoff(n); got != w {
			t.Errorf("backoff(%d) = %s, want %s", n, got, w)
		}
	}
}

func TestBadConfigs(t *testing.T) {
	h := sshtun.Hop{Host: "x", Username: "u", Password: "p"}
	for name, routes := range map[string][]RouteConfig{
		"no id":   {{Hops: []sshtun.Hop{h}}},
		"no hops": {{ID: "a"}},
		"dup":     {{ID: "a", Hops: []sshtun.Hop{h}}, {ID: "a", Hops: []sshtun.Hop{h}}},
	} {
		if m, err := New(Options{}, routes); err == nil {
			m.Close()
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestResetRedialsAtOnce(t *testing.T) {
	echo := startEcho(t)
	server := startServer(t)
	m, _ := newManager(t, server)
	before := waitState(t, m, "a", StateUp).Since

	started := time.Now()
	m.Reset("test")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		s := m.Status()[0]
		if s.State == StateUp && s.Since.After(before) {
			if took := time.Since(started); took > time.Second {
				t.Fatalf("redial took %s", took)
			}
			roundTrip(t, m, "a", echo)
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("route did not come back: %+v", m.Status())
}

func TestRetriesAreQuickAfterANudge(t *testing.T) {
	server := startServer(t)
	m, _ := newManager(t, server)
	waitState(t, m, "a", StateUp)

	// The server goes away and comes back a moment later, the way Wi-Fi
	// does after a wake.
	server.Stall()
	m.Reset("test")
	time.Sleep(1500 * time.Millisecond)
	server.Resume()

	started := time.Now()
	waitState(t, m, "a", StateUp)
	if took := time.Since(started); took > 3*time.Second {
		t.Fatalf("came back %s after the server did; quick retries should make it about a second", took)
	}
}
