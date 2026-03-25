// Flume tun2socks — routes TUN packets through a SOCKS5 proxy.
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
*/
import "C"

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"os"
	"sync"
	"time"
	"unsafe"

	tun "github.com/sagernet/sing-tun"
	"github.com/sagernet/sing/common/logger"
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

var (
	mu        sync.Mutex
	cancelFn  context.CancelFunc
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

	tunDev, err := tun.New(tunOpts)
	if err != nil {
		cancel()
		logErr("tun2socks: tun.New: %v", err)
		return 4
	}

	handler := &socksHandler{dialer: dialer}

	stack, err = tun.NewStack("system", tun.StackOptions{
		Context:    ctx,
		Tun:        tunDev,
		TunOptions: tunOpts,
		Handler:    handler,
		Logger:     logger.NOP(),
		UDPTimeout: 60 * time.Second,
	})
	if err != nil {
		cancel()
		tunDev.Close()
		logErr("tun2socks: NewStack: %v", err)
		return 5
	}

	if err = stack.Start(); err != nil {
		cancel()
		tunDev.Close()
		logErr("tun2socks: stack.Start: %v", err)
		return 6
	}

	running = true
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
	// UDP: best-effort forwarding via SOCKS5 UDP associate.
	// Many SOCKS5 servers (including SSH dynamic) don't support UDP — drop silently.
	if onClose != nil {
		onClose(nil)
	}
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

func main() {}
