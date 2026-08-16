package tunnel

import (
	"strings"
	"testing"
)

// The JSON below is what lib/vpn/ios_vpn_bridge.dart actually sends. Keeping a
// literal copy here means a rename on the Dart side fails a test rather than
// producing a tunnel that starts and carries nothing.
const dartPayload = `{
  "hops": [
    {"host": "203.0.113.10", "port": 22, "username": "flume", "password": "hunter2"}
  ],
  "address": "10.0.0.2/30",
  "mtu": 1500,
  "dnsServers": ["8.8.8.8", "8.8.4.4"]
}`

func TestParseConfigAcceptsWhatTheAppSends(t *testing.T) {
	t.Parallel()

	cfg, err := ParseConfig([]byte(dartPayload))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}

	if len(cfg.Hops) != 1 {
		t.Fatalf("got %d hops, want 1", len(cfg.Hops))
	}

	hop := cfg.Hops[0]
	if hop.Host != "203.0.113.10" {
		t.Errorf("host = %q", hop.Host)
	}
	if hop.Port != 22 {
		t.Errorf("port = %d", hop.Port)
	}
	if hop.Username != "flume" {
		t.Errorf("username = %q", hop.Username)
	}
	if hop.Password != "hunter2" {
		t.Errorf("password did not survive the round trip")
	}
	if cfg.MTU != 1500 {
		t.Errorf("mtu = %d", cfg.MTU)
	}
	if cfg.Address != "10.0.0.2/30" {
		t.Errorf("address = %q", cfg.Address)
	}
}

func TestParseConfigKeepsPrivateKeys(t *testing.T) {
	t.Parallel()

	// Newlines inside a PEM are the thing most likely to be mangled on the way
	// through a method channel.
	payload := `{"hops":[{"host":"h","port":22,"username":"u",` +
		`"privateKeyPem":"-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n"}]}`

	cfg, err := ParseConfig([]byte(payload))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}

	key := cfg.Hops[0].PrivateKeyPEM
	if !strings.HasPrefix(key, "-----BEGIN OPENSSH PRIVATE KEY-----\n") {
		t.Errorf("key lost its structure: %q", key)
	}
	if strings.Count(key, "\n") != 3 {
		t.Errorf("expected three newlines, got %d in %q", strings.Count(key, "\n"), key)
	}
}

func TestParseConfigDefaultsTheAddress(t *testing.T) {
	t.Parallel()

	cfg, err := ParseConfig([]byte(`{"hops":[{"host":"h","username":"u","password":"p"}]}`))
	if err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	if cfg.Address != defaultAddress {
		t.Errorf("address = %q, want %q", cfg.Address, defaultAddress)
	}
}

func TestParseConfigRejections(t *testing.T) {
	t.Parallel()

	cases := []struct {
		name    string
		payload string
		wants   string
	}{
		{"not json", `{`, "valid JSON"},
		{"no hops", `{"hops":[]}`, "no hops"},
		{"hop without host", `{"hops":[{"username":"u","password":"p"}]}`, "no host"},
		{"hop without username", `{"hops":[{"host":"h","password":"p"}]}`, "no username"},
		{"hop without credentials", `{"hops":[{"host":"h","username":"u"}]}`, "neither a password nor a key"},
		{"bad address", `{"hops":[{"host":"h","username":"u","password":"p"}],"address":"10.0.0.2"}`, "address"},
	}

	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()

			_, err := ParseConfig([]byte(test.payload))
			if err == nil {
				t.Fatal("expected an error")
			}
			if !strings.Contains(err.Error(), test.wants) {
				t.Errorf("got %q, want it to mention %q", err, test.wants)
			}
		})
	}
}
