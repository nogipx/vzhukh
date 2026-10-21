// Package udpgw carries UDP over a TCP stream, in the protocol of
// badvpn-udpgw, so UDP can travel an SSH chain, which forwards TCP only.
//
// The daemon opens a direct-tcpip channel to a udpgw server on the far
// end (127.0.0.1:7300 by convention) and frames each datagram:
//
//	length  uint16, little-endian: the size of what follows
//	flags   uint8: 0x01 keepalive, 0x02 rebind, 0x04 dns, 0x08 IPv6
//	conid   uint16, big-endian: which UDP session on this stream
//	address 4 or 16 bytes, then port uint16, big-endian
//	payload
//
// The server sends each reply back the same way, with the address it came
// from. Either side's implementation can be badvpn's or this one.
package udpgw

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"sync"
)

// DefaultAddr is where a udpgw server listens on the far end.
const DefaultAddr = "127.0.0.1:7300"

const (
	flagKeepalive = 0x01
	flagRebind    = 0x02
	flagDNS       = 0x04
	flagIPv6      = 0x08
)

// MaxPayload bounds one datagram; the frame length field is 16 bits.
const MaxPayload = 65535 - 3 - 18

var errTooBig = errors.New("udpgw: datagram too big")

// Frame is one datagram on the stream.
type Frame struct {
	ConID   uint16
	Addr    netip.AddrPort
	Payload []byte
	flags   uint8
}

// WriteFrame encodes f onto w in one write.
func WriteFrame(w io.Writer, f Frame) error {
	addr := f.Addr.Addr().Unmap()
	alen := 4
	flags := f.flags
	if addr.Is6() {
		alen = 16
		flags |= flagIPv6
	}
	body := 3 + alen + 2 + len(f.Payload)
	if body > 65535 {
		return errTooBig
	}
	buf := make([]byte, 2+body)
	binary.LittleEndian.PutUint16(buf[0:], uint16(body))
	buf[2] = flags
	binary.BigEndian.PutUint16(buf[3:], f.ConID)
	off := 5
	if alen == 4 {
		a := addr.As4()
		copy(buf[off:], a[:])
	} else {
		a := addr.As16()
		copy(buf[off:], a[:])
	}
	off += alen
	binary.BigEndian.PutUint16(buf[off:], f.Addr.Port())
	copy(buf[off+2:], f.Payload)
	_, err := w.Write(buf)
	return err
}

// ReadFrame decodes the next frame from r. Keepalives come back with no
// payload and no address.
func ReadFrame(r io.Reader) (Frame, error) {
	var lenBuf [2]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return Frame{}, err
	}
	body := make([]byte, binary.LittleEndian.Uint16(lenBuf[:]))
	if _, err := io.ReadFull(r, body); err != nil {
		return Frame{}, err
	}
	if len(body) < 3 {
		return Frame{}, fmt.Errorf("udpgw: frame of %d bytes", len(body))
	}
	f := Frame{flags: body[0], ConID: binary.BigEndian.Uint16(body[1:3])}
	if f.flags&flagKeepalive != 0 && len(body) == 3 {
		return f, nil
	}
	rest := body[3:]
	alen := 4
	if f.flags&flagIPv6 != 0 {
		alen = 16
	}
	if len(rest) < alen+2 {
		return Frame{}, fmt.Errorf("udpgw: short address in a frame of %d bytes", len(body))
	}
	var addr netip.Addr
	if alen == 4 {
		addr = netip.AddrFrom4([4]byte(rest[:4]))
	} else {
		addr = netip.AddrFrom16([16]byte(rest[:16]))
	}
	f.Addr = netip.AddrPortFrom(addr, binary.BigEndian.Uint16(rest[alen:]))
	f.Payload = rest[alen+2:]
	return f, nil
}

// IsKeepalive reports whether f carries no datagram.
func (f Frame) IsKeepalive() bool { return f.flags&flagKeepalive != 0 && f.Payload == nil }

// Session is one UDP session over a stream of its own: every datagram
// carries conid 1.
type Session struct {
	stream io.ReadWriteCloser
	mu     sync.Mutex
}

// NewSession wraps a stream to a udpgw server.
func NewSession(stream io.ReadWriteCloser) *Session { return &Session{stream: stream} }

// WriteTo sends payload to dst.
func (s *Session) WriteTo(payload []byte, dst netip.AddrPort) error {
	if len(payload) > MaxPayload {
		return errTooBig
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return WriteFrame(s.stream, Frame{ConID: 1, Addr: dst, Payload: payload})
}

// ReadFrom returns the next datagram and where it came from, skipping
// keepalives.
func (s *Session) ReadFrom() ([]byte, netip.AddrPort, error) {
	for {
		f, err := ReadFrame(s.stream)
		if err != nil {
			return nil, netip.AddrPort{}, err
		}
		if !f.IsKeepalive() {
			return f.Payload, f.Addr, nil
		}
	}
}

// Close ends the session.
func (s *Session) Close() error { return s.stream.Close() }
