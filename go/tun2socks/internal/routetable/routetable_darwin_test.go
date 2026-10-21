package routetable

import (
	"net"
	"net/netip"
	"testing"
)

// The real table must route a public address somewhere, and the loopback
// address to the loopback interface.
func TestLoadRealTable(t *testing.T) {
	table, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if len(table.Routes) == 0 {
		t.Fatal("no routes")
	}
	lo, err := net.InterfaceByName("lo0")
	if err != nil {
		t.Skip("no lo0")
	}
	r, ok := table.Lookup(netip.MustParseAddr("127.0.0.1"), nil)
	if !ok || r.Index != lo.Index {
		t.Fatalf("127.0.0.1 -> %+v %v, want lo0 (%d)", r, ok, lo.Index)
	}
	if _, ok := table.Lookup(netip.MustParseAddr("1.1.1.1"), nil); !ok {
		t.Fatal("no route to 1.1.1.1")
	}
}
