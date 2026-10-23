package daemon

import (
	"fmt"
	"net/netip"
)

// VPN is another VPN on this machine: a tunnel interface with an IPv4
// address that is not the daemon's own.
//
// Its interface name is no way to refer to it, since utun numbers are handed
// out afresh every time a VPN connects. ID names what owns the interface
// instead: the system's VPN service, or the process holding the interface
// open. A rule naming a VPN finds it again under a new number.
type VPN struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	Interface string `json:"interface"`
	Index     int    `json:"-"`

	// Prefixes are the routes into the VPN, Domains the names its resolvers
	// answer for, DNS those resolvers. The app reads the first two to tell
	// which VPN a rule written before VPNs could be named meant.
	Prefixes []string     `json:"prefixes,omitempty"`
	Domains  []string     `json:"domains,omitempty"`
	DNS      []netip.Addr `json:"dns,omitempty"`

	// Nets are Prefixes parsed.
	Nets []netip.Prefix `json:"-"`

	// Split is set for a VPN that carries only its own networks, with no
	// route of its own for the rest of the internet.
	Split bool `json:"split"`
}

// CarriesAll says whether the VPN routes the whole internet: a full
// tunnel, with 0.0.0.0/1 and 128.0.0.0/1 or a default route into it.
func (v VPN) CarriesAll() bool {
	for _, n := range v.Nets {
		if n.Bits() < claimMinBits {
			return true
		}
	}
	return false
}

// Routes says whether ip is in one of the VPN's networks.
func (v VPN) Routes(ip netip.Addr) bool {
	ip = ip.Unmap()
	for _, n := range v.Nets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// claimMinBits is the narrowest a VPN's network may be and still be its
// own. A full-tunnel VPN routes 0.0.0.0/1 and 128.0.0.0/1: that is a claim
// on everything, which the user's default decides instead.
const claimMinBits = 8

// claims says whether a connection is the VPN's own business when no rule
// says otherwise: a name under its DNS domains, or an address in one of its
// networks. why is for the connection list.
func (v VPN) claims(domain string, ip netip.Addr) (why string, ok bool) {
	for _, d := range v.Domains {
		if underDomain(domain, d) {
			return fmt.Sprintf("domain %q of VPN %q", d, v.Name), true
		}
	}
	if ip.IsValid() {
		ip = ip.Unmap()
		for _, n := range v.Nets {
			if n.Bits() >= claimMinBits && n.Contains(ip) {
				return fmt.Sprintf("network %s of VPN %q", n, v.Name), true
			}
		}
	}
	return "", false
}

// halves splits n into its two halves.
func halves(n netip.Prefix) (netip.Prefix, netip.Prefix) {
	lo := netip.PrefixFrom(n.Masked().Addr(), n.Bits()+1)
	b := n.Masked().Addr().As4()
	bit := n.Bits()
	b[bit/8] |= 0x80 >> (bit % 8)
	return lo, netip.PrefixFrom(netip.AddrFrom4(b), n.Bits()+1)
}

// errVPNDown refuses a connection a rule sends into a VPN that is not
// connected: going direct instead would quietly put it where the rule says
// it must not go.
type errVPNDown struct{ id string }

func (e errVPNDown) Error() string { return fmt.Sprintf("VPN %s is not connected", e.id) }
