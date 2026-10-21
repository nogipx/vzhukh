package daemon

import (
	"reflect"
	"testing"
)

func TestParseDNSEntry(t *testing.T) {
	out := `<dictionary> {
  DomainName : corp.example
  SearchDomains : <array> {
    0 : corp.example
    1 : CorpDefaultDNS
  }
  ServerAddresses : <array> {
    0 : 172.17.6.11
    1 : 172.17.6.12
  }
  SupplementalMatchDomains : <array> {
    0 : corp.example
  }
  SupplementalMatchDomainsNoSearch : 1
}
`
	e := parseDNSEntry(out)
	if !reflect.DeepEqual(e.Servers, []string{"172.17.6.11", "172.17.6.12"}) ||
		!reflect.DeepEqual(e.Search, []string{"corp.example", "CorpDefaultDNS"}) ||
		!reflect.DeepEqual(e.Supplemental, []string{"corp.example"}) ||
		e.DomainName != "corp.example" {
		t.Fatalf("got %+v", e)
	}

	plain := parseDNSEntry("<dictionary> {\n  ServerAddresses : <array> {\n    0 : 192.168.0.1\n  }\n}\n")
	if !reflect.DeepEqual(plain.Servers, []string{"192.168.0.1"}) || plain.Search != nil {
		t.Fatalf("got %+v", plain)
	}

	s := &dnsState{details: map[string]dnsEntry{"a": e, "b": plain}}
	rs := s.Resolvers()
	if len(rs) != 2 {
		t.Fatalf("resolvers %+v", rs)
	}
}
