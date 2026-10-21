package routetable

import (
	"net/netip"

	"golang.org/x/net/route"
	"golang.org/x/sys/unix"
)

// Load reads the kernel's routing table. Scoped routes (route -ifscope)
// are left out: they apply only to sockets already bound to their
// interface, which is the question being answered, not an input to it.
func Load() (Table, error) {
	var t Table
	for _, af := range []int{unix.AF_INET, unix.AF_INET6} {
		rib, err := route.FetchRIB(af, route.RIBTypeRoute, 0)
		if err != nil {
			return Table{}, err
		}
		msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
		if err != nil {
			return Table{}, err
		}
		for _, m := range msgs {
			rm, ok := m.(*route.RouteMessage)
			if !ok || rm.Flags&unix.RTF_UP == 0 ||
				rm.Flags&(unix.RTF_IFSCOPE|unix.RTF_REJECT|unix.RTF_BLACKHOLE) != 0 {
				continue
			}
			if prefix, ok := prefixOf(rm); ok {
				t.Routes = append(t.Routes, Route{Prefix: prefix, Index: rm.Index})
			}
		}
	}
	return t, nil
}

// Entries reads every IPv4 route, scoped ones included.
func Entries() ([]Entry, error) {
	rib, err := route.FetchRIB(unix.AF_INET, route.RIBTypeRoute, 0)
	if err != nil {
		return nil, err
	}
	msgs, err := route.ParseRIB(route.RIBTypeRoute, rib)
	if err != nil {
		return nil, err
	}
	var out []Entry
	for _, m := range msgs {
		rm, ok := m.(*route.RouteMessage)
		if !ok || rm.Flags&unix.RTF_UP == 0 {
			continue
		}
		prefix, ok := prefixOf(rm)
		if !ok {
			continue
		}
		e := Entry{Prefix: prefix, Index: rm.Index, Scoped: rm.Flags&unix.RTF_IFSCOPE != 0}
		if rm.Flags&unix.RTF_GATEWAY != 0 && len(rm.Addrs) > unix.RTAX_GATEWAY {
			if gw, ok := rm.Addrs[unix.RTAX_GATEWAY].(*route.Inet4Addr); ok {
				e.Gateway = netip.AddrFrom4(gw.IP)
			}
		}
		out = append(out, e)
	}
	return out, nil
}

func prefixOf(rm *route.RouteMessage) (netip.Prefix, bool) {
	if len(rm.Addrs) <= unix.RTAX_DST || rm.Addrs[unix.RTAX_DST] == nil {
		return netip.Prefix{}, false
	}
	var addr netip.Addr
	switch a := rm.Addrs[unix.RTAX_DST].(type) {
	case *route.Inet4Addr:
		addr = netip.AddrFrom4(a.IP)
	case *route.Inet6Addr:
		addr = netip.AddrFrom16(a.IP)
	default:
		return netip.Prefix{}, false
	}
	if rm.Flags&unix.RTF_HOST != 0 {
		return netip.PrefixFrom(addr, addr.BitLen()), true
	}

	bits := 0
	if len(rm.Addrs) > unix.RTAX_NETMASK && rm.Addrs[unix.RTAX_NETMASK] != nil {
		var mask []byte
		switch m := rm.Addrs[unix.RTAX_NETMASK].(type) {
		case *route.Inet4Addr:
			mask = m.IP[:]
		case *route.Inet6Addr:
			mask = m.IP[:]
		}
		for _, b := range mask {
			for i := 7; i >= 0; i-- {
				if b&(1<<i) == 0 {
					goto done
				}
				bits++
			}
		}
	done:
	}
	return netip.PrefixFrom(addr, bits).Masked(), true
}
