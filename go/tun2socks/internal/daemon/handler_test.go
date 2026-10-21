package daemon

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"testing"
	"time"

	singbuf "github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
	"golang.org/x/net/dns/dnsmessage"

	"github.com/nogipx/vzhukh/tun2socks/internal/fakedns"
	"github.com/nogipx/vzhukh/tun2socks/internal/flows"
	"github.com/nogipx/vzhukh/tun2socks/internal/procinfo"
	"github.com/nogipx/vzhukh/tun2socks/internal/router"
	"github.com/nogipx/vzhukh/tun2socks/internal/udpgw"
)

// echoDialer answers every dial with a connection that echoes, and
// remembers what was dialed.
type echoDialer struct {
	mu     sync.Mutex
	dialed []string
}

func (d *echoDialer) record(s string) {
	d.mu.Lock()
	d.dialed = append(d.dialed, s)
	d.mu.Unlock()
}

func (d *echoDialer) got() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.dialed...)
}

func echoConn() net.Conn {
	a, b := net.Pipe()
	go func() { io.Copy(b, b); b.Close() }()
	return a
}

type fakeRoutes struct {
	echoDialer
	// udpgw, when set, is where a dial to the udpgw address really goes;
	// otherwise such a dial is refused, as on a server without one.
	udpgw string
}

func (r *fakeRoutes) DialContext(ctx context.Context, route, network, address string) (net.Conn, error) {
	r.record(route + " " + address)
	if address == udpgw.DefaultAddr {
		if r.udpgw == "" {
			return nil, errors.New("connect failed")
		}
		return net.Dial("tcp", r.udpgw)
	}
	return echoConn(), nil
}

type fakeDirect struct {
	echoDialer
	lookups   []string
	realIP    netip.Addr
	dns       [][]byte
	systemDNS []string
}

func (d *fakeDirect) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	d.record(address)
	return echoConn(), nil
}

func (d *fakeDirect) ListenPacket(ctx context.Context) (net.PacketConn, error) {
	return net.ListenPacket("udp4", "127.0.0.1:0")
}

func (d *fakeDirect) LookupIPv4(ctx context.Context, host string) (netip.Addr, error) {
	d.mu.Lock()
	d.lookups = append(d.lookups, host)
	d.mu.Unlock()
	return d.realIP, nil
}

func (d *fakeDirect) ExchangeSystemDNS(ctx context.Context, query []byte, name string) ([]byte, error) {
	d.mu.Lock()
	d.systemDNS = append(d.systemDNS, name)
	d.mu.Unlock()
	return query, nil
}

func (d *fakeDirect) ExchangeDNS(ctx context.Context, query []byte) ([]byte, error) {
	d.mu.Lock()
	d.dns = append(d.dns, query)
	d.mu.Unlock()
	return query, nil
}

type fixture struct {
	h      *Handler
	routes *fakeRoutes
	direct *fakeDirect
	pool   *fakedns.Pool
	flows  *flows.Table
}

var appSource = netip.MustParseAddrPort("172.19.0.1:50000")

func newFixture(t *testing.T, rules []router.Rule) *fixture {
	t.Helper()
	pool, err := fakedns.NewPool(fakedns.DefaultPrefix)
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{
		routes: &fakeRoutes{},
		direct: &fakeDirect{realIP: netip.MustParseAddr("127.0.0.1")},
		pool:   pool,
		flows:  flows.New(100),
	}
	f.h = NewHandler(HandlerOptions{
		Routes: f.routes,
		Direct: f.direct,
		Pool:   pool,
		Flows:  f.flows,
		Lookup: func(network string, local netip.AddrPort) (procinfo.Process, error) {
			if local == appSource {
				return procinfo.FromPath(42, "/Applications/Telegram.app/Contents/MacOS/Telegram"), nil
			}
			return procinfo.Process{}, procinfo.ErrNotFound
		},
		SniffTimeout: 200 * time.Millisecond,
	})
	r, err := router.Compile(router.Config{
		Rules:   rules,
		Default: router.Decision{Action: router.ActionRoute, Route: "main"},
	}, []string{"main", "work"})
	if err != nil {
		t.Fatal(err)
	}
	f.h.SetRouter(r)
	return f
}

// tcp runs one connection through the handler and returns what the app
// read back after sending payload.
func (f *fixture) tcp(t *testing.T, source, destination netip.AddrPort, payload []byte) ([]byte, error) {
	t.Helper()
	app, stack := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- f.h.handleTCP(context.Background(), stack, source, destination) }()

	app.SetDeadline(time.Now().Add(3 * time.Second))
	var got []byte
	if _, err := app.Write(payload); err == nil {
		got = make([]byte, len(payload))
		if _, err := io.ReadFull(app, got); err != nil {
			got = nil
		}
	}
	app.Close()
	select {
	case err := <-done:
		return got, err
	case <-time.After(3 * time.Second):
		t.Fatal("handler did not return")
		return nil, nil
	}
}

func (f *fixture) lastFlow(t *testing.T) flows.Flow {
	t.Helper()
	s := f.flows.Snapshot(0)
	if len(s.Closed) == 0 {
		t.Fatalf("no closed flow, active %+v", s.Active)
	}
	return s.Closed[len(s.Closed)-1]
}

func TestNamedConnectionGoesThroughTheDefaultRouteByName(t *testing.T) {
	f := newFixture(t, nil)
	place := f.pool.Assign("example.com")

	got, _ := f.tcp(t, netip.MustParseAddrPort("172.19.0.1:1"), netip.AddrPortFrom(place, 443), []byte("hello"))
	if string(got) != "hello" {
		t.Fatalf("echo %q", got)
	}
	if d := f.routes.got(); len(d) != 1 || d[0] != "main example.com:443" {
		t.Fatalf("route dials %v", d)
	}
	fl := f.lastFlow(t)
	if fl.Domain != "example.com" || fl.DomainSource != "dns" || fl.Action != "route" || fl.Route != "main" ||
		fl.Dialed != "example.com:443" || fl.Upload != 5 || fl.Download != 5 {
		t.Fatalf("flow %+v", fl)
	}
}

func TestAppRuleSendsDirect(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "tg", Apps: []string{"/Applications/Telegram.app"}, Action: router.ActionDirect}})
	place := f.pool.Assign("telegram.org")

	f.tcp(t, appSource, netip.AddrPortFrom(place, 443), []byte("x"))
	if d := f.direct.got(); len(d) != 1 || d[0] != "telegram.org:443" {
		t.Fatalf("direct dials %v", d)
	}
	if len(f.routes.got()) != 0 {
		t.Fatalf("route dialed: %v", f.routes.got())
	}
	fl := f.lastFlow(t)
	if fl.App != "Telegram" || fl.PID != 42 || fl.RuleID != "tg" || fl.Action != "direct" {
		t.Fatalf("flow %+v", fl)
	}
}

func TestBlockRule(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "ads", Domains: []string{"ads.example"}, Action: router.ActionBlock}})
	place := f.pool.Assign("x.ads.example")
	if _, err := f.tcp(t, netip.MustParseAddrPort("172.19.0.1:2"), netip.AddrPortFrom(place, 443), []byte("x")); !errors.Is(err, errBlocked) {
		t.Fatalf("err %v", err)
	}
	if len(f.routes.got())+len(f.direct.got()) != 0 {
		t.Fatal("a blocked connection was dialed")
	}
	if fl := f.lastFlow(t); fl.Error != errBlocked.Error() || fl.Action != "block" {
		t.Fatalf("flow %+v", fl)
	}
}

func TestUnknownPlaceholderIsRefused(t *testing.T) {
	f := newFixture(t, nil)
	stale := netip.MustParseAddr("198.18.200.200")
	if _, err := f.tcp(t, netip.MustParseAddrPort("172.19.0.1:3"), netip.AddrPortFrom(stale, 443), []byte("x")); !errors.Is(err, errStalePlace) {
		t.Fatalf("err %v", err)
	}
}

func TestBareAddressIsSniffedAndTheHelloStillArrives(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "ex", Domains: []string{"example.org"}, Action: router.ActionDirect}})
	hello := clientHello(t, "www.example.org")

	got, _ := f.tcp(t, netip.MustParseAddrPort("172.19.0.1:4"), netip.MustParseAddrPort("93.184.216.34:443"), hello)
	if string(got) != string(hello) {
		t.Fatal("the sniffed bytes did not reach the far end intact")
	}
	if d := f.direct.got(); len(d) != 1 || d[0] != "www.example.org:443" {
		t.Fatalf("direct dials %v", d)
	}
	if fl := f.lastFlow(t); fl.Domain != "www.example.org" || fl.DomainSource != "sni" {
		t.Fatalf("flow %+v", fl)
	}
}

// waitDialed reports whether the default route was dialled within d.
func waitDialed(f *fixture, d time.Duration) bool {
	for deadline := time.Now().Add(d); time.Now().Before(deadline); time.Sleep(5 * time.Millisecond) {
		if len(f.routes.got()) > 0 {
			return true
		}
	}
	return false
}

func TestBareAddressIsDialedAtOnceWhenNothingNeedsItsName(t *testing.T) {
	f := newFixture(t, nil)
	f.flows.SetRecording(false)
	app, stack := net.Pipe()
	defer app.Close()
	go f.h.handleTCP(context.Background(), stack, netip.MustParseAddrPort("172.19.0.1:6"), netip.MustParseAddrPort("93.184.216.34:443"))

	// The app says nothing, as with a server that speaks first: the far
	// end is reached well before the sniffing timeout of 200ms.
	if !waitDialed(f, 100*time.Millisecond) {
		t.Fatal("dialling waited for bytes nothing needed")
	}
}

func TestBareAddressWaitsForItsNameWhileRecording(t *testing.T) {
	f := newFixture(t, nil)
	f.flows.SetRecording(true)
	app, stack := net.Pipe()
	defer app.Close()
	go f.h.handleTCP(context.Background(), stack, netip.MustParseAddrPort("172.19.0.1:7"), netip.MustParseAddrPort("93.184.216.34:443"))

	if waitDialed(f, 100*time.Millisecond) {
		t.Fatal("dialled before the name could be read")
	}
	if !waitDialed(f, time.Second) {
		t.Fatal("never dialled after the timeout")
	}
}

func TestBareAddressWithoutANameIsDialedByAddress(t *testing.T) {
	f := newFixture(t, nil)
	f.tcp(t, netip.MustParseAddrPort("172.19.0.1:5"), netip.MustParseAddrPort("10.1.2.3:22"), []byte("SSH-2.0-x\r\n"))
	if d := f.routes.got(); len(d) != 1 || d[0] != "main 10.1.2.3:22" {
		t.Fatalf("route dials %v", d)
	}
}

func TestRulesCanBeSwappedLive(t *testing.T) {
	f := newFixture(t, nil)
	place := f.pool.Assign("example.com")
	r, err := router.Compile(router.Config{Default: router.Decision{Action: router.ActionRoute, Route: "work"}}, []string{"main", "work"})
	if err != nil {
		t.Fatal(err)
	}
	f.h.SetRouter(r)
	f.tcp(t, netip.MustParseAddrPort("172.19.0.1:6"), netip.AddrPortFrom(place, 443), []byte("x"))
	if d := f.routes.got(); len(d) != 1 || d[0] != "work example.com:443" {
		t.Fatalf("route dials %v", d)
	}
}

// packetConn is an N.PacketConn fed from a channel, standing in for the
// stack's side of a UDP session.
type packetConn struct {
	in     chan packet
	out    chan packet
	closed chan struct{}
	once   sync.Once
}

type packet struct {
	data []byte
	addr M.Socksaddr
}

func newPacketConn() *packetConn {
	return &packetConn{in: make(chan packet, 8), out: make(chan packet, 8), closed: make(chan struct{})}
}

func (c *packetConn) ReadPacket(b *singbuf.Buffer) (M.Socksaddr, error) {
	select {
	case p := <-c.in:
		b.Write(p.data)
		return p.addr, nil
	case <-c.closed:
		return M.Socksaddr{}, io.EOF
	}
}

func (c *packetConn) WritePacket(b *singbuf.Buffer, dst M.Socksaddr) error {
	data := append([]byte(nil), b.Bytes()...)
	b.Release()
	select {
	case c.out <- packet{data, dst}:
		return nil
	case <-c.closed:
		return io.EOF
	}
}

func (c *packetConn) Close() error                     { c.once.Do(func() { close(c.closed) }); return nil }
func (c *packetConn) LocalAddr() net.Addr              { return &net.UDPAddr{} }
func (c *packetConn) SetDeadline(time.Time) error      { return nil }
func (c *packetConn) SetReadDeadline(time.Time) error  { return nil }
func (c *packetConn) SetWriteDeadline(time.Time) error { return nil }

func TestUDPThroughARouteIsRefused(t *testing.T) {
	f := newFixture(t, nil)
	conn := newPacketConn()
	err := f.h.handleUDP(context.Background(), conn, netip.MustParseAddrPort("172.19.0.1:7"), netip.MustParseAddrPort("8.8.4.4:443"))
	if !errors.Is(err, errUDPOverRoute) {
		t.Fatalf("err %v", err)
	}
	if fl := f.lastFlow(t); fl.Network != "udp" || !strings.HasPrefix(fl.Error, errUDPOverRoute.Error()) {
		t.Fatalf("flow %+v", fl)
	}
}

func TestDirectUDPToAPlaceholderReachesTheRealAddress(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "d", Domains: []string{"udp.test"}, Action: router.ActionDirect}})

	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 1500)
		for {
			n, from, err := echo.ReadFrom(buf)
			if err != nil {
				return
			}
			echo.WriteTo(buf[:n], from)
		}
	}()
	port := uint16(echo.LocalAddr().(*net.UDPAddr).Port)
	place := f.pool.Assign("udp.test")

	conn := newPacketConn()
	done := make(chan error, 1)
	go func() {
		done <- f.h.handleUDP(context.Background(), conn, netip.MustParseAddrPort("172.19.0.1:8"), netip.AddrPortFrom(place, port))
	}()

	conn.in <- packet{[]byte("datagram"), M.SocksaddrFrom(place, port)}
	select {
	case reply := <-conn.out:
		if string(reply.data) != "datagram" {
			t.Fatalf("reply %q", reply.data)
		}
		if reply.addr.Addr != place {
			t.Fatalf("reply came from %s, want the placeholder %s", reply.addr, place)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no reply")
	}
	conn.Close()
	<-done
	if len(f.direct.lookups) != 1 || f.direct.lookups[0] != "udp.test" {
		t.Fatalf("lookups %v", f.direct.lookups)
	}
}

func dnsQuery(t *testing.T, name string, typ dnsmessage.Type) []byte {
	t.Helper()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 7, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: typ, Class: dnsmessage.ClassINET})
	q, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return q
}

func TestDNSOverUDPGetsAPlaceholderAndLocalNamesGoToTheNetwork(t *testing.T) {
	f := newFixture(t, nil)
	conn := newPacketConn()
	go f.h.serveDNS(context.Background(), conn)
	defer conn.Close()

	server := M.SocksaddrFrom(netip.MustParseAddr("172.19.0.2"), 53)
	conn.in <- packet{dnsQuery(t, "example.com.", dnsmessage.TypeA), server}
	reply := <-conn.out
	var m dnsmessage.Message
	if err := m.Unpack(reply.data); err != nil || len(m.Answers) != 1 {
		t.Fatalf("answer %+v %v", m, err)
	}
	ip := netip.AddrFrom4(m.Answers[0].Body.(*dnsmessage.AResource).A)
	if name, _ := f.pool.Lookup(ip); name != "example.com" {
		t.Fatalf("%s maps to %q", ip, name)
	}
	if reply.addr != server {
		t.Fatalf("reply addressed to %s", reply.addr)
	}

	conn.in <- packet{dnsQuery(t, "router.lan.", dnsmessage.TypeA), server}
	<-conn.out
	if len(f.direct.dns) != 1 {
		t.Fatalf("local name was not sent to the network's resolver: %d", len(f.direct.dns))
	}
}

func clientHello(t *testing.T, serverName string) []byte {
	t.Helper()
	client, server := net.Pipe()
	defer server.Close()
	go func() {
		c := tls.Client(client, &tls.Config{ServerName: serverName, InsecureSkipVerify: true})
		c.SetDeadline(time.Now().Add(2 * time.Second))
		c.Handshake()
		client.Close()
	}()
	buf := make([]byte, 16*1024)
	server.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := server.Read(buf)
	if err != nil {
		t.Fatal(err)
	}
	return buf[:n]
}

func TestNamesLeftToTheSystemGetRealAnswersFromItsResolver(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "corp", Domains: []string{"corp.example"}, Action: router.ActionSystem}})
	conn := newPacketConn()
	go f.h.serveDNS(context.Background(), conn)
	defer conn.Close()

	server := M.SocksaddrFrom(netip.MustParseAddr("172.19.0.2"), 53)
	conn.in <- packet{dnsQuery(t, "git.corp.example.", dnsmessage.TypeA), server}
	<-conn.out
	if len(f.direct.systemDNS) != 1 || f.direct.systemDNS[0] != "git.corp.example" {
		t.Fatalf("system resolver asked for %v", f.direct.systemDNS)
	}
	if _, ok := f.pool.Lookup(f.pool.Assign("probe.test")); !ok {
		t.Fatal("pool broken")
	}

	// Other names still get placeholders.
	conn.in <- packet{dnsQuery(t, "example.com.", dnsmessage.TypeA), server}
	reply := <-conn.out
	var m dnsmessage.Message
	if err := m.Unpack(reply.data); err != nil || len(m.Answers) != 1 {
		t.Fatalf("answer %+v %v", m, err)
	}
	if !f.pool.Contains(netip.AddrFrom4(m.Answers[0].Body.(*dnsmessage.AResource).A)) {
		t.Fatal("example.com did not get a placeholder")
	}
}

func TestSystemConnectionsThatArriveAreDialedDirectly(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "corp", CIDRs: []string{"172.16.0.0/12"}, Action: router.ActionSystem}})
	f.tcp(t, netip.MustParseAddrPort("172.19.0.1:9"), netip.MustParseAddrPort("172.16.20.10:443"), []byte("x"))
	if d := f.direct.got(); len(d) != 1 || d[0] != "172.16.20.10:443" {
		t.Fatalf("direct dials %v", d)
	}
}

// A browser's ClientHello arrives in two segments; the name must still be
// found and the whole hello must still reach the far end.
func TestHelloSplitAcrossWritesIsSniffedWhole(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "yt", Domains: []string{"googlevideo.com"}, Action: router.ActionRoute, Route: "work"}})
	hello := clientHello(t, "rr1.googlevideo.com")
	if len(hello) < 200 {
		t.Fatalf("hello too short to split: %d", len(hello))
	}

	app, stack := net.Pipe()
	done := make(chan error, 1)
	go func() {
		done <- f.h.handleTCP(context.Background(), stack, netip.MustParseAddrPort("172.19.0.1:11"), netip.MustParseAddrPort("142.250.1.1:443"))
	}()
	app.SetDeadline(time.Now().Add(3 * time.Second))
	half := len(hello) / 2
	app.Write(hello[:half])
	time.Sleep(50 * time.Millisecond)
	app.Write(hello[half:])
	got := make([]byte, len(hello))
	if _, err := io.ReadFull(app, got); err != nil {
		t.Fatal(err)
	}
	app.Close()
	<-done
	if string(got) != string(hello) {
		t.Fatal("hello did not arrive intact")
	}
	if d := f.routes.got(); len(d) != 1 || d[0] != "work rr1.googlevideo.com:443" {
		t.Fatalf("route dials %v", d)
	}
}

// Switching a rule off closes the connections it was carrying, so the app
// reconnects under the new rules instead of keeping the old path open.
func TestChangingRulesClosesConnectionsTheyNowSendElsewhere(t *testing.T) {
	f := newFixture(t, []router.Rule{{ID: "ig", Domains: []string{"instagram.com"}, Action: router.ActionRoute, Route: "work"}})
	ig := f.pool.Assign("www.instagram.com")
	other := f.pool.Assign("example.com")

	open := func(dst netip.AddrPort, port uint16) (net.Conn, chan error) {
		app, stack := net.Pipe()
		done := make(chan error, 1)
		go func() {
			done <- f.h.handleTCP(context.Background(), stack, netip.AddrPortFrom(netip.MustParseAddr("172.19.0.1"), port), dst)
		}()
		app.SetDeadline(time.Now().Add(5 * time.Second))
		app.Write([]byte("x"))
		app.Read(make([]byte, 1))
		return app, done
	}
	igApp, igDone := open(netip.AddrPortFrom(ig, 443), 21)
	exApp, exDone := open(netip.AddrPortFrom(other, 443), 22)
	defer igApp.Close()
	defer exApp.Close()

	// The rule goes off: instagram now takes the default, example.com did
	// all along.
	r, err := router.Compile(router.Config{
		Rules:   []router.Rule{{ID: "ig", Domains: []string{"instagram.com"}, Action: router.ActionRoute, Route: "work", Disabled: true}},
		Default: router.Decision{Action: router.ActionRoute, Route: "main"},
	}, []string{"main", "work"})
	if err != nil {
		t.Fatal(err)
	}
	f.h.SetRouter(r)

	select {
	case <-igDone:
	case <-time.After(2 * time.Second):
		t.Fatal("the instagram connection stayed open")
	}
	select {
	case <-exDone:
		t.Fatal("a connection the change does not concern was closed")
	case <-time.After(200 * time.Millisecond):
	}
}

func TestUDPThroughARouteGoesViaUdpgw(t *testing.T) {
	f := newFixture(t, nil)

	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 1500)
		for {
			n, from, err := echo.ReadFrom(buf)
			if err != nil {
				return
			}
			echo.WriteTo(buf[:n], from)
		}
	}()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go udpgw.Serve(ln, time.Minute, t.Logf)
	f.routes.udpgw = ln.Addr().String()

	dst := echo.LocalAddr().(*net.UDPAddr).AddrPort()
	conn := newPacketConn()
	done := make(chan error, 1)
	go func() {
		done <- f.h.handleUDP(context.Background(), conn, netip.MustParseAddrPort("172.19.0.1:12"), dst)
	}()
	conn.in <- packet{[]byte("quic"), M.SocksaddrFromNetIP(dst)}
	select {
	case reply := <-conn.out:
		if string(reply.data) != "quic" || reply.addr.AddrPort() != dst {
			t.Fatalf("reply %q from %s", reply.data, reply.addr)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no reply through udpgw")
	}
	conn.Close()
	<-done
	if fl := f.lastFlow(t); fl.Network != "udp" || fl.Action != "route" || fl.Upload != 4 || fl.Download != 4 {
		t.Fatalf("flow %+v", fl)
	}
}
