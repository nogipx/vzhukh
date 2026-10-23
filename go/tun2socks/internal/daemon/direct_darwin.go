package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/sagernet/sing/common/control"
	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
)

// directNet reaches past the tunnel. Every socket it opens is bound to an
// interface with IP_BOUND_IF, which makes the kernel route it by that
// interface's own table: the routes into the utun do not apply to it, so
// nothing it sends loops back into the daemon.
//
// Which interface depends on what the socket is for. Direct traffic goes
// out of the physical one only, another VPN's routes notwithstanding. A
// rule's VPN gets its own tunnel interface. What a rule leaves to the
// system goes where macOS would send it.
type directNet struct {
	// physical names Wi-Fi or Ethernet; zero when there is no network.
	physical func() (int, string)

	// iface names the interface dst leaves through past the tunnel, as the
	// routing table has it: another VPN's for its networks. An invalid dst
	// asks for the default interface.
	iface func(dst netip.Addr) (int, string)

	// vpn finds a connected VPN by its ID.
	vpn func(id string) (VPN, bool)

	// heal re-adds the platform's routes through the physical interface. It
	// is called when a bound dial finds no route, and reports whether it
	// did anything worth a second try.
	heal func() bool
	logf func(string, ...any)

	// stuck is told when dials keep finding no route after the routes were
	// repaired: what is broken then is not the routes.
	stuck func(reason string)

	mu          sync.Mutex
	upstream    []netip.AddrPort
	system      []sysResolver
	lastExplain time.Time
	failedSince time.Time
	healedFails int
	wokeAt      time.Time
	dead        deadHosts
}

// picker chooses the interface for a socket to dst; dst is invalid for a
// socket not yet aimed anywhere.
type picker func(dst netip.Addr) (int, string)

func (d *directNet) physicalPick(netip.Addr) (int, string) { return d.physical() }

func (d *directNet) vpnPick(id string) (picker, VPN, error) {
	v, ok := d.vpn(id)
	if !ok {
		return nil, VPN{}, errVPNDown{id}
	}
	return func(netip.Addr) (int, string) { return v.Index, v.Interface }, v, nil
}

// woke marks a wake from a long sleep. For a minute after one, a single
// dial that a heal does not fix is enough to call it stuck: that is the
// state sleep leaves things in, and waiting for a second failure only
// costs time.
func (d *directNet) woke() {
	d.mu.Lock()
	d.wokeAt = time.Now()
	d.mu.Unlock()
}

func (d *directNet) setSystem(resolvers []sysResolver) {
	d.mu.Lock()
	d.system = resolvers
	d.mu.Unlock()
}

// ExchangeSystemDNS asks the resolver macOS has for name, a corporate VPN's
// when it set one up, and falls back to the network's own.
func (d *directNet) ExchangeSystemDNS(ctx context.Context, query []byte, name string) ([]byte, error) {
	d.mu.Lock()
	servers := pickSystemServers(d.system, name, tunDNS)
	d.mu.Unlock()
	var lastErr error
	for _, server := range servers {
		resp, err := d.exchangeUDP(ctx, d.iface, netip.AddrPortFrom(server, 53), query)
		if err == nil {
			return resp, nil
		}
		lastErr = err
		if ctx.Err() != nil {
			return nil, err
		}
	}
	if resp, err := d.ExchangeDNS(ctx, query); err == nil {
		return resp, nil
	} else if lastErr == nil {
		lastErr = err
	}
	return nil, lastErr
}

// ExchangeVPNDNS asks the resolvers of the VPN, through it. A VPN that set
// none up gets public ones, still through the VPN: a name meant for it is
// never looked up anywhere else.
func (d *directNet) ExchangeVPNDNS(ctx context.Context, vpn string, query []byte) ([]byte, error) {
	pick, v, err := d.vpnPick(vpn)
	if err != nil {
		return nil, err
	}
	var servers []netip.AddrPort
	for _, s := range v.DNS {
		servers = append(servers, netip.AddrPortFrom(s, 53))
	}
	if len(servers) == 0 {
		for _, s := range fallbackDNS {
			if server, ok := parseNameserver(s); ok {
				servers = append(servers, server)
			}
		}
	}
	return d.exchangeAny(ctx, pick, servers, query)
}

var errNoInterface = errors.New("no network")

func (d *directNet) setUpstream(servers []netip.AddrPort) {
	d.mu.Lock()
	d.upstream = servers
	d.mu.Unlock()
}

func (d *directNet) upstreamServers() []netip.AddrPort {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]netip.AddrPort(nil), d.upstream...)
}

// control binds each socket to the interface pick chooses for its
// destination, when the socket is created.
func (d *directNet) control(pick picker) (func(network, address string, c syscall.RawConn) error, error) {
	if index, _ := pick(netip.Addr{}); index <= 0 {
		return nil, errNoInterface
	}
	return func(network, address string, c syscall.RawConn) error {
		var dst netip.Addr
		if ap, err := netip.ParseAddrPort(address); err == nil {
			dst = ap.Addr()
		}
		index, _ := pick(dst)
		if index <= 0 {
			return errNoInterface
		}
		var bindErr error
		err := c.Control(func(fd uintptr) {
			switch network {
			case "tcp4", "udp4":
				bindErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, index)
			case "tcp6", "udp6":
				bindErr = unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, index)
			}
		})
		if err != nil {
			return err
		}
		return bindErr
	}, nil
}

// DialContext dials address out of the physical interface, resolving a
// name with the network's DNS.
func (d *directNet) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	return d.dial(ctx, network, address, d.physicalPick, d.LookupIPv4, true)
}

// DialSystem dials address where macOS would send it, resolving a name
// with the resolver macOS has for it.
func (d *directNet) DialSystem(ctx context.Context, network, address string) (net.Conn, error) {
	lookup := func(ctx context.Context, host string) (netip.Addr, error) {
		return d.lookupIPv4(ctx, host, func(ctx context.Context, query []byte) ([]byte, error) {
			return d.ExchangeSystemDNS(ctx, query, host)
		})
	}
	return d.dial(ctx, network, address, d.iface, lookup, false)
}

// DialVPN dials address through the VPN, resolving a name with its DNS.
//
// A VPN that carries only its own networks usually drops whatever else is
// put into it, without a word, as a corporate VPN here does. A connection to an address
// outside them is given a few seconds rather than the full timeout, and its
// failure says why.
func (d *directNet) DialVPN(ctx context.Context, vpn, network, address string) (net.Conn, error) {
	pick, v, err := d.vpnPick(vpn)
	if err != nil {
		return nil, err
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		if ip, err = d.LookupIPv4VPN(ctx, vpn, host); err != nil {
			return nil, err
		}
		address = net.JoinHostPort(ip.String(), port)
	}
	outside := !v.CarriesAll() && !v.Routes(ip)
	if outside {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, outsideVPNTimeout)
		defer cancel()
	}
	conn, err := d.dial(ctx, network, address, pick, nil, false)
	if err != nil && outside {
		return nil, fmt.Errorf("%w; VPN %q carries only its own networks, and %s is not in them", err, v.Name, ip)
	}
	return conn, err
}

// outsideVPNTimeout is how long a connection into a VPN to an address
// outside its networks may take: an answer, if any comes, comes fast.
const outsideVPNTimeout = 5 * time.Second

// dial resolves a name with lookup and connects bound to pick's interface.
// physical turns on the repair of the routes through Wi-Fi, which is what
// a failure there needs.
func (d *directNet) dial(ctx context.Context, network, address string, pick picker,
	lookup func(context.Context, string) (netip.Addr, error), physical bool) (net.Conn, error) {
	control, err := d.control(pick)
	if err != nil {
		return nil, err
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	if _, err := netip.ParseAddr(host); err != nil {
		ip, err := lookup(ctx, host)
		if err != nil {
			return nil, err
		}
		address = net.JoinHostPort(ip.String(), port)
	}
	var dst netip.Addr
	if ap, perr := netip.ParseAddrPort(address); perr == nil {
		dst = ap.Addr()
	}
	heal := physical && d.heal != nil && !d.isDead(dst)
	dialer := net.Dialer{Control: control}
	conn, err := dialer.DialContext(ctx, network, address)
	if isUnreachable(err) && heal && d.healAllowed() {
		d.explain(address, pick)
	}
	if isUnreachable(err) && heal && d.heal() {
		// After Wi-Fi drops and comes back, as it does across a sleep, the
		// routes added through it can stay in the table and lead nowhere.
		// Re-adding them is what brings the network back for bound sockets.
		conn, err = dialer.DialContext(ctx, network, address)
		if err != nil {
			// However it failed the second time, the repair did not help.
			d.mu.Lock()
			d.dead.add(dst, time.Now())
			d.mu.Unlock()
		}
		if isUnreachable(err) {
			d.noteStuck()
		}
	}
	if err == nil && physical {
		d.mu.Lock()
		d.healedFails = 0
		d.dead.forget(dst)
		d.mu.Unlock()
	}
	if err != nil {
		_, iface := pick(dst)
		return nil, fmt.Errorf("%w (bound to %s)", err, iface)
	}
	return conn, nil
}

// isDead says whether dst stayed unreachable after the last repair: its
// failures say nothing about the routes, and do not repair them again.
func (d *directNet) isDead(dst netip.Addr) bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.dead.has(dst, time.Now())
}

// healAllowed and explain put into the log how the kernel routes a bound
// socket to the address that failed, once per heal at most, so a failure
// the heal does not cure can still be understood afterwards.
func (d *directNet) healAllowed() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if time.Since(d.lastExplain) < 3*time.Second {
		return false
	}
	d.lastExplain = time.Now()
	return true
}

func (d *directNet) explain(address string, pick picker) {
	ap, err := netip.ParseAddrPort(address)
	if err != nil || d.logf == nil {
		return
	}
	_, iface := pick(ap.Addr())
	out, _ := exec.Command("/sbin/route", "-n", "get", "-ifscope", iface, ap.Addr().String()).CombinedOutput()
	var keep []string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "gateway") || strings.HasPrefix(line, "interface") ||
			strings.HasPrefix(line, "flags") || strings.Contains(line, "not in table") {
			keep = append(keep, line)
		}
	}
	d.logf("direct: %s unreachable bound to %s; kernel says: %s", ap.Addr(), iface, strings.Join(keep, "; "))
}

// noteStuck counts dials that failed right after a heal. Two of them, with
// the physical interface up, mean the routes are not what is broken.
func (d *directNet) noteStuck() {
	d.mu.Lock()
	if time.Since(d.failedSince) > time.Minute {
		d.healedFails = 0
		d.failedSince = time.Now()
	}
	d.healedFails++
	n := d.healedFails
	threshold := 2
	if time.Since(d.wokeAt) < time.Minute {
		threshold = 1
	}
	d.mu.Unlock()
	if index, _ := d.physical(); n >= threshold && index > 0 && d.stuck != nil {
		d.stuck("bound sockets stay unreachable after the routes were repaired")
	}
}

func isUnreachable(err error) bool {
	return errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH)
}

// Control binds a socket to the physical interface.
func (d *directNet) Control() (control.Func, error) { return d.control(d.physicalPick) }

// ControlVPN binds a socket to the VPN's interface.
func (d *directNet) ControlVPN(vpn string) (control.Func, error) {
	pick, _, err := d.vpnPick(vpn)
	if err != nil {
		return nil, err
	}
	return d.control(pick)
}

// ControlSystem binds a socket for dst where macOS would send it.
func (d *directNet) ControlSystem(dst netip.Addr) (control.Func, error) {
	return d.control(func(netip.Addr) (int, string) { return d.iface(dst) })
}

// ListenPacket opens a UDP socket out of the physical interface.
func (d *directNet) ListenPacket(ctx context.Context) (net.PacketConn, error) {
	return d.listen(ctx, d.physicalPick)
}

// ListenPacketSystem opens a UDP socket for packets to dst, on the
// interface macOS would send them out of.
func (d *directNet) ListenPacketSystem(ctx context.Context, dst netip.Addr) (net.PacketConn, error) {
	return d.listen(ctx, func(netip.Addr) (int, string) { return d.iface(dst) })
}

// ListenPacketVPN opens a UDP socket into the VPN.
func (d *directNet) ListenPacketVPN(ctx context.Context, vpn string) (net.PacketConn, error) {
	pick, _, err := d.vpnPick(vpn)
	if err != nil {
		return nil, err
	}
	return d.listen(ctx, pick)
}

func (d *directNet) listen(ctx context.Context, pick picker) (net.PacketConn, error) {
	control, err := d.control(pick)
	if err != nil {
		return nil, err
	}
	lc := net.ListenConfig{Control: control}
	return lc.ListenPacket(ctx, "udp4", "0.0.0.0:0")
}

// LookupIPv4 resolves name to its first A record with the network's DNS.
func (d *directNet) LookupIPv4(ctx context.Context, name string) (netip.Addr, error) {
	return d.lookupIPv4(ctx, name, d.ExchangeDNS)
}

// LookupIPv4VPN resolves name with the VPN's DNS.
func (d *directNet) LookupIPv4VPN(ctx context.Context, vpn, name string) (netip.Addr, error) {
	return d.lookupIPv4(ctx, name, func(ctx context.Context, query []byte) ([]byte, error) {
		return d.ExchangeVPNDNS(ctx, vpn, query)
	})
}

func (d *directNet) lookupIPv4(ctx context.Context, name string,
	exchange func(context.Context, []byte) ([]byte, error)) (netip.Addr, error) {
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: uint16(time.Now().UnixNano()), RecursionDesired: true})
	builder.StartQuestions()
	qname, err := dnsmessage.NewName(name + ".")
	if err != nil {
		return netip.Addr{}, err
	}
	builder.Question(dnsmessage.Question{Name: qname, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET})
	query, err := builder.Finish()
	if err != nil {
		return netip.Addr{}, err
	}
	resp, err := exchange(ctx, query)
	if err != nil {
		return netip.Addr{}, err
	}
	var msg dnsmessage.Message
	if err := msg.Unpack(resp); err != nil {
		return netip.Addr{}, err
	}
	for _, answer := range msg.Answers {
		if a, ok := answer.Body.(*dnsmessage.AResource); ok {
			return netip.AddrFrom4(a.A), nil
		}
	}
	return netip.Addr{}, fmt.Errorf("%s has no IPv4 address (%s)", name, msg.RCode)
}

// ExchangeDNS tries each of the network's resolvers in turn, out of the
// physical interface.
func (d *directNet) ExchangeDNS(ctx context.Context, query []byte) ([]byte, error) {
	servers := d.upstreamServers()
	if len(servers) == 0 {
		return nil, errors.New("no DNS servers known for this network")
	}
	return d.exchangeAny(ctx, d.physicalPick, servers, query)
}

func (d *directNet) exchangeAny(ctx context.Context, pick picker, servers []netip.AddrPort, query []byte) ([]byte, error) {
	var lastErr error
	for _, server := range servers {
		resp, err := d.exchangeUDP(ctx, pick, server, query)
		if err == nil {
			return resp, nil
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	return nil, lastErr
}

func (d *directNet) exchangeUDP(ctx context.Context, pick picker, server netip.AddrPort, query []byte) ([]byte, error) {
	control, err := d.control(pick)
	if err != nil {
		return nil, err
	}
	network := "udp4"
	if server.Addr().Is6() && !server.Addr().Is4In6() {
		network = "udp6"
	}
	dialer := net.Dialer{Control: control, Timeout: 2 * time.Second}
	conn, err := dialer.DialContext(ctx, network, server.String())
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	conn.SetDeadline(deadline)
	if _, err := conn.Write(query); err != nil {
		return nil, err
	}
	buf := make([]byte, 64*1024)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			return nil, err
		}
		// Ignore anything that is not the reply to this query.
		if n >= 2 && len(query) >= 2 && buf[0] == query[0] && buf[1] == query[1] {
			return append([]byte(nil), buf[:n]...), nil
		}
	}
}

// parseNameserver reads "1.2.3.4" or "fe80::1%en0" as a port-53 address.
func parseNameserver(s string) (netip.AddrPort, bool) {
	addr, err := netip.ParseAddr(s)
	if err != nil {
		return netip.AddrPort{}, false
	}
	return netip.AddrPortFrom(addr, 53), true
}
