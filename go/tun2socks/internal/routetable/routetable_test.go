package routetable

import (
	"net/netip"
	"testing"
)

func TestLookupPrefersTheLongestPrefixNotSkipped(t *testing.T) {
	const wifi, tunnel, corp = 15, 20, 30
	table := Table{Routes: []Route{
		{netip.MustParsePrefix("0.0.0.0/0"), wifi},
		{netip.MustParsePrefix("0.0.0.0/1"), tunnel},
		{netip.MustParsePrefix("128.0.0.0/1"), tunnel},
		{netip.MustParsePrefix("172.16.0.0/12"), corp},
		{netip.MustParsePrefix("192.168.1.0/24"), wifi},
		{netip.MustParsePrefix("172.17.6.11/32"), tunnel},
		{netip.MustParsePrefix("::/0"), wifi},
	}}
	skipTunnel := func(i int) bool { return i == tunnel }

	cases := map[string]int{
		"1.1.1.1":      wifi,
		"172.16.20.10": corp,
		"172.17.6.11":  corp, // the tunnel's /32 is skipped, corp's /12 remains
		"192.168.1.1":  wifi,
		"2001:db8::1":  wifi,
	}
	for ip, want := range cases {
		r, ok := table.Lookup(netip.MustParseAddr(ip), skipTunnel)
		if !ok || r.Index != want {
			t.Errorf("%s: got %+v %v, want index %d", ip, r, ok, want)
		}
	}

	if r, _ := table.Lookup(netip.MustParseAddr("1.1.1.1"), nil); r.Index != tunnel {
		t.Errorf("without skipping, 0/1 should win: %+v", r)
	}
	if _, ok := (Table{}).Lookup(netip.MustParseAddr("1.1.1.1"), nil); ok {
		t.Error("empty table found a route")
	}
}

func TestHas(t *testing.T) {
	gw := netip.MustParseAddr("192.168.1.1")
	entries := []Entry{
		{Prefix: netip.MustParsePrefix("203.0.113.10/32"), Index: 15, Gateway: gw},
		{Prefix: netip.MustParsePrefix("198.19.0.0/30"), Index: 20},
		{Prefix: netip.MustParsePrefix("0.0.0.0/0"), Index: 15, Gateway: gw, Scoped: true},
	}
	if !Has(entries, netip.MustParsePrefix("203.0.113.10/32"), false, gw, 0) {
		t.Error("gateway host route not found")
	}
	if Has(entries, netip.MustParsePrefix("203.0.113.10/32"), false, netip.MustParseAddr("10.0.0.1"), 0) {
		t.Error("matched a different gateway")
	}
	if !Has(entries, netip.MustParsePrefix("198.19.0.1/30"), false, netip.Addr{}, 20) {
		t.Error("interface route not found")
	}
	if Has(entries, netip.MustParsePrefix("198.19.0.0/30"), false, netip.Addr{}, 21) {
		t.Error("matched a different interface")
	}
	if !Has(entries, netip.MustParsePrefix("0.0.0.0/0"), true, gw, 0) || Has(entries, netip.MustParsePrefix("0.0.0.0/0"), false, gw, 0) {
		t.Error("scoped and unscoped confused")
	}
}
