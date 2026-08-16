// Package engine pumps packets between a TUN device and a dialer.
//
// It is the platform-independent half of what go/tun2socks/main.go does for
// Android, with one thing generalised: Android hands the packet loop a SOCKS5
// dialer pointing at the Dart-side proxy, whereas here any dialer will do. On
// iOS that dialer is an SSH chain directly, so nothing has to serve SOCKS5 to
// itself over loopback.
//
// The TUN device is not created here. Both platforms that use this already
// have one — Android from VpnService.Builder.establish, iOS from the utun the
// NetworkExtension opens — so the caller passes a file descriptor and the
// addresses that were configured on it.
package engine

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"time"

	tun "github.com/sagernet/sing-tun"
	singbuf "github.com/sagernet/sing/common/buf"
	singlogger "github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"golang.org/x/sys/unix"
)

// Dialer opens connections on the far side of the tunnel.
type Dialer interface {
	DialContext(ctx context.Context, network, address string) (net.Conn, error)
}

// Logger receives both this package's messages and sing-tun's internal ones.
type Logger interface {
	Debugf(format string, args ...any)
	Errorf(format string, args ...any)
}

// Options configures a single run.
type Options struct {
	// FileDescriptor is an open TUN device. It is duplicated, so the caller
	// keeps ownership of the descriptor it passed in — closing the engine
	// does not close it.
	FileDescriptor int

	// MTU must match what was configured on the device. Zero means 1500.
	MTU uint32

	// Inet4Address is the address the stack answers on. It has to agree with
	// the one already set on the device; nothing here applies it.
	Inet4Address netip.Prefix

	// Dialer reaches the internet from the far end of the tunnel.
	Dialer Dialer

	// UDPTimeout expires idle UDP sessions. Zero means 60s.
	UDPTimeout time.Duration

	// ExternalConfiguration tells sing-tun that addresses, routes and DNS are
	// somebody else's job. It must be set on iOS, where a NetworkExtension
	// has already applied them and the syscalls to do it are unavailable.
	ExternalConfiguration bool

	Logger Logger
}

// Engine is a running packet loop. It is not reusable: stop it and start
// another rather than restarting this one.
type Engine struct {
	cancel context.CancelFunc
	stack  tun.Stack
	device tun.Tun
	log    Logger
}

var errNoDialer = errors.New("engine: no dialer")

// Start begins moving packets. On error nothing is left running.
func Start(opts Options) (*Engine, error) {
	if opts.Dialer == nil {
		return nil, errNoDialer
	}
	if opts.FileDescriptor <= 0 {
		return nil, errors.New("engine: bad file descriptor")
	}

	log := opts.Logger
	if log == nil {
		log = nopLogger{}
	}
	mtu := opts.MTU
	if mtu == 0 {
		mtu = 1500
	}
	udpTimeout := opts.UDPTimeout
	if udpTimeout <= 0 {
		udpTimeout = 60 * time.Second
	}

	// Go gets its own descriptor. Without this, tearing the engine down
	// would close the caller's TUN — on iOS that is the extension's utun,
	// and losing it takes the whole tunnel with it.
	dupFd, err := unix.Dup(opts.FileDescriptor)
	if err != nil {
		return nil, err
	}
	unix.CloseOnExec(dupFd)

	tunOpts := tun.Options{
		FileDescriptor:            dupFd,
		MTU:                       mtu,
		EXP_ExternalConfiguration: opts.ExternalConfiguration,
	}
	if opts.Inet4Address.IsValid() {
		tunOpts.Inet4Address = []netip.Prefix{opts.Inet4Address}
	}

	device, err := tun.New(tunOpts)
	if err != nil {
		unix.Close(dupFd)
		return nil, err
	}

	ctx, cancel := context.WithCancel(context.Background())

	// gVisor rather than the system stack, for the reason given in
	// go/tun2socks/main.go: the system stack wants netfilter and root to
	// redirect TCP, and an app process has neither.
	stack, err := tun.NewStack("gvisor", tun.StackOptions{
		Context:    ctx,
		Tun:        device,
		TunOptions: tunOpts,
		Handler:    &handler{dialer: opts.Dialer, log: log},
		Logger:     &stackLogger{log: log},
		UDPTimeout: udpTimeout,
	})
	if err != nil {
		cancel()
		device.Close()
		return nil, err
	}

	if err := stack.Start(); err != nil {
		cancel()
		stack.Close()
		device.Close()
		return nil, err
	}

	log.Debugf("engine: started on fd %d (mtu %d)", dupFd, mtu)
	return &Engine{cancel: cancel, stack: stack, device: device, log: log}, nil
}

// Close stops the packet loop. It is safe to call more than once.
func (e *Engine) Close() error {
	if e.cancel == nil {
		return nil
	}
	e.cancel()
	e.cancel = nil

	var firstErr error
	if e.stack != nil {
		if err := e.stack.Close(); err != nil {
			firstErr = err
		}
		e.stack = nil
	}
	if e.device != nil {
		if err := e.device.Close(); err != nil && firstErr == nil {
			firstErr = err
		}
		e.device = nil
	}
	return firstErr
}

// handler answers the stack's requests for new connections.
type handler struct {
	dialer Dialer
	log    Logger
}

var _ tun.Handler = (*handler)(nil)

// PrepareConnection declines to short-circuit anything: every connection goes
// through the dialer, which is the whole point of the tunnel.
func (h *handler) PrepareConnection(
	network string,
	source M.Socksaddr,
	destination M.Socksaddr,
	routeContext tun.DirectRouteContext,
	timeout time.Duration,
) (tun.DirectRouteDestination, error) {
	return nil, nil
}

func (h *handler) NewConnectionEx(
	ctx context.Context,
	conn net.Conn,
	source M.Socksaddr,
	destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	h.log.Debugf("tcp: %s -> %s", source, destination)
	go func() {
		defer func() {
			conn.Close()
			if onClose != nil {
				onClose(nil)
			}
		}()

		remote, err := h.dialer.DialContext(ctx, "tcp", destination.String())
		if err != nil {
			h.log.Errorf("engine: dial %s: %v", destination, err)
			return
		}
		defer remote.Close()

		done := make(chan struct{}, 2)
		go func() { copyConn(remote, conn); done <- struct{}{} }()
		go func() { copyConn(conn, remote); done <- struct{}{} }()
		<-done
	}()
}

func (h *handler) NewPacketConnectionEx(
	ctx context.Context,
	conn N.PacketConn,
	source M.Socksaddr,
	destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	h.log.Debugf("udp: %s -> %s", source, destination)

	// SSH forwarding carries TCP and nothing else, so UDP has no route out
	// except DNS, which has a TCP form to fall back on. Everything else is
	// dropped rather than left hanging.
	if destination.Port != 53 {
		conn.Close()
		if onClose != nil {
			onClose(nil)
		}
		return
	}

	// The goroutine owns conn from here — closing it in this frame would cut
	// the DNS loop off before it reads its first query.
	go func() {
		defer func() {
			conn.Close()
			if onClose != nil {
				onClose(nil)
			}
		}()
		h.dnsLoop(ctx, conn)
	}()
}

// dnsLoop reads UDP queries off conn and answers each over TCP.
func (h *handler) dnsLoop(ctx context.Context, conn N.PacketConn) {
	buffer := singbuf.New()
	defer buffer.Release()

	for {
		buffer.Reset()
		dest, err := conn.ReadPacket(buffer)
		if err != nil {
			return
		}
		// Copy before the next Reset reclaims it.
		query := append([]byte(nil), buffer.Bytes()...)
		go h.forwardDNS(ctx, conn, dest, query)
	}
}

// forwardDNS sends one query as DNS-over-TCP (RFC 1035 4.2.2: a two-byte
// length prefix) and writes the answer back as a UDP packet.
func (h *handler) forwardDNS(
	ctx context.Context,
	conn N.PacketConn,
	dest M.Socksaddr,
	query []byte,
) {
	tcp, err := h.dialer.DialContext(ctx, "tcp", dest.String())
	if err != nil {
		h.log.Errorf("engine: dns dial %s: %v", dest, err)
		return
	}
	defer tcp.Close()
	tcp.SetDeadline(time.Now().Add(5 * time.Second))

	lenBuf := make([]byte, 2)
	binary.BigEndian.PutUint16(lenBuf, uint16(len(query)))
	if _, err = tcp.Write(append(lenBuf, query...)); err != nil {
		h.log.Errorf("engine: dns write %s: %v", dest, err)
		return
	}

	if _, err = io.ReadFull(tcp, lenBuf); err != nil {
		h.log.Errorf("engine: dns read length %s: %v", dest, err)
		return
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf))
	if respLen == 0 {
		h.log.Errorf("engine: dns empty response from %s", dest)
		return
	}

	resp := make([]byte, respLen)
	if _, err = io.ReadFull(tcp, resp); err != nil {
		h.log.Errorf("engine: dns read body %s: %v", dest, err)
		return
	}

	conn.WritePacket(singbuf.As(resp), dest)
}

func copyConn(dst, src net.Conn) {
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

// stackLogger adapts sing's logger interface onto ours.
type stackLogger struct{ log Logger }

var _ singlogger.Logger = (*stackLogger)(nil)

func (l *stackLogger) Trace(args ...any) { l.log.Debugf("[stack] %v", args) }
func (l *stackLogger) Debug(args ...any) { l.log.Debugf("[stack] %v", args) }
func (l *stackLogger) Info(args ...any)  { l.log.Debugf("[stack] %v", args) }
func (l *stackLogger) Warn(args ...any)  { l.log.Errorf("[stack] %v", args) }
func (l *stackLogger) Error(args ...any) { l.log.Errorf("[stack] %v", args) }
func (l *stackLogger) Fatal(args ...any) { l.log.Errorf("[stack] %v", args) }
func (l *stackLogger) Panic(args ...any) { l.log.Errorf("[stack] %v", args) }

type nopLogger struct{}

func (nopLogger) Debugf(string, ...any) {}
func (nopLogger) Errorf(string, ...any) {}
