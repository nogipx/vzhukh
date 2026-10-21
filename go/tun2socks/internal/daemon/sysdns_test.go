package daemon

import (
	"net/netip"
	"reflect"
	"testing"
)

// What a Mac with a corporate VPN connected shows, trimmed.
const scutilWithVPN = `DNS configuration

resolver #1
  search domain[0] : corp.example
  search domain[1] : CorpDefaultDNS
  nameserver[0] : 172.17.6.11
  nameserver[1] : 172.17.6.12
  nameserver[2] : 192.168.1.1
  flags    : Request A records
  reach    : 0x00000002 (Reachable)

resolver #2
  domain   : local
  options  : mdns
  timeout  : 5
  order    : 300000

resolver #3
  domain   : lab.example.
  nameserver[0] : 10.9.9.9
  nameserver[1] : fe80::1%en0

DNS configuration (for scoped queries)

resolver #1
  search domain[0] : corp.example
  nameserver[0] : 8.8.8.8
  if_index : 15 (en0)
`

func addrs(ss ...string) []netip.Addr {
	var out []netip.Addr
	for _, s := range ss {
		out = append(out, netip.MustParseAddr(s))
	}
	return out
}

func TestParseScutilDNS(t *testing.T) {
	rs := parseScutilDNS(scutilWithVPN)
	if len(rs) != 3 {
		t.Fatalf("%d resolvers: %+v", len(rs), rs)
	}
	if !reflect.DeepEqual(rs[0].Search, []string{"corp.example", "corpdefaultdns"}) ||
		!reflect.DeepEqual(rs[0].Servers, addrs("172.17.6.11", "172.17.6.12", "192.168.1.1")) {
		t.Fatalf("resolver 1: %+v", rs[0])
	}
	if rs[1].Domain != "local" || len(rs[1].Servers) != 0 {
		t.Fatalf("resolver 2: %+v", rs[1])
	}
	if rs[2].Domain != "lab.example" || len(rs[2].Servers) != 2 {
		t.Fatalf("resolver 3: %+v", rs[2])
	}
}

func TestPickSystemServers(t *testing.T) {
	rs := parseScutilDNS(scutilWithVPN)
	own := netip.MustParseAddr("172.19.0.2")
	if got := pickSystemServers(rs, "git.corp.example.", own); !reflect.DeepEqual(got, addrs("172.17.6.11", "172.17.6.12", "192.168.1.1")) {
		t.Fatalf("corp: %v", got)
	}
	if got := pickSystemServers(rs, "x.lab.example", own); got[0] != netip.MustParseAddr("10.9.9.9") {
		t.Fatalf("supplemental: %v", got)
	}

	ours := []sysResolver{{Search: []string{"corp.example"}, Servers: addrs("172.19.0.2")}}
	if got := pickSystemServers(ours, "git.corp.example", own); got != nil {
		t.Fatalf("only our own resolver configured, got %v", got)
	}
}

func TestForeignPrimaryServers(t *testing.T) {
	rs := parseScutilDNS(scutilWithVPN)
	got := foreignPrimaryServers(rs, netip.MustParseAddr("172.19.0.2"))
	if !reflect.DeepEqual(got, addrs("172.17.6.11", "172.17.6.12", "192.168.1.1")) {
		t.Fatalf("got %v", got)
	}
	ours := []sysResolver{{Servers: addrs("172.19.0.2")}, {Domain: "lab", Servers: addrs("10.9.9.9")}}
	if got := foreignPrimaryServers(ours, netip.MustParseAddr("172.19.0.2")); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}
