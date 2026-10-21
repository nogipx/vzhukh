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

	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
)

// directNet reaches the internet past the tunnel. Every socket it opens is
// bound to the physical interface with IP_BOUND_IF, which makes the kernel
// route it by that interface's own table: the routes into the utun do not
// apply to it, so nothing it sends loops back into the daemon.
type directNet struct {
	// iface names the interface dst leaves through past the tunnel. An
	// invalid dst asks for the default interface.
	iface func(dst netip.Addr) (int, string)

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
		resp, err := d.exchangeUDP(ctx, netip.AddrPortFrom(server, 53), query)
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

// control binds each socket to the interface its destination leaves
// through, chosen when the socket is created: a corporate VPN's networks go
// into the corporate VPN, the rest out of Wi-Fi.
func (d *directNet) control() (func(network, address string, c syscall.RawConn) error, error) {
	if index, _ := d.iface(netip.Addr{}); index <= 0 {
		return nil, errNoInterface
	}
	return func(network, address string, c syscall.RawConn) error {
		var dst netip.Addr
		if ap, err := netip.ParseAddrPort(address); err == nil {
			dst = ap.Addr()
		}
		index, _ := d.iface(dst)
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

// DialContext dials address, resolving a name with the network's DNS.
func (d *directNet) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	control, err := d.control()
	if err != nil {
		return nil, err
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, err
	}
	if _, err := netip.ParseAddr(host); err != nil {
		ip, err := d.LookupIPv4(ctx, host)
		if err != nil {
			return nil, err
		}
		address = net.JoinHostPort(ip.String(), port)
	}
	dialer := net.Dialer{Control: control}
	conn, err := dialer.DialContext(ctx, network, address)
	if isUnreachable(err) && d.heal != nil && d.healAllowed() {
		d.explain(address)
	}
	if isUnreachable(err) && d.heal != nil && d.heal() {
		// After Wi-Fi drops and comes back, as it does across a sleep, the
		// routes added through it can stay in the table and lead nowhere.
		// Re-adding them is what brings the network back for bound sockets.
		conn, err = dialer.DialContext(ctx, network, address)
		if isUnreachable(err) {
			d.noteStuck()
		}
	}
	if err == nil {
		d.mu.Lock()
		d.healedFails = 0
		d.mu.Unlock()
	}
	if err != nil {
		var dst netip.Addr
		if ap, perr := netip.ParseAddrPort(address); perr == nil {
			dst = ap.Addr()
		}
		_, iface := d.iface(dst)
		return nil, fmt.Errorf("%w (bound to %s)", err, iface)
	}
	return conn, nil
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

func (d *directNet) explain(address string) {
	ap, err := netip.ParseAddrPort(address)
	if err != nil || d.logf == nil {
		return
	}
	_, iface := d.iface(ap.Addr())
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
// the default interface up, mean the routes are not what is broken.
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
	if index, _ := d.iface(netip.Addr{}); n >= threshold && index > 0 && d.stuck != nil {
		d.stuck("bound sockets stay unreachable after the routes were repaired")
	}
}

func isUnreachable(err error) bool {
	return errors.Is(err, syscall.ENETUNREACH) || errors.Is(err, syscall.EHOSTUNREACH)
}

// ListenPacket opens a UDP socket for both families.
func (d *directNet) ListenPacket(ctx context.Context) (net.PacketConn, error) {
	control, err := d.control()
	if err != nil {
		return nil, err
	}
	lc := net.ListenConfig{Control: control}
	return lc.ListenPacket(ctx, "udp4", "0.0.0.0:0")
}

// LookupIPv4 resolves name to its first A record.
func (d *directNet) LookupIPv4(ctx context.Context, name string) (netip.Addr, error) {
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
	resp, err := d.ExchangeDNS(ctx, query)
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

// ExchangeDNS tries each of the network's resolvers in turn.
func (d *directNet) ExchangeDNS(ctx context.Context, query []byte) ([]byte, error) {
	servers := d.upstreamServers()
	if len(servers) == 0 {
		return nil, errors.New("no DNS servers known for this network")
	}
	var lastErr error
	for _, server := range servers {
		resp, err := d.exchangeUDP(ctx, server, query)
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

func (d *directNet) exchangeUDP(ctx context.Context, server netip.AddrPort, query []byte) ([]byte, error) {
	control, err := d.control()
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
