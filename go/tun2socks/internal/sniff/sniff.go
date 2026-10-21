// Package sniff reads the destination name out of the first bytes a client
// sends: the SNI of a TLS ClientHello, or the Host header of an HTTP request.
//
// The daemon learns most names from its own DNS. This covers the rest: apps
// that resolve names themselves (DNS over HTTPS) or connect to addresses
// they were given. Both parsers look at one buffer and give up on anything
// that does not fit in it; they never block and never read further.
package sniff

import (
	"bytes"
	"encoding/binary"
	"strings"
)

// Source says where a sniffed name came from.
type Source string

const (
	SourceTLS  Source = "sni"
	SourceHTTP Source = "http"
)

// Domain returns the name in data, if either parser finds one.
func Domain(data []byte) (string, Source, bool) {
	if name, ok := ServerName(data); ok {
		return name, SourceTLS, true
	}
	if name, ok := HTTPHost(data); ok {
		return name, SourceHTTP, true
	}
	return "", "", false
}

// ServerName parses a TLS ClientHello and returns its server_name extension.
func ServerName(data []byte) (string, bool) {
	// Record header: type 22 (handshake), version, length.
	if len(data) < 5 || data[0] != 22 || data[1] != 3 {
		return "", false
	}
	recordLen := int(binary.BigEndian.Uint16(data[3:5]))
	body := data[5:]
	if len(body) > recordLen {
		body = body[:recordLen]
	}

	// Handshake header: type 1 (ClientHello), 3-byte length.
	if len(body) < 4 || body[0] != 1 {
		return "", false
	}
	r := reader{b: body[4:]}

	r.skip(2)  // client version
	r.skip(32) // random
	r.skip(int(r.u8()))
	r.skip(int(r.u16())) // cipher suites
	r.skip(int(r.u8()))  // compression methods

	extensions := reader{b: r.take(int(r.u16()))}
	for !extensions.bad && len(extensions.b) >= 4 {
		typ := extensions.u16()
		ext := reader{b: extensions.take(int(extensions.u16()))}
		if typ != 0 { // server_name
			continue
		}
		list := reader{b: ext.take(int(ext.u16()))}
		for !list.bad && len(list.b) >= 3 {
			nameType := list.u8()
			name := list.take(int(list.u16()))
			if nameType == 0 && !list.bad && validName(name) {
				return strings.ToLower(string(name)), true
			}
		}
	}
	return "", false
}

var methods = [][]byte{
	[]byte("GET "), []byte("POST "), []byte("HEAD "), []byte("PUT "),
	[]byte("DELETE "), []byte("OPTIONS "), []byte("PATCH "), []byte("CONNECT "),
}

// HTTPHost returns the Host header of a plain HTTP/1 request, without port.
func HTTPHost(data []byte) (string, bool) {
	isHTTP := false
	for _, m := range methods {
		if bytes.HasPrefix(data, m) {
			isHTTP = true
			break
		}
	}
	if !isHTTP {
		return "", false
	}

	lines := bytes.Split(data, []byte("\r\n"))
	for _, line := range lines[1:] {
		if len(line) == 0 {
			break // end of headers
		}
		name, value, ok := bytes.Cut(line, []byte(":"))
		if !ok || !strings.EqualFold(string(bytes.TrimSpace(name)), "host") {
			continue
		}
		host := string(bytes.TrimSpace(value))
		if strings.HasPrefix(host, "[") {
			// An IPv6 literal is an address, not a name.
			return "", false
		}
		if h, _, found := strings.Cut(host, ":"); found {
			host = h
		}
		if !validName([]byte(host)) {
			return "", false
		}
		return strings.ToLower(host), true
	}
	return "", false
}

// validName accepts what can be a DNS name and rejects anything with bytes a
// name cannot hold, so a garbled buffer is not reported as a domain.
func validName(name []byte) bool {
	if len(name) == 0 || len(name) > 253 {
		return false
	}
	for _, c := range name {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '-', c == '.', c == '_':
		default:
			return false
		}
	}
	return true
}

// reader walks a buffer and turns every overrun into bad instead of a panic.
type reader struct {
	b   []byte
	bad bool
}

func (r *reader) take(n int) []byte {
	if r.bad || n < 0 || n > len(r.b) {
		r.bad = true
		r.b = nil
		return nil
	}
	out := r.b[:n]
	r.b = r.b[n:]
	return out
}

func (r *reader) skip(n int) { r.take(n) }

func (r *reader) u8() byte {
	b := r.take(1)
	if b == nil {
		return 0
	}
	return b[0]
}

func (r *reader) u16() uint16 {
	b := r.take(2)
	if b == nil {
		return 0
	}
	return binary.BigEndian.Uint16(b)
}

// MaxHead bounds how much NeedMore asks for: a ClientHello fits in one TLS
// record of at most 16KB, and HTTP headers worth reading fit in less.
const MaxHead = 16*1024 + 5

// NeedMore reports whether data looks like the start of a TLS ClientHello
// or an HTTP request that is not complete yet. Browsers that offer
// post-quantum key exchange send a ClientHello of about 1.8KB, which
// arrives in two TCP segments; reading only the first loses the name.
func NeedMore(data []byte) bool {
	if len(data) == 0 || len(data) >= MaxHead {
		return false
	}
	if len(data) >= 1 && data[0] == 22 {
		if len(data) < 5 {
			return true
		}
		if data[1] != 3 {
			return false
		}
		return len(data) < 5+int(binary.BigEndian.Uint16(data[3:5]))
	}
	for _, m := range methods {
		if len(data) < len(m) {
			if bytes.HasPrefix(m, data) {
				return true
			}
			continue
		}
		if bytes.HasPrefix(data, m) {
			return !bytes.Contains(data, []byte("\r\n\r\n")) && len(data) < 8*1024
		}
	}
	return false
}
