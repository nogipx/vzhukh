package procinfo

import (
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
)

// The test process opens sockets and looks itself up: if an offset is wrong,
// the pid or the address comes out as garbage and this fails.

func selfPath(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	// The kernel reports the resolved path: /private/var, not /var.
	resolved, err := filepath.EvalSymlinks(exe)
	if err != nil {
		t.Fatal(err)
	}
	return resolved
}

func TestLookupFindsOurOwnTCPConnection(t *testing.T) {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			defer c.Close()
			buf := make([]byte, 1)
			c.Read(buf)
		}
	}()

	conn, err := net.Dial("tcp4", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	local := conn.LocalAddr().(*net.TCPAddr).AddrPort()
	p, err := Lookup("tcp", local)
	if err != nil {
		t.Fatalf("lookup %s: %v", local, err)
	}
	if p.PID != os.Getpid() {
		t.Fatalf("pid %d, want %d", p.PID, os.Getpid())
	}
	if p.Path != selfPath(t) {
		t.Fatalf("path %q, want %q", p.Path, selfPath(t))
	}
}

func TestLookupFindsOurOwnUDPSocket(t *testing.T) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	p, err := Lookup("udp", conn.LocalAddr().(*net.UDPAddr).AddrPort())
	if err != nil {
		t.Fatal(err)
	}
	if p.PID != os.Getpid() {
		t.Fatalf("pid %d, want %d", p.PID, os.Getpid())
	}
}

func TestLookupFindsIPv6(t *testing.T) {
	ln, err := net.Listen("tcp6", "[::1]:0")
	if err != nil {
		t.Skip("no IPv6 loopback")
	}
	defer ln.Close()
	go func() {
		c, err := ln.Accept()
		if err == nil {
			defer c.Close()
			c.Read(make([]byte, 1))
		}
	}()
	conn, err := net.Dial("tcp6", ln.Addr().String())
	if err != nil {
		// A transparent proxy (Proxifier) can refuse even loopback v6.
		t.Skipf("cannot reach IPv6 loopback: %v", err)
	}
	defer conn.Close()
	p, err := Lookup("tcp", conn.LocalAddr().(*net.TCPAddr).AddrPort())
	if err != nil {
		t.Fatal(err)
	}
	if p.PID != os.Getpid() {
		t.Fatalf("pid %d, want %d", p.PID, os.Getpid())
	}
}

func TestLookupOfAClosedPortIsNotFound(t *testing.T) {
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().(*net.TCPAddr).AddrPort()
	ln.Close()
	if _, err := Lookup("tcp", netip.AddrPortFrom(addr.Addr(), addr.Port())); err != ErrNotFound {
		t.Fatalf("got %v, want ErrNotFound", err)
	}
}
