package sniff

import (
	"crypto/tls"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// clientHello captures the first flight of a real crypto/tls handshake.
func clientHello(t *testing.T, serverName string) []byte {
	t.Helper()
	client, server := net.Pipe()
	defer server.Close()

	go func() {
		c := tls.Client(client, &tls.Config{ServerName: serverName, InsecureSkipVerify: true})
		c.SetDeadline(time.Now().Add(2 * time.Second))
		c.Handshake()
		client.Close()
	}()

	buf := make([]byte, 16*1024)
	server.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := server.Read(buf)
	if err != nil {
		t.Fatalf("read hello: %v", err)
	}
	return buf[:n]
}

func TestServerNameFromARealClientHello(t *testing.T) {
	hello := clientHello(t, "Www.Example.com")
	name, ok := ServerName(hello)
	if !ok || name != "www.example.com" {
		t.Fatalf("got %q %v", name, ok)
	}
	if d, src, ok := Domain(hello); !ok || d != "www.example.com" || src != SourceTLS {
		t.Fatalf("Domain: %q %q %v", d, src, ok)
	}
}

func TestTruncatedHelloIsRejectedNotPanicking(t *testing.T) {
	hello := clientHello(t, "example.com")
	for i := 0; i < len(hello); i++ {
		if name, ok := ServerName(hello[:i]); ok && name != "example.com" {
			t.Fatalf("prefix %d gave %q", i, name)
		}
	}
}

func TestHelloWithoutSNI(t *testing.T) {
	// An IP address as ServerName makes crypto/tls leave the extension out.
	if _, ok := ServerName(clientHello(t, "10.0.0.1")); ok {
		t.Fatal("found a name in a hello without SNI")
	}
}

func TestHTTPHost(t *testing.T) {
	cases := map[string]string{
		"GET / HTTP/1.1\r\nHost: Example.com\r\n\r\n":                   "example.com",
		"POST /x HTTP/1.1\r\nUser-Agent: a\r\nhost: a.b.c:8080\r\n\r\n": "a.b.c",
		"GET / HTTP/1.1\r\nHost: [::1]:80\r\n\r\n":                      "",
		"GET / HTTP/1.1\r\n\r\nHost: late.com\r\n":                      "",
		"SSH-2.0-OpenSSH_9.6\r\n":                                       "",
		"GET / HTTP/1.1\r\nHost: bad host\r\n\r\n":                      "",
	}
	for req, want := range cases {
		got, ok := HTTPHost([]byte(req))
		if got != want || ok != (want != "") {
			t.Errorf("%q: got %q %v, want %q", req, got, ok, want)
		}
	}
}

func TestGarbage(t *testing.T) {
	for _, data := range [][]byte{nil, {22}, {22, 3, 1, 0, 0}, {22, 3, 1, 255, 255, 1}, []byte("hello")} {
		if _, _, ok := Domain(data); ok {
			t.Errorf("%v: found a domain in garbage", data)
		}
	}
}

func TestNeedMore(t *testing.T) {
	hello := clientHello(t, "www.example.com")
	if NeedMore(hello) {
		t.Fatal("a whole hello asks for more")
	}
	for _, cut := range []int{1, 4, 5, len(hello) / 2, len(hello) - 1} {
		if !NeedMore(hello[:cut]) {
			t.Errorf("hello cut at %d does not ask for more", cut)
		}
	}
	if !NeedMore([]byte("GET / HTTP/1.1\r\nHost: a")) || NeedMore([]byte("GET / HTTP/1.1\r\nHost: a\r\n\r\n")) {
		t.Error("HTTP completeness wrong")
	}
	if !NeedMore([]byte("GE")) || NeedMore([]byte("SSH-2.0-x\r\n")) || NeedMore(nil) {
		t.Error("prefixes wrong")
	}
}

// A ClientHello split the way a browser's post-quantum one arrives.
func TestServerNameFromABigHelloInPieces(t *testing.T) {
	hello := clientHello(t, "rr1---sn-abc.googlevideo.com")
	padded := padHello(t, hello, 1800)
	if NeedMore(padded) {
		t.Fatal("padded hello incomplete")
	}
	if name, ok := ServerName(padded); !ok || name != "rr1---sn-abc.googlevideo.com" {
		t.Fatalf("got %q %v", name, ok)
	}
	if _, ok := ServerName(padded[:1400]); ok {
		t.Fatal("first segment alone should not parse; the test would prove nothing")
	}
}

// padHello grows a ClientHello to about size bytes with a padding
// extension (RFC 7685), fixing up every length on the way.
func padHello(t *testing.T, hello []byte, size int) []byte {
	t.Helper()
	pad := size - len(hello) - 4
	if pad <= 0 {
		return hello
	}
	body := append([]byte(nil), hello[5:]...)
	// handshake header 4, version 2, random 32
	i := 4 + 2 + 32
	i += 1 + int(body[i])
	i += 2 + int(binary.BigEndian.Uint16(body[i:]))
	i += 1 + int(body[i])
	extLenAt := i
	ext := make([]byte, 4+pad)
	binary.BigEndian.PutUint16(ext[0:], 21)
	binary.BigEndian.PutUint16(ext[2:], uint16(pad))
	body = append(body, ext...)
	binary.BigEndian.PutUint16(body[extLenAt:], binary.BigEndian.Uint16(body[extLenAt:])+uint16(len(ext)))
	hsLen := len(body) - 4
	body[1], body[2], body[3] = byte(hsLen>>16), byte(hsLen>>8), byte(hsLen)
	rec := []byte{22, 3, 1, 0, 0}
	binary.BigEndian.PutUint16(rec[3:], uint16(len(body)))
	return append(rec, body...)
}
