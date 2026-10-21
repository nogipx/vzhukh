package mobile

import "testing"

func TestParseConfig(t *testing.T) {
	cfg, err := ParseConfig([]byte(`{"hops":[{"host":"h","username":"u","password":"p"}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Address != "10.0.0.2/32" || cfg.UDPGateway != "127.0.0.1:7300" {
		t.Fatalf("defaults %+v", cfg)
	}
	off, _ := ParseConfig([]byte(`{"hops":[{"host":"h","username":"u","password":"p"}],"udpGateway":"-"}`))
	if off.UDPGateway != "" {
		t.Fatalf("udp off %+v", off)
	}
	for _, bad := range []string{`{}`, `{"hops":[]}`, `nope`, `{"hops":[{"host":"h"}],"address":"x"}`} {
		if _, err := ParseConfig([]byte(bad)); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
}
