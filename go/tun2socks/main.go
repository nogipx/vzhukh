// Vzhukh tun2socks — routes TUN packets through a SOCKS5 proxy.
// Uses sagernet/sing-tun with "system" stack (no gVisor, Android-compatible).
//
// Compiled as a shared library (.so) for Android via:
//
//	GOOS=android GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-shared -o libtun2socks.so .
package main

/*
#include <stdlib.h>
#include <android/log.h>

static void logError(const char* msg) {
    __android_log_print(ANDROID_LOG_ERROR, "tun2socks", "%s", msg);
}
static void logDebug(const char* msg) {
    __android_log_print(ANDROID_LOG_DEBUG, "tun2socks", "%s", msg);
}
*/
import "C"

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sync"
	"time"
	"unsafe"

	tun "github.com/sagernet/sing-tun"
	singbuf "github.com/sagernet/sing/common/buf"
	singlogger "github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"golang.org/x/net/proxy"
	"golang.org/x/sys/unix"
)

func logErr(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	fmt.Fprintln(os.Stderr, msg)
	cs := C.CString(msg)
	C.logError(cs)
	C.free(unsafe.Pointer(cs))
}

func logDbg(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	cs := C.CString(msg)
	C.logDebug(cs)
	C.free(unsafe.Pointer(cs))
}

var (
	mu        sync.Mutex
	cancelFn  context.CancelFunc
	tunDev    tun.Tun
	stack     tun.Stack
	running   bool
)

// tun2socks_start opens the TUN fd and starts routing traffic through socksAddr.
// Returns 0 on success, non-zero on error.
//
//export tun2socks_start
func tun2socks_start(tunFd C.int, socksAddr *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return 1
	}

	addr := C.GoString(socksAddr)
	if addr == "" {
		logErr("tun2socks: empty socks address")
		return 2
	}

	dialer, err := proxy.SOCKS5("tcp", addr, nil, proxy.Direct)
	if err != nil {
		logErr("tun2socks: socks5 dialer: %v", err)
		return 3
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancelFn = cancel

	// Duplicate the fd so Go owns its copy; Kotlin side keeps the original.
	dupFd, dupErr := unix.Dup(int(tunFd))
	if dupErr != nil {
		cancel()
		logErr("tun2socks: dup fd: %v", dupErr)
		return 4
	}
	unix.CloseOnExec(dupFd)

	tunOpts := tun.Options{
		FileDescriptor: dupFd,
		// /30 gives system stack a gateway address (10.0.0.3); actual interface
		// is already configured as /32 by Android VpnService — this is metadata only.
		Inet4Address: []netip.Prefix{netip.MustParsePrefix("10.0.0.2/30")},
		MTU:          1500,
	}

	dev, err := tun.New(tunOpts)
	if err != nil {
		cancel()
		logErr("tun2socks: tun.New: %v", err)
		return 4
	}
	tunDev = dev

	handler := &socksHandler{dialer: dialer}

	stack, err = tun.NewStack("system", tun.StackOptions{
		Context:    ctx,
		Tun:        dev,
		TunOptions: tunOpts,
		Handler:    handler,
		Logger:     &stackLogger{},
		UDPTimeout: 60 * time.Second,
	})
	if err != nil {
		cancel()
		dev.Close()
		tunDev = nil
		logErr("tun2socks: NewStack: %v", err)
		return 5
	}

	if err = stack.Start(); err != nil {
		cancel()
		dev.Close()
		tunDev = nil
		logErr("tun2socks: stack.Start: %v", err)
		return 6
	}

	running = true
	logDbg("tun2socks started: fd=%d socks=%s", dupFd, addr)
	return 0
}

// tun2socks_stop stops the routing engine.
//
//export tun2socks_stop
func tun2socks_stop() {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return
	}
	if cancelFn != nil {
		cancelFn()
		cancelFn = nil
	}
	if stack != nil {
		stack.Close()
		stack = nil
	}
	if tunDev != nil {
		tunDev.Close()
		tunDev = nil
	}
	running = false
}

// socksHandler implements tun.Handler — forwards all connections to SOCKS5.
type socksHandler struct {
	dialer proxy.Dialer
}

func (h *socksHandler) PrepareConnection(
	network string,
	source M.Socksaddr,
	destination M.Socksaddr,
	routeContext tun.DirectRouteContext,
	timeout time.Duration,
) (tun.DirectRouteDestination, error) {
	return nil, nil
}

func (h *socksHandler) NewConnectionEx(
	ctx context.Context,
	conn net.Conn,
	source M.Socksaddr,
	destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	logDbg("tcp: %s -> %s", source, destination)
	go func() {
		defer func() {
			conn.Close()
			if onClose != nil {
				onClose(nil)
			}
		}()

		remote, err := h.dialer.Dial("tcp", destination.String())
		if err != nil {
			logErr("tun2socks: dial %s: %v", destination, err)
			return
		}
		defer remote.Close()

		done := make(chan struct{}, 2)
		go func() { copyConn(remote, conn); done <- struct{}{} }()
		go func() { copyConn(conn, remote); done <- struct{}{} }()
		<-done
	}()
}

func (h *socksHandler) NewPacketConnectionEx(
	ctx context.Context,
	conn N.PacketConn,
	source M.Socksaddr,
	destination M.Socksaddr,
	onClose N.CloseHandlerFunc,
) {
	logDbg("udp: %s -> %s", source, destination)
	// Only handle DNS (port 53) via DNS-over-TCP through the SOCKS5 tunnel.
	// All other UDP is dropped — SSH dynamic forwarding doesn't support UDP associate.
	if destination.Port != 53 {
		conn.Close()
		if onClose != nil {
			onClose(nil)
		}
		return
	}

	// Hand off conn ownership to the goroutine — do NOT defer close here.
	go func() {
		defer func() {
			conn.Close()
			if onClose != nil {
				onClose(nil)
			}
		}()
		h.handleDNSOverTCP(ctx, conn, destination)
	}()
}

// handleDNSOverTCP reads UDP DNS queries from conn, converts each to TCP DNS
// (RFC 1035 §4.2.2: 2-byte length prefix), sends through SOCKS5, and writes
// the response back as a UDP packet.
func (h *socksHandler) handleDNSOverTCP(ctx context.Context, conn N.PacketConn, destination M.Socksaddr) {
	logDbg("dns loop start: %s", destination)
	singBuf := singbuf.New()
	defer singBuf.Release()

	for {
		singBuf.Reset()
		dest, err := conn.ReadPacket(singBuf)
		if err != nil {
			logDbg("dns loop read err: %v", err)
			return
		}

		logDbg("dns query: %d bytes -> %s", singBuf.Len(), dest)
		query := append([]byte(nil), singBuf.Bytes()...) // copy before buffer reset
		go h.forwardDNSTCP(ctx, conn, dest, query)
	}
}

func (h *socksHandler) forwardDNSTCP(ctx context.Context, conn N.PacketConn, dest M.Socksaddr, query []byte) {
	logDbg("dns forward: %d bytes -> %s", len(query), dest)
	tcp, err := h.dialer.Dial("tcp", dest.String())
	if err != nil {
		logErr("tun2socks: dns tcp dial %s: %v", dest, err)
		return
	}
	defer tcp.Close()
	tcp.SetDeadline(time.Now().Add(5 * time.Second))

	// Write length-prefixed query.
	lenBuf := make([]byte, 2)
	binary.BigEndian.PutUint16(lenBuf, uint16(len(query)))
	if _, err = tcp.Write(append(lenBuf, query...)); err != nil {
		logErr("dns write %s: %v", dest, err)
		return
	}
	logDbg("dns wrote %d bytes to %s", len(query)+2, dest)

	// Read 2-byte response length.
	if _, err = io.ReadFull(tcp, lenBuf); err != nil {
		logErr("dns read len %s: %v", dest, err)
		return
	}
	respLen := int(binary.BigEndian.Uint16(lenBuf))
	logDbg("dns resp len=%d from %s", respLen, dest)
	if respLen == 0 || respLen > 65535 {
		logErr("dns bad respLen=%d from %s", respLen, dest)
		return
	}

	// Read response body.
	resp := make([]byte, respLen)
	if _, err = io.ReadFull(tcp, resp); err != nil {
		logErr("dns read body %s: %v", dest, err)
		return
	}

	// Write back as UDP packet.
	respBuf := singbuf.As(resp)
	conn.WritePacket(respBuf, dest)
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

// stackLogger forwards sing-tun internal logs to Android logcat.
type stackLogger struct{}

var _ singlogger.Logger = (*stackLogger)(nil)

func (l *stackLogger) Trace(args ...any) { logDbg("[stack] %v", fmt.Sprint(args...)) }
func (l *stackLogger) Debug(args ...any) { logDbg("[stack] %v", fmt.Sprint(args...)) }
func (l *stackLogger) Info(args ...any)  { logDbg("[stack] %v", fmt.Sprint(args...)) }
func (l *stackLogger) Warn(args ...any)  { logErr("[stack] %v", fmt.Sprint(args...)) }
func (l *stackLogger) Error(args ...any) { logErr("[stack] %v", fmt.Sprint(args...)) }
func (l *stackLogger) Fatal(args ...any) { logErr("[stack] %v", fmt.Sprint(args...)) }
func (l *stackLogger) Panic(args ...any) { logErr("[stack] %v", fmt.Sprint(args...)) }

func main() {}
