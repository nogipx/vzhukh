package daemon

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing-tun/ping"
	singbuf "github.com/sagernet/sing/common/buf"
	"github.com/sagernet/sing/common/control"
	singlogger "github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"golang.org/x/net/dns/dnsmessage"

	"github.com/nogipx/vzhukh/tun2socks/internal/fakedns"
	"github.com/nogipx/vzhukh/tun2socks/internal/flows"
	"github.com/nogipx/vzhukh/tun2socks/internal/procinfo"
	"github.com/nogipx/vzhukh/tun2socks/internal/router"
	"github.com/nogipx/vzhukh/tun2socks/internal/sniff"
	"github.com/nogipx/vzhukh/tun2socks/internal/udpgw"
)

// RouteDialer opens connections through a named route.
type RouteDialer interface {
	DialContext(ctx context.Context, route, network, address string) (net.Conn, error)
}

// DirectNet reaches past the tunnel: out of the physical interface, into
// another VPN, or where macOS would send it.
type DirectNet interface {
	// DialContext goes out of the physical interface and never into
	// another VPN. It accepts a name as well as an address; a name is
	// resolved with the network's own DNS servers.
	DialContext(ctx context.Context, network, address string) (net.Conn, error)
	ListenPacket(ctx context.Context) (net.PacketConn, error)
	LookupIPv4(ctx context.Context, host string) (netip.Addr, error)

	// ExchangeDNS sends a raw query to the network's own DNS servers.
	ExchangeDNS(ctx context.Context, query []byte) ([]byte, error)

	// DialVPN and the rest go into the VPN with that ID and ask its DNS.
	// They fail with errVPNDown while it is not connected.
	DialVPN(ctx context.Context, vpn, network, address string) (net.Conn, error)
	ListenPacketVPN(ctx context.Context, vpn string) (net.PacketConn, error)
	LookupIPv4VPN(ctx context.Context, vpn, host string) (netip.Addr, error)
	ExchangeVPNDNS(ctx context.Context, vpn string, query []byte) ([]byte, error)

	// DialSystem and ListenPacketSystem go where macOS would send the
	// connection, for rules that leave it to the system.
	DialSystem(ctx context.Context, network, address string) (net.Conn, error)
	ListenPacketSystem(ctx context.Context, dst netip.Addr) (net.PacketConn, error)

	// Control, ControlVPN and ControlSystem bind a socket the way the
	// dials above do, for pings.
	Control() (control.Func, error)
	ControlVPN(vpn string) (control.Func, error)
	ControlSystem(dst netip.Addr) (control.Func, error)

	// ExchangeSystemDNS sends a query to the resolver macOS has for name:
	// a corporate VPN's, when it set one up for that domain.
	ExchangeSystemDNS(ctx context.Context, query []byte, name string) ([]byte, error)
}

// ProcessLookup names the process that owns a local socket.
type ProcessLookup func(network string, local netip.AddrPort) (procinfo.Process, error)

// HandlerOptions are the handler's dependencies, all replaceable in tests.
type HandlerOptions struct {
	Routes RouteDialer
	Direct DirectNet
	Lookup ProcessLookup
	Pool   *fakedns.Pool

	// VPNs lists the other VPNs connected now. What no rule decides goes
	// into the VPN whose network or DNS domain it is, as it would without
	// vzhukh. Nil knows of none.
	VPNs    func() []VPN
	Flows   *flows.Table
	Exclude []string

	// RemoteDNS is the resolver queried through a route, for the queries
	// that are not answered with a placeholder. Empty means 1.1.1.1:53.
	RemoteDNS string

	// UDPGateway is the udpgw server dialed through a route to carry UDP.
	// Empty means udpgw.DefaultAddr, 127.0.0.1:7300 on the far end.
	UDPGateway string

	// SniffTimeout bounds how long a connection to a bare address on 80 or
	// 443 waits for its first bytes. Zero means 300ms.
	SniffTimeout time.Duration

	DialTimeout time.Duration

	Logf func(format string, args ...any)
}

// Handler is what the packet stack hands every new connection to. Rules can
// be swapped while it runs.
type Handler struct {
	opts   HandlerOptions
	dns    *fakedns.Server
	router atomic.Pointer[router.Router]

	liveMu sync.Mutex
	live   map[*liveConn]struct{}

	gwMu      sync.Mutex
	noGateway map[string]time.Time

	// downLogged is when each down VPN was last mentioned in the log.
	downLogged map[string]time.Time

	// answered remembers the names behind real answers: a connection to
	// one of those addresses that reaches the tunnel still matches the
	// rule for its name.
	answeredMu sync.Mutex
	answered   map[netip.Addr]answeredName
}

type answeredName struct {
	name    string
	expires time.Time
}

var _ tun.Handler = (*Handler)(nil)

var (
	errBlocked      = errors.New("blocked by rule")
	errStalePlace   = errors.New("address from an old DNS answer, ask again")
	errUDPOverRoute = errors.New("UDP cannot go through an SSH route")
	errNoRules      = errors.New("no rules loaded")
)

const dnsExchangeLimit = 5 * time.Second

// NewHandler builds a handler. SetRouter must be called before traffic flows.
func NewHandler(opts HandlerOptions) *Handler {
	if opts.RemoteDNS == "" {
		opts.RemoteDNS = "1.1.1.1:53"
	}
	if opts.UDPGateway == "" {
		opts.UDPGateway = udpgw.DefaultAddr
	}
	if opts.SniffTimeout <= 0 {
		opts.SniffTimeout = 300 * time.Millisecond
	}
	if opts.DialTimeout <= 0 {
		opts.DialTimeout = 20 * time.Second
	}
	if opts.Logf == nil {
		opts.Logf = func(string, ...any) {}
	}
	h := &Handler{opts: opts}
	h.dns = &fakedns.Server{
		Pool:       opts.Pool,
		Exclude:    opts.Exclude,
		Forward:    h.forwardDNS,
		RealAnswer: h.realAnswer,
	}
	return h
}

// SetRouter replaces the rules. Connections already open keep going where
// they were sent.
//
// Open connections whose decision the new rules change are closed: a
// browser keeps its connections to a site open for minutes, and without
// this a rule switched off would go on carrying that site until it lets
// go. The app reconnects, and the new connection follows the new rules.
func (h *Handler) SetRouter(r *router.Router) {
	old := h.router.Swap(r)
	if old == nil {
		return
	}
	h.liveMu.Lock()
	var stale []*liveConn
	for c := range h.live {
		d := r.Decide(c.meta)
		if d.Action != c.decision.Action || d.Route != c.decision.Route {
			stale = append(stale, c)
		}
	}
	h.liveMu.Unlock()
	for _, c := range stale {
		c.entry.Update(func(f *flows.Flow) { f.Error = "closed: the rules changed" })
		c.close()
	}
	if len(stale) > 0 {
		h.opts.Logf("rules: closed %d connections the new rules send elsewhere", len(stale))
	}
}

// liveConn is an open connection, kept so a change of rules can find it.
type liveConn struct {
	meta     router.Meta
	decision router.Decision
	entry    *flows.Entry
	close    func()
}

func (h *Handler) track(c *liveConn) func() {
	h.liveMu.Lock()
	if h.live == nil {
		h.live = map[*liveConn]struct{}{}
	}
	h.live[c] = struct{}{}
	h.liveMu.Unlock()
	return func() {
		h.liveMu.Lock()
		delete(h.live, c)
		h.liveMu.Unlock()
	}
}

func (h *Handler) decide(m router.Meta) (router.Decision, error) {
	d, _, err := h.decideWhy(m)
	return d, err
}

// decideWhy also says what of the rule matched, for the connection list.
func (h *Handler) decideWhy(m router.Meta) (router.Decision, string, error) {
	r := h.router.Load()
	if r == nil {
		return router.Decision{}, "", errNoRules
	}
	d, why := r.DecideWhy(m)
	if d.RuleID == "" && h.opts.VPNs != nil {
		for _, v := range h.opts.VPNs() {
			if claim, ok := v.claims(strings.TrimSuffix(strings.ToLower(m.Domain), "."), m.IP); ok {
				return router.Decision{Action: router.ActionVPN, VPN: v.ID}, claim, nil
			}
		}
	}
	return d, why, nil
}

// PrepareConnection lets TCP and UDP through to the handlers below and
// sends pings where the rules send the address: out of Wi-Fi, into a VPN,
// or nowhere. A ping the rules send through a route, which cannot carry
// one, or to a placeholder is answered by the stack itself, as before.
func (h *Handler) PrepareConnection(
	network string,
	source M.Socksaddr,
	destination M.Socksaddr,
	routeContext tun.DirectRouteContext,
	timeout time.Duration,
) (tun.DirectRouteDestination, error) {
	if network != N.NetworkICMP {
		return nil, nil
	}
	dst := destination.Addr.Unmap()
	if h.opts.Pool.Contains(dst) {
		return nil, nil
	}
	meta := router.Meta{IP: dst}
	if name, ok := h.answeredName(dst); ok {
		meta.Domain = name
	}
	d, _, err := h.decideWhy(meta)
	if err != nil {
		return nil, nil
	}
	var ctrl control.Func
	switch d.Action {
	case router.ActionBlock:
		return nil, tun.ErrReset
	case router.ActionDirect:
		ctrl, err = h.opts.Direct.Control()
	case router.ActionVPN:
		ctrl, err = h.opts.Direct.ControlVPN(d.VPN)
	case router.ActionSystem:
		ctrl, err = h.opts.Direct.ControlSystem(dst)
	default:
		return nil, nil
	}
	if err != nil {
		return nil, tun.ErrReset
	}
	pinger, err := ping.ConnectDestination(context.Background(), singlogger.NOP(), ctrl, dst, routeContext, timeout)
	if err != nil {
		h.opts.Logf("ping %s: %v", dst, err)
		return nil, tun.ErrReset
	}
	return pinger, nil
}

// connInfo is what is learnt about a connection before it is decided.
type connInfo struct {
	meta   router.Meta
	flow   flows.Flow
	domain string
}

func (h *Handler) describe(network string, source, destination netip.AddrPort) (connInfo, error) {
	dst := destination.Addr().Unmap()
	info := connInfo{
		meta: router.Meta{IP: dst, Port: destination.Port()},
		flow: flows.Flow{Network: network, Destination: destination.String()},
	}

	if h.opts.Lookup != nil {
		if p, err := h.opts.Lookup(network, source); err == nil {
			// The executable's path: a rule for a bundle is a prefix of it.
			info.meta.AppPath = p.Path
			info.meta.AppName = p.Name
			info.meta.ExeName = p.ExeName()
			info.flow.PID = p.PID
			info.flow.App = p.Name
			info.flow.AppPath = p.AppPath
			info.flow.ExePath = p.Path
		}
	}

	if h.opts.Pool.Contains(dst) {
		name, ok := h.opts.Pool.Lookup(dst)
		if !ok {
			return info, errStalePlace
		}
		info.domain = name
		info.meta.Domain = name
		info.flow.Domain = name
		info.flow.DomainSource = "dns"
	} else if name, ok := h.answeredName(dst); ok {
		// Not info.domain: the address is what the app chose to dial.
		info.meta.Domain = name
		info.flow.Domain = name
		info.flow.DomainSource = "dns"
	}
	return info, nil
}

// wantsDomain says whether a connection to a bare address is worth
// holding until its first bytes name the site: only when a rule looks at
// domains, or traffic is being recorded and the name belongs in it.
// Otherwise the far end is dialled at once, and a server that speaks first
// is not kept waiting for the sniffing timeout.
func (h *Handler) wantsDomain() bool {
	if r := h.router.Load(); r != nil && r.UsesDomains() {
		return true
	}
	recording, _ := h.opts.Flows.Recording()
	return recording
}

// target is what to dial: the name when there is one, so a route resolves
// it at the far end.
func (info connInfo) target() string {
	if info.domain != "" {
		return net.JoinHostPort(info.domain, strconv.Itoa(int(info.meta.Port)))
	}
	return netip.AddrPortFrom(info.meta.IP, info.meta.Port).String()
}

func (h *Handler) open(info connInfo, d router.Decision) *flows.Entry {
	info.flow.Action = string(d.Action)
	info.flow.Route = d.Route
	if d.Action == router.ActionVPN {
		info.flow.Route = d.VPN
	}
	info.flow.RuleID = d.RuleID
	return h.opts.Flows.Open(info.flow)
}

// NewConnectionEx handles one TCP connection.
func (h *Handler) NewConnectionEx(
	ctx context.Context,
	conn net.Conn,
	source M.Socksaddr,
	destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	go func() {
		err := h.handleTCP(ctx, conn, source.AddrPort(), destination.AddrPort())
		conn.Close()
		if onClose != nil {
			onClose(err)
		}
	}()
}

func (h *Handler) handleTCP(ctx context.Context, conn net.Conn, source, destination netip.AddrPort) error {
	if destination.Port() == 53 {
		// DNS over TCP, which the system falls back to for long answers.
		return h.serveDNSOverTCP(ctx, conn)
	}

	info, err := h.describe("tcp", source, destination)
	if err != nil {
		h.opts.Flows.Open(info.flow).Close(err)
		return err
	}

	var head []byte
	if info.domain == "" && (info.meta.Port == 443 || info.meta.Port == 80) && h.wantsDomain() {
		head = h.readHead(conn)
		if name, src, ok := sniff.Domain(head); ok {
			info.domain = name
			info.meta.Domain = name
			info.flow.Domain = name
			info.flow.DomainSource = string(src)
		}
	}

	d, why, err := h.decideWhy(info.meta)
	if err != nil {
		h.opts.Flows.Open(info.flow).Close(err)
		return err
	}
	info.flow.Matched = why
	entry := h.open(info, d)
	defer h.track(&liveConn{meta: info.meta, decision: d, entry: entry, close: func() { conn.Close() }})()

	remote, err := h.dial(ctx, d, info, entry)
	if err != nil {
		entry.Close(err)
		return err
	}
	defer remote.Close()

	if len(head) > 0 {
		if _, err := remote.Write(head); err != nil {
			entry.Close(err)
			return err
		}
		entry.AddUpload(len(head))
	}

	err = pump(conn, remote, entry)
	entry.Close(err)
	return err
}

func (h *Handler) dial(ctx context.Context, d router.Decision, info connInfo, entry *flows.Entry) (net.Conn, error) {
	target := info.target()
	if (d.Action == router.ActionVPN || d.Action == router.ActionSystem) && !h.opts.Pool.Contains(info.meta.IP) {
		// The app looked the name up with the VPN's resolver already, or
		// knew the address: dial what it chose.
		target = netip.AddrPortFrom(info.meta.IP, info.meta.Port).String()
	}
	entry.Update(func(f *flows.Flow) { f.Dialed = target })

	dialCtx, cancel := context.WithTimeout(ctx, h.opts.DialTimeout)
	defer cancel()

	switch d.Action {
	case router.ActionBlock:
		return nil, errBlocked
	case router.ActionRoute:
		return h.opts.Routes.DialContext(dialCtx, d.Route, "tcp", target)
	case router.ActionDirect:
		return h.opts.Direct.DialContext(dialCtx, "tcp", target)
	case router.ActionVPN:
		return h.opts.Direct.DialVPN(dialCtx, d.VPN, "tcp", target)
	case router.ActionSystem:
		// A system connection that still arrived here goes where the
		// system would have sent it.
		return h.opts.Direct.DialSystem(dialCtx, "tcp", target)
	default:
		return nil, fmt.Errorf("unknown action %q", d.Action)
	}
}

// readHead waits briefly for the client's first bytes. Protocols where the
// server speaks first get nothing and lose only the timeout.
//
// It keeps reading while what came looks like an unfinished ClientHello or
// HTTP request, so a hello split across segments is read whole.
func (h *Handler) readHead(conn net.Conn) []byte {
	buf := make([]byte, sniff.MaxHead)
	conn.SetReadDeadline(time.Now().Add(h.opts.SniffTimeout))
	defer conn.SetReadDeadline(time.Time{})
	n := 0
	for {
		m, err := conn.Read(buf[n:])
		n += m
		if err != nil || !sniff.NeedMore(buf[:n]) {
			return buf[:n]
		}
	}
}

type closeWriter interface{ CloseWrite() error }

// pump copies both ways until both directions finish, passing a half-close
// on: a client that is done sending may still be waiting for the answer.
func pump(app, remote net.Conn, entry *flows.Entry) error {
	var wg sync.WaitGroup
	var firstErr error
	var once sync.Once
	record := func(err error) {
		if err != nil && !isOrdinaryClose(err) {
			once.Do(func() { firstErr = err })
		}
	}

	copyHalf := func(dst, src net.Conn, count func(int)) {
		defer wg.Done()
		buf := make([]byte, 32*1024)
		for {
			n, err := src.Read(buf)
			if n > 0 {
				if _, werr := dst.Write(buf[:n]); werr != nil {
					record(werr)
					// The other side is gone; stop the opposite copy too.
					app.Close()
					remote.Close()
					return
				}
				count(n)
			}
			if err != nil {
				record(err)
				if cw, ok := dst.(closeWriter); ok && errors.Is(err, io.EOF) {
					cw.CloseWrite()
				} else {
					app.Close()
					remote.Close()
				}
				return
			}
		}
	}

	wg.Add(2)
	go copyHalf(remote, app, entry.AddUpload)
	go copyHalf(app, remote, entry.AddDownload)
	wg.Wait()
	return firstErr
}

// isOrdinaryClose is true for the ways a connection normally ends: one side
// closes, and whatever the other was doing at that moment fails with EOF, a
// closed socket, a broken pipe or a reset. Recording those as errors would
// paint every finished connection red in the app.
func isOrdinaryClose(err error) bool {
	return errors.Is(err, io.EOF) ||
		errors.Is(err, net.ErrClosed) ||
		errors.Is(err, syscall.EPIPE) ||
		errors.Is(err, syscall.ECONNRESET) ||
		errors.Is(err, io.ErrClosedPipe)
}

// NewPacketConnectionEx handles one UDP session.
func (h *Handler) NewPacketConnectionEx(
	ctx context.Context,
	conn N.PacketConn,
	source M.Socksaddr,
	destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	go func() {
		var err error
		if destination.Port == 53 {
			err = h.serveDNS(ctx, conn)
		} else {
			err = h.handleUDP(ctx, conn, source.AddrPort(), destination.AddrPort())
		}
		conn.Close()
		if onClose != nil {
			onClose(err)
		}
	}()
}

func (h *Handler) handleUDP(ctx context.Context, conn N.PacketConn, source, destination netip.AddrPort) error {
	info, err := h.describe("udp", source, destination)
	if err != nil {
		h.opts.Flows.Open(info.flow).Close(err)
		return err
	}
	d, why, err := h.decideWhy(info.meta)
	if err != nil {
		h.opts.Flows.Open(info.flow).Close(err)
		return err
	}
	info.flow.Matched = why
	entry := h.open(info, d)

	switch d.Action {
	case router.ActionBlock:
		entry.Close(errBlocked)
		return errBlocked
	}

	defer h.track(&liveConn{meta: info.meta, decision: d, entry: entry, close: func() { conn.Close() }})()
	if d.Action == router.ActionRoute {
		err = h.relayUDPRoute(ctx, conn, d.Route, info, entry)
	} else {
		err = h.relayUDP(ctx, conn, d, info, entry)
	}
	entry.Close(err)
	return err
}

// relayUDPRoute carries a UDP session through a route, framed for a udpgw
// server at the far end (internal/udpgw). Without one there, the session
// is refused as before, and apps fall back to TCP: a browser whose QUIC
// goes nowhere uses HTTP/2. A route found without udpgw is not asked
// again for a minute.
func (h *Handler) relayUDPRoute(ctx context.Context, conn N.PacketConn, route string, info connInfo, entry *flows.Entry) error {
	if h.noGatewayUntil(route) {
		return errUDPOverRoute
	}
	dialCtx, cancel := context.WithTimeout(ctx, h.opts.DialTimeout)
	stream, err := h.opts.Routes.DialContext(dialCtx, route, "tcp", h.opts.UDPGateway)
	cancel()
	if err != nil {
		h.markNoGateway(route)
		h.opts.Logf("udp: no udpgw at %s through route %s (%v); UDP through it is refused", h.opts.UDPGateway, route, err)
		return fmt.Errorf("%w: no udpgw on the server (%v)", errUDPOverRoute, err)
	}
	session := udpgw.NewSession(stream)
	defer session.Close()

	var mu sync.Mutex
	realToPlace := map[netip.Addr]netip.Addr{}
	placeToReal := map[netip.Addr]netip.Addr{}
	resolve := func(dst netip.AddrPort) (netip.AddrPort, error) {
		addr := dst.Addr().Unmap()
		if !h.opts.Pool.Contains(addr) {
			return netip.AddrPortFrom(addr, dst.Port()), nil
		}
		mu.Lock()
		real, ok := placeToReal[addr]
		mu.Unlock()
		if ok {
			return netip.AddrPortFrom(real, dst.Port()), nil
		}
		name, known := h.opts.Pool.Lookup(addr)
		if !known {
			return netip.AddrPort{}, errStalePlace
		}
		// Resolved at the far end, through the route, like a TCP
		// connection by name would be.
		lookupCtx, cancel := context.WithTimeout(ctx, dnsExchangeLimit)
		real, err := h.lookupThroughRoute(lookupCtx, route, name)
		cancel()
		if err != nil {
			return netip.AddrPort{}, err
		}
		mu.Lock()
		placeToReal[addr] = real
		realToPlace[real] = addr
		mu.Unlock()
		return netip.AddrPortFrom(real, dst.Port()), nil
	}

	// SSH channels take no deadlines, so idleness is kept by hand.
	var last atomic.Int64
	last.Store(time.Now().UnixNano())
	touch := func() { last.Store(time.Now().UnixNano()) }

	errs := make(chan error, 3)
	go func() {
		buffer := singbuf.NewPacket()
		defer buffer.Release()
		for {
			buffer.Reset()
			dst, err := conn.ReadPacket(buffer)
			if err != nil {
				errs <- err
				return
			}
			real, err := resolve(dst.AddrPort())
			if err != nil {
				errs <- err
				return
			}
			if err := session.WriteTo(buffer.Bytes(), real); err != nil {
				errs <- err
				return
			}
			entry.AddUpload(buffer.Len())
			touch()
		}
	}()
	go func() {
		for {
			payload, from, err := session.ReadFrom()
			if err != nil {
				errs <- err
				return
			}
			addr := from.Addr().Unmap()
			mu.Lock()
			if place, ok := realToPlace[addr]; ok {
				addr = place
			}
			mu.Unlock()
			if err := conn.WritePacket(singbuf.As(append([]byte(nil), payload...)), M.SocksaddrFrom(addr, from.Port())); err != nil {
				errs <- err
				return
			}
			entry.AddDownload(len(payload))
			touch()
		}
	}()
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if time.Since(time.Unix(0, last.Load())) > 2*time.Minute {
				errs <- nil
				return
			}
		}
	}()

	err = <-errs
	conn.Close()
	session.Close()
	if err == nil || errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || isOrdinaryClose(err) {
		return nil
	}
	return err
}

// lookupThroughRoute resolves name's IPv4 address with RemoteDNS, asked
// through the route.
func (h *Handler) lookupThroughRoute(ctx context.Context, route, name string) (netip.Addr, error) {
	qname, err := dnsmessage.NewName(name + ".")
	if err != nil {
		return netip.Addr{}, err
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: uint16(time.Now().UnixNano()), RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{Name: qname, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	query, err := b.Finish()
	if err != nil {
		return netip.Addr{}, err
	}
	resp, err := h.exchangeTCP(ctx, route, query)
	if err != nil {
		return netip.Addr{}, err
	}
	var msg dnsmessage.Message
	if err := msg.Unpack(resp); err != nil {
		return netip.Addr{}, err
	}
	for _, a := range msg.Answers {
		if rec, ok := a.Body.(*dnsmessage.AResource); ok {
			return netip.AddrFrom4(rec.A), nil
		}
	}
	return netip.Addr{}, fmt.Errorf("%s has no IPv4 address at the far end", name)
}

func (h *Handler) noGatewayUntil(route string) bool {
	h.gwMu.Lock()
	defer h.gwMu.Unlock()
	return time.Now().Before(h.noGateway[route])
}

func (h *Handler) markNoGateway(route string) {
	h.gwMu.Lock()
	defer h.gwMu.Unlock()
	if h.noGateway == nil {
		h.noGateway = map[string]time.Time{}
	}
	h.noGateway[route] = time.Now().Add(time.Minute)
}

// relayUDP carries a UDP session past the tunnel: out of the physical
// interface, into a VPN, or where the system would send it. Packets to
// placeholder addresses go to the real address of their name, and replies
// from it come back looking as if the placeholder sent them.
func (h *Handler) relayUDP(ctx context.Context, conn N.PacketConn, d router.Decision, info connInfo, entry *flows.Entry) error {
	var out net.PacketConn
	var err error
	lookup := h.opts.Direct.LookupIPv4
	switch d.Action {
	case router.ActionVPN:
		out, err = h.opts.Direct.ListenPacketVPN(ctx, d.VPN)
		lookup = func(ctx context.Context, host string) (netip.Addr, error) {
			return h.opts.Direct.LookupIPv4VPN(ctx, d.VPN, host)
		}
	case router.ActionSystem:
		out, err = h.opts.Direct.ListenPacketSystem(ctx, info.meta.IP)
	default:
		out, err = h.opts.Direct.ListenPacket(ctx)
	}
	if err != nil {
		return err
	}
	defer out.Close()

	var mu sync.Mutex
	realToPlace := map[netip.Addr]netip.Addr{}
	placeToReal := map[netip.Addr]netip.Addr{}

	resolve := func(dst netip.AddrPort) (netip.AddrPort, error) {
		addr := dst.Addr().Unmap()
		if !h.opts.Pool.Contains(addr) {
			return netip.AddrPortFrom(addr, dst.Port()), nil
		}
		mu.Lock()
		real, ok := placeToReal[addr]
		mu.Unlock()
		if !ok {
			name, known := h.opts.Pool.Lookup(addr)
			if !known {
				return netip.AddrPort{}, errStalePlace
			}
			lookupCtx, cancel := context.WithTimeout(ctx, dnsExchangeLimit)
			real, err = lookup(lookupCtx, name)
			cancel()
			if err != nil {
				return netip.AddrPort{}, err
			}
			mu.Lock()
			placeToReal[addr] = real
			realToPlace[real] = addr
			mu.Unlock()
		}
		return netip.AddrPortFrom(real, dst.Port()), nil
	}

	errs := make(chan error, 2)
	go func() {
		buffer := singbuf.NewPacket()
		defer buffer.Release()
		for {
			buffer.Reset()
			dst, err := conn.ReadPacket(buffer)
			if err != nil {
				errs <- err
				return
			}
			real, err := resolve(dst.AddrPort())
			if err != nil {
				errs <- err
				return
			}
			n, err := out.WriteTo(buffer.Bytes(), net.UDPAddrFromAddrPort(real))
			if err != nil {
				errs <- err
				return
			}
			entry.AddUpload(n)
		}
	}()
	go func() {
		buf := make([]byte, 64*1024)
		for {
			out.SetReadDeadline(time.Now().Add(2 * time.Minute))
			n, from, err := out.ReadFrom(buf)
			if err != nil {
				errs <- err
				return
			}
			src := from.(*net.UDPAddr).AddrPort()
			addr := src.Addr().Unmap()
			mu.Lock()
			if place, ok := realToPlace[addr]; ok {
				addr = place
			}
			mu.Unlock()
			if err := conn.WritePacket(singbuf.As(append([]byte(nil), buf[:n]...)), M.SocksaddrFrom(addr, src.Port())); err != nil {
				errs <- err
				return
			}
			entry.AddDownload(n)
		}
	}()

	err = <-errs
	conn.Close()
	out.Close()
	if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || errors.Is(err, context.Canceled) {
		return nil
	}
	var timeout interface{ Timeout() bool }
	if errors.As(err, &timeout) && timeout.Timeout() {
		return nil
	}
	return err
}

// serveDNS answers UDP queries on one session until it goes idle.
func (h *Handler) serveDNS(ctx context.Context, conn N.PacketConn) error {
	buffer := singbuf.NewPacket()
	defer buffer.Release()
	for {
		buffer.Reset()
		dest, err := conn.ReadPacket(buffer)
		if err != nil {
			return nil
		}
		query := append([]byte(nil), buffer.Bytes()...)
		go func() {
			answerCtx, cancel := context.WithTimeout(ctx, dnsExchangeLimit)
			defer cancel()
			resp, ok := h.answerDNS(answerCtx, query)
			if !ok {
				return
			}
			conn.WritePacket(singbuf.As(resp), dest)
		}()
	}
}

// serveDNSOverTCP answers length-prefixed queries (RFC 1035 4.2.2).
func (h *Handler) serveDNSOverTCP(ctx context.Context, conn net.Conn) error {
	lenBuf := make([]byte, 2)
	for {
		conn.SetReadDeadline(time.Now().Add(30 * time.Second))
		if _, err := io.ReadFull(conn, lenBuf); err != nil {
			return nil
		}
		query := make([]byte, binary.BigEndian.Uint16(lenBuf))
		if _, err := io.ReadFull(conn, query); err != nil {
			return nil
		}
		answerCtx, cancel := context.WithTimeout(ctx, dnsExchangeLimit)
		resp, ok := h.answerDNS(answerCtx, query)
		cancel()
		if !ok {
			return nil
		}
		binary.BigEndian.PutUint16(lenBuf, uint16(len(resp)))
		if _, err := conn.Write(append(lenBuf, resp...)); err != nil {
			return err
		}
	}
}

// answerDNS answers one query, or reports that there is nothing to send. A
// name whose VPN is down gets SERVFAIL at once rather than a wait for the
// timeout, and the log hears of each VPN once a minute: names a rule sends
// into a VPN are asked about all the time while it is off.
func (h *Handler) answerDNS(ctx context.Context, query []byte) ([]byte, bool) {
	resp, err := h.dns.Answer(ctx, query)
	if err == nil {
		return resp, true
	}
	var down errVPNDown
	if !errors.As(err, &down) {
		h.opts.Logf("dns: %v", err)
		return nil, false
	}
	h.gwMu.Lock()
	if h.downLogged == nil {
		h.downLogged = map[string]time.Time{}
	}
	quiet := time.Since(h.downLogged[down.id]) < time.Minute
	if !quiet {
		h.downLogged[down.id] = time.Now()
	}
	h.gwMu.Unlock()
	if !quiet {
		h.opts.Logf("dns: %v; its names fail until it is", err)
	}
	var msg dnsmessage.Message
	if msg.Unpack(query) != nil {
		return nil, false
	}
	msg.Header.Response = true
	msg.Header.RCode = dnsmessage.RCodeServerFailure
	msg.Answers, msg.Authorities, msg.Additionals = nil, nil, nil
	out, err := msg.Pack()
	return out, err == nil
}

// forwardDNS sends a query that gets a real answer. Local names always go to
// the network's own resolver. Anything else follows the rules for its name:
// through a route it goes to RemoteDNS over TCP, so the lookup does not
// leak, otherwise to the network's resolver.
func (h *Handler) forwardDNS(ctx context.Context, query []byte, name string) ([]byte, error) {
	switch d, err := h.decide(router.Meta{Domain: name, Port: 53}); {
	case err != nil:
	case d.Action == router.ActionSystem:
		return h.remember(h.opts.Direct.ExchangeSystemDNS(ctx, query, name))
	case d.Action == router.ActionVPN:
		return h.remember(h.opts.Direct.ExchangeVPNDNS(ctx, d.VPN, query))
	case d.Action == router.ActionRoute && !h.dns.Excluded(name):
		return h.exchangeTCP(ctx, d.Route, query)
	}
	return h.opts.Direct.ExchangeDNS(ctx, query)
}

// realAnswer is true for names a rule sends into a VPN or leaves to the
// system: they get real addresses from that VPN's resolvers, so that what
// the VPN routes goes into it without passing through here, and what
// needs a real address (ping, Kerberos) has one. Rules naming an app
// cannot match here: DNS queries come from mDNSResponder, not the app.
func (h *Handler) realAnswer(name string) bool {
	d, err := h.decide(router.Meta{Domain: name, Port: 53})
	return err == nil && (d.Action == router.ActionSystem || d.Action == router.ActionVPN)
}

// remember notes the names in a real answer by address, for as long as the
// answer lives and at least a few minutes: apps keep addresses past the
// TTL.
func (h *Handler) remember(resp []byte, err error) ([]byte, error) {
	if err != nil {
		return resp, err
	}
	var msg dnsmessage.Message
	if msg.Unpack(resp) != nil || len(msg.Questions) == 0 {
		return resp, nil
	}
	name := strings.TrimSuffix(strings.ToLower(msg.Questions[0].Name.String()), ".")
	now := time.Now()
	h.answeredMu.Lock()
	defer h.answeredMu.Unlock()
	if h.answered == nil || len(h.answered) > 4096 {
		h.answered = map[netip.Addr]answeredName{}
	}
	for _, a := range msg.Answers {
		var addr netip.Addr
		switch body := a.Body.(type) {
		case *dnsmessage.AResource:
			addr = netip.AddrFrom4(body.A)
		case *dnsmessage.AAAAResource:
			addr = netip.AddrFrom16(body.AAAA)
		default:
			continue
		}
		ttl := max(time.Duration(a.Header.TTL)*time.Second, 10*time.Minute)
		h.answered[addr] = answeredName{name: name, expires: now.Add(min(ttl, 24*time.Hour))}
	}
	return resp, nil
}

func (h *Handler) answeredName(addr netip.Addr) (string, bool) {
	h.answeredMu.Lock()
	defer h.answeredMu.Unlock()
	a, ok := h.answered[addr]
	if !ok || time.Now().After(a.expires) {
		return "", false
	}
	return a.name, true
}

func (h *Handler) exchangeTCP(ctx context.Context, route string, query []byte) ([]byte, error) {
	conn, err := h.opts.Routes.DialContext(ctx, route, "tcp", h.opts.RemoteDNS)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	}
	msg := make([]byte, 2+len(query))
	binary.BigEndian.PutUint16(msg, uint16(len(query)))
	copy(msg[2:], query)
	if _, err := conn.Write(msg); err != nil {
		return nil, err
	}
	lenBuf := make([]byte, 2)
	if _, err := io.ReadFull(conn, lenBuf); err != nil {
		return nil, err
	}
	resp := make([]byte, binary.BigEndian.Uint16(lenBuf))
	if _, err := io.ReadFull(conn, resp); err != nil {
		return nil, err
	}
	return resp, nil
}
