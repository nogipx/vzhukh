package udpgw

import (
	"io"
	"net"
	"net/netip"
	"sync"
	"time"
)

// Serve answers udpgw clients on ln until it closes. Each client stream may
// carry many sessions; each session gets a UDP socket of its own, dropped
// after idle of no traffic either way.
func Serve(ln net.Listener, idle time.Duration, logf func(string, ...any)) error {
	if idle <= 0 {
		idle = 2 * time.Minute
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			return err
		}
		go serveStream(conn, idle, logf)
	}
}

func serveStream(stream net.Conn, idle time.Duration, logf func(string, ...any)) {
	defer stream.Close()
	var writeMu sync.Mutex
	write := func(f Frame) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return WriteFrame(stream, f)
	}

	var mu sync.Mutex
	sockets := map[uint16]*net.UDPConn{}
	defer func() {
		mu.Lock()
		for _, s := range sockets {
			s.Close()
		}
		mu.Unlock()
	}()

	for {
		f, err := ReadFrame(stream)
		if err != nil {
			if err != io.EOF && logf != nil {
				logf("udpgw: %v", err)
			}
			return
		}
		if f.IsKeepalive() {
			continue
		}
		mu.Lock()
		sock := sockets[f.ConID]
		if sock == nil || f.flags&flagRebind != 0 {
			if sock != nil {
				sock.Close()
			}
			network := "udp4"
			if f.Addr.Addr().Is6() && !f.Addr.Addr().Is4In6() {
				network = "udp6"
			}
			sock, err = net.ListenUDP(network, nil)
			if err != nil {
				mu.Unlock()
				continue
			}
			sockets[f.ConID] = sock
			go relayBack(sock, f.ConID, idle, write, func() {
				mu.Lock()
				if sockets[f.ConID] == sock {
					delete(sockets, f.ConID)
				}
				mu.Unlock()
			})
		}
		mu.Unlock()
		sock.SetReadDeadline(time.Now().Add(idle))
		sock.WriteToUDPAddrPort(f.Payload, f.Addr)
	}
}

func relayBack(sock *net.UDPConn, conid uint16, idle time.Duration, write func(Frame) error, done func()) {
	defer done()
	defer sock.Close()
	buf := make([]byte, 65535)
	for {
		sock.SetReadDeadline(time.Now().Add(idle))
		n, from, err := sock.ReadFromUDPAddrPort(buf)
		if err != nil {
			return
		}
		src := netip.AddrPortFrom(from.Addr().Unmap(), from.Port())
		if err := write(Frame{ConID: conid, Addr: src, Payload: append([]byte(nil), buf[:n]...)}); err != nil {
			return
		}
	}
}
