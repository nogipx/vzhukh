package router

import (
	"net/netip"
	"strings"
	"testing"
)

func mustCompile(t *testing.T, cfg Config, routes ...string) *Router {
	t.Helper()
	r, err := Compile(cfg, routes)
	if err != nil {
		t.Fatalf("compile: %v", err)
	}
	return r
}

var viaMain = Decision{Action: ActionRoute, Route: "main"}

func TestDefaultAppliesWhenNothingMatches(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "r", Domains: []string{"example.com"}, Action: ActionDirect}},
		Default: viaMain,
	}, "main")
	got := r.Decide(Meta{Domain: "other.org", Port: 443})
	if got != viaMain {
		t.Fatalf("got %+v, want default %+v", got, viaMain)
	}
}

func TestFirstMatchWins(t *testing.T) {
	r := mustCompile(t, Config{
		Rules: []Rule{
			{ID: "first", Domains: []string{"example.com"}, Action: ActionBlock},
			{ID: "second", Domains: []string{"example.com"}, Action: ActionDirect},
		},
		Default: viaMain,
	}, "main")
	if got := r.Decide(Meta{Domain: "example.com"}); got.RuleID != "first" || got.Action != ActionBlock {
		t.Fatalf("got %+v", got)
	}
}

func TestDomainMatchesItselfAndSubdomainsOnly(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "r", Domains: []string{"Example.COM."}, Action: ActionDirect}},
		Default: viaMain,
	}, "main")
	cases := map[string]bool{
		"example.com":      true,
		"cdn.example.com":  true,
		"a.b.example.com.": true,
		"EXAMPLE.com":      true,
		"notexample.com":   false,
		"example.com.evil": false,
		"":                 false,
	}
	for domain, want := range cases {
		got := r.Decide(Meta{Domain: domain}).Action == ActionDirect
		if got != want {
			t.Errorf("%q: matched=%v, want %v", domain, got, want)
		}
	}
}

func TestWildcardPrefixIsTheSameAsTheBareDomain(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "r", Domains: []string{"*.example.com"}, Action: ActionDirect}},
		Default: viaMain,
	}, "main")
	if r.Decide(Meta{Domain: "example.com"}).Action != ActionDirect {
		t.Fatal("*.example.com should cover example.com")
	}
}

func TestAppsByPathPrefixAndByName(t *testing.T) {
	r := mustCompile(t, Config{
		Rules: []Rule{
			{ID: "tg", Apps: []string{"/Applications/Telegram.app/"}, Action: ActionDirect},
			{ID: "curl", Apps: []string{"CURL"}, Action: ActionBlock},
			{ID: "chrome", Apps: []string{"google chrome"}, Action: ActionBlock},
		},
		Default: viaMain,
	}, "main")
	cases := []struct {
		meta Meta
		want string
	}{
		{Meta{AppPath: "/Applications/Telegram.app/Contents/MacOS/Telegram"}, "tg"},
		{Meta{AppPath: "/Applications/Telegram.app"}, "tg"},
		{Meta{AppPath: "/Applications/Telegram.appx/Contents/MacOS/x"}, ""},
		{Meta{AppPath: "/usr/bin/curl", ExeName: "curl"}, "curl"},
		{Meta{AppName: "Google Chrome", ExeName: "Google Chrome Helper"}, "chrome"},
		{Meta{}, ""},
	}
	for _, c := range cases {
		if got := r.Decide(c.meta).RuleID; got != c.want {
			t.Errorf("%+v: rule %q, want %q", c.meta, got, c.want)
		}
	}
}

func TestEveryCriterionHasToMatch(t *testing.T) {
	r := mustCompile(t, Config{
		Rules: []Rule{{
			ID:      "r",
			Apps:    []string{"Safari", "Telegram"},
			Ports:   []string{"443", "8000-8999"},
			Domains: []string{"example.com"},
			Action:  ActionDirect,
		}},
		Default: viaMain,
	}, "main")
	match := func(m Meta) bool { return r.Decide(m).RuleID == "r" }

	if !match(Meta{AppName: "telegram", Domain: "example.com", Port: 8500}) {
		t.Error("all three criteria hold, rule should match")
	}
	if match(Meta{AppName: "telegram", Domain: "example.com", Port: 80}) {
		t.Error("port 80 is outside both entries")
	}
	if match(Meta{AppName: "mail", Domain: "example.com", Port: 443}) {
		t.Error("mail is not one of the apps")
	}
	if match(Meta{AppName: "safari", Port: 443}) {
		t.Error("no domain known, a domain criterion cannot hold")
	}
}

func TestDomainsAndAddressesAreAlternatives(t *testing.T) {
	r := mustCompile(t, Config{
		Rules: []Rule{{
			ID:      "corp",
			Domains: []string{"corp.example"},
			CIDRs:   []string{"172.16.0.0/12"},
			Ports:   []string{"443"},
			Action:  ActionSystem,
		}},
		Default: viaMain,
	}, "main")
	match := func(m Meta) bool { return r.Decide(m).RuleID == "corp" }

	if !match(Meta{Domain: "git.corp.example", IP: netip.MustParseAddr("198.18.0.3"), Port: 443}) {
		t.Error("the domain alone should do")
	}
	if !match(Meta{IP: netip.MustParseAddr("172.16.20.10"), Port: 443}) {
		t.Error("the address alone should do")
	}
	if match(Meta{Domain: "other.example", IP: netip.MustParseAddr("1.1.1.1"), Port: 443}) {
		t.Error("neither matches")
	}
	if match(Meta{Domain: "git.corp.example", Port: 22}) {
		t.Error("ports still have to match")
	}
}

// BypassPrefixes are the addresses of rules that leave to the system nothing
// but addresses: those can be cut out of the tunnel's routes entirely.
func TestBypassPrefixes(t *testing.T) {
	r := mustCompile(t, Config{
		Rules: []Rule{
			{ID: "gw", Domains: []string{"corp.example"}, CIDRs: []string{"203.0.113.7"}, Action: ActionSystem},
			{ID: "app", Apps: []string{"Slack"}, CIDRs: []string{"10.0.0.0/8"}, Action: ActionSystem},
			{ID: "port", CIDRs: []string{"10.1.0.0/16"}, Ports: []string{"22"}, Action: ActionSystem},
			{ID: "off", CIDRs: []string{"10.2.0.0/16"}, Action: ActionSystem, Disabled: true},
			{ID: "direct", CIDRs: []string{"10.3.0.0/16"}, Action: ActionDirect},
			{ID: "public", CIDRs: []string{"198.51.100.9", "1.0.0.0/8"}, Action: ActionDirect},
			{ID: "vpn", CIDRs: []string{"192.0.2.1"}, Action: ActionVPN, VPN: "corp"},
		},
		Default: viaMain,
	}, "main")
	got := r.BypassPrefixes()
	want := []netip.Prefix{netip.MustParsePrefix("203.0.113.7/32"), netip.MustParsePrefix("198.51.100.9/32")}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %v", got)
	}
}

func TestVPNActionNamesItsVPN(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "corp", Domains: []string{"corp.example"}, Action: ActionVPN, VPN: "app:/Applications/Corp.app", Route: "main"}},
		Default: viaMain,
	}, "main")
	got := r.Decide(Meta{Domain: "git.corp.example"})
	if got.Action != ActionVPN || got.VPN != "app:/Applications/Corp.app" || got.Route != "" {
		t.Fatalf("got %+v", got)
	}
	if _, err := Compile(Config{Rules: []Rule{{ID: "x", Action: ActionVPN}}, Default: viaMain}, []string{"main"}); err == nil {
		t.Fatal("a VPN rule without a VPN compiled")
	}
}

func TestCIDRsAndBareAddresses(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "r", CIDRs: []string{"10.0.0.0/8", "1.1.1.1", "2001:db8::/32"}, Action: ActionDirect}},
		Default: viaMain,
	}, "main")
	cases := map[string]bool{
		"10.20.30.40":     true,
		"1.1.1.1":         true,
		"1.1.1.2":         false,
		"::ffff:10.0.0.1": true,
		"2001:db8::1":     true,
		"2001:db9::1":     false,
	}
	for ip, want := range cases {
		got := r.Decide(Meta{IP: netip.MustParseAddr(ip)}).RuleID == "r"
		if got != want {
			t.Errorf("%s: matched=%v, want %v", ip, got, want)
		}
	}
	if r.Decide(Meta{}).RuleID == "r" {
		t.Error("no address known, a CIDR criterion cannot hold")
	}
}

func TestRuleWithoutCriteriaMatchesEverything(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "all", Action: ActionBlock}},
		Default: viaMain,
	}, "main")
	if r.Decide(Meta{}).RuleID != "all" {
		t.Fatal("empty rule should match")
	}
}

func TestDisabledRulesAreSkipped(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "off", Action: ActionBlock, Disabled: true}},
		Default: viaMain,
	}, "main")
	if r.Decide(Meta{}).RuleID == "off" {
		t.Fatal("disabled rule matched")
	}
}

func TestCompileRejectsMistakes(t *testing.T) {
	cases := map[string]Config{
		"unknown route":    {Rules: []Rule{{ID: "r", Action: ActionRoute, Route: "nope"}}, Default: viaMain},
		"route without id": {Rules: []Rule{{ID: "r", Action: ActionRoute}}, Default: viaMain},
		"no action":        {Rules: []Rule{{ID: "r"}}, Default: viaMain},
		"bad action":       {Rules: []Rule{{ID: "r", Action: "teleport"}}, Default: viaMain},
		"bad cidr":         {Rules: []Rule{{ID: "r", CIDRs: []string{"10.0.0/8"}, Action: ActionDirect}}, Default: viaMain},
		"bad port":         {Rules: []Rule{{ID: "r", Ports: []string{"0"}, Action: ActionDirect}}, Default: viaMain},
		"backwards range":  {Rules: []Rule{{ID: "r", Ports: []string{"9-1"}, Action: ActionDirect}}, Default: viaMain},
		"bad default":      {Default: Decision{Action: ActionRoute, Route: "gone"}},
		"empty default":    {},
	}
	for name, cfg := range cases {
		if _, err := Compile(cfg, []string{"main"}); err == nil {
			t.Errorf("%s: compiled without error", name)
		}
	}
}

func TestCompileErrorNamesTheRule(t *testing.T) {
	_, err := Compile(Config{
		Rules:   []Rule{{ID: "x", Name: "Work stuff", Action: ActionRoute, Route: "nope"}},
		Default: viaMain,
	}, []string{"main"})
	if err == nil || !strings.Contains(err.Error(), "Work stuff") {
		t.Fatalf("error %v should name the rule", err)
	}
}

func TestSystemActionTakesNoRoute(t *testing.T) {
	r := mustCompile(t, Config{
		Rules:   []Rule{{ID: "corp", Domains: []string{"corp.example"}, Action: ActionSystem, Route: "main"}},
		Default: viaMain,
	}, "main")
	got := r.Decide(Meta{Domain: "git.corp.example"})
	if got.Action != ActionSystem || got.Route != "" {
		t.Fatalf("got %+v", got)
	}
}

func TestUsesDomains(t *testing.T) {
	without := mustCompile(t, Config{Rules: []Rule{{ID: "r", Ports: []string{"22"}, Action: ActionDirect}}, Default: viaMain}, "main")
	with := mustCompile(t, Config{Rules: []Rule{{ID: "r", Domains: []string{"a.b"}, Action: ActionDirect}}, Default: viaMain}, "main")
	if without.UsesDomains() || !with.UsesDomains() {
		t.Fatal("UsesDomains is wrong")
	}
}

func TestDecideWhySaysWhatMatched(t *testing.T) {
	r, err := Compile(Config{
		Rules: []Rule{
			{ID: "tg", Apps: []string{"Telegram"}, Domains: []string{"t.me"}, Ports: []string{"443"}, Action: ActionDirect},
			{ID: "lan", CIDRs: []string{"10.0.0.0/8"}, Ports: []string{"8000-8999"}, Action: ActionBlock},
		},
		Default: viaMain,
	}, []string{"main"})
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		meta Meta
		want string
	}{
		{Meta{AppName: "Telegram", Domain: "cdn.t.me", Port: 443}, `app "telegram", domain "t.me", port 443`},
		{Meta{IP: netip.MustParseAddr("10.1.2.3"), Port: 8080}, `address 10.0.0.0/8, ports 8000-8999`},
		{Meta{Domain: "example.com", Port: 443}, ``},
	}
	for _, c := range cases {
		if _, why := r.DecideWhy(c.meta); why != c.want {
			t.Errorf("%+v: %q, want %q", c.meta, why, c.want)
		}
	}
}
