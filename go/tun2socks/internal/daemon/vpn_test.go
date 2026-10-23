package daemon

import (
	"net/netip"
	"testing"
)

func TestHalvesAreOneBitNarrower(t *testing.T) {
	for _, c := range []struct{ n, lo, hi string }{
		{"172.20.0.0/14", "172.20.0.0/15", "172.22.0.0/15"},
		{"10.64.0.0/11", "10.64.0.0/12", "10.80.0.0/12"},
		{"0.0.0.0/1", "0.0.0.0/2", "64.0.0.0/2"},
		{"10.1.2.0/24", "10.1.2.0/25", "10.1.2.128/25"},
	} {
		lo, hi := halves(netip.MustParsePrefix(c.n))
		if lo.String() != c.lo || hi.String() != c.hi {
			t.Errorf("%s: got %s %s", c.n, lo, hi)
		}
	}
}

func TestAVPNClaimsItsNetworksAndDomainsButNotEverything(t *testing.T) {
	v := VPN{
		ID:      "corp",
		Name:    "Corp",
		Domains: []string{"corp.example"},
		Nets: []netip.Prefix{
			netip.MustParsePrefix("172.16.0.0/16"),
			netip.MustParsePrefix("0.0.0.0/1"),
		},
	}
	if _, ok := v.claims("git.corp.example", netip.Addr{}); !ok {
		t.Error("its domain is not its")
	}
	if _, ok := v.claims("", netip.MustParseAddr("172.16.20.10")); !ok {
		t.Error("its network is not its")
	}
	if why, ok := v.claims("example.com", netip.MustParseAddr("8.8.8.8")); ok {
		t.Errorf("a full-tunnel route claimed everything: %s", why)
	}
}

func TestASplitVPNCarriesOnlyItsNetworks(t *testing.T) {
	split := VPN{Nets: []netip.Prefix{netip.MustParsePrefix("172.20.0.0/14"), netip.MustParsePrefix("172.20.3.161/32")}}
	if split.CarriesAll() {
		t.Error("a split VPN carries everything")
	}
	if !split.Routes(netip.MustParseAddr("172.21.9.8")) || split.Routes(netip.MustParseAddr("198.51.100.82")) {
		t.Error("networks wrong")
	}
	full := VPN{Nets: []netip.Prefix{netip.MustParsePrefix("0.0.0.0/1"), netip.MustParsePrefix("128.0.0.0/1")}}
	if !full.CarriesAll() {
		t.Error("a full tunnel does not carry everything")
	}
}
