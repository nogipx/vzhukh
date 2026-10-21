// Package router decides where a connection goes: through one of the
// configured routes, straight out, or nowhere.
//
// It is pure: it sees what the daemon already knows about a connection —
// which app opened it, which domain it is for, where it is headed — and
// returns a decision. Nothing here touches the network.
package router

import (
	"errors"
	"fmt"
	"net/netip"
	"path"
	"strconv"
	"strings"
)

// Action is what happens to a matched connection.
type Action string

const (
	// ActionRoute sends the connection through the SSH chain named by Route.
	ActionRoute Action = "route"
	// ActionDirect sends it out of the physical interface, as if the tunnel
	// were not there.
	ActionDirect Action = "direct"
	// ActionBlock refuses it.
	ActionBlock Action = "block"
	// ActionSystem leaves the connection to macOS and whatever else is
	// installed: a corporate VPN, typically. Its names get real answers
	// from the resolver the system has for them, so the connection goes
	// where the system routes it and never enters the tunnel at all.
	ActionSystem Action = "system"
)

// Rule matches connections and says what to do with them.
//
// Apps, the destination and Ports each have to match when set, and within
// each any entry may: Apps [Telegram, Safari] with Ports [443] means
// "Telegram or Safari, on 443". The destination is Domains and CIDRs
// together, as alternatives: "example.com or 10.0.0.0/8", the way Proxifier
// reads its target lists. A rule with no criteria matches everything.
type Rule struct {
	ID   string `json:"id"`
	Name string `json:"name,omitempty"`

	// Apps are matched against the process that opened the connection. An
	// entry starting with "/" is a path prefix, so "/Applications/Telegram.app"
	// covers everything inside that bundle. Anything else is a name, compared
	// case-insensitively with the app's name ("Telegram") or the executable's
	// ("curl").
	Apps []string `json:"apps,omitempty"`

	// Domains match the name and every name under it: "example.com" matches
	// example.com and cdn.example.com, not notexample.com.
	Domains []string `json:"domains,omitempty"`

	// CIDRs match the destination address. A connection made by name gets a
	// placeholder address from the daemon's DNS, so these only see the real
	// address for connections made to an address directly.
	CIDRs []string `json:"cidrs,omitempty"`

	// Ports are single ports ("443") or inclusive ranges ("8000-8999").
	Ports []string `json:"ports,omitempty"`

	Action Action `json:"action"`
	Route  string `json:"route,omitempty"`

	Disabled bool `json:"disabled,omitempty"`
}

// Config is the whole rule set. Rules are tried in order and the first match
// wins; Default applies when none does.
type Config struct {
	Rules   []Rule   `json:"rules"`
	Default Decision `json:"default"`
}

// Decision is the outcome for one connection.
type Decision struct {
	Action Action `json:"action"`
	Route  string `json:"route,omitempty"`

	// RuleID is the rule that matched, empty when the default applied.
	RuleID string `json:"ruleId,omitempty"`
}

// Meta is what is known about a connection when it is decided. Any field may
// be empty: a process that exited before it was looked up has no app, a
// connection made to an address has no domain until its first bytes say.
type Meta struct {
	AppPath string
	AppName string
	ExeName string
	Domain  string
	IP      netip.Addr
	Port    uint16
}

// Router is a compiled Config.
type Router struct {
	rules []compiled
	def   Decision
}

type compiled struct {
	id      string
	system  bool
	apps    []appMatcher
	domains []string
	cidrs   []netip.Prefix
	ports   []portRange
	result  Decision
}

type appMatcher struct {
	prefix string // set for path entries
	name   string // lower-cased, set for name entries
}

type portRange struct{ lo, hi uint16 }

// Compile checks a Config and prepares it for matching. routes lists the
// route IDs that exist; a rule or default naming any other is an error, not
// something to find out when the first connection arrives.
func Compile(cfg Config, routes []string) (*Router, error) {
	known := make(map[string]bool, len(routes))
	for _, id := range routes {
		known[id] = true
	}

	def, err := checkDecision(cfg.Default, known)
	if err != nil {
		return nil, fmt.Errorf("router: default: %w", err)
	}

	r := &Router{def: def}
	for i, rule := range cfg.Rules {
		if rule.Disabled {
			continue
		}
		c, err := compile(rule, known)
		if err != nil {
			label := rule.Name
			if label == "" {
				label = rule.ID
			}
			return nil, fmt.Errorf("router: rule %d (%s): %w", i+1, label, err)
		}
		r.rules = append(r.rules, c)
	}
	return r, nil
}

func checkDecision(d Decision, known map[string]bool) (Decision, error) {
	switch d.Action {
	case ActionRoute:
		if d.Route == "" {
			return d, errors.New("action route names no route")
		}
		if !known[d.Route] {
			return d, fmt.Errorf("unknown route %q", d.Route)
		}
	case ActionDirect, ActionBlock, ActionSystem:
		d.Route = ""
	case "":
		return d, errors.New("no action")
	default:
		return d, fmt.Errorf("unknown action %q", d.Action)
	}
	return d, nil
}

func compile(rule Rule, known map[string]bool) (compiled, error) {
	result, err := checkDecision(Decision{Action: rule.Action, Route: rule.Route}, known)
	if err != nil {
		return compiled{}, err
	}
	result.RuleID = rule.ID
	c := compiled{id: rule.ID, result: result, system: result.Action == ActionSystem}

	for _, app := range rule.Apps {
		app = strings.TrimSpace(app)
		switch {
		case app == "":
		case strings.HasPrefix(app, "/"):
			c.apps = append(c.apps, appMatcher{prefix: strings.TrimSuffix(path.Clean(app), "/")})
		default:
			c.apps = append(c.apps, appMatcher{name: strings.ToLower(app)})
		}
	}

	for _, domain := range rule.Domains {
		domain = normalizeDomain(domain)
		domain = strings.TrimPrefix(domain, "*.")
		if domain != "" {
			c.domains = append(c.domains, domain)
		}
	}

	for _, cidr := range rule.CIDRs {
		cidr = strings.TrimSpace(cidr)
		if cidr == "" {
			continue
		}
		prefix, err := netip.ParsePrefix(cidr)
		if err != nil {
			// A bare address is a /32 or /128.
			addr, addrErr := netip.ParseAddr(cidr)
			if addrErr != nil {
				return compiled{}, fmt.Errorf("bad CIDR %q", cidr)
			}
			prefix = netip.PrefixFrom(addr, addr.BitLen())
		}
		c.cidrs = append(c.cidrs, prefix.Masked())
	}

	for _, spec := range rule.Ports {
		spec = strings.TrimSpace(spec)
		if spec == "" {
			continue
		}
		pr, err := parsePorts(spec)
		if err != nil {
			return compiled{}, err
		}
		c.ports = append(c.ports, pr)
	}
	return c, nil
}

func parsePorts(spec string) (portRange, error) {
	lo, hi, isRange := strings.Cut(spec, "-")
	from, err := strconv.ParseUint(strings.TrimSpace(lo), 10, 16)
	if err != nil || from == 0 {
		return portRange{}, fmt.Errorf("bad port %q", spec)
	}
	to := from
	if isRange {
		to, err = strconv.ParseUint(strings.TrimSpace(hi), 10, 16)
		if err != nil || to < from {
			return portRange{}, fmt.Errorf("bad port range %q", spec)
		}
	}
	return portRange{uint16(from), uint16(to)}, nil
}

// normalizeDomain lower-cases a name and drops the trailing dot DNS adds.
func normalizeDomain(domain string) string {
	return strings.TrimSuffix(strings.ToLower(strings.TrimSpace(domain)), ".")
}

// Decide returns what to do with a connection.
func (r *Router) Decide(m Meta) Decision {
	d, _ := r.DecideWhy(m)
	return d
}

// DecideWhy is Decide plus what of the rule matched, for people reading
// the connection list: `app "Telegram", domain "t.me", port 443`. Empty
// when the default applied or the rule has no criteria.
func (r *Router) DecideWhy(m Meta) (Decision, string) {
	m.Domain = normalizeDomain(m.Domain)
	for _, rule := range r.rules {
		if why, ok := rule.matches(m); ok {
			return rule.result, why
		}
	}
	return r.def, ""
}

func (c compiled) matches(m Meta) (string, bool) {
	var why []string
	if len(c.apps) > 0 {
		app, ok := c.matchApp(m)
		if !ok {
			return "", false
		}
		why = append(why, "app "+strconv.Quote(app))
	}
	if len(c.domains) > 0 || len(c.cidrs) > 0 {
		if d, ok := c.matchDomain(m.Domain); ok {
			why = append(why, "domain "+strconv.Quote(d))
		} else if p, ok := c.matchIP(m.IP); ok {
			why = append(why, "address "+p.String())
		} else {
			return "", false
		}
	}
	if len(c.ports) > 0 {
		pr, ok := c.matchPort(m.Port)
		if !ok {
			return "", false
		}
		if pr.lo == pr.hi {
			why = append(why, "port "+strconv.Itoa(int(pr.lo)))
		} else {
			why = append(why, fmt.Sprintf("ports %d-%d", pr.lo, pr.hi))
		}
	}
	return strings.Join(why, ", "), true
}

// matchApp returns the entry that matched, as the rule has it.
func (c compiled) matchApp(m Meta) (string, bool) {
	appName := strings.ToLower(m.AppName)
	exeName := strings.ToLower(m.ExeName)
	for _, app := range c.apps {
		if app.prefix != "" {
			if m.AppPath == app.prefix || strings.HasPrefix(m.AppPath, app.prefix+"/") {
				return app.prefix, true
			}
			continue
		}
		if app.name == appName && appName != "" || app.name == exeName && exeName != "" {
			return app.name, true
		}
	}
	return "", false
}

func (c compiled) matchDomain(domain string) (string, bool) {
	if domain == "" {
		return "", false
	}
	for _, d := range c.domains {
		if domain == d || strings.HasSuffix(domain, "."+d) {
			return d, true
		}
	}
	return "", false
}

func (c compiled) matchIP(ip netip.Addr) (netip.Prefix, bool) {
	if !ip.IsValid() {
		return netip.Prefix{}, false
	}
	ip = ip.Unmap()
	for _, prefix := range c.cidrs {
		if prefix.Contains(ip) {
			return prefix, true
		}
	}
	return netip.Prefix{}, false
}

func (c compiled) matchPort(port uint16) (portRange, bool) {
	for _, pr := range c.ports {
		if port >= pr.lo && port <= pr.hi {
			return pr, true
		}
	}
	return portRange{}, false
}

// UsesDomains reports whether any rule looks at domains. When none does,
// there is no point delaying a connection to sniff its first bytes.
func (r *Router) UsesDomains() bool {
	for _, rule := range r.rules {
		if len(rule.domains) > 0 {
			return true
		}
	}
	return false
}

// BypassPrefixes are the addresses of "leave to the system" rules that
// match by destination alone, with no apps and no ports. Whatever reaches
// them can be kept out of the tunnel by the routing table rather than by
// the rule, which is what another VPN's gateway needs: its own traffic
// never passes through here at all.
func (r *Router) BypassPrefixes() []netip.Prefix {
	var out []netip.Prefix
	for _, rule := range r.rules {
		if rule.system && len(rule.apps) == 0 && len(rule.ports) == 0 {
			out = append(out, rule.cidrs...)
		}
	}
	return out
}
