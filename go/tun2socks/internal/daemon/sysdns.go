package daemon

import (
	"net/netip"
	"strings"
)

// sysResolver is one resolver from macOS's DNS configuration (scutil --dns).
type sysResolver struct {
	// Domain is set for a supplemental resolver, one that answers only for
	// names under it.
	Domain  string
	Search  []string
	Servers []netip.Addr
}

// parseScutilDNS reads the first section of `scutil --dns`, the resolvers
// for unscoped queries, and stops at the scoped section after it.
func parseScutilDNS(out string) []sysResolver {
	var resolvers []sysResolver
	var cur *sysResolver
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "DNS configuration (") && len(resolvers) > 0:
			return resolvers
		case strings.HasPrefix(line, "resolver #"):
			resolvers = append(resolvers, sysResolver{})
			cur = &resolvers[len(resolvers)-1]
		case cur == nil:
		default:
			key, value, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			key, value = strings.TrimSpace(key), strings.TrimSpace(value)
			switch {
			case key == "domain":
				cur.Domain = strings.TrimSuffix(strings.ToLower(value), ".")
			case strings.HasPrefix(key, "search domain"):
				cur.Search = append(cur.Search, strings.TrimSuffix(strings.ToLower(value), "."))
			case strings.HasPrefix(key, "nameserver"):
				if addr, err := netip.ParseAddr(value); err == nil {
					cur.Servers = append(cur.Servers, addr)
				}
			}
		}
	}
	return resolvers
}

func underDomain(name, domain string) bool {
	return domain != "" && (name == domain || strings.HasSuffix(name, "."+domain))
}

// pickSystemServers chooses who to ask about name the way macOS would,
// leaving out the tunnel's own address: the supplemental resolver with the
// longest matching domain, else a general resolver whose search domains
// cover the name, else the first general resolver with servers.
func pickSystemServers(resolvers []sysResolver, name string, own netip.Addr) []netip.Addr {
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	usable := func(r sysResolver) []netip.Addr {
		var out []netip.Addr
		for _, s := range r.Servers {
			if s != own {
				out = append(out, s)
			}
		}
		return out
	}

	best, bestLen := []netip.Addr(nil), -1
	for _, r := range resolvers {
		if underDomain(name, r.Domain) && len(r.Domain) > bestLen {
			if servers := usable(r); len(servers) > 0 {
				best, bestLen = servers, len(r.Domain)
			}
		}
	}
	if best != nil {
		return best
	}
	for _, r := range resolvers {
		if r.Domain != "" {
			continue
		}
		for _, s := range r.Search {
			if underDomain(name, s) {
				if servers := usable(r); len(servers) > 0 {
					return servers
				}
			}
		}
	}
	for _, r := range resolvers {
		if r.Domain == "" {
			if servers := usable(r); len(servers) > 0 {
				return servers
			}
		}
	}
	return nil
}

// foreignPrimaryServers are the general (not supplemental) resolvers other
// than the tunnel's. While the tunnel runs there should be none: another
// VPN that makes itself the primary resolver is the reason for one, and
// its servers are routed into the tunnel so its DNS keeps being answered
// here.
func foreignPrimaryServers(resolvers []sysResolver, own netip.Addr) []netip.Addr {
	seen := map[netip.Addr]bool{}
	var out []netip.Addr
	for _, r := range resolvers {
		if r.Domain != "" {
			continue
		}
		for _, s := range r.Servers {
			if s == own || seen[s] || s.IsLoopback() || s.IsLinkLocalUnicast() || s.Zone() != "" {
				continue
			}
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}
