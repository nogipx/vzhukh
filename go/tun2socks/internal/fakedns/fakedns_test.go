package fakedns

import (
	"context"
	"net/netip"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

func query(t *testing.T, name string, typ dnsmessage.Type) []byte {
	t.Helper()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 0x1234, RecursionDesired: true})
	b.StartQuestions()
	b.Question(dnsmessage.Question{
		Name:  dnsmessage.MustNewName(name),
		Type:  typ,
		Class: dnsmessage.ClassINET,
	})
	out, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func parse(t *testing.T, raw []byte) dnsmessage.Message {
	t.Helper()
	var m dnsmessage.Message
	if err := m.Unpack(raw); err != nil {
		t.Fatalf("unpack: %v", err)
	}
	return m
}

func newServer(t *testing.T, forwarded *[]string) *Server {
	t.Helper()
	pool, err := NewPool(DefaultPrefix)
	if err != nil {
		t.Fatal(err)
	}
	return &Server{
		Pool: pool,
		Forward: func(_ context.Context, q []byte, name string) ([]byte, error) {
			*forwarded = append(*forwarded, name)
			return q, nil
		},
	}
}

func TestAGetsAPlaceholderThatMapsBack(t *testing.T) {
	var forwarded []string
	s := newServer(t, &forwarded)

	raw, err := s.Answer(context.Background(), query(t, "Www.Example.com.", dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	m := parse(t, raw)
	if m.ID != 0x1234 || !m.Response || m.RCode != dnsmessage.RCodeSuccess {
		t.Fatalf("header %+v", m.Header)
	}
	if len(m.Answers) != 1 {
		t.Fatalf("%d answers", len(m.Answers))
	}
	a := m.Answers[0].Body.(*dnsmessage.AResource)
	ip := netip.AddrFrom4(a.A)
	if !s.Pool.Contains(ip) {
		t.Fatalf("%s is outside the pool", ip)
	}
	if name, ok := s.Pool.Lookup(ip); !ok || name != "www.example.com" {
		t.Fatalf("lookup %s: %q %v", ip, name, ok)
	}
	if m.Answers[0].Header.TTL != 1 {
		t.Fatalf("ttl %d", m.Answers[0].Header.TTL)
	}

	// Asking again gives the same address.
	again := parse(t, must(s.Answer(context.Background(), query(t, "www.example.com.", dnsmessage.TypeA))))
	if netip.AddrFrom4(again.Answers[0].Body.(*dnsmessage.AResource).A) != ip {
		t.Fatal("second answer differs")
	}
	if len(forwarded) != 0 {
		t.Fatalf("forwarded %v", forwarded)
	}
}

func must(b []byte, err error) []byte {
	if err != nil {
		panic(err)
	}
	return b
}

func TestAAAAAndHTTPSGetNoData(t *testing.T) {
	var forwarded []string
	s := newServer(t, &forwarded)
	for _, typ := range []dnsmessage.Type{dnsmessage.TypeAAAA, typeHTTPS, typeSVCB} {
		m := parse(t, must(s.Answer(context.Background(), query(t, "example.com.", typ))))
		if m.RCode != dnsmessage.RCodeSuccess || len(m.Answers) != 0 {
			t.Errorf("type %d: rcode %v, %d answers", typ, m.RCode, len(m.Answers))
		}
	}
	if len(forwarded) != 0 {
		t.Fatalf("forwarded %v", forwarded)
	}
}

func TestLocalAndOtherQueriesAreForwarded(t *testing.T) {
	var forwarded []string
	s := newServer(t, &forwarded)
	queries := []struct {
		name string
		typ  dnsmessage.Type
	}{
		{"printer.local.", dnsmessage.TypeA},
		{"router.lan.", dnsmessage.TypeA},
		{"nas.", dnsmessage.TypeA},
		{"1.0.168.192.in-addr.arpa.", dnsmessage.TypePTR},
		{"example.com.", dnsmessage.TypeTXT},
		{"example.com.", dnsmessage.TypeMX},
	}
	for _, q := range queries {
		if _, err := s.Answer(context.Background(), query(t, q.name, q.typ)); err != nil {
			t.Fatal(err)
		}
	}
	if len(forwarded) != len(queries) {
		t.Fatalf("forwarded %v", forwarded)
	}
}

func TestPoolReusesTheOldestAddressWhenFull(t *testing.T) {
	pool, err := NewPool(netip.MustParsePrefix("10.0.0.0/24"))
	if err != nil {
		t.Fatal(err)
	}
	first := pool.Assign("first.test")
	if first != netip.MustParseAddr("10.0.0.2") {
		t.Fatalf("first address %s", first)
	}
	for i := 1; i < int(pool.size); i++ {
		pool.Assign("n" + itoa(i) + ".test")
	}
	if _, ok := pool.Lookup(first); !ok {
		t.Fatal("pool not yet full, first mapping evicted early")
	}
	reused := pool.Assign("late.test")
	if reused != first {
		t.Fatalf("got %s, want the oldest %s reused", reused, first)
	}
	if name, _ := pool.Lookup(first); name != "late.test" {
		t.Fatalf("address maps to %q", name)
	}
	// The evicted name gets a fresh address rather than the reused one.
	if again := pool.Assign("first.test"); again == first {
		t.Fatal("evicted name still owns its old address")
	}
	if pool.Contains(netip.MustParseAddr("10.0.0.1")) || pool.Contains(netip.MustParseAddr("10.0.0.255")) {
		t.Fatal("reserved addresses are in the pool")
	}
}

func TestPoolRejectsTinyOrV6Prefixes(t *testing.T) {
	for _, p := range []string{"10.0.0.0/25", "fd00::/64"} {
		if _, err := NewPool(netip.MustParsePrefix(p)); err == nil {
			t.Errorf("%s accepted", p)
		}
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for ; i > 0; i /= 10 {
		b = append([]byte{byte('0' + i%10)}, b...)
	}
	return string(b)
}
