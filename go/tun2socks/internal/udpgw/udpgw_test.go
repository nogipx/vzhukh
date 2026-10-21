package udpgw

import (
	"bytes"
	"net"
	"net/netip"
	"testing"
	"time"
)

func TestFrameRoundTrip(t *testing.T) {
	for _, addr := range []string{"1.2.3.4:443", "[2001:db8::1]:53"} {
		var buf bytes.Buffer
		in := Frame{ConID: 7, Addr: netip.MustParseAddrPort(addr), Payload: []byte("hello")}
		if err := WriteFrame(&buf, in); err != nil {
			t.Fatal(err)
		}
		out, err := ReadFrame(&buf)
		if err != nil {
			t.Fatal(err)
		}
		if out.ConID != 7 || out.Addr != in.Addr || string(out.Payload) != "hello" {
			t.Fatalf("%s: got %+v", addr, out)
		}
	}
}

// Bytes as badvpn's client writes them, so the two interoperate.
func TestWireFormatMatchesBadvpn(t *testing.T) {
	var buf bytes.Buffer
	WriteFrame(&buf, Frame{ConID: 0x0102, Addr: netip.MustParseAddrPort("10.0.0.1:53"), Payload: []byte{0xAA}})
	want := []byte{
		10, 0, // length 10, little-endian
		0x00,       // flags
		0x01, 0x02, // conid, big-endian
		10, 0, 0, 1, // address
		0x00, 0x35, // port 53, big-endian
		0xAA,
	}
	if !bytes.Equal(buf.Bytes(), want) {
		t.Fatalf("got % x\nwant % x", buf.Bytes(), want)
	}
}

func TestSessionThroughServer(t *testing.T) {
	echo, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer echo.Close()
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := echo.ReadFromUDP(buf)
			if err != nil {
				return
			}
			echo.WriteToUDP(append([]byte("re:"), buf[:n]...), from)
		}
	}()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go Serve(ln, time.Minute, t.Logf)

	stream, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	s := NewSession(stream)
	defer s.Close()
	dst := echo.LocalAddr().(*net.UDPAddr).AddrPort()
	for _, msg := range []string{"one", "two"} {
		if err := s.WriteTo([]byte(msg), dst); err != nil {
			t.Fatal(err)
		}
		stream.SetReadDeadline(time.Now().Add(3 * time.Second))
		payload, from, err := s.ReadFrom()
		if err != nil {
			t.Fatal(err)
		}
		if string(payload) != "re:"+msg || from != dst {
			t.Fatalf("got %q from %s", payload, from)
		}
	}
}
